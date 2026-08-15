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
