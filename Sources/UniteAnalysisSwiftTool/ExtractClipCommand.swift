// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import ArgumentParser
import CoreMedia
import Foundation
import LDTXRecordingSupport
import RecordVisionSupport

struct ExtractClip: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "extract-clip",
    abstract: "Copy a match-relative interval into an MP4 without re-encoding.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because it uses AVFoundation media export.

      INPUT. --record-spec identifies one match in a recording format v2 .ldtxrecord. Run from the .ldtxrecord root. --start and --end are seconds relative to match start. --start defaults to 0 and --end defaults to the match duration.

      COMPLETE EXAMPLE.

      unite-analysis swift extract-clip --record-spec _PokemonUniteMatches/match-01/record-spec.json --start 420 --end 510 --output _PokemonUniteAnalysis/matches/match-01/final-stretch.mp4

      COPYING. AVAssetExportPresetPassthrough copies compatible compressed audio and video samples
      without decoding and re-encoding them. The requested start does not create a new video
      keyframe, so a player may begin decoding from an adjacent sync sample. Use re-encoding when a
      frame-exact independently decodable start is required.

      OUTPUT. The output must have the .mp4 extension. An existing output is an error unless --force is supplied. Export first writes a temporary sibling and only replaces the destination after a successful export. The generated absolute output path is printed to stdout.

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

  mutating func run() async throws {
    guard start.isFinite else {
      throw ValidationError("--start must be finite")
    }
    if let end, !end.isFinite {
      throw ValidationError("--end must be finite")
    }
    try await extractClip(
      recordSpecURL: resolveRecordSpec(recordSpec),
      start: start,
      end: end,
      outputURL: resolvePath(output),
      force: force
    )
  }
}

func extractClip(
  recordSpecURL: URL,
  start: Double,
  end requestedEnd: Double?,
  outputURL: URL,
  force: Bool
) async throws {
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
  guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
    throw UniteAnalysisSwiftToolError.message(
      "Output collision: \(outputURL.path). Pass --force to replace.")
  }

  let bundleURL = try recordingBundle(above: recordSpecURL)
  if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path) {
    RecordVisionInputLogger.unfinishedRecording(bundleURL)
  }
  let videoURL = try extractClipVideoURL(in: bundleURL)
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
  if FileManager.default.fileExists(atPath: outputURL.path) {
    _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
  } else {
    try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
  }
  print(outputURL.path)
}

func extractClipVideoURL(in bundleURL: URL) throws -> URL {
  let infoURL = bundleURL.appendingPathComponent("Info.plist")
  guard let data = try? Data(contentsOf: infoURL),
    let plist = try? PropertyListSerialization.propertyList(from: data, options: 0, format: nil),
    let dictionary = plist as? [String: Any]
  else {
    throw UniteAnalysisSwiftToolError.message(
      "Could not read LDTX recording metadata: \(infoURL.path)")
  }
  let formatVersion = (dictionary["LDTXRecordingFormatVersion"] as? NSNumber)?.intValue
  guard formatVersion == 2 else {
    throw UniteAnalysisSwiftToolError.message(
      "extract-clip requires LDTX recording format version 2: \(infoURL.path)")
  }
  let videoURL = bundleURL.appendingPathComponent("main.fragmented.mp4").standardizedFileURL
  guard FileManager.default.fileExists(atPath: videoURL.path) else {
    throw UniteAnalysisSwiftToolError.message(
      "Recording format v2 main media file was not found: \(videoURL.path)")
  }
  return videoURL
}
