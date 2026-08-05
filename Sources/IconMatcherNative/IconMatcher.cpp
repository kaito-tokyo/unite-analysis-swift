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
#include <fstream>
#include <limits>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace unite_analysis {

bool isAkazeAvailable() {
  const auto detector = cv::xfeatures2d::AKAZE::create(
      cv::xfeatures2d::AKAZE::DESCRIPTOR_MLDB,
      0,
      3,
      0.001F);
  return !detector.empty() &&
      detector->getDescriptorType() == cv::xfeatures2d::AKAZE::DESCRIPTOR_MLDB;
}

namespace {

constexpr std::uint32_t kSupportedFormatVersion = 1;
constexpr std::size_t kMaximumDatabaseBytes = 64 * 1024 * 1024;
constexpr int kMaximumEntries = 4096;
constexpr std::uint64_t kMaximumDescriptorsPerEntry = 1'000'000;
constexpr float kHeldCircleEdgeFraction = 0.49F;
constexpr float kHeldPaddingFraction = 0.20F;

struct RankedMatch {
  std::string name;
  float distance;
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
      result.push_back({name, static_cast<float>(-score)});
    }
  }
  std::sort(result.begin(), result.end(), [](const auto &left, const auto &right) {
    return left.distance != right.distance ? left.distance < right.distance
                                           : left.name < right.name;
  });
  if (result.size() > limit) {
    result.resize(limit);
  }
  return result;
}

std::string validate(const DescriptorDatabase &database) {
  if (database.formatVersion != kSupportedFormatVersion) {
    return "unsupported descriptor database format version";
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
  std::string error;
};

struct IconMatchResults::Value final {
  std::vector<RankedMatch> matches;
};

IconMatchResults::IconMatchResults(std::shared_ptr<Value> value)
    : value_(std::move(value)) {}

std::size_t IconMatchResults::count() const noexcept {
  return value_ == nullptr ? 0 : value_->matches.size();
}

std::string IconMatchResults::name(const std::size_t index) const {
  return value_ == nullptr || index >= count() ? std::string{}
                                               : value_->matches[index].name;
}

float IconMatchResults::distance(const std::size_t index) const noexcept {
  return value_ == nullptr || index >= count()
      ? std::numeric_limits<float>::quiet_NaN()
      : value_->matches[index].distance;
}

IconMatcher::IconMatcher(const std::string &path)
    : implementation_(std::make_shared<Implementation>()) {
  std::ifstream stream(path, std::ios::binary | std::ios::ate);
  if (!stream) {
    implementation_->error = "could not open descriptor database";
    return;
  }
  const auto byteCount = stream.tellg();
  if (byteCount < 0 ||
      static_cast<std::uint64_t>(byteCount) > kMaximumDatabaseBytes) {
    implementation_->error = "descriptor database is too large";
    return;
  }
  stream.seekg(0);
  std::vector<std::uint8_t> bytes(static_cast<std::size_t>(byteCount));
  if (!stream.read(
          reinterpret_cast<char *>(bytes.data()),
          static_cast<std::streamsize>(bytes.size()))) {
    implementation_->error = "could not read descriptor database";
    return;
  }
  if (!decodeDatabase(bytes, implementation_->message, implementation_->error)) {
    return;
  }
  implementation_->error = validate(implementation_->message);
}

bool IconMatcher::isValid() const noexcept {
  return implementation_ != nullptr && implementation_->error.empty();
}

std::string IconMatcher::errorMessage() const {
  return implementation_ == nullptr ? "descriptor database is unavailable"
                                    : implementation_->error;
}

std::uint32_t IconMatcher::formatVersion() const noexcept {
  return isValid() ? implementation_->message.formatVersion : 0;
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
    const float ratio) const {
  auto value = std::make_shared<IconMatchResults::Value>();
  const auto source = inputBGR(bytes, byteCount, width, height, bytesPerRow);
  if (!isValid() || source.empty() || !(radiusFraction > 0 && radiusFraction <= 0.5F)) {
    return IconMatchResults(std::move(value));
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
  const int imageHeight = static_cast<int>(implementation_->message.akaze.imageHeight);
  cv::resize(padded, scaled, cv::Size(imageHeight, imageHeight), 0, 0, cv::INTER_LINEAR);
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
}

IconMatchResults IconMatcher::matchBattleBGR(
    const std::uint8_t *bytes,
    const std::size_t byteCount,
    const std::uint32_t width,
    const std::uint32_t height,
    const std::size_t bytesPerRow,
    const std::size_t limit,
    const float ratio) const {
  auto value = std::make_shared<IconMatchResults::Value>();
  const auto source = inputBGR(bytes, byteCount, width, height, bytesPerRow);
  if (!isValid() || source.empty()) {
    return IconMatchResults(std::move(value));
  }
  const int imageHeight = static_cast<int>(implementation_->message.akaze.imageHeight);
  cv::Mat scaled;
  cv::resize(source, scaled, cv::Size(imageHeight, imageHeight), 0, 0, cv::INTER_LINEAR);
  const int inset = static_cast<int>(std::lround(imageHeight * 0.08));
  const int center = imageHeight / 2;
  cv::Mat mask = cv::Mat::zeros(scaled.size(), CV_8U);
  const int diamondRadius = center - inset;
  for (int row = 0; row < mask.rows; ++row) {
    auto *maskRow = mask.ptr<std::uint8_t>(row);
    for (int column = 0; column < mask.cols; ++column) {
      maskRow[column] =
          std::abs(column - center) + std::abs(row - center) <= diamondRadius ? 255 : 0;
    }
  }
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
}

}  // namespace unite_analysis
