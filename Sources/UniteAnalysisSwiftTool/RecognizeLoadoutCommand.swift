// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoreGraphics
import CoreMedia
import CxxStdlib
import Foundation
import IconMatcherNative
import LDTXRecordingSupport
import RecordVisionSupport
import UniteAnalysisConfiguration

private struct LoadoutOutputDocument: Encodable {
  let format: String
  let matchFormat: String
  let video: String
  let finalPrepTime: Double?
  let versusTime: Double?
  let prepTime: Double?
  let recognizer: RecognizerDescription
  let allies: [RecognizedAllyLoadout]
  let enemies: [RecognizedEnemyLoadout]

  struct RecognizerDescription: Encodable {
    let matching = "AKAZE MLDB full + BF-Hamming KNN + Lowe ratio"
    let heldKNNRatio: Float = 0.90
    let battleKNNRatio: Float = 0.80
    let selectionMode = "caller-selected from visual review/contact sheet"
  }
}

private func defaultDescriptorDatabaseURL() -> URL {
  UserConfigurationStore.defaultFileURL.deletingLastPathComponent()
    .appendingPathComponent("descriptors.pb")
}

private func loadIconMatcher(from url: URL) throws -> unite_analysis.IconMatcher {
  let matcher = unite_analysis.IconMatcher(std.string(url.path))
  guard matcher.isValid() else {
    let errorMessage = matcher.errorMessage()
    throw ValidationError(swiftString(from: errorMessage))
  }
  return matcher
}

private func loadoutInputs(
  recordSpec recordSpecPath: String?,
  input inputPath: String?,
  matchTimes: [Double]
) async throws -> (video: URL, outputDirectory: URL, frames: [CGImage]) {
  guard matchTimes.allSatisfy(\.isFinite) else {
    throw ValidationError("Recognition times must be finite match-relative seconds")
  }
  for index in matchTimes.indices.dropFirst() where matchTimes[index] <= matchTimes[index - 1] {
    throw ValidationError("Recognition times must be strictly increasing")
  }
  guard (recordSpecPath == nil) != (inputPath == nil) else {
    throw ValidationError("Specify exactly one of --record-spec or --input")
  }
  let recording: ResolvedRecordingInput
  let outputDirectory: URL
  let component: RecordSpec.VideoComponent?
  let times: [CMTime]
  if let recordSpecPath {
    let recordSpecURL = resolveRecordSpec(recordSpecPath)
    let spec = try JSONDecoder().decode(RecordSpec.self, from: Data(contentsOf: recordSpecURL))
    guard spec.startPTS.timescale > 0 else {
      throw ValidationError("startPTS.timescale must be positive")
    }
    guard let gameScreen = spec.videoComponents.first(where: { $0.name == "game-screen" }) else {
      throw ValidationError("record-spec.json has no game-screen video component")
    }
    let bundle = try recordingBundle(above: recordSpecURL)
    if !FileManager.default.fileExists(atPath: bundle.appendingPathComponent(".finalized").path) {
      RecordVisionInputLogger.unfinishedRecording(bundle)
    }
    recording = try ResolvedRecordingInput.resolve(bundle.path, allowUnfinished: true)
    outputDirectory = recordSpecURL.deletingLastPathComponent()
      .appendingPathComponent("_PokemonUniteAnalysis", isDirectory: true)
    component = gameScreen
    let start = CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale)
    times = matchTimes.map {
      CMTimeAdd(start, CMTime(seconds: $0, preferredTimescale: spec.startPTS.timescale))
    }
  } else {
    recording = try ResolvedRecordingInput.resolve(inputPath!, allowUnfinished: true)
    guard let bundleURL = recording.bundleURL else {
      throw ValidationError("--input must identify a .ldtxrecord bundle")
    }
    if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path)
    {
      RecordVisionInputLogger.unfinishedRecording(bundleURL)
    }
    outputDirectory = bundleURL.appendingPathComponent("_PokemonUniteAnalysis", isDirectory: true)
    component = nil
    times = matchTimes.map { CMTime(seconds: $0, preferredTimescale: 600) }
  }
  let extractor = try await VideoFrameExtractor(videoURL: recording.videoURL)
  var frames = [CGImage?](repeating: nil, count: times.count)
  try extractor.extractFrames(at: times) { index, image in
    frames[index] = image
    FileHandle.standardError.write(
      Data(
        "unite-analysis-swift: loadout frame at or after requested PTS \(canonicalSeconds(times[index].seconds))s\n"
          .utf8))
  }
  return (
    recording.videoURL, outputDirectory,
    try frames.map { frame in
      guard let frame else {
        throw UniteAnalysisSwiftToolError.message("Missing decoded loadout frame")
      }
      return try normalizedGameScreen(frame, component: component)
    }
  )
}

func normalizedGameScreen(
  _ image: CGImage,
  component: RecordSpec.VideoComponent?
) throws -> CGImage {
  guard let component else { return image }
  guard component.x >= 0, component.y >= 0, component.width > 0, component.height > 0,
    component.x <= image.width - component.width,
    component.y <= image.height - component.height,
    let cropped = image.cropping(
      to: CGRect(x: component.x, y: component.y, width: component.width, height: component.height))
  else {
    throw ValidationError("game-screen video component is outside the decoded frame")
  }
  return try VideoFrameSupport.resized(cropped, width: 1920, height: 1080)
}

private func writeLoadout(
  _ document: LoadoutOutputDocument,
  defaultName: String,
  outputDirectory: URL,
  output: String?,
  force: Bool
) throws {
  let outputURL =
    output.map(resolvePath)
    ?? outputDirectory.appendingPathComponent(defaultName)
  guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
    throw ValidationError("Output exists: \(outputURL.path). Pass --force to overwrite")
  }
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  let encoder = JSONEncoder()
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  var data = try encoder.encode(document)
  data.append(0x0A)
  try data.write(to: outputURL, options: .atomic)
  print(outputURL.path)
}

struct RecognizeDraftLoadout: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "recognize-draft-loadout",
    abstract: "Recognize draft final-preparation and versus-screen item loadouts.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because AVFoundation source-video decoding is unavailable in the sandboxed execution environment.

      Select draft mode by visually reviewing the recording or a contact sheet. This command does not guess draft versus blind. With --record-spec, times are relative to match start. With --input for a v1 .ldtxrecord, times use the recording timeline. Use the last stable final-preparation frame, not an intermediate edited loadout. The versus frame supplies enemy battle items; enemy held items are never inferred.
      """.reflowedHelp())

  @Option(help: "record-spec.json path for match-relative times; exclusive with --input.")
  var recordSpec: String?
  @Option(help: "v1 .ldtxrecord path for recording-relative times; exclusive with --record-spec.")
  var input: String?
  @Option(
    name: .customLong("final-prep-time"),
    help: "Final stable preparation time relative to match start.")
  var finalPreparationTime: Double
  @Option(name: .customLong("vs-time"), help: "Versus-screen time relative to match start.")
  var versusTime: Double
  @Option(help: "Combined descriptor database; defaults to Application Support/descriptors.pb.")
  var descriptors: String?
  @Option(help: "Output JSON path; defaults inside _PokemonUniteAnalysis.")
  var output: String?
  @Flag(help: "Overwrite an existing output JSON file.") var force = false

  mutating func run() async throws {
    let inputs = try await loadoutInputs(
      recordSpec: recordSpec, input: input, matchTimes: [finalPreparationTime, versusTime])
    let matcher = try loadIconMatcher(
      from: descriptors.map(resolvePath) ?? defaultDescriptorDatabaseURL())
    let result = try LoadoutRecognizer.recognizeDraft(
      finalPreparation: inputs.frames[0], versus: inputs.frames[1], matcher: matcher)
    try writeLoadout(
      LoadoutOutputDocument(
        format: result.format, matchFormat: result.matchFormat, video: inputs.video.path,
        finalPrepTime: finalPreparationTime, versusTime: versusTime, prepTime: nil,
        recognizer: .init(), allies: result.allies, enemies: result.enemies),
      defaultName: "draft-loadout.json", outputDirectory: inputs.outputDirectory, output: output,
      force: force)
  }
}

struct RecognizeBlindLoadout: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "recognize-blind-loadout",
    abstract: "Recognize allied loadouts from a blind-selection preparation screen.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because AVFoundation source-video decoding is unavailable in the sandboxed execution environment.

      Select blind mode by visually reviewing the recording or a contact sheet. This command does not guess draft versus blind. With --record-spec, --prep-time is relative to match start. With --input for a v1 .ldtxrecord, it uses the recording timeline. The time must identify the stable five-card selection screen. Enemy loadouts are absent because this screen does not expose them.
      """.reflowedHelp())

  @Option(help: "record-spec.json path for match-relative times; exclusive with --input.")
  var recordSpec: String?
  @Option(help: "v1 .ldtxrecord path for recording-relative times; exclusive with --record-spec.")
  var input: String?
  @Option(help: "Stable blind-selection screen time relative to match start.") var prepTime: Double
  @Option(help: "Combined descriptor database; defaults to Application Support/descriptors.pb.")
  var descriptors: String?
  @Option(help: "Output JSON path; defaults inside _PokemonUniteAnalysis.")
  var output: String?
  @Flag(help: "Overwrite an existing output JSON file.") var force = false

  mutating func run() async throws {
    let inputs = try await loadoutInputs(
      recordSpec: recordSpec, input: input, matchTimes: [prepTime])
    let matcher = try loadIconMatcher(
      from: descriptors.map(resolvePath) ?? defaultDescriptorDatabaseURL())
    let result = try LoadoutRecognizer.recognizeBlind(
      preparation: inputs.frames[0], matcher: matcher)
    try writeLoadout(
      LoadoutOutputDocument(
        format: result.format, matchFormat: result.matchFormat, video: inputs.video.path,
        finalPrepTime: nil, versusTime: nil, prepTime: prepTime, recognizer: .init(),
        allies: result.allies, enemies: result.enemies),
      defaultName: "blind-loadout.json", outputDirectory: inputs.outputDirectory, output: output,
      force: force)
  }
}
