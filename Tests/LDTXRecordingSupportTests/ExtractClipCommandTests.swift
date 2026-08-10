// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import UniteAnalysisSwiftCommands

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

@Test func networkOptimizedMP4PlacesMoovBeforeMdat() throws {
  let optimized =
    mp4Atom("ftyp", payloadSize: 4) + mp4Atom("moov", payloadSize: 8)
    + mp4Atom("mdat", payloadSize: 16)
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try optimized.write(to: url)
  let atoms = try parseAtoms(optimized)

  try validateNetworkOptimizedMP4(at: url)
  #expect(atoms.map(\.type) == ["ftyp", "moov", "mdat"])
  #expect(atoms[1].offset < atoms[2].offset)
}

@Test func topLevelMP4ParserExposesMdatBeforeMoov() throws {
  let nonoptimized =
    mp4Atom("ftyp", payloadSize: 4) + mp4Atom("mdat", payloadSize: 16)
    + mp4Atom("moov", payloadSize: 8)
  let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: url) }
  try nonoptimized.write(to: url)
  let atoms = try parseAtoms(nonoptimized)

  #expect(throws: UniteAnalysisSwiftToolError.self) {
    try validateNetworkOptimizedMP4(at: url)
  }
  let moov = try #require(atoms.first(where: { $0.type == "moov" }))
  let mdat = try #require(atoms.first(where: { $0.type == "mdat" }))
  #expect(moov.offset > mdat.offset)
}

@Test func topLevelMP4ParserRejectsTruncatedAtoms() {
  let data = Data([0, 0, 0, 20]) + Data("mdat".utf8) + Data(repeating: 0, count: 4)

  #expect(throws: UniteAnalysisSwiftToolError.self) {
    _ = try parseAtoms(data)
  }
}

private func parseAtoms(_ data: Data) throws -> [MP4TopLevelAtom] {
  try parseTopLevelMP4Atoms(fileSize: UInt64(data.count)) { offset, count in
    let start = Int(offset)
    return data.subdata(in: start..<min(start + count, data.count))
  }
}

private func mp4Atom(_ type: String, payloadSize: Int) -> Data {
  let size = UInt32(payloadSize + 8)
  var data = Data([
    UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
    UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
  ])
  data.append(Data(type.utf8))
  data.append(Data(repeating: 0, count: payloadSize))
  return data
}
