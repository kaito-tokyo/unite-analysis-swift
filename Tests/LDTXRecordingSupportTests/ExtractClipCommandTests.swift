// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

import UniteAnalysisSwiftCommands

@Test func extractClipUsesV2FixedNameInsteadOfConflictingMetadata() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let bundle = root.appendingPathComponent("sample.ldtxrecord", isDirectory: true)
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let plist: [String: Any] = [
    "LDTXRecordingFormatVersion": 2,
    "LDTXRecordingMainMediaFile": "unexpected.mp4",
  ]
  try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    .write(to: bundle.appendingPathComponent("Info.plist"))
  FileManager.default.createFile(
    atPath: bundle.appendingPathComponent("main.fragmented.mp4").path, contents: Data())
  FileManager.default.createFile(
    atPath: bundle.appendingPathComponent("unexpected.mp4").path, contents: Data())

  #expect(
    try extractClipVideoURL(in: bundle)
      == bundle.appendingPathComponent("main.fragmented.mp4"))
}
