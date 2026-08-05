// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CxxStdlib
import Foundation
import IconMatcherNative
import RecordVisionSupport
import Testing

@testable import UniteAnalysisSwiftTool

@Test func openCV5AkazeIsAvailable() {
  #expect(unite_analysis.isAkazeAvailable())
}

@Test func missingDescriptorDatabaseIsRejected() {
  let matcher = unite_analysis.IconMatcher(std.string("/definitely-missing/descriptors.pb"))
  #expect(!matcher.isValid())
  #expect(!String(matcher.errorMessage()).isEmpty)
}

@Test func validDescriptorDatabaseLoadsMetadata() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pb")
  defer { try? FileManager.default.removeItem(at: url) }
  try descriptorDatabaseFixture().write(to: url)

  let matcher = unite_analysis.IconMatcher(std.string(url.path))
  #expect(matcher.isValid())
  #expect(matcher.formatVersion() == 1)
  #expect(matcher.akazeDescriptorSize() == 8)
  #expect(abs(matcher.akazeThreshold() - 0.001) < 0.000_001)
  #expect(matcher.akazeImageHeight() == 64)
  #expect(matcher.count() == 2)
  #expect(String(matcher.entryName(0)) == "held-fixture")
  #expect(String(matcher.entryName(1)) == "battle-fixture")
  #expect(matcher.entryDescriptorCount(0) == 2)
  #expect(matcher.entryDescriptorCount(1) == 2)
}

@Test func ratioRejectedDescriptorsDoNotProduceCandidates() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pb")
  defer { try? FileManager.default.removeItem(at: url) }
  try descriptorDatabaseFixture().write(to: url)

  let matcher = unite_analysis.IconMatcher(std.string(url.path))
  let pixels = (0..<40).flatMap { y in
    (0..<40).flatMap { x -> [UInt8] in
      let value: UInt8 = (x / 4 + y / 4).isMultiple(of: 2) ? 0 : 255
      return [value, value, value]
    }
  }
  let image = try BGRImage(width: 40, height: 40, bytesPerRow: 120, bytes: pixels)

  #expect(matcher.isValid())
  #expect(matcher.matchHeldItem(in: image).isEmpty)
}

@Test func invalidBGRImageIsRejected() {
  #expect(throws: LoadoutRecognitionError.invalidImage) {
    try BGRImage(width: 2, height: 2, bytesPerRow: 6, bytes: [0, 1, 2])
  }
}

@Test(arguments: [
  ([UInt8](arrayLiteral: 0, 0, 255), "top"),
  ([UInt8](arrayLiteral: 255, 255, 0), "central"),
  ([UInt8](arrayLiteral: 255, 0, 255), "bottom"),
])
func declaredRouteUsesOpenCVHueScale(sample: ([UInt8], String)) throws {
  let pixels = Array(repeating: sample.0, count: 36 * 28).flatMap { $0 }
  let image = try BGRImage(width: 36, height: 28, bytesPerRow: 36 * 3, bytes: pixels)
  #expect(LoadoutRecognizer.classifyRoute(image).name == sample.1)
}

@Test func lowSaturationRouteIsUnrecognized() throws {
  let pixels = [UInt8](repeating: 128, count: 36 * 28 * 3)
  let image = try BGRImage(width: 36, height: 28, bytesPerRow: 36 * 3, bytes: pixels)
  let result = LoadoutRecognizer.classifyRoute(image)
  #expect(result.name == nil)
  #expect(result.chromaticFraction == 0)
}

@Test func normalizesDeclaredGameScreenComponent() throws {
  let context = try #require(
    CGContext(
      data: nil,
      width: 100,
      height: 80,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  let image = try #require(context.makeImage())
  let component = RecordSpec.VideoComponent(
    name: "game-screen", x: 10, y: 20, width: 50, height: 30)

  let normalized = try normalizedGameScreen(image, component: component)

  #expect(normalized.width == 1920)
  #expect(normalized.height == 1080)
}

private func descriptorDatabaseFixture() -> Data {
  let configuration = protobufMessage([
    protobufVarintField(1, 8),
    protobufFixed32Field(2, Float(0.001).bitPattern),
    protobufVarintField(3, 64),
  ])
  let held = descriptorEntry(name: "held-fixture", category: 1, byte: 0x00)
  let battle = descriptorEntry(name: "battle-fixture", category: 2, byte: 0xFF)
  return protobufMessage([
    protobufVarintField(1, 1),
    protobufBytesField(2, configuration),
    protobufBytesField(3, held),
    protobufBytesField(3, battle),
  ])
}

private func descriptorEntry(name: String, category: UInt64, byte: UInt8) -> Data {
  protobufMessage([
    protobufBytesField(1, Data(name.utf8)),
    protobufVarintField(2, category),
    protobufVarintField(3, 2),
    protobufVarintField(4, 1),
    protobufBytesField(5, Data([byte, byte])),
  ])
}

private func protobufMessage(_ fields: [Data]) -> Data {
  fields.reduce(into: Data()) { $0.append($1) }
}

private func protobufVarintField(_ number: UInt64, _ value: UInt64) -> Data {
  protobufVarint(number << 3) + protobufVarint(value)
}

private func protobufFixed32Field(_ number: UInt64, _ value: UInt32) -> Data {
  var littleEndian = value.littleEndian
  return protobufVarint((number << 3) | 5)
    + withUnsafeBytes(of: &littleEndian) { Data($0) }
}

private func protobufBytesField(_ number: UInt64, _ value: Data) -> Data {
  protobufVarint((number << 3) | 2) + protobufVarint(UInt64(value.count)) + value
}

private func protobufVarint(_ input: UInt64) -> Data {
  var value = input
  var bytes = [UInt8]()
  while value >= 0x80 {
    bytes.append(UInt8(value & 0x7F) | 0x80)
    value >>= 7
  }
  bytes.append(UInt8(value))
  return Data(bytes)
}
