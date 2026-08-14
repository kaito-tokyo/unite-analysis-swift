// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import ArgumentParser
import CoreMedia
import Foundation
import Speech

struct ASRCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "asr-v1",
    abstract: "Transcribe a local audio or video file with on-device speech recognition.",
    discussion: """
      INPUT. --input is a local audio or video file containing a readable audio track. --config is a strict asr-v1.input.schema.json document containing a language identifier and up to 100 short contextual strings. Paths are resolved from the current working directory.

      EXECUTION. Speech framework media processing must run outside an application sandbox. The requested language is resolved through DictationTranscriber's supported-locale API. The input audio track is decoded to PCM with AVAssetReader before asset status is checked. Install missing Apple-managed on-device assets explicitly with install-asr-assets-v1 before running this command. Asset and resolved-input diagnostics are written to stderr.

      CONTEXT. contextualStrings are trimmed, must contain 1 through 100 characters, and must be unique after trimming. They are supplied only as AnalysisContext general contextual strings. This command does not train or load a custom language model, accept custom pronunciations, or select an arbitrary recognition model.

      OUTPUT. Pretty-printed, sorted asr-v1.output.schema.json is written to stdout. Each result contains recognized text, its media-relative start and duration in seconds, and whether the framework finalized it.

      SCHEMAS. Print the contracts with `unite-analysis-swift schema asr-v1.input.schema.json` and `unite-analysis-swift schema asr-v1.output.schema.json`.
      """.reflowedHelp()
  )

  @Option(help: "Local audio or video input path.")
  var input: String

  @Option(help: "Configuration conforming to asr-v1.input.schema.json.")
  var config: String

  func outputRecords() -> AsyncThrowingStream<ASROutput, Error> {
    commandOutputStream { continuation in
      continuation.yield(try await result())
    }
  }

  private func result() async throws -> ASROutput {
    let inputURL = resolvePath(input).standardizedFileURL
    let configURL = resolvePath(config).standardizedFileURL
    guard FileManager.default.fileExists(atPath: inputURL.path) else {
      throw UniteAnalysisSwiftToolError.message("Input file not found: \(inputURL.path)")
    }
    let configuration: ASRConfiguration
    do {
      configuration = try JSONDecoder().decode(
        ASRConfiguration.self, from: Data(contentsOf: configURL))
    } catch {
      throw UniteAnalysisSwiftToolError.message("Invalid ASR configuration: \(error)")
    }
    let contextualStrings: [String]
    do {
      contextualStrings = try configuration.validatedContextualStrings()
    } catch {
      throw UniteAnalysisSwiftToolError.message(String(describing: error))
    }

    let locale = try await ASRSupport.resolveLocale(configuration.language)
    ASRDiagnostics.write("ASR input: \(inputURL.path)")
    ASRDiagnostics.write("ASR locale: \(configuration.language) -> \(locale.identifier)")

    let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
    let modules: [any SpeechModule] = [transcriber]
    guard let audioFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
    else {
      throw UniteAnalysisSwiftToolError.message(
        "No compatible PCM format is available for locale '\(locale.identifier)'")
    }
    try await ASRAudioInput.validate(url: inputURL, audioFormat: audioFormat)
    switch await AssetInventory.status(forModules: modules) {
    case .unsupported:
      throw UniteAnalysisSwiftToolError.message(
        "Speech assets are unsupported for locale '\(locale.identifier)'")
    case .installed:
      ASRDiagnostics.write("Speech asset status: installed")
    case .supported, .downloading:
      throw UniteAnalysisSwiftToolError.message(
        "Speech assets are not installed for locale '\(locale.identifier)'. Run install-asr-assets-v1 --language \(configuration.language) explicitly, then retry asr-v1."
      )
    @unknown default:
      throw UniteAnalysisSwiftToolError.message("Unknown Speech asset status")
    }

    let context = AnalysisContext()
    if !contextualStrings.isEmpty {
      context.contextualStrings[.general] = contextualStrings
    }
    let analyzer = SpeechAnalyzer(modules: modules)
    try await analyzer.setContext(context)
    let inputSequence = try await ASRAudioInput.sequence(url: inputURL, audioFormat: audioFormat)

    let resultsTask = Task<[ASRSegment], Error> {
      var segments: [ASRSegment] = []
      for try await result in transcriber.results {
        segments.append(.init(result: result))
      }
      return segments
    }
    do {
      _ = try await analyzer.analyzeSequence(inputSequence)
      try await analyzer.finalizeAndFinishThroughEndOfInput()
      return ASROutput(
        input: inputURL.path,
        requestedLanguage: configuration.language,
        resolvedLanguage: locale.identifier,
        contextualStrings: contextualStrings,
        results: try await resultsTask.value)
    } catch {
      resultsTask.cancel()
      throw UniteAnalysisSwiftToolError.message("Speech analysis failed: \(error)")
    }
  }
}

struct InstallASRAssets: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "install-asr-assets-v1",
    abstract: "Install Apple-managed on-device speech assets for one language.",
    discussion: """
      This command performs a network download and persistent host installation when the resolved locale's speech assets are absent. Run it directly from the CLI only after the user has explicitly chosen to install those assets. It is not available through MCP and must run outside an application sandbox. Installed assets are managed by Apple.

      The requested language is resolved through DictationTranscriber's supported-locale API. A machine-readable JSON result is written to stdout and diagnostics are written to stderr.
      """.reflowedHelp()
  )

  @Option(help: "Language identifier resolved to an equivalent supported locale.")
  var language: String

  func result() async throws -> ASRAssetInstallationOutput {
    let locale = try await ASRSupport.resolveLocale(language)
    let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
    let modules: [any SpeechModule] = [transcriber]
    switch await AssetInventory.status(forModules: modules) {
    case .unsupported:
      throw UniteAnalysisSwiftToolError.message(
        "Speech assets are unsupported for locale '\(locale.identifier)'")
    case .installed:
      ASRDiagnostics.write("Speech asset status: installed")
    case .supported, .downloading:
      guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules)
      else {
        throw UniteAnalysisSwiftToolError.message(
          "Could not create a speech asset installation request for locale '\(locale.identifier)'")
      }
      ASRDiagnostics.write("Speech asset installation: started")
      try await request.downloadAndInstall()
      ASRDiagnostics.write("Speech asset installation: completed")
    @unknown default:
      throw UniteAnalysisSwiftToolError.message("Unknown Speech asset status")
    }
    return ASRAssetInstallationOutput(
      requestedLanguage: language, resolvedLanguage: locale.identifier, status: "installed")
  }
}

struct ASRAssetInstallationOutput: Encodable, Equatable, Sendable {
  let requestedLanguage: String
  let resolvedLanguage: String
  let status: String
}

struct ASRConfiguration: Codable, Equatable, Sendable {
  static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/asr-v1.input.schema.json"
  static let maximumContextualStringCount = 100
  static let maximumContextualStringLength = 100

  let language: String
  let contextualStrings: [String]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schema = "$schema"
    case language, contextualStrings
  }

  init(language: String, contextualStrings: [String] = []) {
    self.language = language
    self.contextualStrings = contextualStrings
  }

  init(from decoder: Decoder) throws {
    try rejectUnknownKeys(
      from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
      context: "asr-v1 configuration")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let schema = try container.decode(String.self, forKey: .schema)
    if schema != Self.schemaURL {
      throw DecodingError.dataCorruptedError(
        forKey: .schema, in: container,
        debugDescription: "$schema must equal \(Self.schemaURL)")
    }
    language = try container.decode(String.self, forKey: .language)
    contextualStrings =
      try container.decodeIfPresent(
        [String].self, forKey: .contextualStrings) ?? []
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schemaURL, forKey: .schema)
    try container.encode(language, forKey: .language)
    try container.encode(contextualStrings, forKey: .contextualStrings)
  }

  func validatedContextualStrings() throws -> [String] {
    guard !language.isEmpty,
      language.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else {
      throw ValidationError("ASR language must be a nonempty locale identifier without whitespace")
    }
    guard contextualStrings.count <= Self.maximumContextualStringCount else {
      throw ValidationError(
        "ASR contextualStrings must contain at most \(Self.maximumContextualStringCount) entries")
    }
    var seen: Set<String> = []
    return try contextualStrings.enumerated().map { index, value in
      guard !value.isEmpty else {
        throw ValidationError("ASR contextualStrings[\(index)] must not be empty")
      }
      guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
        throw ValidationError(
          "ASR contextualStrings[\(index)] must not have leading or trailing whitespace")
      }
      guard value.unicodeScalars.count <= Self.maximumContextualStringLength else {
        throw ValidationError(
          "ASR contextualStrings[\(index)] must contain at most \(Self.maximumContextualStringLength) Unicode code points"
        )
      }
      guard value.rangeOfCharacter(from: .newlines) == nil else {
        throw ValidationError("ASR contextualStrings[\(index)] must not contain line breaks")
      }
      guard seen.insert(value).inserted else {
        throw ValidationError("ASR contextualStrings contains duplicate '\(value)'")
      }
      return value
    }
  }
}

struct ASROutput: Encodable, Sendable {
  static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/asr-v1.output.schema.json"

  let schema = schemaURL
  let input: String
  let requestedLanguage: String
  let resolvedLanguage: String
  let contextualStrings: [String]
  let results: [ASRSegment]

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case input, requestedLanguage, resolvedLanguage, contextualStrings, results
  }
}

struct ASRSegment: Encodable, Equatable, Sendable {
  let text: String
  let startTime: Double
  let duration: Double
  let isFinal: Bool

  init(text: String, startTime: Double, duration: Double, isFinal: Bool) {
    self.text = text
    self.startTime = startTime
    self.duration = duration
    self.isFinal = isFinal
  }

  init(result: DictationTranscriber.Result) {
    self.init(
      text: String(result.text.characters),
      startTime: result.range.start.seconds,
      duration: result.range.duration.seconds,
      isFinal: result.isFinal)
  }
}

private enum ASRSupport {
  static func resolveLocale(_ language: String) async throws -> Locale {
    guard !language.isEmpty,
      language.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
    else {
      throw UniteAnalysisSwiftToolError.message(
        "ASR language must be a nonempty locale identifier without whitespace")
    }
    let requestedLocale = Locale(identifier: language)
    guard let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
    else {
      throw UniteAnalysisSwiftToolError.message(
        "No supported DictationTranscriber locale is equivalent to '\(language)'")
    }
    return locale
  }
}

private enum ASRAudioInput {
  static func validate(url: URL, audioFormat: AVAudioFormat) async throws {
    let sequence = try await sequence(url: url, audioFormat: audioFormat)
    var iterator = sequence.makeAsyncIterator()
    guard try await iterator.next() != nil else {
      throw UniteAnalysisSwiftToolError.message(
        "Audio decoding produced no PCM samples: \(url.path)")
    }
    sequence.cancel()
  }

  static func sequence(
    url: URL, audioFormat: AVAudioFormat
  ) async throws -> ASRAnalyzerInputSequence {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw UniteAnalysisSwiftToolError.message("Input has no audio track: \(url.path)")
    }
    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: false,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
      AVSampleRateKey: audioFormat.sampleRate,
      AVNumberOfChannelsKey: audioFormat.channelCount,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw UniteAnalysisSwiftToolError.message(
        "Could not configure PCM audio decoding: \(url.path)")
    }
    reader.add(output)
    guard reader.startReading() else {
      throw UniteAnalysisSwiftToolError.message(
        "Could not start audio decoding: \(reader.error?.localizedDescription ?? "unknown error")")
    }
    return ASRAnalyzerInputSequence(reader: reader, output: output, inputPath: url.path)
  }
}

private final class ASRAnalyzerInputSequence: AsyncSequence, @unchecked Sendable {
  typealias Element = AnalyzerInput

  private let state: State

  init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, inputPath: String) {
    state = State(reader: reader, output: output, inputPath: inputPath)
  }

  func makeAsyncIterator() -> Iterator { Iterator(state: state) }

  func cancel() { state.cancel() }

  struct Iterator: AsyncIteratorProtocol {
    let state: State

    mutating func next() async throws -> AnalyzerInput? { try state.next() }
  }

  final class State: @unchecked Sendable {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private let inputPath: String
    private let lock = NSLock()

    init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, inputPath: String) {
      self.reader = reader
      self.output = output
      self.inputPath = inputPath
    }

    func next() throws -> AnalyzerInput? {
      lock.lock()
      defer { lock.unlock() }
      if let sampleBuffer = output.copyNextSampleBuffer() {
        return try AnalyzerInput(
          buffer: Self.audioBuffer(from: sampleBuffer),
          bufferStartTime: sampleBuffer.presentationTimeStamp)
      }
      guard reader.status == .completed else {
        throw UniteAnalysisSwiftToolError.message(
          "Audio decoding failed: \(reader.error?.localizedDescription ?? "unknown error"): \(inputPath)"
        )
      }
      return nil
    }

    func cancel() {
      lock.lock()
      defer { lock.unlock() }
      reader.cancelReading()
    }

    private static func audioBuffer(from sampleBuffer: CMSampleBuffer) throws -> AVAudioPCMBuffer {
      guard let formatDescription = sampleBuffer.formatDescription,
        var streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
          formatDescription)?.pointee,
        let format = AVAudioFormat(streamDescription: &streamDescription)
      else {
        throw UniteAnalysisSwiftToolError.message("Decoded audio has no valid PCM format")
      }
      let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw UniteAnalysisSwiftToolError.message("Could not allocate a decoded PCM buffer")
      }
      buffer.frameLength = frameCount
      let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
        sampleBuffer, at: 0, frameCount: Int32(frameCount), into: buffer.mutableAudioBufferList)
      guard status == noErr else {
        throw UniteAnalysisSwiftToolError.message(
          "Could not copy decoded PCM data (status \(status))")
      }
      return buffer
    }
  }
}

private enum ASRDiagnostics {
  static func write(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
  }
}
