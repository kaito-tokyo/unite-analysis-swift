// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import ArgumentParser
import CoreMedia
import Foundation
import LDTXRecordingSupport
import RecordVisionSupport

struct ExtractClip: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "extract-clip",
    abstract: "Copy a match-relative interval into an MP4 without re-encoding.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because it uses AVFoundation media export.

      INPUT. --record-spec identifies one match in a recording format v2 .ldtxrecord. Run from the .ldtxrecord root. --start and --end are seconds relative to match start. --start defaults to 0 and --end defaults to the match duration.

      COMPLETE EXAMPLE.

      unite-analysis-swift extract-clip --record-spec _PokemonUniteMatches/match-01/record-spec.json --start 420 --end 510 --output _PokemonUniteAnalysis/matches/match-01/final-stretch.mp4

      COPYING. AVAssetExportPresetPassthrough copies compatible compressed audio and video samples
      without decoding and re-encoding them. The requested start does not create a new video
      keyframe. A non-keyframe start can retain negative-timestamp synchronization-sample preroll
      and edit-list handling even though the visible interval starts at the requested time. Use
      re-encoding when a frame-exact independently decodable start without preroll is required.

      OUTPUT. The output must have the .mp4 extension. An existing output is an error unless --force is supplied. Export first writes a temporary sibling, requests network-optimized layout, verifies that the top-level moov atom precedes mdat, and only replaces the destination after successful export and verification. The generated absolute output path is printed to stdout.

      DIAGNOSTICS. The resolved record-spec.json and main video, unfinished-recording warnings, and requested source PTS interval are written to stderr.
      """.reflowedHelp()
  )

  @Option(help: "Required record-spec.json path. Run from the .ldtxrecord root.")
  var recordSpec: String
  @Option(help: "Finite seconds relative to match start; defaults to 0.") var start = 0.0
  @Option(help: "Finite seconds relative to match start; defaults to match duration.")
  var end: Double?
  @Option(help: "Required .mp4 output path.") var output: String
  @Flag(help: "Replace the output if it already exists.") var force = false

  func validate() throws {
    guard start.isFinite else {
      throw ValidationError("--start must be finite")
    }
    if let end, !end.isFinite {
      throw ValidationError("--end must be finite")
    }
  }

}

extension ExtractClip {
  struct OutputRecord: Sendable {
    let output: String
  }

  func outputRecords() -> AsyncThrowingStream<OutputRecord, Error> {
    commandOutputStream { continuation in
      let command = self
      let output = try await extractClip(
        recordSpecURL: resolveRecordSpec(command.recordSpec),
        start: command.start,
        end: command.end,
        outputURL: resolvePath(command.output),
        force: command.force)
      continuation.yield(.init(output: output))
    }
  }
}

func extractClip(
  recordSpecURL: URL,
  start: Double,
  end requestedEnd: Double?,
  outputURL: URL,
  force: Bool
) async throws -> String {
  let spec = try JSONDecoder().decode(RecordSpec.self, from: Data(contentsOf: recordSpecURL))
  RecordVisionInputLogger.recordSpec(recordSpecURL)
  guard spec.startPTS.timescale > 0, spec.duration.isFinite, spec.duration > 0 else {
    throw UniteAnalysisSwiftToolError.message(
      "record-spec.json must have a positive startPTS timescale and duration")
  }
  let end = requestedEnd ?? spec.duration
  guard start >= 0, end <= spec.duration, start < end else {
    throw UniteAnalysisSwiftToolError.message(
      "Clip interval must satisfy 0 <= start < end <= record-spec duration (\(canonicalSeconds(spec.duration))s)"
    )
  }
  guard outputURL.pathExtension.lowercased() == "mp4" else {
    throw UniteAnalysisSwiftToolError.message("Output path must have the .mp4 extension")
  }
  try validateOutputPath(outputURL, force: force)

  let bundleURL = try LDTXRecordingBundle.containing(recordSpecURL)
  if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path) {
    RecordVisionInputLogger.unfinishedRecording(bundleURL)
  }
  let videoURL = try LDTXRecordingBundle.formatV2MainMediaURL(in: bundleURL)
  RecordVisionInputLogger.sourceVideo(videoURL)
  let asset = AVURLAsset(url: videoURL)
  let assetDuration = try await asset.load(.duration)
  let matchStart = CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale)
  let clipStart = CMTimeAdd(matchStart, CMTime(seconds: start, preferredTimescale: 60_000))
  let clipEnd = CMTimeAdd(matchStart, CMTime(seconds: end, preferredTimescale: 60_000))
  guard CMTimeCompare(clipStart, .zero) >= 0, CMTimeCompare(clipEnd, assetDuration) <= 0 else {
    throw UniteAnalysisSwiftToolError.message(
      "Requested clip is outside source-video range [0.000, \(canonicalSeconds(assetDuration.seconds))]s"
    )
  }
  guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough)
  else {
    throw UniteAnalysisSwiftToolError.message("Source media does not support passthrough export")
  }
  guard session.supportedFileTypes.contains(.mp4) else {
    throw UniteAnalysisSwiftToolError.message("Source media cannot be passed through to MP4")
  }
  session.timeRange = CMTimeRange(start: clipStart, end: clipEnd)
  session.shouldOptimizeForNetworkUse = true

  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
    ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.mp4")
  defer { try? FileManager.default.removeItem(at: temporaryURL) }
  FileHandle.standardError.write(
    Data(
      "unite-analysis-swift: clip requested PTS [\(canonicalSeconds(clipStart.seconds)), \(canonicalSeconds(clipEnd.seconds)))s\n"
        .utf8))
  try await session.export(to: temporaryURL, as: .mp4)
  try validateNetworkOptimizedMP4(at: temporaryURL)
  try OutputFileWriter.install(temporaryURL, at: outputURL, force: force)
  return outputURL.path
}

package struct MP4TopLevelAtom: Equatable, Sendable {
  package let type: String
  package let offset: UInt64
  package let size: UInt64
}

package func parseTopLevelMP4Atoms(
  fileSize: UInt64,
  read: (UInt64, Int) throws -> Data
) throws -> [MP4TopLevelAtom] {
  var atoms: [MP4TopLevelAtom] = []
  var offset: UInt64 = 0
  while offset < fileSize {
    guard fileSize - offset >= 8 else {
      throw UniteAnalysisSwiftToolError.message("Truncated MP4 top-level atom header")
    }
    let header = try read(offset, 8)
    guard header.count == 8 else {
      throw UniteAnalysisSwiftToolError.message("Could not read MP4 top-level atom header")
    }
    let size32 = UInt64(header.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
    let type = String(decoding: header.dropFirst(4), as: UTF8.self)
    let headerSize: UInt64
    let atomSize: UInt64
    if size32 == 1 {
      let extended = try read(offset + 8, 8)
      guard extended.count == 8 else {
        throw UniteAnalysisSwiftToolError.message("Truncated MP4 extended atom size")
      }
      headerSize = 16
      atomSize = extended.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    } else if size32 == 0 {
      headerSize = 8
      atomSize = fileSize - offset
    } else {
      headerSize = 8
      atomSize = size32
    }
    guard atomSize >= headerSize, atomSize <= fileSize - offset else {
      throw UniteAnalysisSwiftToolError.message(
        "Invalid MP4 top-level atom size for \(type) at offset \(offset)")
    }
    atoms.append(.init(type: type, offset: offset, size: atomSize))
    offset += atomSize
  }
  return atoms
}

package func validateNetworkOptimizedMP4(at url: URL) throws {
  let handle = try FileHandle(forReadingFrom: url)
  defer { try? handle.close() }
  let fileSize = try handle.seekToEnd()
  let atoms = try parseTopLevelMP4Atoms(fileSize: fileSize) { offset, count in
    try handle.seek(toOffset: offset)
    return try handle.read(upToCount: count) ?? Data()
  }
  guard let moov = atoms.first(where: { $0.type == "moov" }),
    let mdat = atoms.first(where: { $0.type == "mdat" })
  else {
    throw UniteAnalysisSwiftToolError.message(
      "Exported MP4 must contain top-level moov and mdat atoms")
  }
  guard moov.offset < mdat.offset else {
    throw UniteAnalysisSwiftToolError.message(
      "Exported MP4 is not network optimized: top-level moov follows mdat")
  }
}
