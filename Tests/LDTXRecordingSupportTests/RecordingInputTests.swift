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
