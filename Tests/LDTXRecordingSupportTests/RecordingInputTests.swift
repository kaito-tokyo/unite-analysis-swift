// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import LDTXRecordingSupport

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test func resolvesMainMediaFromInfoPlistAndReadsVisionIndex() throws {
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

  let visionDirectory = bundle.appendingPathComponent("Visions/scene", isDirectory: true)
  try FileManager.default.createDirectory(at: visionDirectory, withIntermediateDirectories: true)
  FileManager.default.createFile(
    atPath: visionDirectory.appendingPathComponent("frame.jpg").path, contents: Data())
  let vision: [String: Any] = [
    "visionID": "scene",
    "recordingTimelineMilliseconds": 5_250,
    "output": "RS",
    "imageFileName": "frame.jpg",
  ]
  try JSONSerialization.data(withJSONObject: vision).write(
    to: visionDirectory.appendingPathComponent("frame.json"))

  let resolved = try ResolvedRecordingInput.resolve(bundle.path)
  #expect(resolved.videoURL.lastPathComponent == "main.mp4")
  let records = resolved.visionIndexRecords()
  #expect(records.count == 1)
  #expect(records[0].visionID == "scene")
  #expect(records[0].recordingTimelineMilliseconds == 5_250)
  #expect(records[0].output == "RS")
  #expect(
    records[0].jsonURL.resolvingSymlinksInPath().path
      == visionDirectory.appendingPathComponent("frame.json").resolvingSymlinksInPath().path)
  #expect(
    records[0].imageURL?.resolvingSymlinksInPath().path
      == visionDirectory.appendingPathComponent("frame.jpg").resolvingSymlinksInPath().path)
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

@Test func findsExecutablesUsingPath() {
  #expect(findExecutable("sh") != nil)
  #expect(findExecutable("an-executable-that-should-not-exist-ldtx") == nil)
}
