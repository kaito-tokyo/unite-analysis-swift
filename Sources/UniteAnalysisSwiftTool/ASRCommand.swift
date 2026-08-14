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

      EXECUTION. Speech framework media processing must run outside an application sandbox. The requested language is resolved through DictationTranscriber's supported-locale API. Required Apple-managed on-device assets are downloaded and installed before analysis when necessary. Asset and resolved-input diagnostics are written to stderr.

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

    let requestedLocale = Locale(identifier: configuration.language)
    guard
      let locale = await DictationTranscriber.supportedLocale(equivalentTo: requestedLocale)
    else {
      throw UniteAnalysisSwiftToolError.message(
        "No supported DictationTranscriber locale is equivalent to '\(configuration.language)'")
    }
    ASRDiagnostics.write("ASR input: \(inputURL.path)")
    ASRDiagnostics.write("ASR locale: \(configuration.language) -> \(locale.identifier)")

    let transcriber = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
    let modules: [any SpeechModule] = [transcriber]
    switch await AssetInventory.status(forModules: modules) {
    case .unsupported:
      throw UniteAnalysisSwiftToolError.message(
        "Speech assets are unsupported for locale '\(locale.identifier)'")
    case .installed:
      ASRDiagnostics.write("Speech asset status: installed")
    case .supported, .downloading:
      if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
        ASRDiagnostics.write("Speech asset installation: started")
        try await request.downloadAndInstall()
        ASRDiagnostics.write("Speech asset installation: completed")
      }
    @unknown default:
      throw UniteAnalysisSwiftToolError.message("Unknown Speech asset status")
    }

    let context = AnalysisContext()
    if !contextualStrings.isEmpty {
      context.contextualStrings[.general] = contextualStrings
    }
    let analyzer = SpeechAnalyzer(modules: modules)
    try await analyzer.setContext(context)
    let audioFile: AVAudioFile
    do {
      audioFile = try AVAudioFile(forReading: inputURL)
    } catch {
      throw UniteAnalysisSwiftToolError.message(
        "Could not open input audio track at \(inputURL.path): \(error)")
    }

    let resultsTask = Task<[ASRSegment], Error> {
      var segments: [ASRSegment] = []
      for try await result in transcriber.results {
        segments.append(.init(result: result))
      }
      return segments
    }
    do {
      _ = try await analyzer.analyzeSequence(from: audioFile)
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
      guard value.count <= Self.maximumContextualStringLength else {
        throw ValidationError(
          "ASR contextualStrings[\(index)] must contain at most \(Self.maximumContextualStringLength) characters"
        )
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

private enum ASRDiagnostics {
  static func write(_ message: String) {
    try? FileHandle.standardError.write(contentsOf: Data("\(message)\n".utf8))
  }
}
