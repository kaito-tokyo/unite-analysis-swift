// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CxxStdlib
import Foundation
import IconMatcherNative
import ImageIO
import LDTXRecordingSupport
import RecordVisionSupport
import Testing
import UniteAnalysisSwiftCommands

private let descriptorFixtureURL = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .appendingPathComponent("Contents/Resources/descriptors.pb")

@Test func openCV5AkazeIsAvailable() {
  #expect(unite_analysis.isAkazeAvailable())
}

@Test func referenceIconProducesDescriptors() {
  let side = 64
  var bgra = [UInt8](repeating: 0, count: side * side * 4)
  for y in 12..<52 {
    for x in 12..<52 where (x / 4 + y / 4).isMultiple(of: 2) {
      let offset = (y * side + x) * 4
      bgra[offset] = UInt8((x * 5) % 256)
      bgra[offset + 1] = UInt8((y * 5) % 256)
      bgra[offset + 2] = 255
      bgra[offset + 3] = 255
    }
  }
  let descriptors = bgra.withUnsafeBufferPointer { buffer in
    unite_analysis.IconDescriptors(
      buffer.baseAddress, buffer.count, UInt32(side), UInt32(side), side * 4,
      256, 128, 0.0001, 0.20)
  }
  #expect(descriptors.isValid())
  #expect(descriptors.rows() > 0)
  #expect(descriptors.columns() == 16)
  #expect(descriptors.byteCount() == Int(descriptors.rows() * descriptors.columns()))
}

@Test func narrowReferenceIconDoesNotRequestZeroWidthResize() {
  let bgra = [UInt8](repeating: 255, count: 1 * 5 * 4)
  let descriptors = bgra.withUnsafeBufferPointer { buffer in
    unite_analysis.IconDescriptors(
      buffer.baseAddress, buffer.count, 1, 5, 4,
      4, 128, 0.0001, 0)
  }
  #expect(!descriptors.isValid())
  #expect(descriptors.errorMessage() == std.string("AKAZE produced no descriptors"))
}

@Test func descriptorSourceRejectsOverflowingRowStorage() {
  let bgra = [UInt8](repeating: 255, count: 8)
  let descriptors = bgra.withUnsafeBufferPointer { buffer in
    unite_analysis.IconDescriptors(
      buffer.baseAddress, buffer.count, 1, 2, .max,
      256, 128, 0.0001, 0)
  }
  #expect(!descriptors.isValid())
}

@Test func descriptorSourceRejectsExcessiveResizeWidth() {
  let width = 10_000
  let bgra = [UInt8](repeating: 255, count: width * 4)
  let descriptors = bgra.withUnsafeBufferPointer { buffer in
    unite_analysis.IconDescriptors(
      buffer.baseAddress, buffer.count, UInt32(width), 1, width * 4,
      256, 128, 0.0001, 0)
  }
  #expect(!descriptors.isValid())
  #expect(
    descriptors.errorMessage()
      == std.string("resized descriptor image exceeds 4096 pixels in width"))
}

@Test func missingDescriptorDatabaseIsRejected() {
  let matcher = unite_analysis.IconMatcher(std.string("/definitely-missing/descriptors.pb"))
  #expect(!matcher.isValid())
  let errorMessage = matcher.errorMessage()
  #expect(!swiftString(from: errorMessage).isEmpty)
}

@Test func validDescriptorDatabaseLoadsMetadata() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pb")
  defer { try? FileManager.default.removeItem(at: url) }
  try descriptorDatabaseFixture().write(to: url)

  let matcher = unite_analysis.IconMatcher(std.string(url.path))
  #expect(matcher.isValid())
  #expect(matcher.formatVersion() == 2)
  #expect(swiftString(from: matcher.databaseID()) == "550e8400-e29b-41d4-a716-446655440000")
  #expect(swiftString(from: matcher.createdAt()) == "2026-08-06T00:00:00Z")
  #expect(matcher.akazeDescriptorSize() == 8)
  #expect(abs(matcher.akazeThreshold() - 0.001) < 0.000_001)
  #expect(matcher.akazeImageHeight() == 64)
  #expect(matcher.count() == 2)
  let heldName = matcher.entryName(0)
  let battleName = matcher.entryName(1)
  #expect(swiftString(from: heldName) == "held-fixture")
  #expect(swiftString(from: battleName) == "battle-fixture")
  #expect(matcher.entryDescriptorCount(0) == 2)
  #expect(matcher.entryDescriptorCount(1) == 2)
}

@Test func descriptorDatabaseRejectsUnknownCategory() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pb")
  defer { try? FileManager.default.removeItem(at: url) }
  try descriptorDatabaseFixture(category: 3).write(to: url)

  let matcher = unite_analysis.IconMatcher(std.string(url.path))
  #expect(!matcher.isValid())
  #expect(swiftString(from: matcher.errorMessage()).contains("unsupported category"))
}

@Test func descriptorDatabaseRejectsInvalidUTF8Name() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pb")
  defer { try? FileManager.default.removeItem(at: url) }
  try descriptorDatabaseFixture(heldName: Data([0xC0, 0xAF])).write(to: url)

  let matcher = unite_analysis.IconMatcher(std.string(url.path))
  #expect(!matcher.isValid())
  #expect(swiftString(from: matcher.errorMessage()).contains("UTF-8"))
}

@Test func descriptorDatabaseRejectsInvalidCreationTime() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pb")
  defer { try? FileManager.default.removeItem(at: url) }
  try descriptorDatabaseFixture(createdAt: "2026-99-99T99:99:99Z").write(to: url)

  let matcher = unite_analysis.IconMatcher(std.string(url.path))
  #expect(!matcher.isValid())
  #expect(swiftString(from: matcher.errorMessage()).contains("RFC 3339"))
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
  #expect(try matcher.matchHeldItem(in: image).isEmpty)
}

@Test func invalidNativeMatchInputSurfacesAnError() throws {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("pb")
  defer { try? FileManager.default.removeItem(at: url) }
  try descriptorDatabaseFixture().write(to: url)
  let matcher = unite_analysis.IconMatcher(std.string(url.path))

  let result = matcher.matchHeldBGR(nil, 0, 0, 0, 0, 0.40, 3, 0.90)

  #expect(result.count() == 0)
  #expect(swiftString(from: matcher.errorMessage()) == "invalid held-item match input")
}

@Test func invalidBGRImageIsRejected() {
  #expect(throws: LoadoutRecognitionError.invalidImage) {
    try BGRImage(width: 2, height: 2, bytesPerRow: 6, bytes: [0, 1, 2])
  }
}

@Test func cgImageConversionRendersIntoBGRStorage() throws {
  let sourceBytes: [UInt8] = [12, 34, 56, 255, 78, 90, 123, 255]
  let provider = try #require(CGDataProvider(data: Data(sourceBytes) as CFData))
  let image = try #require(
    CGImage(
      width: 2,
      height: 1,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 8,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent))

  let converted = try BGRImage(image)

  #expect(converted.width == 2)
  #expect(converted.height == 1)
  #expect(converted.bytesPerRow == 6)
  #expect(converted.bytes == [56, 34, 12, 123, 90, 78])
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

@Test func unrelatedSaturatedRouteCropIsUnrecognized() throws {
  let greenBGR = [UInt8](arrayLiteral: 0, 255, 0)
  let pixels = Array(repeating: greenBGR, count: 36 * 28).flatMap { $0 }
  let image = try BGRImage(width: 36, height: 28, bytesPerRow: 36 * 3, bytes: pixels)
  let result = LoadoutRecognizer.classifyRoute(image)

  #expect(result.name == nil)
  #expect(result.medianHue == 60)
  #expect(result.chromaticFraction == 1)
  #expect(LoadoutRecognizer.maximumRouteHueDistance == 24.5)
}

@Test func recognizedItemAbstainsBelowOneVoteOfEvidence() {
  let item = RecognizedItem([IconMatch(name: "first", score: 0.99)])

  #expect(item.name == nil)
  #expect(item.score == 0.99)
  #expect(item.candidates.count == 1)
  #expect(LoadoutRecognizer.minimumAcceptedVoteSum == 1)
}

@Test func recognizedItemAbstainsWithoutTwoToOneMargin() {
  let item = RecognizedItem([
    IconMatch(name: "first", score: 2),
    IconMatch(name: "second", score: 1.01),
  ])

  #expect(item.name == nil)
  #expect(item.score == 2)
  #expect(item.candidates.count == 2)
  #expect(LoadoutRecognizer.minimumTopToRunnerUpRatio == 2)
}

@Test func recognizedItemAcceptsGroundedEvidenceBoundaries() {
  let item = RecognizedItem([
    IconMatch(name: "first", score: 2),
    IconMatch(name: "second", score: 1),
  ])

  #expect(item.name == "first")
  #expect(item.score == 2)
}

@Test func duplicateHeldItemsAbstainWithoutDiscardingEvidence() {
  let duplicate = RecognizedItem([
    IconMatch(name: "same", score: 4), IconMatch(name: "other", score: 1),
  ])
  let distinct = RecognizedItem([
    IconMatch(name: "distinct", score: 4), IconMatch(name: "other", score: 1),
  ])

  let result = LoadoutRecognizer.abstainingOnDuplicateHeldItems([
    duplicate, duplicate, distinct,
  ])

  #expect(result.map(\.name) == [nil, nil, "distinct"])
  #expect(result[0].candidates == duplicate.candidates)
  #expect(result[1].score == duplicate.score)
}

@Test func recognizesDraftRecordingFixture() throws {
  let preparation = try loadAndNormalizeFixtureImage(
    try #require(
      Bundle.module.url(forResource: "final-preparation", withExtension: "jpg")))
  let versus = try loadAndNormalizeFixtureImage(
    try #require(
      Bundle.module.url(forResource: "versus", withExtension: "jpg")))
  let matcher = unite_analysis.IconMatcher(std.string(descriptorFixtureURL.path))
  #expect(matcher.isValid())

  let result = try LoadoutRecognizer.recognizeDraft(
    finalPreparation: preparation, versus: versus, matcher: matcher)

  #expect(
    result.allies.map { $0.heldItems.map(\.name) } == [
      ["Choice Specs", "Shell Bell", "Slick Spoon"],
      ["Vanguard Bell", "Focus Band", "Muscle Band"],
      ["Rapid Fire Scarf", "Float Stone", "Curse Bangle"],
      ["Choice Specs", "Slick Spoon", "Wise Glasses"],
      ["Accel Bracer", "Razor Claw", "Weakness Policy"],
    ])
  #expect(
    result.allies.map { $0.battleItem.name } == [
      "Eject Button", "Eject Button", "Eject Button", "X Speed", "Full Heal",
    ])
  #expect(
    result.allies.map { $0.declaredRoute.name } == [
      "top", "bottom", "top", "bottom", "central",
    ])
  #expect(
    result.enemies.map { $0.battleItem.name } == [
      "Eject Button", "X Speed", "Eject Button", "Full Heal", "Full Heal",
    ])
}

@Test func preparedDiagnosticImagesUseDatabaseDimensions() throws {
  let matcher = unite_analysis.IconMatcher(std.string(descriptorFixtureURL.path))
  let pixels = [UInt8](repeating: 255, count: 48 * 48 * 3)
  let input = try BGRImage(width: 48, height: 48, bytesPerRow: 48 * 3, bytes: pixels)

  let held = try matcher.preparedHeldImage(input)
  let battle = try matcher.preparedBattleImage(input)

  #expect(held.image.width == Int(matcher.akazeImageHeight()))
  #expect(held.image.height == Int(matcher.akazeImageHeight()))
  #expect(held.mask == nil)
  #expect(battle.image.width == Int(matcher.akazeImageHeight()))
  #expect(battle.image.height == Int(matcher.akazeImageHeight()))
  let battleMask = try #require(battle.mask)
  #expect(battleMask.bytes[0] == 0)
  let centerOffset =
    battleMask.height / 2 * battleMask.bytesPerRow + battleMask.width / 2 * 3
  #expect(battleMask.bytes[centerOffset] == 255)
}

@Test func preparedDiagnosticImageFailuresUpdateAndClearMatcherError() throws {
  let matcher = unite_analysis.IconMatcher(std.string(descriptorFixtureURL.path))

  let invalid = matcher.prepareHeldBGR(nil, 0, 0, 0, 0, 0.40)
  #expect(!invalid.isValid())
  #expect(swiftString(from: matcher.errorMessage()) == "invalid held-item preparation input")

  let pixels = [UInt8](repeating: 255, count: 48 * 48 * 3)
  let input = try BGRImage(width: 48, height: 48, bytesPerRow: 48 * 3, bytes: pixels)
  _ = try matcher.preparedHeldImage(input)
  #expect(swiftString(from: matcher.errorMessage()).isEmpty)
}

@Test func diagnosticOutputsPreflightEveryGeneratedPath() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let collision = directory.appendingPathComponent("ally-3-battle-mask.png")
  try Data("existing".utf8).write(to: collision)

  #expect(throws: Error.self) {
    try prepareDiagnosticDirectory(directory, matchFormat: "draft", force: false)
  }
  #expect(try Data(contentsOf: collision) == Data("existing".utf8))
  #expect(throws: Never.self) {
    try prepareDiagnosticDirectory(directory, matchFormat: "draft", force: true)
  }
  let directoryCollision = directory.appendingPathComponent("ally-4-battle-mask.png")
  try FileManager.default.createDirectory(
    at: directoryCollision, withIntermediateDirectories: false)
  #expect(throws: Error.self) {
    try prepareDiagnosticDirectory(directory, matchFormat: "draft", force: true)
  }
}

@Test func loadoutOutputDestinationRejectsInvalidTypesBeforeRecognition() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let regularFile = root.appendingPathComponent("file")
  try Data().write(to: regularFile)

  #expect(throws: Error.self) {
    try validateLoadoutOutputDestination(
      regularFile.appendingPathComponent("result.json"), force: false)
  }
  #expect(throws: Error.self) {
    try validateLoadoutOutputDestination(root, force: true)
  }
  #expect(throws: Never.self) {
    try validateLoadoutOutputDestination(root.appendingPathComponent("result.json"), force: false)
  }
}

@Test func loadoutOutputCannotOverlapDiagnosticOutput() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let output = directory.appendingPathComponent("ally-1-held-1.png")

  #expect(throws: Error.self) {
    try validateDistinctLoadoutOutputs(
      outputURL: output, diagnosticDirectory: directory, matchFormat: "draft")
  }
  let volumeValues = try FileManager.default.temporaryDirectory.resourceValues(forKeys: [
    .volumeSupportsCaseSensitiveNamesKey
  ])
  if volumeValues.volumeSupportsCaseSensitiveNames == true {
    #expect(throws: Never.self) {
      try validateDistinctLoadoutOutputs(
        outputURL: directory.appendingPathComponent("ALLY-1-HELD-1.PNG"),
        diagnosticDirectory: directory,
        matchFormat: "draft")
    }
  } else {
    #expect(throws: Error.self) {
      try validateDistinctLoadoutOutputs(
        outputURL: directory.appendingPathComponent("ALLY-1-HELD-1.PNG"),
        diagnosticDirectory: directory,
        matchFormat: "draft")
    }
  }
  #expect(throws: Error.self) {
    try validateDistinctLoadoutOutputs(
      outputURL: directory.deletingLastPathComponent(),
      diagnosticDirectory: directory,
      matchFormat: "draft")
  }
  #expect(throws: Error.self) {
    try validateDistinctLoadoutOutputs(
      outputURL: directory, diagnosticDirectory: directory, matchFormat: "draft")
  }
  #expect(throws: Error.self) {
    try validateDistinctLoadoutOutputs(
      outputURL: directory.appendingPathComponent("ally-1-held-1.png/result.json"),
      diagnosticDirectory: directory,
      matchFormat: "draft")
  }
  #expect(throws: Never.self) {
    try validateDistinctLoadoutOutputs(
      outputURL: directory.appendingPathComponent("loadout.json"),
      diagnosticDirectory: directory,
      matchFormat: "draft")
  }
}

@Test func loadoutOutputCollisionResolvesExistingSymlinks() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let realDirectory = root.appendingPathComponent("real", isDirectory: true)
  let linkedDirectory = root.appendingPathComponent("link", isDirectory: true)
  try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    at: linkedDirectory, withDestinationURL: realDirectory)
  defer { try? FileManager.default.removeItem(at: root) }

  #expect(throws: Error.self) {
    try validateDistinctLoadoutOutputs(
      outputURL: realDirectory.appendingPathComponent("ally-1-held-1.png"),
      diagnosticDirectory: linkedDirectory,
      matchFormat: "draft")
  }
  #expect(throws: Error.self) {
    try validateDistinctLoadoutOutputs(
      outputURL: linkedDirectory.appendingPathComponent("ally-1-held-1.png"),
      diagnosticDirectory: realDirectory,
      matchFormat: "draft")
  }
}

@Test func loadoutOutputCollisionResolvesDanglingSymlinks() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  let realDirectory = root.appendingPathComponent("real", isDirectory: true)
  let linkedDirectory = root.appendingPathComponent("link", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(
    at: linkedDirectory, withDestinationURL: realDirectory)
  defer { try? FileManager.default.removeItem(at: root) }

  #expect(throws: Error.self) {
    try validateDistinctLoadoutOutputs(
      outputURL: linkedDirectory.appendingPathComponent("ally-1-held-1.png"),
      diagnosticDirectory: realDirectory,
      matchFormat: "draft")
  }
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

@Test func legacyLoadoutInputRejectsFormatVersion2() throws {
  let bundle = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("ldtxrecord")
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: bundle) }
  let data = try PropertyListSerialization.data(
    fromPropertyList: ["LDTXRecordingFormatVersion": 2], format: .xml, options: 0)
  try data.write(to: bundle.appendingPathComponent("Info.plist"))

  #expect(throws: Error.self) {
    try validateLegacyLoadoutInputBundle(bundle)
  }
}

private func descriptorDatabaseFixture(
  category: UInt64? = nil,
  heldName: Data? = nil,
  createdAt: String = "2026-08-06T00:00:00Z"
) -> Data {
  let configuration = protobufMessage([
    protobufVarintField(1, 8),
    protobufFixed32Field(2, Float(0.001).bitPattern),
    protobufVarintField(3, 64),
  ])
  let held = descriptorEntry(
    name: heldName ?? Data("held-fixture".utf8), category: category ?? 1, byte: 0x00)
  let battle = descriptorEntry(name: Data("battle-fixture".utf8), category: 2, byte: 0xFF)
  return protobufMessage([
    protobufVarintField(1, 2),
    protobufBytesField(2, configuration),
    protobufBytesField(3, held),
    protobufBytesField(3, battle),
    protobufBytesField(4, Data("550e8400-e29b-41d4-a716-446655440000".utf8)),
    protobufBytesField(5, Data(createdAt.utf8)),
  ])
}

private func loadAndNormalizeFixtureImage(_ url: URL) throws -> CGImage {
  let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  return try VideoFrameSupport.resized(image, width: 1920, height: 1080)
}

private func descriptorEntry(name: Data, category: UInt64, byte: UInt8) -> Data {
  protobufMessage([
    protobufBytesField(1, name),
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
