// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoreMedia
import Foundation
import LDTXRecordingSupport
import RecordVisionSupport

struct MatchInputOptions: ParsableArguments {
  @Flag(help: "Read a standalone MP4 using --input and the required --record-spec.")
  var standaloneMP4 = false
  @Option(help: "Source .mp4 file; required with --standalone-mp4.") var input: String?

  func validate() throws {
    guard standaloneMP4 == (input != nil) else {
      throw ValidationError("--standalone-mp4 and --input must be supplied together")
    }
  }

  func source() throws -> MatchVideoInput {
    try validate()
    return standaloneMP4 ? .standaloneMP4(resolvePath(input!)) : .recordingBundle
  }
}

func resolveMatchRecording(
  recordSpecURL: URL, source: MatchVideoInput, requireModernBundle: Bool = false
) throws -> ResolvedRecordingInput {
  let recording = try source.resolve(
    recordSpecURL: recordSpecURL, requireModernBundle: requireModernBundle)
  if let bundle = recording.bundleURL,
    !FileManager.default.fileExists(atPath: bundle.appendingPathComponent(".finalized").path)
  {
    RecordVisionInputLogger.unfinishedRecording(bundle)
  }
  return recording
}

struct StandaloneDetectionOptions: ParsableArguments {
  @Flag(help: "Read --input as a standalone MP4 and generate match specs in --output-dir.")
  var standaloneMP4 = false
  @Option(
    help:
      "Dedicated output directory, required with --standalone-mp4. --force replaces it entirely.")
  var outputDir: String?
  @Option(help: "Game-screen left edge; supply all four game-screen options together.")
  var gameScreenX: Int?
  @Option(help: "Game-screen top edge.") var gameScreenY: Int?
  @Option(help: "Game-screen width.") var gameScreenWidth: Int?
  @Option(help: "Game-screen height.") var gameScreenHeight: Int?

  func validate() throws {
    guard standaloneMP4 == (outputDir != nil) else {
      throw ValidationError(
        "--standalone-mp4 requires --output-dir; --output-dir requires --standalone-mp4")
    }
    let count = [gameScreenX, gameScreenY, gameScreenWidth, gameScreenHeight].compactMap { $0 }
      .count
    guard count == 0 || (standaloneMP4 && count == 4) else {
      throw ValidationError("Supply all four --game-screen-* options with --standalone-mp4")
    }
  }

  func rectangle(videoWidth: Int, videoHeight: Int) throws -> GameScreenRectangle {
    try validate()
    var fields: [String: String] = [:]
    for (key, value) in [
      ("x", gameScreenX), ("y", gameScreenY), ("width", gameScreenWidth),
      ("height", gameScreenHeight),
    ] {
      if let value { fields["unite-analysis-swift." + key] = String(value) }
    }
    return try .resolve(customFields: fields, videoWidth: videoWidth, videoHeight: videoHeight)
  }

  func destination(output: String?, force: Bool, protectedInputs: [URL]) throws -> URL? {
    try validate()
    guard standaloneMP4 else { return nil }
    guard output == nil else {
      throw ValidationError("--output cannot be combined with --standalone-mp4; use --output-dir")
    }
    let destination = resolvePath(outputDir!)
    try validateStandaloneDestination(destination, force: force, protectedInputs: protectedInputs)
    return destination
  }
}

func validateStandaloneDestination(_ destination: URL, force: Bool, protectedInputs: [URL]) throws {
  let resolved = try resolvingSymlinkComponents(in: destination)
  var ancestor = resolved
  while !FileManager.default.fileExists(atPath: ancestor.path), ancestor.path != "/" {
    ancestor.deleteLastPathComponent()
  }
  let caseSensitive =
    try ancestor.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
    .volumeSupportsCaseSensitiveNames ?? true
  func components(_ url: URL) -> [String] {
    url.pathComponents.map {
      let value = $0.decomposedStringWithCanonicalMapping
      return caseSensitive ? value : value.lowercased()
    }
  }
  let destinationComponents = components(resolved)
  for input in protectedInputs + [cwdURL()] {
    let inputComponents = components(try resolvingSymlinkComponents(in: input))
    guard !inputComponents.starts(with: destinationComponents) else {
      throw ValidationError(
        "Output directory must not contain an input or the working directory: \(input.path)")
    }
  }
  if (try? FileManager.default.attributesOfItem(atPath: destination.path)[.type])
    as? FileAttributeType == .typeSymbolicLink
  {
    throw ValidationError("Output directory must not be a symbolic link")
  }
  try validateManagedAuditDestination(destination, force: force)
}

struct StandaloneMatchSpec: Encodable {
  struct StartPTS: Encodable {
    let value: Int64
    let timescale: Int32
  }
  struct Component: Encodable {
    let name = "game-screen"
    let x: Int
    let y: Int
    let width: Int
    let height: Int
  }
  let version = 2
  let matchId: String
  let startPTS: StartPTS
  let duration: Double
  let videoComponents: [Component]

  init(_ match: DetectedMatch, gameScreen: GameScreenRectangle) {
    self.init(
      matchId: match.matchId, start: match.recordingPTSStart, duration: match.duration,
      gameScreen: gameScreen)
  }

  init(_ match: DetectedMatchV2, gameScreen: GameScreenRectangle) {
    self.init(
      matchId: match.matchId, start: match.recordingPTSStart, duration: match.duration,
      gameScreen: gameScreen)
  }

  init(matchId: String, start: Double, duration: Double, gameScreen: GameScreenRectangle) {
    let pts = CMTimeConvertScale(
      CMTime(seconds: start, preferredTimescale: 600_000), timescale: 600_000, method: .default)
    self.matchId = matchId
    self.startPTS = .init(value: pts.value, timescale: pts.timescale)
    self.duration = duration
    self.videoComponents = [
      .init(x: gameScreen.x, y: gameScreen.y, width: gameScreen.width, height: gameScreen.height)
    ]
  }
}

func stageStandaloneDirectory(at destination: URL) throws -> URL {
  let parent = destination.deletingLastPathComponent()
  try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
  let staged = parent.appendingPathComponent(
    ".\(destination.lastPathComponent).\(UUID().uuidString).staged", isDirectory: true)
  try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
  return staged
}

func writeStandaloneDetection<Output: Encodable>(
  _ output: Output, specs: [StandaloneMatchSpec], staged: URL, destination: URL,
  force: Bool, protectedInputs: [URL]
) throws {
  try prettyPrintedJSONData(output).write(to: staged.appendingPathComponent("match-detection.json"))
  for spec in specs {
    let directory = staged.appendingPathComponent(spec.matchId, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    try prettyPrintedJSONData(spec).write(to: directory.appendingPathComponent("record-spec.json"))
  }
  try validateStandaloneDestination(destination, force: force, protectedInputs: protectedInputs)
  try installManagedAuditDirectory(staged, at: destination, force: force)
}
