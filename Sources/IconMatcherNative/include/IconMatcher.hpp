// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

#ifndef UNITE_ANALYSIS_ICON_MATCHER_HPP
#define UNITE_ANALYSIS_ICON_MATCHER_HPP

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>

namespace unite_analysis {

[[nodiscard]] bool isAkazeAvailable() noexcept;

enum class ItemCategory : std::uint8_t {
  unspecified = 0,
  held = 1,
  battle = 2,
};

class IconMatchResults final {
 public:
  [[nodiscard]] std::size_t count() const noexcept;
  [[nodiscard]] std::string name(std::size_t index) const;
  [[nodiscard]] float score(std::size_t index) const noexcept;

 private:
  struct Value;
  std::shared_ptr<Value> value_;
  explicit IconMatchResults(std::shared_ptr<Value> value);
  friend class IconMatcher;
};

class IconDescriptors final {
 public:
  IconDescriptors(
      const std::uint8_t *bytes,
      std::size_t byteCount,
      std::uint32_t width,
      std::uint32_t height,
      std::size_t bytesPerRow,
      std::uint32_t imageHeight,
      std::uint32_t descriptorSize,
      float threshold,
      float paddingFraction) noexcept;

  [[nodiscard]] bool isValid() const noexcept;
  [[nodiscard]] std::string errorMessage() const;
  [[nodiscard]] std::uint32_t rows() const noexcept;
  [[nodiscard]] std::uint32_t columns() const noexcept;
  [[nodiscard]] std::size_t byteCount() const noexcept;
  [[nodiscard]] std::uint8_t byte(std::size_t index) const noexcept;

 private:
  class Implementation;
  std::shared_ptr<Implementation> implementation_;
};

class PreparedIconImage final {
 public:
  [[nodiscard]] bool isValid() const noexcept;
  [[nodiscard]] std::uint32_t width() const noexcept;
  [[nodiscard]] std::uint32_t height() const noexcept;
  [[nodiscard]] std::size_t byteCount() const noexcept;
  [[nodiscard]] std::uint8_t byte(std::size_t index) const noexcept;
  [[nodiscard]] bool hasMask() const noexcept;
  [[nodiscard]] std::size_t maskByteCount() const noexcept;
  [[nodiscard]] std::uint8_t maskByte(std::size_t index) const noexcept;

 private:
  struct Value;
  std::shared_ptr<Value> value_;
  explicit PreparedIconImage(std::shared_ptr<Value> value);
  friend class IconMatcher;
};

class IconMatcher final {
 public:
  explicit IconMatcher(const std::string &path) noexcept;

  [[nodiscard]] bool isValid() const noexcept;
  [[nodiscard]] std::string errorMessage() const;
  [[nodiscard]] std::uint32_t formatVersion() const noexcept;
  [[nodiscard]] std::string databaseID() const;
  [[nodiscard]] std::string createdAt() const;
  [[nodiscard]] std::uint32_t akazeDescriptorSize() const noexcept;
  [[nodiscard]] float akazeThreshold() const noexcept;
  [[nodiscard]] std::uint32_t akazeImageHeight() const noexcept;
  [[nodiscard]] std::size_t count() const noexcept;
  [[nodiscard]] std::string entryName(std::size_t index) const;
  [[nodiscard]] ItemCategory entryCategory(std::size_t index) const noexcept;
  [[nodiscard]] std::uint32_t entryDescriptorCount(
      std::size_t index) const noexcept;
  [[nodiscard]] IconMatchResults matchHeldBGR(
      const std::uint8_t *bytes,
      std::size_t byteCount,
      std::uint32_t width,
      std::uint32_t height,
      std::size_t bytesPerRow,
      float radiusFraction = 0.40F,
      std::size_t limit = 3,
      float ratio = 0.90F) const noexcept;
  [[nodiscard]] IconMatchResults matchBattleBGR(
      const std::uint8_t *bytes,
      std::size_t byteCount,
      std::uint32_t width,
      std::uint32_t height,
      std::size_t bytesPerRow,
      std::size_t limit = 3,
      float ratio = 0.80F) const noexcept;
  /// Returns the exact normalized BGR pixels supplied to AKAZE for diagnostics.
  [[nodiscard]] PreparedIconImage prepareHeldBGR(
      const std::uint8_t *bytes,
      std::size_t byteCount,
      std::uint32_t width,
      std::uint32_t height,
      std::size_t bytesPerRow,
      float radiusFraction = 0.40F) const noexcept;
  /// Returns the exact normalized BGR pixels supplied to AKAZE for diagnostics.
  [[nodiscard]] PreparedIconImage prepareBattleBGR(
      const std::uint8_t *bytes,
      std::size_t byteCount,
      std::uint32_t width,
      std::uint32_t height,
      std::size_t bytesPerRow) const noexcept;

 private:
  class Implementation;
  std::shared_ptr<Implementation> implementation_;
};

}  // namespace unite_analysis

#endif
