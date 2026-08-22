// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import LDTXRecordingSupport
import Testing

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test func resolvesMainMediaFromInfoPlist() throws {
  let bundle = try temporaryDirectory().appendingPathComponent("sample.ldtxrecord")
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
  FileManager.default.createFile(
    atPath: bundle.appendingPathComponent(".finalized").path, contents: Data())
  FileManager.default.createFile(
    atPath: bundle.appendingPathComponent("main.mp4").path, contents: Data())
  let plist = ["LDTXRecordingMainMediaFile": "main.mp4"]
  let plistData = try PropertyListSerialization.data(
    fromPropertyList: plist, format: .xml, options: 0)
  try plistData.write(to: bundle.appendingPathComponent("Info.plist"))

  let resolved = try ResolvedRecordingInput.resolve(bundle.path)
  #expect(resolved.videoURL.lastPathComponent == "main.mp4")
}

@Test func rejectsUnfinishedBundlesUnlessExplicitlyAllowed() throws {
  let bundle = try temporaryDirectory().appendingPathComponent("sample.ldtxrecord")
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: bundle.deletingLastPathComponent()) }
  FileManager.default.createFile(
    atPath: bundle.appendingPathComponent("output-video.mp4").path, contents: Data())

  #expect(throws: RecordingInputError.self) {
    try ResolvedRecordingInput.resolve(bundle.path)
  }
  let resolved = try ResolvedRecordingInput.resolve(bundle.path, allowUnfinished: true)
  #expect(resolved.videoURL.lastPathComponent == "output-video.mp4")
}

@Test func findsRecordingBundleAboveNestedRecordSpec() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let bundle = root.appendingPathComponent("sample.ldtxrecord", isDirectory: true)
  let recordSpec = bundle.appendingPathComponent("Visions/match/record-spec.json")
  try FileManager.default.createDirectory(
    at: recordSpec.deletingLastPathComponent(), withIntermediateDirectories: true)

  #expect(try LDTXRecordingBundle.containing(recordSpec) == bundle)
}

@Test func formatV2MainMediaUsesFixedFilename() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let bundle = root.appendingPathComponent("sample.ldtxrecord", isDirectory: true)
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  let plist: [String: Any] = [
    "LDTXRecordingFormatVersion": 2,
    "LDTXRecordingMainMediaFile": "unexpected.mp4",
  ]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: bundle.appendingPathComponent("Info.plist"))
  FileManager.default.createFile(
    atPath: bundle.appendingPathComponent("main.fragmented.mp4").path, contents: Data())

  #expect(
    try LDTXRecordingBundle.formatV2MainMediaURL(in: bundle)
      == bundle.appendingPathComponent("main.fragmented.mp4"))
}

@Test func formatV2MainMediaStillRejectsInvalidMetadataAndMissingMedia() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let bundle = root.appendingPathComponent("sample.ldtxrecord", isDirectory: true)
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

  try Data("not a plist".utf8).write(to: bundle.appendingPathComponent("Info.plist"))
  #expect(throws: RecordingInputError.self) {
    try LDTXRecordingBundle.formatV2MainMediaURL(in: bundle)
  }

  let legacyPlist: [String: Any] = ["LDTXRecordingFormatVersion": 1]
  try PropertyListSerialization.data(
    fromPropertyList: legacyPlist, format: .xml, options: 0
  ).write(to: bundle.appendingPathComponent("Info.plist"))
  #expect(throws: RecordingInputError.self) {
    try LDTXRecordingBundle.formatV2MainMediaURL(in: bundle)
  }

  let currentPlist: [String: Any] = ["LDTXRecordingFormatVersion": 2]
  try PropertyListSerialization.data(
    fromPropertyList: currentPlist, format: .xml, options: 0
  ).write(to: bundle.appendingPathComponent("Info.plist"))
  #expect(throws: RecordingInputError.self) {
    try LDTXRecordingBundle.formatV2MainMediaURL(in: bundle)
  }
}

@Test func outputFileWriterRejectsDestinationCreatedAfterPreflight() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let output = root.appendingPathComponent("output.json")
  let temporary = OutputFileWriter.temporaryURL(for: output)
  try Data("candidate\n".utf8).write(to: temporary)
  try Data("raced\n".utf8).write(to: output)

  #expect(throws: OutputFileError.self) {
    try OutputFileWriter.install(temporary, at: output, force: false)
  }
  #expect(try Data(contentsOf: output) == Data("raced\n".utf8))
}

@Test func outputFileWriterReplacesExistingDestinationWhenForced() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let output = root.appendingPathComponent("output.json")
  try Data("original\n".utf8).write(to: output)

  try OutputFileWriter.write(Data("replacement\n".utf8), to: output, force: true)

  #expect(try Data(contentsOf: output) == Data("replacement\n".utf8))
}

@Test func forcedOutputReplacementPreservesDestinationPermissions() throws {
  let root = try temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let output = root.appendingPathComponent("output.json")
  try Data("original\n".utf8).write(to: output)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o600], ofItemAtPath: output.path)

  try OutputFileWriter.write(Data("replacement\n".utf8), to: output, force: true)

  let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
  #expect(attributes[.posixPermissions] as? NSNumber == NSNumber(value: 0o600))
}
