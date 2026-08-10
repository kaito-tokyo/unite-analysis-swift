// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoreGraphics
import CoreMedia
import CxxStdlib
import Foundation
import IconMatcherNative
import ImageIO
import LDTXRecordingSupport
import RecordVisionSupport
import UniformTypeIdentifiers
import UniteAnalysisConfiguration

private struct LoadoutOutputDocument: Encodable {
  let schema = "https://kaito-tokyo.github.io/unite-analysis-swift/loadout.output.schema.json"
  let format: String
  let matchFormat: String
  let video: String
  let finalPrepTime: Double?
  let versusTime: Double?
  let prepTime: Double?
  let finalPrepPresentationTime: Double?
  let versusPresentationTime: Double?
  let prepPresentationTime: Double?
  let timeBasis: String
  let recognizer: RecognizerDescription
  let allies: [RecognizedAllyLoadout]
  let enemies: [RecognizedEnemyLoadout]

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case format, matchFormat, video, finalPrepTime, versusTime, prepTime
    case finalPrepPresentationTime, versusPresentationTime, prepPresentationTime
    case timeBasis, recognizer, allies, enemies
  }

  struct RecognizerDescription: Encodable {
    let matching: String
    let heldKNNRatio: Float = 0.90
    let battleKNNRatio: Float = 0.80
    let selectionMode = "caller-selected from visual review/contact sheet"
    let databaseID: String
    let databaseCreatedAt: String

    init(matcher: unite_analysis.IconMatcher) {
      let descriptorSize = matcher.akazeDescriptorSize()
      self.matching =
        descriptorSize == 0
        ? "AKAZE MLDB full + BF-Hamming KNN + Lowe ratio"
        : "AKAZE MLDB \(descriptorSize)-bit + BF-Hamming KNN + Lowe ratio"
      self.databaseID = swiftString(from: matcher.databaseID())
      self.databaseCreatedAt = swiftString(from: matcher.createdAt())
    }
  }
}

private struct DecodedLoadoutFrame {
  let image: CGImage
  let presentationTime: Double
}

private func defaultDescriptorDatabaseURL() -> URL {
  if let path = ProcessInfo.processInfo.environment["UNITE_ANALYSIS_DESCRIPTOR_DATABASE"],
    !path.isEmpty
  {
    return URL(fileURLWithPath: path)
  }
  return (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
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
) async throws -> (video: URL, outputDirectory: URL, frames: [DecodedLoadoutFrame]) {
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
    outputDirectory =
      bundle
      .appendingPathComponent("_PokemonUniteAnalysis/matches", isDirectory: true)
      .appendingPathComponent(
        recordSpecURL.deletingLastPathComponent().lastPathComponent,
        isDirectory: true
      )
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
    try validateLegacyLoadoutInputBundle(bundleURL)
    if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path)
    {
      RecordVisionInputLogger.unfinishedRecording(bundleURL)
    }
    outputDirectory = bundleURL.appendingPathComponent("_PokemonUniteAnalysis", isDirectory: true)
    component = nil
    times = matchTimes.map { CMTime(seconds: $0, preferredTimescale: 600) }
  }
  let extractor = try await VideoFrameExtractor(videoURL: recording.videoURL)
  guard
    times.allSatisfy({
      CMTimeCompare($0, .zero) >= 0 && CMTimeCompare($0, extractor.duration) < 0
    })
  else {
    throw ValidationError("Recognition time is outside the source-video range")
  }
  var frames = [DecodedLoadoutFrame?](repeating: nil, count: times.count)
  try extractor.extractFrames(at: times) { index, image, presentationTime in
    frames[index] = DecodedLoadoutFrame(
      image: try normalizedGameScreen(image, component: component),
      presentationTime: presentationTime.seconds
    )
    FileHandle.standardError.write(
      Data(
        "unite-analysis-swift: loadout frame requested PTS \(canonicalSeconds(times[index].seconds))s, decoded PTS \(canonicalSeconds(presentationTime.seconds))s\n"
          .utf8))
  }
  return (
    recording.videoURL, outputDirectory,
    try frames.map { frame in
      guard let frame else {
        throw UniteAnalysisSwiftToolError.message("Missing decoded loadout frame")
      }
      return frame
    }
  )
}

package func validateLegacyLoadoutInputBundle(_ bundleURL: URL) throws {
  let infoURL = bundleURL.appendingPathComponent("Info.plist")
  let data = try Data(contentsOf: infoURL)
  guard
    let dictionary = try PropertyListSerialization.propertyList(
      from: data, options: 0, format: nil)
      as? [String: Any],
    (dictionary["LDTXRecordingFormatVersion"] as? NSNumber)?.intValue == 1
  else {
    throw ValidationError("--input requires LDTX recording format version 1")
  }
}

package func normalizedGameScreen(
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
  to outputURL: URL,
  force: Bool
) throws -> String {
  try validateOutputPath(outputURL, force: force)
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  let encoder = JSONEncoder()
  encoder.keyEncodingStrategy = .convertToSnakeCase
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  var data = try encoder.encode(document)
  data.append(0x0A)
  try data.write(to: outputURL, options: .atomic)
  return outputURL.path
}

private func writeAKAZEInput(
  _ input: PreparedAKAZEInput, named name: String, to directory: URL, force: Bool
) throws {
  try writeDiagnosticPNG(
    input.image, to: directory.appendingPathComponent(name), force: force)
  if let mask = input.mask {
    try writeDiagnosticPNG(
      mask, to: directory.appendingPathComponent("\(name)-mask"), force: force)
  }
}

private func writeDiagnosticPNG(_ image: BGRImage, to path: URL, force: Bool) throws {
  var rgba = [UInt8]()
  rgba.reserveCapacity(image.width * image.height * 4)
  for y in 0..<image.height {
    for x in 0..<image.width {
      let offset = y * image.bytesPerRow + x * 3
      rgba.append(image.bytes[offset + 2])
      rgba.append(image.bytes[offset + 1])
      rgba.append(image.bytes[offset])
      rgba.append(255)
    }
  }
  guard
    let provider = CGDataProvider(data: Data(rgba) as CFData),
    let cgImage = CGImage(
      width: image.width, height: image.height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
  else {
    throw ValidationError("Could not create AKAZE diagnostic image")
  }
  let url = path.appendingPathExtension("png")
  let encoded = NSMutableData()
  guard
    let destination = CGImageDestinationCreateWithData(
      encoded, UTType.png.identifier as CFString, 1, nil)
  else {
    throw ValidationError("Could not create AKAZE diagnostic output: \(url.path)")
  }
  CGImageDestinationAddImage(destination, cgImage, nil)
  guard CGImageDestinationFinalize(destination) else {
    throw ValidationError("Could not write AKAZE diagnostic output: \(url.path)")
  }
  try writeOutputData(encoded as Data, to: url, force: force)
}

private func loadoutOutputURL(
  defaultName: String, outputDirectory: URL, output: String?
) -> URL {
  output.map(resolvePath) ?? outputDirectory.appendingPathComponent(defaultName)
}

private func diagnosticNames(matchFormat: String) -> [String] {
  let allyHeld = (1...5).flatMap { player in
    (1...3).map { item in "ally-\(player)-held-\(item)" }
  }
  let allyBattle = (1...5).flatMap { player in
    ["ally-\(player)-battle", "ally-\(player)-battle-mask"]
  }
  let enemyBattle =
    matchFormat == "draft"
    ? (1...5).flatMap { player in
      ["enemy-\(player)-battle", "enemy-\(player)-battle-mask"]
    } : []
  return allyHeld + allyBattle + enemyBattle
}

package func validateDistinctLoadoutOutputs(
  outputURL: URL, diagnosticDirectory: URL?, matchFormat: String
) throws {
  guard let diagnosticDirectory else { return }
  let normalizedOutput = outputURL.standardizedFileURL
  let normalizedDirectory = diagnosticDirectory.standardizedFileURL
  var existingAncestor = normalizedDirectory
  while !FileManager.default.fileExists(atPath: existingAncestor.path) {
    let parent = existingAncestor.deletingLastPathComponent()
    guard parent != existingAncestor else { break }
    existingAncestor = parent
  }
  let volumeValues = try existingAncestor.resourceValues(forKeys: [
    .volumeSupportsCaseSensitiveNamesKey
  ])
  let caseSensitive = volumeValues.volumeSupportsCaseSensitiveNames ?? true
  let pathKey: (URL) -> [String] = { url in
    url.standardizedFileURL.pathComponents.map { component in
      let normalized = component.decomposedStringWithCanonicalMapping
      return caseSensitive ? normalized : normalized.lowercased()
    }
  }
  let outputComponents = pathKey(normalizedOutput)
  let directoryComponents = pathKey(normalizedDirectory)
  let outputContainsDiagnostics =
    outputComponents.count <= directoryComponents.count
    && Array(directoryComponents.prefix(outputComponents.count)) == outputComponents
  let diagnosticURLs = diagnosticNames(matchFormat: matchFormat).map {
    normalizedDirectory.appendingPathComponent($0).appendingPathExtension("png")
      .standardizedFileURL
  }
  let normalizedOutputComponents = pathKey(normalizedOutput)
  guard !outputContainsDiagnostics,
    !diagnosticURLs.contains(where: { pathKey($0) == normalizedOutputComponents })
  else {
    throw ValidationError(
      "Output path overlaps an AKAZE diagnostic output: \(normalizedOutput.path)")
  }
}

package func prepareDiagnosticDirectory(
  _ directory: URL?, matchFormat: String, force: Bool
) throws {
  guard let directory else { return }
  for name in diagnosticNames(matchFormat: matchFormat) {
    try validateOutputPath(
      directory.appendingPathComponent(name).appendingPathExtension("png"),
      force: force)
  }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
}

struct RecognizeDraftLoadout: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "recognize-draft-loadout",
    abstract: "Recognize draft final-preparation and versus-screen item loadouts.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because AVFoundation source-video decoding is unavailable in the sandboxed execution environment.

      Select draft mode by visually reviewing the recording or a contact sheet. This command does not guess draft versus blind. With --record-spec, times are relative to match start. With --input for a v1 .ldtxrecord, times use the recording timeline. Use the last stable final-preparation frame, not an intermediate edited loadout. The versus frame supplies enemy battle items; enemy held items are never inferred.

      RECOGNITION. Each candidate score is the unnormalized sum of surviving Lowe-ratio descriptor votes, where each query descriptor contributes 1 - nearestDistance / secondNearestDistance. It orders candidates within one crop, but is not a probability or a calibrated value comparable across crops or database revisions. name is null unless the top score is at least one full-strength vote worth of evidence and at least twice the runner-up score. A player's held-item names also become null when independently accepted slots select the same item, because duplicate held items are invalid. Candidates and the top score remain available whenever recognition abstains. Declared-route HSV classification also abstains for a low-chroma crop or when the median hue is more than 24.5 OpenCV hue units from every route reference. The 24.5 limit is half the smallest circular separation between route reference hues.
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
  @Option(help: "Combined descriptor database; defaults to the app bundle resource.")
  var descriptors: String?
  @Option(help: "Output JSON path; defaults inside _PokemonUniteAnalysis.")
  var output: String?
  @Option(
    name: .customLong("dump-akaze-inputs"),
    help: "Directory for lossless PNGs of the normalized AKAZE pixels and keypoint masks.")
  var dumpAKAZEInputs: String?
  @Flag(help: "Overwrite an existing output JSON file.") var force = false

}

extension RecognizeDraftLoadout {
  struct OutputRecord: Sendable { let output: String }

  func outputRecords() -> AsyncThrowingStream<OutputRecord, Error> {
    commandOutputStream { continuation in
      let command = self
      let inputs = try await loadoutInputs(
        recordSpec: command.recordSpec, input: command.input,
        matchTimes: [command.finalPreparationTime, command.versusTime])
      let matcher = try loadIconMatcher(
        from: command.descriptors.map(resolvePath) ?? defaultDescriptorDatabaseURL())
      let outputURL = loadoutOutputURL(
        defaultName: "draft-loadout.json", outputDirectory: inputs.outputDirectory,
        output: command.output)
      let diagnosticDirectory = command.dumpAKAZEInputs.map(resolvePath)
      try validateDistinctLoadoutOutputs(
        outputURL: outputURL, diagnosticDirectory: diagnosticDirectory, matchFormat: "draft")
      try validateOutputPath(outputURL, force: command.force)
      try prepareDiagnosticDirectory(
        diagnosticDirectory, matchFormat: "draft", force: command.force)
      let result = try LoadoutRecognizer.recognizeDraft(
        finalPreparation: inputs.frames[0].image, versus: inputs.frames[1].image,
        matcher: matcher,
        akazeInputObserver: diagnosticDirectory.map { directory in
          return { name, input in
            try writeAKAZEInput(
              input, named: name, to: directory, force: command.force)
          }
        })
      let output = try writeLoadout(
        LoadoutOutputDocument(
          format: result.format, matchFormat: result.matchFormat, video: inputs.video.path,
          finalPrepTime: command.finalPreparationTime, versusTime: command.versusTime,
          prepTime: nil,
          finalPrepPresentationTime: inputs.frames[0].presentationTime,
          versusPresentationTime: inputs.frames[1].presentationTime,
          prepPresentationTime: nil,
          timeBasis: command.recordSpec == nil ? "recording-timeline" : "match-relative",
          recognizer: .init(matcher: matcher), allies: result.allies, enemies: result.enemies),
        to: outputURL, force: command.force)
      continuation.yield(.init(output: output))
    }
  }

}

struct RecognizeBlindLoadout: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "recognize-blind-loadout",
    abstract: "Recognize allied loadouts from a blind-selection preparation screen.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because AVFoundation source-video decoding is unavailable in the sandboxed execution environment.

      Select blind mode by visually reviewing the recording or a contact sheet. This command does not guess draft versus blind. With --record-spec, --prep-time is relative to match start. With --input for a v1 .ldtxrecord, it uses the recording timeline. The time must identify the stable five-card selection screen. Enemy loadouts are absent because this screen does not expose them.

      RECOGNITION. Each candidate score is the unnormalized sum of surviving Lowe-ratio descriptor votes, where each query descriptor contributes 1 - nearestDistance / secondNearestDistance. It orders candidates within one crop, but is not a probability or a calibrated value comparable across crops or database revisions. name is null unless the top score is at least one full-strength vote worth of evidence and at least twice the runner-up score. A player's held-item names also become null when independently accepted slots select the same item, because duplicate held items are invalid. Candidates and the top score remain available whenever recognition abstains. Declared-route HSV classification also abstains for a low-chroma crop or when the median hue is more than 24.5 OpenCV hue units from every route reference. The 24.5 limit is half the smallest circular separation between route reference hues.
      """.reflowedHelp())

  @Option(help: "record-spec.json path for match-relative times; exclusive with --input.")
  var recordSpec: String?
  @Option(help: "v1 .ldtxrecord path for recording-relative times; exclusive with --record-spec.")
  var input: String?
  @Option(help: "Stable blind-selection screen time relative to match start.") var prepTime: Double
  @Option(help: "Combined descriptor database; defaults to the app bundle resource.")
  var descriptors: String?
  @Option(help: "Output JSON path; defaults inside _PokemonUniteAnalysis.")
  var output: String?
  @Option(
    name: .customLong("dump-akaze-inputs"),
    help: "Directory for lossless PNGs of the normalized AKAZE pixels and keypoint masks.")
  var dumpAKAZEInputs: String?
  @Flag(help: "Overwrite an existing output JSON file.") var force = false

}

extension RecognizeBlindLoadout {
  struct OutputRecord: Sendable { let output: String }

  func outputRecords() -> AsyncThrowingStream<OutputRecord, Error> {
    commandOutputStream { continuation in
      let command = self
      let inputs = try await loadoutInputs(
        recordSpec: command.recordSpec, input: command.input, matchTimes: [command.prepTime])
      let matcher = try loadIconMatcher(
        from: command.descriptors.map(resolvePath) ?? defaultDescriptorDatabaseURL())
      let outputURL = loadoutOutputURL(
        defaultName: "blind-loadout.json", outputDirectory: inputs.outputDirectory,
        output: command.output)
      let diagnosticDirectory = command.dumpAKAZEInputs.map(resolvePath)
      try validateDistinctLoadoutOutputs(
        outputURL: outputURL, diagnosticDirectory: diagnosticDirectory, matchFormat: "blind")
      try validateOutputPath(outputURL, force: command.force)
      try prepareDiagnosticDirectory(
        diagnosticDirectory, matchFormat: "blind", force: command.force)
      let result = try LoadoutRecognizer.recognizeBlind(
        preparation: inputs.frames[0].image, matcher: matcher,
        akazeInputObserver: diagnosticDirectory.map { directory in
          return { name, input in
            try writeAKAZEInput(
              input, named: name, to: directory, force: command.force)
          }
        })
      let output = try writeLoadout(
        LoadoutOutputDocument(
          format: result.format, matchFormat: result.matchFormat, video: inputs.video.path,
          finalPrepTime: nil, versusTime: nil, prepTime: command.prepTime,
          finalPrepPresentationTime: nil, versusPresentationTime: nil,
          prepPresentationTime: inputs.frames[0].presentationTime,
          timeBasis: command.recordSpec == nil ? "recording-timeline" : "match-relative",
          recognizer: .init(matcher: matcher), allies: result.allies, enemies: result.enemies),
        to: outputURL, force: command.force)
      continuation.yield(.init(output: output))
    }
  }

}
