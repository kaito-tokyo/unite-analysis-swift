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

      unite-analysis-swift extract-clip --record-spec _PokemonUniteMatches/match-01/record-spec.json --start 420 --end 510 --output _PokemonUniteAnalysis/matches/match-01/final-stretch.mp4

      COPYING. AVAssetExportPresetPassthrough copies compatible compressed audio and video samples
      without decoding and re-encoding them. The requested start does not create a new video
      keyframe, so a player may begin decoding from an adjacent sync sample. Use re-encoding when a
      frame-exact independently decodable start is required.

      OUTPUT. The output must have the .mp4 extension. An existing output is an error unless --force is supplied. Export first writes a temporary sibling and only replaces the destination after a successful export. stdout contains one JSON object with the output path, requested interval, actual duration, duration difference, first output-video sample PTS and sync status, preceding source-video sync PTS, and the requested start's GOP alignment offset.

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
  let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
  RecordVisionInputLogger.sourceVideo(recording.videoURL)
  try validateClipOutput(outputURL, isDistinctFrom: recording.videoURL)
  let asset = AVURLAsset(url: recording.videoURL)
  let assetDuration = try await asset.load(.duration)
  let matchStart = CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale)
  let clipStart = CMTimeAdd(matchStart, CMTime(seconds: start, preferredTimescale: 60_000))
  let clipEnd = CMTimeAdd(matchStart, CMTime(seconds: end, preferredTimescale: 60_000))
  guard CMTimeCompare(clipStart, .zero) >= 0, CMTimeCompare(clipEnd, assetDuration) <= 0 else {
    throw UniteAnalysisSwiftToolError.message(
      "Requested clip is outside source-video range [0.000, \(canonicalSeconds(assetDuration.seconds))]s"
    )
  }
  let gopAlignment = try await inspectSourceGOPAlignment(asset: asset, requestedStart: clipStart)
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
  let result = try await inspectExtractedClip(
    at: temporaryURL, outputURL: outputURL, requestedStart: start, requestedEnd: end,
    gopAlignment: gopAlignment)
  try finalizeExtractedClip(at: temporaryURL, outputURL: outputURL, force: force)
  FileHandle.standardOutput.write(try encodeExtractedClipResult(result) + Data("\n".utf8))
}

func finalizeExtractedClip(at temporaryURL: URL, outputURL: URL, force: Bool) throws {
  if force {
    if FileManager.default.fileExists(atPath: outputURL.path) {
      _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
    }
    return
  }

  do {
    try FileManager.default.linkItem(at: temporaryURL, to: outputURL)
    try FileManager.default.removeItem(at: temporaryURL)
  } catch CocoaError.fileWriteFileExists {
    throw UniteAnalysisSwiftToolError.message(
      "Output collision: \(outputURL.path). Pass --force to replace.")
  }
}

struct ExtractedClipResult: Encodable {
  let output: String
  let requestedStart: Double
  let requestedEnd: Double
  let requestedDuration: Double
  let actualDuration: Double
  let durationDifference: Double
  let firstVideoPTS: Double
  let firstVideoSampleIsSync: Bool
  let precedingSourceVideoSyncPTS: Double?
  let startGOPAlignmentOffset: Double?
}

func inspectExtractedClip(
  at clipURL: URL, outputURL: URL, requestedStart: Double, requestedEnd: Double,
  gopAlignment: SourceGOPAlignment
) async throws -> ExtractedClipResult {
  let asset = AVURLAsset(url: clipURL)
  let duration = try await asset.load(.duration).seconds
  guard duration.isFinite, duration > 0 else {
    throw UniteAnalysisSwiftToolError.message(
      "Could not determine a positive extracted-clip duration: \(clipURL.path)")
  }
  guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
    throw UniteAnalysisSwiftToolError.message("Extracted clip has no video track: \(clipURL.path)")
  }
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
  output.alwaysCopiesSampleData = false
  guard reader.canAdd(output) else {
    throw UniteAnalysisSwiftToolError.message(
      "Could not inspect extracted-clip video samples: \(clipURL.path)")
  }
  reader.add(output)
  guard reader.startReading(), let sample = output.copyNextSampleBuffer() else {
    throw reader.error
      ?? UniteAnalysisSwiftToolError.message(
        "Extracted clip contains no readable video samples: \(clipURL.path)")
  }
  let firstPTS = CMSampleBufferGetPresentationTimeStamp(sample).seconds
  guard firstPTS.isFinite else {
    throw UniteAnalysisSwiftToolError.message(
      "Extracted clip has no finite first video PTS: \(clipURL.path)")
  }
  let requestedDuration = requestedEnd - requestedStart
  return ExtractedClipResult(
    output: outputURL.path,
    requestedStart: requestedStart,
    requestedEnd: requestedEnd,
    requestedDuration: requestedDuration,
    actualDuration: duration,
    durationDifference: duration - requestedDuration,
    firstVideoPTS: firstPTS,
    firstVideoSampleIsSync: videoSampleIsSync(sample),
    precedingSourceVideoSyncPTS: gopAlignment.precedingSyncPTS,
    startGOPAlignmentOffset: gopAlignment.offset)
}

struct SourceGOPAlignment {
  let precedingSyncPTS: Double?
  let offset: Double?
}

func inspectSourceGOPAlignment(asset: AVAsset, requestedStart: CMTime) async throws
  -> SourceGOPAlignment
{
  guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
    throw UniteAnalysisSwiftToolError.message("Source media has no video track")
  }
  let reader = try AVAssetReader(asset: asset)
  let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: nil)
  output.alwaysCopiesSampleData = false
  guard reader.canAdd(output) else {
    throw UniteAnalysisSwiftToolError.message("Could not inspect source-video GOP alignment")
  }
  reader.add(output)
  reader.timeRange = CMTimeRange(
    start: .zero,
    end: CMTimeAdd(requestedStart, CMTime(value: 1, timescale: 60_000)))
  guard reader.startReading() else {
    throw reader.error
      ?? UniteAnalysisSwiftToolError.message("Could not read source-video GOP alignment")
  }
  var precedingSyncPTS: Double?
  while let sample = output.copyNextSampleBuffer() {
    let pts = CMSampleBufferGetPresentationTimeStamp(sample).seconds
    if pts.isFinite, pts <= requestedStart.seconds, videoSampleIsSync(sample) {
      precedingSyncPTS = pts
    }
  }
  if reader.status == .failed {
    throw reader.error
      ?? UniteAnalysisSwiftToolError.message("Could not read source-video GOP alignment")
  }
  let offset = precedingSyncPTS.map { requestedStart.seconds - $0 }
  return SourceGOPAlignment(precedingSyncPTS: precedingSyncPTS, offset: offset)
}

func videoSampleIsSync(_ sample: CMSampleBuffer) -> Bool {
  guard
    let attachments = CMSampleBufferGetSampleAttachmentsArray(
      sample, createIfNecessary: false) as? [[CFString: Any]],
    let first = attachments.first
  else { return true }
  return first[kCMSampleAttachmentKey_NotSync] as? Bool != true
}

func encodeExtractedClipResult(_ result: ExtractedClipResult) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return try encoder.encode(result)
}

func validateClipOutput(_ outputURL: URL, isDistinctFrom sourceVideoURL: URL) throws {
  let resolvedOutputURL = outputURL.standardizedFileURL.resolvingSymlinksInPath()
  let resolvedSourceVideoURL = sourceVideoURL.standardizedFileURL.resolvingSymlinksInPath()
  guard resolvedOutputURL != resolvedSourceVideoURL else {
    throw UniteAnalysisSwiftToolError.message(
      "Output path must not replace the source video: \(sourceVideoURL.path)")
  }
}
