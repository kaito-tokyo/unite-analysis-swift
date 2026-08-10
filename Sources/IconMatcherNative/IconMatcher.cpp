// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#include "IconMatcher.hpp"

#include "descriptor_database.pb.h"
#include <pb_decode.h>

#include <opencv2/core.hpp>
#include <opencv2/features.hpp>
#include <opencv2/imgproc.hpp>
#include <opencv2/xfeatures2d.hpp>

#include <algorithm>
#include <cmath>
#include <exception>
#include <fstream>
#include <limits>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace unite_analysis {

bool isAkazeAvailable() noexcept {
  try {
    const auto detector = cv::xfeatures2d::AKAZE::create(
        cv::xfeatures2d::AKAZE::DESCRIPTOR_MLDB,
        0,
        3,
        0.001F);
    return !detector.empty() &&
        detector->getDescriptorType() == cv::xfeatures2d::AKAZE::DESCRIPTOR_MLDB;
  } catch (...) {
    return false;
  }
}

namespace {

constexpr std::uint32_t kSupportedFormatVersion = 2;
constexpr std::size_t kMaximumDatabaseBytes = 64 * 1024 * 1024;
constexpr int kMaximumEntries = 4096;
constexpr std::uint64_t kMaximumDescriptorsPerEntry = 1'000'000;
constexpr float kHeldCircleEdgeFraction = 0.49F;
constexpr float kHeldPaddingFraction = 0.20F;

void setError(std::string &destination, const char *message) noexcept {
  try {
    destination = message;
  } catch (...) {
    destination.clear();
  }
}

struct RankedMatch {
  std::string name;
  float score;
};

struct AkazeConfiguration {
  std::uint32_t descriptorSize = 0;
  float threshold = 0;
  std::uint32_t imageHeight = 0;
};

struct DescriptorEntry {
  std::string name;
  ItemCategory category = ItemCategory::unspecified;
  std::uint32_t rows = 0;
  std::uint32_t columns = 0;
  std::vector<std::uint8_t> descriptors;
};

struct DescriptorDatabase {
  std::uint32_t formatVersion = 0;
  std::string databaseID;
  std::string createdAt;
  bool hasAkaze = false;
  AkazeConfiguration akaze;
  std::vector<DescriptorEntry> entries;
};

using WireDatabase =
    tokyo_kaito_unite_analysis_descriptors_v1_DescriptorDatabase;
using WireEntry = tokyo_kaito_unite_analysis_descriptors_v1_DescriptorEntry;

bool decodeString(pb_istream_t *stream, const pb_field_t *, void **argument) {
  auto &value = *static_cast<std::string *>(*argument);
  if (stream->bytes_left > kMaximumDatabaseBytes) {
    PB_RETURN_ERROR(stream, "string field is too large");
  }
  value.resize(stream->bytes_left);
  return pb_read(
      stream,
      reinterpret_cast<pb_byte_t *>(value.data()),
      stream->bytes_left);
}

bool decodeBytes(pb_istream_t *stream, const pb_field_t *, void **argument) {
  auto &value = *static_cast<std::vector<std::uint8_t> *>(*argument);
  if (stream->bytes_left > kMaximumDatabaseBytes) {
    PB_RETURN_ERROR(stream, "bytes field is too large");
  }
  value.resize(stream->bytes_left);
  return pb_read(stream, value.data(), stream->bytes_left);
}

bool decodeEntry(pb_istream_t *stream, const pb_field_t *, void **argument) {
  auto &database = *static_cast<DescriptorDatabase *>(*argument);
  if (database.entries.size() >= kMaximumEntries) {
    PB_RETURN_ERROR(stream, "descriptor database contains too many entries");
  }

  DescriptorEntry entry;
  WireEntry wire =
      tokyo_kaito_unite_analysis_descriptors_v1_DescriptorEntry_init_zero;
  wire.name.funcs.decode = decodeString;
  wire.name.arg = &entry.name;
  wire.descriptors.funcs.decode = decodeBytes;
  wire.descriptors.arg = &entry.descriptors;
  if (!pb_decode(
          stream,
          tokyo_kaito_unite_analysis_descriptors_v1_DescriptorEntry_fields,
          &wire)) {
    return false;
  }

  switch (wire.category) {
  case tokyo_kaito_unite_analysis_descriptors_v1_ItemCategory_ITEM_CATEGORY_UNSPECIFIED:
  case tokyo_kaito_unite_analysis_descriptors_v1_ItemCategory_ITEM_CATEGORY_HELD:
  case tokyo_kaito_unite_analysis_descriptors_v1_ItemCategory_ITEM_CATEGORY_BATTLE:
    entry.category = static_cast<ItemCategory>(wire.category);
    break;
  default:
    PB_RETURN_ERROR(stream, "descriptor entry has an unsupported category");
  }
  entry.rows = wire.rows;
  entry.columns = wire.columns;
  database.entries.push_back(std::move(entry));
  return true;
}

bool decodeDatabase(
    const std::vector<std::uint8_t> &bytes,
    DescriptorDatabase &database,
    std::string &error) {
  WireDatabase wire =
      tokyo_kaito_unite_analysis_descriptors_v1_DescriptorDatabase_init_zero;
  wire.entries.funcs.decode = decodeEntry;
  wire.entries.arg = &database;
  wire.database_id.funcs.decode = decodeString;
  wire.database_id.arg = &database.databaseID;
  wire.created_at.funcs.decode = decodeString;
  wire.created_at.arg = &database.createdAt;
  auto stream = pb_istream_from_buffer(bytes.data(), bytes.size());
  if (!pb_decode(
          &stream,
          tokyo_kaito_unite_analysis_descriptors_v1_DescriptorDatabase_fields,
          &wire)) {
    error = std::string("could not parse descriptor database: ") +
        PB_GET_ERROR(&stream);
    return false;
  }
  database.formatVersion = wire.format_version;
  database.hasAkaze = wire.has_akaze;
  database.akaze = {
      wire.akaze.descriptor_size,
      wire.akaze.threshold,
      wire.akaze.image_height,
  };
  return true;
}

cv::Ptr<cv::xfeatures2d::AKAZE> makeDetector(
    const AkazeConfiguration &configuration) {
  return cv::xfeatures2d::AKAZE::create(
      cv::xfeatures2d::AKAZE::DESCRIPTOR_MLDB,
      static_cast<int>(configuration.descriptorSize),
      3,
      configuration.threshold);
}

cv::Mat inputBGR(
    const std::uint8_t *bytes,
    const std::size_t byteCount,
    const std::uint32_t width,
    const std::uint32_t height,
    const std::size_t bytesPerRow) {
  if (bytes == nullptr || width == 0 || height == 0 ||
      bytesPerRow < static_cast<std::size_t>(width) * 3 ||
      byteCount < bytesPerRow * height || width > INT_MAX || height > INT_MAX ||
      bytesPerRow > static_cast<std::size_t>(INT_MAX)) {
    return {};
  }
  return cv::Mat(
      static_cast<int>(height),
      static_cast<int>(width),
      CV_8UC3,
      const_cast<std::uint8_t *>(bytes),
      bytesPerRow);
}

std::vector<RankedMatch> rankDescriptors(
    const DescriptorDatabase &database,
    const cv::Mat &query,
    const ItemCategory category,
    const std::size_t limit,
    const float ratio) {
  if (query.empty() || limit == 0 || !(ratio > 0 && ratio < 1)) {
    return {};
  }

  std::vector<cv::Mat> matrices;
  std::vector<std::pair<std::size_t, const std::string *>> labelRanges;
  std::map<std::string, double> votes;
  std::size_t descriptorCount = 0;
  for (const auto &entry : database.entries) {
    if (entry.category != category) {
      continue;
    }
    matrices.emplace_back(
        static_cast<int>(entry.rows),
        static_cast<int>(entry.columns),
        CV_8U,
        const_cast<std::uint8_t *>(entry.descriptors.data()));
    descriptorCount += entry.rows;
    labelRanges.emplace_back(descriptorCount, &entry.name);
    votes.try_emplace(entry.name, 0.0);
  }
  if (matrices.empty()) {
    return {};
  }

  cv::Mat search;
  cv::vconcat(matrices, search);
  std::vector<std::vector<cv::DMatch>> matches;
  cv::DescriptorMatcher::create("BruteForce-Hamming")
      ->knnMatch(query, search, matches, 2);
  for (const auto &pair : matches) {
    if (pair.size() != 2 || pair[0].trainIdx < 0) {
      continue;
    }
    const auto trainIndex = static_cast<std::size_t>(pair[0].trainIdx);
    const auto label = std::upper_bound(
        labelRanges.begin(),
        labelRanges.end(),
        trainIndex,
        [](const std::size_t index, const auto &range) {
          return index < range.first;
        });
    if (label == labelRanges.end()) {
      continue;
    }
    const auto first = static_cast<double>(pair[0].distance);
    const auto second = static_cast<double>(pair[1].distance);
    if (first < static_cast<double>(ratio) * second) {
      votes[*label->second] += 1.0 - first / std::max(second, 1e-9);
    }
  }

  std::vector<RankedMatch> result;
  result.reserve(votes.size());
  for (const auto &[name, score] : votes) {
    if (score > 0) {
      result.push_back({name, static_cast<float>(score)});
    }
  }
  std::sort(result.begin(), result.end(), [](const auto &left, const auto &right) {
    return left.score != right.score ? left.score > right.score
                                           : left.name < right.name;
  });
  if (result.size() > limit) {
    result.resize(limit);
  }
  return result;
}

cv::Mat prepareHeldImage(
    const cv::Mat &source,
    const int imageHeight,
    const float radiusFraction) {
  if (source.empty() || !(radiusFraction > 0 && radiusFraction <= 0.5F)) {
    return {};
  }
  const int side = std::max(
      4,
      static_cast<int>(std::lround(
          std::min(source.cols, source.rows) * radiusFraction * 2)));
  const int x = std::max(0, source.cols / 2 - side / 2);
  const int y = std::max(0, source.rows / 2 - side / 2);
  const int croppedSide = std::min({side, source.cols - x, source.rows - y});
  const auto crop = source(cv::Rect(x, y, croppedSide, croppedSide));
  cv::Mat circleMask = cv::Mat::zeros(crop.size(), CV_8U);
  const int circleCenterX = crop.cols / 2;
  const int circleCenterY = crop.rows / 2;
  const int circleRadius = static_cast<int>(
      std::lround(std::min(crop.cols, crop.rows) * kHeldCircleEdgeFraction));
  for (int row = 0; row < crop.rows; ++row) {
    auto *maskRow = circleMask.ptr<std::uint8_t>(row);
    for (int column = 0; column < crop.cols; ++column) {
      const int dx = column - circleCenterX;
      const int dy = row - circleCenterY;
      maskRow[column] = dx * dx + dy * dy <= circleRadius * circleRadius ? 255 : 0;
    }
  }
  cv::Mat circular(crop.size(), crop.type(), cv::Scalar(255, 255, 255));
  crop.copyTo(circular, circleMask);
  const int padding = static_cast<int>(std::lround(croppedSide * kHeldPaddingFraction));
  cv::Mat padded;
  cv::copyMakeBorder(
      circular,
      padded,
      padding,
      padding,
      padding,
      padding,
      cv::BORDER_CONSTANT,
      cv::Scalar(255, 255, 255));
  cv::Mat scaled;
  cv::resize(padded, scaled, cv::Size(imageHeight, imageHeight), 0, 0, cv::INTER_LINEAR);
  return scaled;
}

cv::Mat prepareBattleImage(const cv::Mat &source, const int imageHeight) {
  if (source.empty()) {
    return {};
  }
  cv::Mat scaled;
  cv::resize(source, scaled, cv::Size(imageHeight, imageHeight), 0, 0, cv::INTER_LINEAR);
  return scaled;
}

cv::Mat battleImageMask(const cv::Size size) {
  const int inset = static_cast<int>(std::lround(size.height * 0.08));
  const int centerX = size.width / 2;
  const int centerY = size.height / 2;
  const int diamondRadius = std::min(centerX, centerY) - inset;
  cv::Mat mask = cv::Mat::zeros(size, CV_8U);
  for (int row = 0; row < mask.rows; ++row) {
    auto *maskRow = mask.ptr<std::uint8_t>(row);
    for (int column = 0; column < mask.cols; ++column) {
      maskRow[column] =
          std::abs(column - centerX) + std::abs(row - centerY) <= diamondRadius ? 255 : 0;
    }
  }
  return mask;
}

bool isRFC3339UTC(const std::string &value) {
  if (value.size() < 20 || value[4] != '-' || value[7] != '-' ||
      value[10] != 'T' || value[13] != ':' || value[16] != ':' ||
      value.back() != 'Z') {
    return false;
  }
  for (const auto index : {0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18}) {
    if (value[index] < '0' || value[index] > '9') {
      return false;
    }
  }
  if (value.size() > 20) {
    if (value[19] != '.' || value.size() == 21) {
      return false;
    }
    for (std::size_t index = 20; index + 1 < value.size(); ++index) {
      if (value[index] < '0' || value[index] > '9') {
        return false;
      }
    }
  }
  const auto number = [&value](const std::size_t offset, const std::size_t count) {
    int result = 0;
    for (std::size_t index = offset; index < offset + count; ++index) {
      result = result * 10 + value[index] - '0';
    }
    return result;
  };
  const int year = number(0, 4);
  const int month = number(5, 2);
  const int day = number(8, 2);
  const int hour = number(11, 2);
  const int minute = number(14, 2);
  const int second = number(17, 2);
  if (year == 0 || month < 1 || month > 12 || hour > 23 || minute > 59 ||
      second > 59) {
    return false;
  }
  constexpr int daysPerMonth[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
  int maximumDay = daysPerMonth[month - 1];
  if (month == 2 && (year % 400 == 0 || (year % 4 == 0 && year % 100 != 0))) {
    maximumDay = 29;
  }
  return day >= 1 && day <= maximumDay;
}

std::string validate(const DescriptorDatabase &database) {
  if (database.formatVersion != kSupportedFormatVersion) {
    return "unsupported descriptor database format version";
  }
  const auto isHex = [](const char character) {
    return (character >= '0' && character <= '9') ||
        (character >= 'a' && character <= 'f') ||
        (character >= 'A' && character <= 'F');
  };
  if (database.databaseID.size() != 36 ||
      database.databaseID[8] != '-' || database.databaseID[13] != '-' ||
      database.databaseID[18] != '-' || database.databaseID[23] != '-' ||
      database.databaseID[14] != '4') {
    return "descriptor database id must be a UUIDv4";
  }
  for (std::size_t index = 0; index < database.databaseID.size(); ++index) {
    if (index != 8 && index != 13 && index != 18 && index != 23 &&
        !isHex(database.databaseID[index])) {
      return "descriptor database id must be a UUIDv4";
    }
  }
  const char variant = database.databaseID[19];
  if (variant != '8' && variant != '9' && variant != 'a' && variant != 'A' &&
      variant != 'b' && variant != 'B') {
    return "descriptor database id must be a UUIDv4";
  }
  if (!isRFC3339UTC(database.createdAt)) {
    return "descriptor database creation time must be RFC 3339 UTC";
  }
  if (!database.hasAkaze) {
    return "descriptor database has no AKAZE configuration";
  }
  const auto &akaze = database.akaze;
  if (akaze.descriptorSize > 486) {
    return "AKAZE descriptor size exceeds MLDB capacity";
  }
  if (!std::isfinite(akaze.threshold) || akaze.threshold <= 0) {
    return "AKAZE threshold must be positive and finite";
  }
  if (akaze.imageHeight < 4 || akaze.imageHeight > 4096) {
    return "AKAZE image height is outside the supported range";
  }
  if (database.entries.size() > kMaximumEntries) {
    return "descriptor database contains too many entries";
  }

  std::uint64_t heldDescriptors = 0;
  std::uint64_t battleDescriptors = 0;
  for (const auto &entry : database.entries) {
    if (entry.name.empty()) {
      return "descriptor entry has an empty name";
    }
    const auto *bytes = reinterpret_cast<const unsigned char *>(entry.name.data());
    for (std::size_t index = 0; index < entry.name.size();) {
      const auto first = bytes[index];
      std::size_t length = 0;
      if (first <= 0x7F) {
        length = 1;
      } else if (first >= 0xC2 && first <= 0xDF) {
        length = 2;
      } else if (first >= 0xE0 && first <= 0xEF) {
        length = 3;
      } else if (first >= 0xF0 && first <= 0xF4) {
        length = 4;
      } else {
        return "descriptor entry name is not valid UTF-8";
      }
      if (index + length > entry.name.size()) {
        return "descriptor entry name is not valid UTF-8";
      }
      for (std::size_t offset = 1; offset < length; ++offset) {
        if ((bytes[index + offset] & 0xC0) != 0x80) {
          return "descriptor entry name is not valid UTF-8";
        }
      }
      if ((first == 0xE0 && bytes[index + 1] < 0xA0) ||
          (first == 0xED && bytes[index + 1] >= 0xA0) ||
          (first == 0xF0 && bytes[index + 1] < 0x90) ||
          (first == 0xF4 && bytes[index + 1] >= 0x90)) {
        return "descriptor entry name is not valid UTF-8";
      }
      index += length;
    }
    if (entry.rows == 0 || entry.columns == 0) {
      return "descriptor entry has an empty matrix";
    }
    const std::uint32_t descriptorBits =
        akaze.descriptorSize == 0 ? 486 : akaze.descriptorSize;
    if (entry.columns != (descriptorBits + 7) / 8) {
      return "descriptor matrix width does not match the AKAZE configuration";
    }
    if (entry.rows > kMaximumDescriptorsPerEntry) {
      return "descriptor entry contains too many descriptors";
    }
    const std::uint64_t expectedSize =
        static_cast<std::uint64_t>(entry.rows) * entry.columns;
    if (expectedSize != entry.descriptors.size()) {
      return "descriptor matrix dimensions do not match its byte count";
    }

    const cv::Mat view(
        static_cast<int>(entry.rows),
        static_cast<int>(entry.columns),
        CV_8U,
        const_cast<std::uint8_t *>(entry.descriptors.data()));
    if (!view.isContinuous()) {
      return "descriptor matrix is not continuous";
    }
    switch (entry.category) {
    case ItemCategory::held:
      heldDescriptors += entry.rows;
      break;
    case ItemCategory::battle:
      battleDescriptors += entry.rows;
      break;
    case ItemCategory::unspecified:
      return "descriptor entry has an unspecified category";
    }
  }
  if (heldDescriptors == 1 || battleDescriptors == 1) {
    return "each populated descriptor category needs at least two descriptors";
  }
  return {};
}

}  // namespace

class IconMatcher::Implementation final {
 public:
  DescriptorDatabase message;
  std::string databaseError;
  mutable std::string operationError;
};

struct IconMatchResults::Value final {
  std::vector<RankedMatch> matches;
};

struct PreparedIconImage::Value final {
  std::uint32_t width = 0;
  std::uint32_t height = 0;
  std::vector<std::uint8_t> bytes;
  std::vector<std::uint8_t> mask;
};

class IconDescriptors::Implementation final {
 public:
  cv::Mat descriptors;
  std::string error;
};

IconDescriptors::IconDescriptors(
    const std::uint8_t *bytes,
    const std::size_t byteCount,
    const std::uint32_t width,
    const std::uint32_t height,
    const std::size_t bytesPerRow,
    const std::uint32_t imageHeight,
    const std::uint32_t descriptorSize,
    const float threshold,
    const float paddingFraction) noexcept
    : implementation_(nullptr) {
  try {
    implementation_ = std::make_shared<Implementation>();
    if (bytes == nullptr || width == 0 || height == 0 ||
        bytesPerRow < static_cast<std::size_t>(width) * 4 ||
        bytesPerRow > std::numeric_limits<std::size_t>::max() / height ||
        byteCount < bytesPerRow * height || imageHeight < 4 || imageHeight > 4096 ||
        descriptorSize > 486 ||
        !std::isfinite(threshold) || threshold <= 0 ||
        !std::isfinite(paddingFraction) || paddingFraction < 0 || paddingFraction > 1) {
      implementation_->error = "invalid descriptor source image or configuration";
      return;
    }
    const cv::Mat source(
        static_cast<int>(height),
        static_cast<int>(width),
        CV_8UC4,
        const_cast<std::uint8_t *>(bytes),
        bytesPerRow);
    const int padding = static_cast<int>(std::lround(height * paddingFraction));
    cv::Mat padded;
    cv::copyMakeBorder(
        source,
        padded,
        padding,
        padding,
        padding,
        padding,
        cv::BORDER_CONSTANT,
        cv::Scalar(0, 0, 0, 0));
    const auto scaledWidthValue =
        static_cast<std::uint64_t>(padded.cols) * imageHeight / padded.rows;
    if (scaledWidthValue > 4096) {
      implementation_->error = "resized descriptor image exceeds 4096 pixels in width";
      return;
    }
    const int scaledWidth = std::max(1, static_cast<int>(scaledWidthValue));
    cv::Mat scaled;
    cv::resize(
        padded,
        scaled,
        cv::Size(scaledWidth, static_cast<int>(imageHeight)),
        0,
        0,
        cv::INTER_LINEAR);
    std::vector<cv::Mat> channels;
    cv::split(scaled, channels);
    cv::Mat bgr;
    cv::merge(std::vector<cv::Mat>{channels[0], channels[1], channels[2]}, bgr);
    const cv::Mat inverseAlpha = 255 - channels[3];
    cv::Mat inverseAlphaBGR;
    cv::merge(
        std::vector<cv::Mat>{inverseAlpha, inverseAlpha, inverseAlpha},
        inverseAlphaBGR);
    cv::add(bgr, inverseAlphaBGR, bgr);
    const int kernelSizeCandidate = std::max(3, static_cast<int>(std::lround(imageHeight * 17.0 / 512.0)));
    const int kernelSize = kernelSizeCandidate % 2 == 0 ? kernelSizeCandidate + 1 : kernelSizeCandidate;
    cv::Mat mask = cv::Mat::zeros(channels[3].size(), CV_8U);
    const int radius = kernelSize / 2;
    const int integralColumns = mask.cols + 1;
    std::vector<int> integral(static_cast<std::size_t>(mask.rows + 1) * integralColumns, 0);
    for (int row = 0; row < mask.rows; ++row) {
      const auto *alphaRow = channels[3].ptr<std::uint8_t>(row);
      int rowSum = 0;
      for (int column = 0; column < mask.cols; ++column) {
        rowSum += alphaRow[column] > 8 ? 1 : 0;
        integral[static_cast<std::size_t>(row + 1) * integralColumns + column + 1] =
            integral[static_cast<std::size_t>(row) * integralColumns + column + 1] + rowSum;
      }
    }
    for (int row = 0; row < mask.rows; ++row) {
      auto *maskRow = mask.ptr<std::uint8_t>(row);
      for (int column = 0; column < mask.cols; ++column) {
        const int top = std::max(0, row - radius);
        const int left = std::max(0, column - radius);
        const int bottom = std::min(mask.rows, row + radius + 1);
        const int right = std::min(mask.cols, column + radius + 1);
        const int sum =
            integral[static_cast<std::size_t>(bottom) * integralColumns + right] -
            integral[static_cast<std::size_t>(top) * integralColumns + right] -
            integral[static_cast<std::size_t>(bottom) * integralColumns + left] +
            integral[static_cast<std::size_t>(top) * integralColumns + left];
        maskRow[column] = sum > 0 ? 255 : 0;
      }
    }
    std::vector<cv::KeyPoint> keypoints;
    auto detector = cv::xfeatures2d::AKAZE::create(
        cv::xfeatures2d::AKAZE::DESCRIPTOR_MLDB,
        static_cast<int>(descriptorSize),
        3,
        threshold);
    detector->detectAndCompute(bgr, mask, keypoints, implementation_->descriptors);
    if (implementation_->descriptors.empty()) {
      implementation_->error = "AKAZE produced no descriptors";
    }
  } catch (const std::exception &error) {
    if (implementation_ != nullptr) {
      setError(implementation_->error, error.what());
    }
  } catch (...) {
    if (implementation_ != nullptr) {
      setError(implementation_->error, "unknown descriptor generation error");
    }
  }
}

bool IconDescriptors::isValid() const noexcept {
  return implementation_ != nullptr && implementation_->error.empty();
}

std::string IconDescriptors::errorMessage() const {
  return implementation_ == nullptr ? "descriptor generation is unavailable"
                                    : implementation_->error;
}

std::uint32_t IconDescriptors::rows() const noexcept {
  return isValid() ? static_cast<std::uint32_t>(implementation_->descriptors.rows) : 0;
}

std::uint32_t IconDescriptors::columns() const noexcept {
  return isValid() ? static_cast<std::uint32_t>(implementation_->descriptors.cols) : 0;
}

std::size_t IconDescriptors::byteCount() const noexcept {
  return isValid() ? implementation_->descriptors.total() * implementation_->descriptors.elemSize() : 0;
}

std::uint8_t IconDescriptors::byte(const std::size_t index) const noexcept {
  return isValid() && index < byteCount() ? implementation_->descriptors.ptr<std::uint8_t>()[index] : 0;
}

IconMatchResults::IconMatchResults(std::shared_ptr<Value> value)
    : value_(std::move(value)) {}

std::size_t IconMatchResults::count() const noexcept {
  return value_ == nullptr ? 0 : value_->matches.size();
}

std::string IconMatchResults::name(const std::size_t index) const {
  return value_ == nullptr || index >= count() ? std::string{}
                                               : value_->matches[index].name;
}

float IconMatchResults::score(const std::size_t index) const noexcept {
  return value_ == nullptr || index >= count()
      ? std::numeric_limits<float>::quiet_NaN()
      : value_->matches[index].score;
}

PreparedIconImage::PreparedIconImage(std::shared_ptr<Value> value)
    : value_(std::move(value)) {}

bool PreparedIconImage::isValid() const noexcept {
  return value_ != nullptr && value_->width > 0 && value_->height > 0 &&
      value_->bytes.size() ==
          static_cast<std::size_t>(value_->width) * value_->height * 3;
}

std::uint32_t PreparedIconImage::width() const noexcept {
  return isValid() ? value_->width : 0;
}

std::uint32_t PreparedIconImage::height() const noexcept {
  return isValid() ? value_->height : 0;
}

std::size_t PreparedIconImage::byteCount() const noexcept {
  return isValid() ? value_->bytes.size() : 0;
}

std::uint8_t PreparedIconImage::byte(const std::size_t index) const noexcept {
  return isValid() && index < value_->bytes.size() ? value_->bytes[index] : 0;
}

bool PreparedIconImage::copyBytes(
    std::uint8_t *const destination,
    const std::size_t destinationByteCount) const noexcept {
  if (!isValid() || destination == nullptr ||
      destinationByteCount < value_->bytes.size()) {
    return false;
  }
  std::copy(value_->bytes.begin(), value_->bytes.end(), destination);
  return true;
}

bool PreparedIconImage::hasMask() const noexcept {
  return isValid() && value_->mask.size() ==
      static_cast<std::size_t>(value_->width) * value_->height;
}

std::size_t PreparedIconImage::maskByteCount() const noexcept {
  return hasMask() ? value_->mask.size() : 0;
}

std::uint8_t PreparedIconImage::maskByte(const std::size_t index) const noexcept {
  return hasMask() && index < value_->mask.size() ? value_->mask[index] : 0;
}

bool PreparedIconImage::copyMaskBytes(
    std::uint8_t *const destination,
    const std::size_t destinationByteCount) const noexcept {
  if (!hasMask() || destination == nullptr ||
      destinationByteCount < value_->mask.size()) {
    return false;
  }
  std::copy(value_->mask.begin(), value_->mask.end(), destination);
  return true;
}

IconMatcher::IconMatcher(const std::string &path) noexcept
    : implementation_(nullptr) {
  try {
    implementation_ = std::make_shared<Implementation>();
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    if (!stream) {
      implementation_->databaseError = "could not open descriptor database";
      return;
    }
    const auto byteCount = stream.tellg();
    if (byteCount < 0 ||
        static_cast<std::uint64_t>(byteCount) > kMaximumDatabaseBytes) {
      implementation_->databaseError = "descriptor database is too large";
      return;
    }
    stream.seekg(0);
    std::vector<std::uint8_t> bytes(static_cast<std::size_t>(byteCount));
    if (!stream.read(
            reinterpret_cast<char *>(bytes.data()),
            static_cast<std::streamsize>(bytes.size()))) {
      implementation_->databaseError = "could not read descriptor database";
      return;
    }
    if (!decodeDatabase(bytes, implementation_->message, implementation_->databaseError)) {
      return;
    }
    implementation_->databaseError = validate(implementation_->message);
  } catch (const std::exception &error) {
    if (implementation_ != nullptr) {
      setError(implementation_->databaseError, error.what());
    }
  } catch (...) {
    if (implementation_ != nullptr) {
      setError(implementation_->databaseError, "unknown descriptor database error");
    }
  }
}

bool IconMatcher::isValid() const noexcept {
  return implementation_ != nullptr && implementation_->databaseError.empty();
}

std::string IconMatcher::errorMessage() const {
  if (implementation_ == nullptr) {
    return "descriptor database is unavailable";
  }
  return implementation_->operationError.empty()
      ? implementation_->databaseError
      : implementation_->operationError;
}

std::uint32_t IconMatcher::formatVersion() const noexcept {
  return isValid() ? implementation_->message.formatVersion : 0;
}

std::string IconMatcher::databaseID() const {
  return isValid() ? implementation_->message.databaseID : std::string{};
}

std::string IconMatcher::createdAt() const {
  return isValid() ? implementation_->message.createdAt : std::string{};
}

std::uint32_t IconMatcher::akazeDescriptorSize() const noexcept {
  return isValid() ? implementation_->message.akaze.descriptorSize : 0;
}

float IconMatcher::akazeThreshold() const noexcept {
  return isValid() ? implementation_->message.akaze.threshold : 0;
}

std::uint32_t IconMatcher::akazeImageHeight() const noexcept {
  return isValid() ? implementation_->message.akaze.imageHeight : 0;
}

std::size_t IconMatcher::count() const noexcept {
  return isValid()
      ? implementation_->message.entries.size()
      : 0;
}

std::string IconMatcher::entryName(const std::size_t index) const {
  if (!isValid() || index >= count()) {
    return {};
  }
  return implementation_->message.entries[index].name;
}

ItemCategory IconMatcher::entryCategory(
    const std::size_t index) const noexcept {
  if (!isValid() || index >= count()) {
    return ItemCategory::unspecified;
  }
  return implementation_->message.entries[index].category;
}

std::uint32_t IconMatcher::entryDescriptorCount(
    const std::size_t index) const noexcept {
  if (!isValid() || index >= count()) {
    return 0;
  }
  return implementation_->message.entries[index].rows;
}

IconMatchResults IconMatcher::matchHeldBGR(
    const std::uint8_t *bytes,
    const std::size_t byteCount,
    const std::uint32_t width,
    const std::uint32_t height,
    const std::size_t bytesPerRow,
    const float radiusFraction,
    const std::size_t limit,
    const float ratio) const noexcept {
  try {
    auto value = std::make_shared<IconMatchResults::Value>();
    if (!isValid()) {
      return IconMatchResults(std::move(value));
    }
    implementation_->operationError.clear();
    const auto source = inputBGR(bytes, byteCount, width, height, bytesPerRow);
    if (source.empty() || !(radiusFraction > 0 && radiusFraction <= 0.5F)) {
      implementation_->operationError = "invalid held-item match input";
      return IconMatchResults(std::move(value));
    }

    const int imageHeight = static_cast<int>(implementation_->message.akaze.imageHeight);
    const cv::Mat scaled = prepareHeldImage(source, imageHeight, radiusFraction);
    cv::Mat keypointsMask(scaled.size(), CV_8U, cv::Scalar(255));
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat query;
    makeDetector(implementation_->message.akaze)
        ->detectAndCompute(scaled, keypointsMask, keypoints, query);
    value->matches = rankDescriptors(
        implementation_->message,
        query,
        ItemCategory::held,
        limit,
        ratio);
    return IconMatchResults(std::move(value));
  } catch (const std::exception &error) {
    if (implementation_ != nullptr) {
      setError(implementation_->operationError, error.what());
    }
  } catch (...) {
    if (implementation_ != nullptr) {
      setError(implementation_->operationError, "unknown held-item matching error");
    }
  }
  return IconMatchResults(nullptr);
}

IconMatchResults IconMatcher::matchBattleBGR(
    const std::uint8_t *bytes,
    const std::size_t byteCount,
    const std::uint32_t width,
    const std::uint32_t height,
    const std::size_t bytesPerRow,
    const std::size_t limit,
    const float ratio) const noexcept {
  try {
    auto value = std::make_shared<IconMatchResults::Value>();
    if (!isValid()) {
      return IconMatchResults(std::move(value));
    }
    implementation_->operationError.clear();
    const auto source = inputBGR(bytes, byteCount, width, height, bytesPerRow);
    if (source.empty()) {
      implementation_->operationError = "invalid battle-item match input";
      return IconMatchResults(std::move(value));
    }
    const int imageHeight = static_cast<int>(implementation_->message.akaze.imageHeight);
    const cv::Mat scaled = prepareBattleImage(source, imageHeight);
    const cv::Mat mask = battleImageMask(scaled.size());
    std::vector<cv::KeyPoint> keypoints;
    cv::Mat query;
    makeDetector(implementation_->message.akaze)
        ->detectAndCompute(scaled, mask, keypoints, query);
    value->matches = rankDescriptors(
        implementation_->message,
        query,
        ItemCategory::battle,
        limit,
        ratio);
    return IconMatchResults(std::move(value));
  } catch (const std::exception &error) {
    if (implementation_ != nullptr) {
      setError(implementation_->operationError, error.what());
    }
  } catch (...) {
    if (implementation_ != nullptr) {
      setError(implementation_->operationError, "unknown battle-item matching error");
    }
  }
  return IconMatchResults(nullptr);
}

PreparedIconImage IconMatcher::prepareHeldBGR(
    const std::uint8_t *bytes,
    const std::size_t byteCount,
    const std::uint32_t width,
    const std::uint32_t height,
    const std::size_t bytesPerRow,
    const float radiusFraction) const noexcept {
  try {
    auto value = std::make_shared<PreparedIconImage::Value>();
    if (!isValid()) {
      return PreparedIconImage(std::move(value));
    }
    implementation_->operationError.clear();
    const auto source = inputBGR(bytes, byteCount, width, height, bytesPerRow);
    const auto prepared = prepareHeldImage(
        source,
        static_cast<int>(implementation_->message.akaze.imageHeight),
        radiusFraction);
    if (prepared.empty() || !prepared.isContinuous()) {
      implementation_->operationError = "invalid held-item preparation input";
      return PreparedIconImage(std::move(value));
    }
    value->width = static_cast<std::uint32_t>(prepared.cols);
    value->height = static_cast<std::uint32_t>(prepared.rows);
    value->bytes.assign(
        prepared.ptr<std::uint8_t>(),
        prepared.ptr<std::uint8_t>() + prepared.total() * prepared.elemSize());
    return PreparedIconImage(std::move(value));
  } catch (const std::exception &error) {
    if (implementation_ != nullptr) {
      setError(implementation_->operationError, error.what());
    }
  } catch (...) {
    if (implementation_ != nullptr) {
      setError(implementation_->operationError, "unknown held-item preparation error");
    }
  }
  return PreparedIconImage(nullptr);
}

PreparedIconImage IconMatcher::prepareBattleBGR(
    const std::uint8_t *bytes,
    const std::size_t byteCount,
    const std::uint32_t width,
    const std::uint32_t height,
    const std::size_t bytesPerRow) const noexcept {
  try {
    auto value = std::make_shared<PreparedIconImage::Value>();
    if (!isValid()) {
      return PreparedIconImage(std::move(value));
    }
    implementation_->operationError.clear();
    const auto source = inputBGR(bytes, byteCount, width, height, bytesPerRow);
    const auto prepared = prepareBattleImage(
        source, static_cast<int>(implementation_->message.akaze.imageHeight));
    if (prepared.empty() || !prepared.isContinuous()) {
      implementation_->operationError = "invalid battle-item preparation input";
      return PreparedIconImage(std::move(value));
    }
    value->width = static_cast<std::uint32_t>(prepared.cols);
    value->height = static_cast<std::uint32_t>(prepared.rows);
    value->bytes.assign(
        prepared.ptr<std::uint8_t>(),
        prepared.ptr<std::uint8_t>() + prepared.total() * prepared.elemSize());
    const cv::Mat mask = battleImageMask(prepared.size());
    value->mask.assign(
        mask.ptr<std::uint8_t>(), mask.ptr<std::uint8_t>() + mask.total());
    return PreparedIconImage(std::move(value));
  } catch (const std::exception &error) {
    if (implementation_ != nullptr) {
      setError(implementation_->operationError, error.what());
    }
  } catch (...) {
    if (implementation_ != nullptr) {
      setError(implementation_->operationError, "unknown battle-item preparation error");
    }
  }
  return PreparedIconImage(nullptr);
}

}  // namespace unite_analysis
