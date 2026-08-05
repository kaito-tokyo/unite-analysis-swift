// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import ArgumentParser
import CoreGraphics
import CoreMedia
import Foundation
import LDTXRecordingSupport
import RecordVisionSupport
import ResultScannerSupport
import UniteAnalysisConfiguration

private enum UniteAnalysisSwiftToolError: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let value):
      return value
    }
  }
}

private typealias RecordSpec = RecordVisionRecordSpec

private enum Scene {
  case inmatch(Double)
  case beforeStart(Double)
  case afterEnd(Double)
}

private struct FrameSource: Decodable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int

  var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

  func validate() throws {
    guard x >= 0, y >= 0, width > 0, height > 0 else {
      throw UniteAnalysisSwiftToolError.message(
        "source must be a positive top-left-origin rectangle")
    }
  }
}

private struct FrameRequest {
  let scene: Scene
  let source: FrameSource
  let outputURL: URL
}

private struct BatchFrameJob: Decodable {
  let inmatch: Double?
  let beforeStart: Double?
  let afterEnd: Double?
  let source: FrameSource
  let output: String

  func scene() throws -> Scene {
    let values = [inmatch, beforeStart, afterEnd].compactMap { $0 }
    guard values.count == 1, let value = values.first, value.isFinite, value >= 0 else {
      throw UniteAnalysisSwiftToolError.message(
        "Each batch-frame job must specify exactly one finite nonnegative inmatch, beforeStart, or afterEnd value"
      )
    }
    if inmatch != nil { return .inmatch(value) }
    if beforeStart != nil { return .beforeStart(value) }
    return .afterEnd(value)
  }
}

private func cwdURL() -> URL {
  URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

private func resolvePath(_ path: String) -> URL {
  if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
  return cwdURL().appendingPathComponent(path).standardizedFileURL
}

private func recordingBundle(above recordSpecURL: URL) throws -> URL {
  var candidate = recordSpecURL.deletingLastPathComponent()
  while candidate.path != "/" {
    if candidate.pathExtension == "ldtxrecord" { return candidate }
    candidate.deleteLastPathComponent()
  }
  throw UniteAnalysisSwiftToolError.message(
    "record-spec.json must be inside a .ldtxrecord bundle: \(recordSpecURL.path)")
}

private func canonicalSeconds(_ value: Double) -> String {
  String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
}

private func renderFrames(
  recordSpecURL: URL,
  requests frameRequests: [FrameRequest],
  quality: Double,
  force: Bool
) async throws {
  guard !frameRequests.isEmpty else {
    throw UniteAnalysisSwiftToolError.message("At least one frame request is required")
  }
  let spec = try JSONDecoder().decode(RecordSpec.self, from: Data(contentsOf: recordSpecURL))
  RecordVisionInputLogger.recordSpec(recordSpecURL)
  guard spec.startPTS.timescale > 0 else {
    throw UniteAnalysisSwiftToolError.message("startPTS.timescale must be positive")
  }
  let start = CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale)
  let bundleURL = try recordingBundle(above: recordSpecURL)
  if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path) {
    RecordVisionInputLogger.unfinishedRecording(bundleURL)
  }
  let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
  RecordVisionInputLogger.sourceVideo(recording.videoURL)
  let extractor = try await VideoFrameExtractor(videoURL: recording.videoURL)
  let videoDurationSeconds = CMTimeGetSeconds(extractor.duration)
  guard videoDurationSeconds.isFinite, videoDurationSeconds > 0 else {
    throw UniteAnalysisSwiftToolError.message(
      "Could not determine a positive source-video duration: \(recording.videoURL.path)")
  }
  var requests: [(time: CMTime, source: FrameSource, url: URL)] = []
  for frameRequest in frameRequests {
    try frameRequest.source.validate()
    let scene = frameRequest.scene
    let offset: Double
    switch scene {
    case .inmatch(let seconds):
      guard seconds.isFinite, seconds >= 0 else {
        throw UniteAnalysisSwiftToolError.message(
          "inmatch seconds must be a finite value greater than or equal to zero")
      }
      offset = seconds
    case .beforeStart(let seconds):
      guard seconds.isFinite, seconds >= 0 else {
        throw UniteAnalysisSwiftToolError.message(
          "before-start seconds must be a finite value greater than or equal to zero")
      }
      offset = -seconds
    case .afterEnd(let seconds):
      guard seconds.isFinite, seconds >= 0 else {
        throw UniteAnalysisSwiftToolError.message(
          "after-end seconds must be a finite value greater than or equal to zero")
      }
      offset = spec.duration + seconds
    }
    let requestedTime = CMTimeAdd(
      start, CMTime(seconds: offset, preferredTimescale: spec.startPTS.timescale))
    let requestedSeconds = CMTimeGetSeconds(requestedTime)
    guard requestedSeconds.isFinite, requestedSeconds >= 0, requestedSeconds < videoDurationSeconds
    else {
      throw UniteAnalysisSwiftToolError.message(
        "Requested frame time \(canonicalSeconds(requestedSeconds))s is outside source-video range [0.000, \(canonicalSeconds(videoDurationSeconds)))s: \(frameRequest.outputURL.path)"
      )
    }
    try FileManager.default.createDirectory(
      at: frameRequest.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    requests.append((requestedTime, frameRequest.source, frameRequest.outputURL))
  }
  var seenPaths = Set<String>()
  for request in requests {
    guard
      force
        || (seenPaths.insert(request.url.path).inserted
          && !FileManager.default.fileExists(atPath: request.url.path))
    else {
      throw UniteAnalysisSwiftToolError.message(
        "Output collision: \(request.url.path). Pass --force to overwrite.")
    }
  }
  let orderedRequests = requests.sorted { CMTimeCompare($0.time, $1.time) < 0 }
  try await extractor.extractApproximateFrames(at: orderedRequests.map(\.time)) {
    index, frame, actualTime in
    let request = orderedRequests[index]
    let image = try VideoFrameSupport.cropped(frame, rect: request.source.rect)
    let outputURL = request.url
    try VideoFrameSupport.writeBaselineJPEG(image, to: outputURL, quality: quality)
    FileHandle.standardError.write(
      Data(
        "unite-analysis-swift: batch frame requested PTS \(canonicalSeconds(request.time.seconds))s, actual PTS \(canonicalSeconds(actualTime.seconds))s\n"
          .utf8
      ))
    print(outputURL.path)
  }
}

private func renderPreciseFrame(
  recordSpecURL: URL,
  scene: Scene,
  source: FrameSource,
  outputURL: URL,
  quality: Double,
  force: Bool
) async throws {
  guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
    throw UniteAnalysisSwiftToolError.message(
      "Output collision: \(outputURL.path). Pass --force to overwrite.")
  }
  let spec = try JSONDecoder().decode(RecordSpec.self, from: Data(contentsOf: recordSpecURL))
  RecordVisionInputLogger.recordSpec(recordSpecURL)
  guard spec.startPTS.timescale > 0 else {
    throw UniteAnalysisSwiftToolError.message("record-spec.json has no usable startPTS")
  }
  try source.validate()
  let offset: Double
  switch scene {
  case .inmatch(let value): offset = value
  case .beforeStart(let value): offset = -value
  case .afterEnd(let value): offset = spec.duration + value
  }
  let requestedTime = CMTimeAdd(
    CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale),
    CMTime(seconds: offset, preferredTimescale: spec.startPTS.timescale))
  let bundleURL = try recordingBundle(above: recordSpecURL)
  if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path) {
    RecordVisionInputLogger.unfinishedRecording(bundleURL)
  }
  let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
  RecordVisionInputLogger.sourceVideo(recording.videoURL)
  let extractor = try await VideoFrameExtractor(videoURL: recording.videoURL)
  guard CMTimeCompare(requestedTime, .zero) >= 0,
    CMTimeCompare(requestedTime, extractor.duration) < 0
  else {
    throw UniteAnalysisSwiftToolError.message(
      "Requested precise frame is outside the source-video range: \(canonicalSeconds(requestedTime.seconds))s"
    )
  }
  let frame = try extractor.extractPreciseFrame(at: requestedTime)
  let image = try VideoFrameSupport.cropped(frame.image, rect: source.rect)
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try VideoFrameSupport.writeBaselineJPEG(image, to: outputURL, quality: quality)
  FileHandle.standardError.write(
    Data(
      "unite-analysis-swift: precise frame requested PTS \(canonicalSeconds(requestedTime.seconds))s, decoded PTS \(canonicalSeconds(frame.presentationTime.seconds))s\n"
        .utf8))
  print(outputURL.path)
}

@main
private struct UniteAnalysisSwiftTool: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "unite-analysis-swift",
    abstract: "Run source-video operations for one Pokémon UNITE record.",
    discussion: """
      Reads record-spec.json as the physical match-to-recording mapping used to locate the
      enclosing .ldtxrecord and its main video. Match-relative inmatch, beforeStart, and afterEnd
      times are converted through that mapping before frames are decoded.
      \(VideoFrameSupport.sandboxDecodingGuidance)
      Requires macOS 26 or later. OCR uses Apple Vision locally. The input video is never a Vision
      JPEG. Commands print machine-readable results or output paths to stdout and diagnostics,
      resolved inputs, timestamps, and unfinished-recording warnings to stderr.
      Audio peak detection uses recording format v2 main-media audio
      to propose visually interesting times; it does not classify events. Run `batch-frame --help`, `precise-frame --help`,
      `contact-sheet --help`, `continuous-ocr --help`, `ocr-input-frame --help`, `detect-chroma-events --help`,
      `audio-peaks --help`, `result-scan --help`, `eval-draw-text-script --help`, or `config --help`
      for their JSON and output contracts.
      """,
    subcommands: [
      BatchFrame.self, PreciseFrame.self, ContactSheet.self, ContinuousOCRCommand.self,
      OCRInputFrame.self, DetectChromaEvents.self, AudioPeaks.self, ResultScan.self,
      EvaluateDrawText.self, Config.self,
    ]
  )
}

private struct Config: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Manage user-specific unite-analysis-swift settings.",
    subcommands: [ConfigGet.self, ConfigSet.self, ConfigUnset.self, ConfigPath.self]
  )
}

private enum ConfigKey: String, ExpressibleByArgument, CaseIterable {
  case obsidianMatchReportsRoot = "obsidian-match-reports-root"
  case obsidianStrategyBooksRoot = "obsidian-strategy-books-root"

  var obsidianDirectory: ObsidianDirectory {
    switch self {
    case .obsidianMatchReportsRoot: .matchReports
    case .obsidianStrategyBooksRoot: .strategyBooks
    }
  }
}

private struct ConfigGet: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "get", abstract: "Print one configured value.")

  @Argument(help: "Configuration key: obsidian-match-reports-root or obsidian-strategy-books-root.")
  var key: ConfigKey

  func run() throws {
    let configuration = try UserConfigurationStore().load()
    let value: String?
    switch key {
    case .obsidianMatchReportsRoot:
      value = configuration.obsidianMatchReportsRoot
    case .obsidianStrategyBooksRoot:
      value = configuration.obsidianStrategyBooksRoot
    }
    guard let value else {
      throw UniteAnalysisSwiftToolError.message("\(key.rawValue) is not configured")
    }
    print(value)
  }
}

private struct ConfigSet: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set", abstract: "Validate and save one configured value.")

  @Argument(help: "Configuration key: obsidian-match-reports-root or obsidian-strategy-books-root.")
  var key: ConfigKey

  @Argument(help: "Value to save.")
  var value: String

  func run() throws {
    print(
      try UserConfigurationStore().setObsidianDirectory(key.obsidianDirectory, path: value).path)
  }
}

private struct ConfigUnset: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "unset", abstract: "Remove one configured value.")

  @Argument(help: "Configuration key: obsidian-match-reports-root or obsidian-strategy-books-root.")
  var key: ConfigKey

  func run() throws {
    try UserConfigurationStore().unsetObsidianDirectory(key.obsidianDirectory)
  }
}

private struct ConfigPath: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "path", abstract: "Print the user configuration file path.")

  func run() {
    print(UserConfigurationStore.defaultFileURL.path)
  }
}

private struct ResultScan: ParsableCommand {
  private enum ScreenType: String, ExpressibleByArgument, CaseIterable {
    case summary
    case battleData = "battle-data"
  }

  static let configuration = CommandConfiguration(
    commandName: "result-scan",
    abstract: "Scan Pokémon UNITE result and battle-data screens into JSON.",
    discussion: """
      Accepts only a 1632x918 cropped game-screen still image. --type is required and selects either
      summary or battle-data parsing; the command does not auto-detect or emit another screen type.
      The image must be a batch-frame or precise-frame
      output using source {x:0,y:0,width:1632,height:918}. Videos, recording bundles, full 1920x1080
      composition images, and other dimensions are rejected. Text recognition uses Apple Vision.

      The highlighted cursor row is never treated as the operated player; all recognized rows are returned.
      Accepted still-image formats are PNG, JPEG, HEIC, TIFF, BMP, and GIF. The selected screen type
      is always returned even when its detection score is low; that condition is added to warnings.
      Output records the input image, generation time, selected screen type, recognized values,
      confidence, and warnings. It does not invent video timestamps or scan metadata.

      This command reads a still image and does not decode video itself. When producing its input
      with a video-decoding command, note: \(VideoFrameSupport.sandboxDecodingGuidance)

      Battle-data uses fixed cell OCR. Summary combines full-screen and row OCR. Japanese and English
      recognition are enabled; language correction is disabled for numeric and proper-name fields. A
      missing standalone score 0 is supplemented without confidence only when the other three values
      in the same row were recognized. Low-confidence player names should be verified from the image.
      """
  )

  @Argument(help: "Path to a cropped 1632x918 game-screen still image.")
  var input: String

  @Option(help: "Screen layout to parse: summary or battle-data.")
  private var type: ScreenType

  @Option(help: "Output JSON path. Writes JSON to stdout when omitted.")
  var output: String?

  mutating func run() throws {
    let resultType: ResultScreenType =
      switch type {
      case .summary: .summary
      case .battleData: .battleData
      }
    try ResultScannerRunner.run(input: input, type: resultType, output: output)
  }
}

private struct AudioPeaks: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "audio-peaks",
    abstract: "Print visually interesting recording-audio SE peak times as JSON.",
    discussion: """
      For recording format v2, reads the audio track embedded in main.fragmented.mp4. The v2
      filename is fixed by the format; LDTXRecordingMainMediaFile normally records the same name
      but is not required for input resolution. Other recording format versions are rejected.
      It then runs a fixed Pokémon UNITE onset detector. The detector uses 10ms integer power blocks and a
      fixed 50ms-versus-200ms FIR. It proposes times for later source-video or contact-sheet
      analysis and never labels a peak as KO, ping, announcement, or any other event.

      Each detected peak is dilated by a fixed 0.5 seconds in both temporal directions. Overlapping
      dilated ranges are united, clipped to the selected interval, and returned alongside the original
      peaks. The detector reads 200ms before the selected start to preserve FIR history and 20ms after
      its end for local-maximum detection, but reports only peaks inside the requested interval.

      --inmatch-start and --duration select one interval within the record-spec match. Omit both
      to analyze the full match. --gain is a fixed linear gain applied before Int16 power
      calculation; there is no automatic gain control. Detector windows, threshold, and peak
      separation are intentionally not configurable. JSON is written to stdout. Input paths and
      unfinished-recording warnings are written to stderr. Missing input metadata or media, a v2
      main media file with no audio track, or an undecodable interval is an error.
      """
  )

  @Option(help: "Path to record-spec.json. Defaults to record-spec.json in the current directory.")
  var recordSpec: String?

  @Option(help: "First match-relative second to analyze. Defaults to 0.")
  var inmatchStart = 0.0

  @Option(help: "Interval length in seconds. Defaults to the rest of the match.")
  var duration: Double?

  @Option(help: "Fixed linear input gain applied before power calculation.")
  var gain = 1.0

  mutating func run() async throws {
    guard inmatchStart.isFinite, inmatchStart >= 0 else {
      throw ValidationError("--inmatch-start must be a finite value greater than or equal to zero")
    }
    guard gain.isFinite, gain > 0 else {
      throw ValidationError("--gain must be a finite value greater than zero")
    }
    let recordSpecURL =
      recordSpec.map(resolvePath) ?? cwdURL().appendingPathComponent("record-spec.json")
    let spec = try JSONDecoder().decode(RecordSpec.self, from: Data(contentsOf: recordSpecURL))
    RecordVisionInputLogger.recordSpec(recordSpecURL)
    guard spec.startPTS.timescale > 0 else {
      throw UniteAnalysisSwiftToolError.message("startPTS.timescale must be positive")
    }
    guard spec.duration.isFinite, spec.duration > 0 else {
      throw UniteAnalysisSwiftToolError.message(
        "record-spec duration must be a positive finite value")
    }
    let selectedDuration = duration ?? (spec.duration - inmatchStart)
    guard selectedDuration.isFinite, selectedDuration > 0 else {
      throw ValidationError("--duration must be a finite value greater than zero")
    }
    guard inmatchStart <= spec.duration,
      inmatchStart + selectedDuration <= spec.duration + 0.000_001
    else {
      throw ValidationError(
        "The requested interval must be contained within the record-spec match duration")
    }

    let bundleURL = try recordingBundle(above: recordSpecURL)
    if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path)
    {
      RecordVisionInputLogger.unfinishedRecording(bundleURL)
    }
    let audioURL = try AudioPeakDetector.audioURL(in: bundleURL)
    RecordVisionInputLogger.sourceAudio(audioURL)
    let result = try await AudioPeakDetector.detect(
      audioURL: audioURL,
      globalId: spec.globalId,
      matchStartPTS: CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale),
      inmatchStart: inmatchStart,
      duration: selectedDuration,
      gain: gain
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(result))
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
}

private struct BatchFrame: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "batch-frame",
    abstract: "Write source-video screenshots from a JSON array of frame jobs.",
    discussion: """
      Supply exactly one positional JSON array. Each object has an output path and exactly one of
      inmatch, beforeStart, or afterEnd in seconds, plus an explicit source {x,y,width,height} rectangle in
      main-video pixels. Frames use AVAssetImageGenerator with its default time tolerance: they are fast but are not
      frame-exact. Each requested and actual source PTS is written to stderr. The source is cropped without resizing.
      Outputs are baseline 8-bit RGB JPEGs. $schema is intentionally
      not used. Relative output paths resolve from the jobs file's directory; with jobs -, they
      resolve from the current directory.

      The resolved record-spec.json and main video are logged to stderr; output paths are printed to
      stdout. An unfinished recording is allowed with a warning, but callers should request only
      finalized time ranges. Decode failures never fall back to another image source.
      \(VideoFrameSupport.sandboxDecodingGuidance)

      Example:
      [
        {"inmatch": 45.5, "source":{"x":0,"y":0,"width":1632,"height":918}, "output": "screenshots/opening.jpg"},
        {"beforeStart": 2, "source":{"x":0,"y":0,"width":1632,"height":918}, "output": "screenshots/selection.jpg"}
      ]
      """
  )

  @Argument(help: "JSON array of frame jobs, or - to read it from standard input.") var jobs: String
  @Option(help: "Required path to record-spec.json.") var recordSpec: String

  @Option(help: "JPEG quality from 0 through 1.")
  var quality: Double = 0.6

  @Flag(help: "Allow overwriting existing outputs or duplicate fixed names.")
  var force = false

  mutating func run() async throws {
    guard quality.isFinite, (0...1).contains(quality) else {
      throw ValidationError("--quality must be a finite value from 0 through 1")
    }
    let jobsURL = jobs == "-" ? nil : resolvePath(jobs)
    let data: Data
    if let jobsURL {
      data = try Data(contentsOf: jobsURL)
    } else {
      data = FileHandle.standardInput.readDataToEndOfFile()
    }
    let definitions = try JSONDecoder().decode([BatchFrameJob].self, from: data)
    guard !definitions.isEmpty else {
      throw ValidationError("jobs must contain at least one frame job")
    }
    let baseURL = jobsURL?.deletingLastPathComponent() ?? cwdURL()
    let requests = try definitions.map { job in
      FrameRequest(
        scene: try job.scene(), source: job.source,
        outputURL: URL(fileURLWithPath: job.output, relativeTo: baseURL).standardizedFileURL)
    }
    try await renderFrames(
      recordSpecURL: resolvePath(recordSpec),
      requests: requests,
      quality: quality,
      force: force
    )
  }
}

private struct PreciseFrame: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "precise-frame",
    abstract: "Write exactly one AVAssetReader-decoded explicit-source screenshot.",
    discussion: """
      This command accepts options only and starts AVAssetReader once, two seconds before the requested time.
      It then reads forward to the first decoded sample at or after that time and prints both PTS values to stderr.
      Specify exactly one of --inmatch, --before-start, or --after-end, all four --source-* values, and --output.
      Unlike batch-frame, it accepts no jobs JSON. The explicit source rectangle is cropped without resizing and output is baseline 8-bit RGB JPEG.
      The default JPEG quality is 0.6. Progressive JPEG is not used. Decode failures never fall back
      to another image source.
      \(VideoFrameSupport.sandboxDecodingGuidance)
      """
  )

  @Option(help: "Required path to record-spec.json.") var recordSpec: String
  @Option(help: "Seconds elapsed from match start.") var inmatch: Double?
  @Option(help: "Seconds before match start.") var beforeStart: Double?
  @Option(help: "Seconds after match end.") var afterEnd: Double?
  @Option(name: .customLong("source-x"), help: "Required source rectangle x in main-video pixels.")
  var sourceX: Int?
  @Option(name: .customLong("source-y"), help: "Required source rectangle y in main-video pixels.")
  var sourceY: Int?
  @Option(
    name: .customLong("source-width"), help: "Required source rectangle width in main-video pixels."
  ) var sourceWidth: Int?
  @Option(
    name: .customLong("source-height"),
    help: "Required source rectangle height in main-video pixels.") var sourceHeight: Int?
  @Option(help: "Required JPEG output path.") var output: String
  @Option(help: "JPEG quality from 0 through 1.") var quality: Double = 0.6
  @Flag(help: "Allow overwriting the output.") var force = false

  mutating func run() async throws {
    guard quality.isFinite, (0...1).contains(quality) else {
      throw ValidationError("--quality must be a finite value from 0 through 1")
    }
    let values = [inmatch, beforeStart, afterEnd].compactMap { $0 }
    guard values.count == 1, let value = values.first, value.isFinite, value >= 0 else {
      throw ValidationError(
        "Specify exactly one finite nonnegative --inmatch, --before-start, or --after-end")
    }
    guard let sourceX, let sourceY, let sourceWidth, let sourceHeight else {
      throw ValidationError("Specify --source-x, --source-y, --source-width, and --source-height")
    }
    let scene: Scene =
      inmatch != nil ? .inmatch(value) : beforeStart != nil ? .beforeStart(value) : .afterEnd(value)
    try await renderPreciseFrame(
      recordSpecURL: resolvePath(recordSpec),
      scene: scene,
      source: FrameSource(x: sourceX, y: sourceY, width: sourceWidth, height: sourceHeight),
      outputURL: resolvePath(output),
      quality: quality,
      force: force
    )
  }
}

private struct EvaluateDrawText: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "eval-draw-text-script",
    abstract: "Evaluate one drawText JSC expression and print its resulting string.",
    discussion: """
      This uses exactly the same JSC globals as drawText.script: FRAME (index, inmatch,
      beforeStart, afterEnd), MATCH (duration), RECORD (globalId), and VIDEO (width, height,
      frameRate, duration). Supply one match-relative time and a JavaScript expression.
      Pass the exact value of drawText.script.return. Example: '"#" + (FRAME.index + 1) + " / " + MATCH.duration'. Pass - as script to read it from standard input.
      """
  )

  @Argument(
    help:
      "JavaScript expression whose result is converted to text, or - to read from standard input.")
  var script: String
  @Option(help: "Match physical metadata. Defaults to record-spec.json in the current directory.")
  var recordSpec: String?
  @Option(help: "Zero-based FRAME.index.") var index = 0
  @Option(help: "Seconds elapsed from the match start.") var inmatch: Double?
  @Option(help: "Seconds before the match start.") var beforeStart: Double?
  @Option(help: "Seconds after the match end.") var afterEnd: Double?

  mutating func run() async throws {
    guard index >= 0 else { throw ValidationError("--index must be non-negative") }
    let result = try await DrawTextScriptEngine.evaluate(
      script: script == "-"
        ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : script,
      recordSpecURL: recordSpec.map(resolvePath)
        ?? cwdURL().appendingPathComponent("record-spec.json"),
      index: index,
      inmatch: inmatch,
      beforeStart: beforeStart,
      afterEnd: afterEnd
    )
    print(result)
  }
}

private struct ContactSheet: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "contact-sheet",
    abstract: "Render contact sheets from a JSON array of jobs and source-video frames.",
    discussion: """
      Supply one positional JSON array. Each job is a contact-sheet definition with a required output path,
      cell {width,height}, columns, optional backgroundColor
      (#RRGGBB or #RRGGBBAA), placements, and frames. A placement is either an image placement:
      {"source":{"x":0,"y":0,"width":1632,"height":918},
       "destination":{"x":0,"y":0,"width":408,"height":230}}
      or a text placement:
      {"drawText":{"text":"label","x":8,"y":8,"fontSize":18,"color":"#FFFFFF",
      "backgroundColor":"#00000099","borderColor":"#FFFFFFFF"}}.
      source coordinates are main-video pixels; destination and drawText x/y coordinates are
      relative to the cell's top-left. Cells are separated by a fixed 8px #FF00FF gutter so labels
      remain visibly attached to their own cell. placements are composited in order for every cell. Each frame is exactly one of
      {"inmatch":N}, {"beforeStart":N}, or {"afterEnd":N}; N is seconds.
      drawText colors accept #RRGGBB or #RRGGBBAA. backgroundColor automatically fits the rendered
      text with a fixed 4px padding; borderColor draws a fixed 1px border only when backgroundColor is set.
      drawText may use script instead of text as {"script":{"return":"EXPRESSION"}}. Its return
      expression is evaluated by JSC once per cell and must return a value. FRAME.index is zero-based. Available values are FRAME (index, inmatch,
      beforeStart, afterEnd, actualInmatch), MATCH (duration), RECORD (globalId), and VIDEO (width, height,
      frameRate, duration). $schema is not used. Pass - as jobs to read JSON from standard input. Relative
      job output paths resolve from the jobs file's directory; with jobs -, they resolve from the current directory.
      Frames must be in strictly increasing source-time order after converting beforeStart, inmatch,
      and afterEnd through record-spec.json. Duplicate or reverse times are rejected before decoding.
      One AVAssetImageGenerator and its video resources are shared by all frames in a job. Requested
      time fields preserve the JSON values; FRAME.actualInmatch is the actual source timestamp minus
      match startPTS and should be used for exact labels.
      Output width is columns * cell.width + (columns - 1) * 8. Output height is
      rows * cell.height + (rows - 1) * 8, where rows is ceil(frames.count / columns).
      Output is always baseline 8-bit RGB JPEG without alpha, regardless of its filename extension.
      Existing outputs are rejected unless --force is supplied.
      \(VideoFrameSupport.sandboxDecodingGuidance)
      """
  )

  @Argument(help: "JSON array of contact-sheet jobs, or - to read it from standard input.")
  var jobs: String
  @Option(help: "Required path to record-spec.json.") var recordSpec: String
  @Option(help: "JPEG quality from 0 through 1.") var quality: Double = 0.6
  @Flag(help: "Allow overwriting an existing output file.") var force = false

  mutating func run() async throws {
    guard quality.isFinite, (0...1).contains(quality) else {
      throw ValidationError("--quality must be a finite value from 0 through 1")
    }
    let jobsURL = jobs == "-" ? nil : resolvePath(jobs)
    let data =
      try jobsURL.map { try Data(contentsOf: $0) } ?? FileHandle.standardInput.readDataToEndOfFile()
    let definitions = try JSONDecoder().decode([ContactSheetDefinition].self, from: data)
    guard !definitions.isEmpty else {
      throw ValidationError("jobs must contain at least one contact-sheet job")
    }
    let baseURL = jobsURL?.deletingLastPathComponent() ?? cwdURL()
    for definition in definitions {
      guard let output = definition.output, !output.isEmpty else {
        throw ValidationError("Each contact-sheet job requires output")
      }
      try await ContactSheetGenerator.run(
        definitionData: try JSONEncoder().encode(definition),
        recordSpecURL: resolvePath(recordSpec),
        outputURL: URL(fileURLWithPath: output, relativeTo: baseURL).standardizedFileURL,
        quality: quality,
        force: force
      )
      print(URL(fileURLWithPath: output, relativeTo: baseURL).standardizedFileURL.path)
    }
  }
}

private struct ContinuousOCRCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "continuous-ocr",
    abstract: "OCR one source-video region across a full match or selected chroma-event times.",
    discussion: """
      Supply one positional JSON array. Each job has an output path and a top-left-origin source-video rectangle:
      {"source":{"x":300,"y":80,"width":1030,"height":300},"recognitionLanguages":["ja-JP"],"output":"messages.txt"}.
      recognitionLanguages is required and must contain at least one language identifier. Optional customWords is passed
      unchanged to VNRecognizeTextRequest.customWords while language correction is disabled. Use it
      for expected system-message phrases, Pokémon names, and player names. The source rectangle is
      cropped exactly as specified without added padding or enlargement. Twelve frames are stacked
      vertically at native source resolution with fixed 8px
      FF00FF separators and submitted in one Vision request. Observations are mapped back to their
      source frame by centroid; only cell-local horizontal centroids from 0.45 through 0.55 remain.
      Without chromaEvents and minimumScore in a job, the full record-spec match is sampled at a fixed 2fps with one
      AVAssetImageGenerator. With both chromaEvents and minimumScore, only event samples meeting that score,
      plus 0.5 seconds on either side, are OCRed. The event file globalId must match record-spec.json.
      Every non-empty OCR sample retains
      requested/actual match time, text, confidence, and normalized ROI-relative bounding boxes.
      Consecutive similar OCR results are united into intervals. The output is readable plain text:
      one match-clock range followed by all OCR strings observed in that same range. Coordinates,
      confidence, dictionaries, and message classification are intentionally omitted. Pass - as
      jobs to read JSON from standard input. $schema is not used. Relative output, observationsOutput, and
      chromaEvents paths resolve from the jobs file's directory; with jobs -, they resolve from the current directory.
      continuous-ocr and ocr-input-frame use a fixed 0.2-second tolerance before and after each
      requested frame so adjacent 2fps requests do not collapse onto one distant frame. Duplicate
      actual timestamps are OCRed once. Plain-text output starts with the recording ID, sampling rate,
      and scanned-frame count. Existing outputs are rejected unless --force is supplied.
      \(VideoFrameSupport.sandboxDecodingGuidance)
      """
  )

  @Argument(help: "JSON array of OCR jobs, or - to read it from standard input.") var jobs: String
  @Option(help: "Required path to record-spec.json.") var recordSpec: String
  @Flag(help: "Allow overwriting an existing output file.") var force = false

  mutating func run() async throws {
    let jobsURL = jobs == "-" ? nil : resolvePath(jobs)
    let data =
      try jobsURL.map { try Data(contentsOf: $0) } ?? FileHandle.standardInput.readDataToEndOfFile()
    let definitions = try JSONDecoder().decode([ContinuousOCRDefinition].self, from: data)
    guard !definitions.isEmpty else {
      throw ValidationError("jobs must contain at least one OCR job")
    }
    let baseURL = jobsURL?.deletingLastPathComponent() ?? cwdURL()
    let specURL = resolvePath(recordSpec)
    for definition in definitions {
      guard let output = definition.output, !output.isEmpty else {
        throw ValidationError("Each OCR job requires output")
      }
      let inmatchTimes: [Double]?
      switch (definition.chromaEvents, definition.minimumScore) {
      case (nil, nil):
        inmatchTimes = nil
      case (.some(let eventsPath), .some(let score)):
        let eventURL = URL(fileURLWithPath: eventsPath, relativeTo: baseURL).standardizedFileURL
        let eventResult = try JSONDecoder().decode(
          ChromaEventResult.self, from: Data(contentsOf: eventURL))
        let spec = try JSONDecoder().decode(
          RecordVisionRecordSpec.self, from: Data(contentsOf: specURL))
        guard eventResult.globalId == spec.globalId else {
          throw ValidationError("chromaEvents globalId does not match record-spec.json")
        }
        inmatchTimes = try ChromaEventDetector.expandedCandidateTimes(
          eventResult.samples,
          minimumScore: score,
          duration: spec.duration
        )
      case (nil, .some): throw ValidationError("minimumScore requires chromaEvents")
      case (.some, nil): throw ValidationError("chromaEvents requires minimumScore")
      }
      try await ContinuousOCR.run(
        definitionData: try JSONEncoder().encode(definition),
        recordSpecURL: specURL,
        outputURL: URL(fileURLWithPath: output, relativeTo: baseURL).standardizedFileURL,
        observationsOutputURL: definition.observationsOutput.map {
          URL(fileURLWithPath: $0, relativeTo: baseURL).standardizedFileURL
        },
        inmatchTimes: inmatchTimes,
        force: force
      )
      print(URL(fileURLWithPath: output, relativeTo: baseURL).standardizedFileURL.path)
    }
  }
}

private struct DetectChromaEvents: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "detect-chroma-events",
    abstract: "Propose visual event times from temporal Cb and Cr differences.",
    discussion: """
      Supply one positional JSON array. Each job has an output path and source rectangle. This is an event-candidate detector,
      independent from OCR. It samples the full match at fixed 2fps. A minimal job is
      {"source":{"x":430,"y":105,"width":800,"height":115},"output":"events.json"}.
      output is required and is always a ChromaEventResult JSON document, regardless of its filename extension.
      continuous-ocr accepts this path as chromaEvents. The source rectangle
      is reduced 8x without padding. Every consecutive-frame absolute Cb and Cr difference is thresholded
      independently with its own Otsu threshold. The two threshold values are the per-sample change-magnitude
      signals: the explicit score field is max(cbThreshold, crThreshold), since a UI can be vivid in only one
      chroma plane. The changed-pixel counts remain diagnostic only. Output deliberately applies no domain
      cutoff, so recordings can establish one. $schema is not used. Relative output paths resolve from the jobs file's directory.
      \(VideoFrameSupport.sandboxDecodingGuidance)
      """
  )

  @Argument(help: "JSON array of chroma-event jobs, or - to read it from standard input.") var jobs:
    String
  @Option(help: "Required path to record-spec.json.") var recordSpec: String
  @Flag(help: "Allow overwriting an existing output file.") var force = false

  mutating func run() async throws {
    let jobsURL = jobs == "-" ? nil : resolvePath(jobs)
    let data =
      try jobsURL.map { try Data(contentsOf: $0) } ?? FileHandle.standardInput.readDataToEndOfFile()
    let definitions = try JSONDecoder().decode([ChromaEventDefinition].self, from: data)
    guard !definitions.isEmpty else {
      throw ValidationError("jobs must contain at least one chroma-event job")
    }
    let baseURL = jobsURL?.deletingLastPathComponent() ?? cwdURL()
    for definition in definitions {
      guard let output = definition.output, !output.isEmpty else {
        throw ValidationError("Each chroma-event job requires output")
      }
      let outputURL = URL(fileURLWithPath: output, relativeTo: baseURL).standardizedFileURL
      try await ChromaEventDetector.run(
        definitionData: try JSONEncoder().encode(definition),
        recordSpecURL: resolvePath(recordSpec), outputURL: outputURL, force: force)
      print(outputURL.path)
    }
  }
}

private struct OCRInputFrame: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ocr-input-frame",
    abstract: "Write the native-resolution per-frame cells used by continuous OCR.",
    discussion: """
      Uses the same JSON definition, no added source padding, no enlargement, encoded-pixel
      orientation, and AVAssetImageGenerator behavior as continuous-ocr. Supply one or more
      match-relative --inmatch values. PNG export happens after preprocessing and is only an
      inspection copy of one cell before twelve cells are assembled into the batched Vision image.
      \(VideoFrameSupport.sandboxDecodingGuidance)
      """
  )

  @Argument(help: "JSON OCR definition, or - to read it from standard input.") var definition:
    String
  @Option(help: "Seconds elapsed from match start. May be repeated.") var inmatch: [Double] = []
  @Option(
    help: "Directory for inspection PNGs. Defaults to ocr-input-frames in the current directory.")
  var outputDir: String?
  @Option(help: "Match physical metadata. Defaults to record-spec.json in the current directory.")
  var recordSpec: String?
  @Flag(help: "Allow overwriting existing PNGs.") var force = false

  mutating func run() async throws {
    guard !inmatch.isEmpty else { throw ValidationError("Specify at least one --inmatch value") }
    let data =
      definition == "-"
      ? FileHandle.standardInput.readDataToEndOfFile()
      : try Data(contentsOf: resolvePath(definition))
    let outputs = try await ContinuousOCR.writeInputFrames(
      definitionData: data,
      recordSpecURL: recordSpec.map(resolvePath)
        ?? cwdURL().appendingPathComponent("record-spec.json"),
      inmatchTimes: inmatch,
      outputDirectory: outputDir.map(resolvePath)
        ?? cwdURL().appendingPathComponent("ocr-input-frames", isDirectory: true),
      force: force
    )
    for output in outputs {
      print(output.path)
    }
  }
}
