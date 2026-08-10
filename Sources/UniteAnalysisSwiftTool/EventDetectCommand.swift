// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import RecordVisionSupport

struct EventDetect: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "event-detect",
    abstract: "Deterministically merge audio, chroma, OCR, and scheduled candidates.",
    discussion: """
      INPUT. Pass an event-detect.input.schema.json manifest. Paths in audioPeaks and chromaEvents are resolved relative to the manifest. Each chromaEvents entry assigns one nonempty region name to one detect-chroma-events output. OCR and scheduled candidates are embedded because they are already small normalized observations.

      DETECTION. Audio scores use a nearest-rank 95th percentile and fixed-width five-second clusters anchored on the first peak. Chroma scores use independent nearest-rank 99.5th and 99th percentiles per region. Secondary chroma samples are admitted only when more than two seconds from every primary chroma or selected audio constituent point. Final candidates merge transitively across adjacent points at most two seconds apart. Scores from different sources or regions are never compared.

      OUTPUT. The complete event-detect.output.schema.json result is written atomically to --output. Existing output is rejected unless --force is supplied. The absolute output path is written to stdout.

      COMPLETE EXAMPLE.

      unite-analysis-swift event-detect event-detect.input.json --output _PokemonUniteAnalysis/matches/match-01/candidates/events.json

      SCHEMAS. Print the contracts with `unite-analysis-swift schema event-detect.input.schema.json` and `unite-analysis-swift schema event-detect.output.schema.json`.
      """.reflowedHelp()
  )

  @Argument(help: "Input manifest conforming to event-detect.input.schema.json.")
  var input: String

  @Option(help: "Required event-detect.output.schema.json path.")
  var output: String

  @Flag(help: "Replace an existing output atomically.")
  var force = false

  struct OutputRecord: Sendable { let output: String }

  func outputRecords() -> AsyncThrowingStream<OutputRecord, Error> {
    commandOutputStream { continuation in
      let inputURL = resolvePath(input)
      let outputURL = resolvePath(output)
      try validateOutputPath(outputURL, force: force)
      let result = try EventCandidateGenerator.run(manifestURL: inputURL)
      try writeOutputData(try prettyPrintedJSONData(result), to: outputURL, force: force)
      continuation.yield(.init(output: outputURL.path))
    }
  }
}

struct EventDetectManifest: Codable, Equatable, Sendable {
  static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/event-detect.input.schema.json"

  let audioPeaks: String
  let chromaEvents: [ChromaInput]
  let ocrCandidates: [OCRCandidate]
  let scheduledCandidates: [ScheduledCandidate]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schema = "$schema"
    case audioPeaks, chromaEvents, ocrCandidates, scheduledCandidates
  }

  init(
    audioPeaks: String, chromaEvents: [ChromaInput], ocrCandidates: [OCRCandidate],
    scheduledCandidates: [ScheduledCandidate]
  ) {
    self.audioPeaks = audioPeaks
    self.chromaEvents = chromaEvents
    self.ocrCandidates = ocrCandidates
    self.scheduledCandidates = scheduledCandidates
  }

  init(from decoder: Decoder) throws {
    try rejectUnknownKeys(
      from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
      context: "event-detect manifest")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let schema = try container.decodeIfPresent(String.self, forKey: .schema),
      schema != Self.schemaURL
    {
      throw DecodingError.dataCorruptedError(
        forKey: .schema, in: container,
        debugDescription: "$schema must equal \(Self.schemaURL)")
    }
    audioPeaks = try container.decode(String.self, forKey: .audioPeaks)
    chromaEvents = try container.decode([ChromaInput].self, forKey: .chromaEvents)
    ocrCandidates = try container.decode([OCRCandidate].self, forKey: .ocrCandidates)
    scheduledCandidates = try container.decode(
      [ScheduledCandidate].self, forKey: .scheduledCandidates)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(audioPeaks, forKey: .audioPeaks)
    try container.encode(chromaEvents, forKey: .chromaEvents)
    try container.encode(ocrCandidates, forKey: .ocrCandidates)
    try container.encode(scheduledCandidates, forKey: .scheduledCandidates)
  }

  struct ChromaInput: Codable, Equatable, Sendable {
    let region: String
    let path: String

    private enum CodingKeys: String, CodingKey, CaseIterable { case region, path }

    init(region: String, path: String) {
      self.region = region
      self.path = path
    }

    init(from decoder: Decoder) throws {
      try rejectUnknownKeys(
        from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
        context: "event-detect chroma input")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      region = try container.decode(String.self, forKey: .region)
      path = try container.decode(String.self, forKey: .path)
    }
  }

  struct OCRCandidate: Codable, Equatable, Sendable {
    let region: String
    let inmatch: Double
    let value: String
    let confidence: Double

    private enum CodingKeys: String, CodingKey, CaseIterable {
      case region, inmatch, value, confidence
    }

    init(region: String, inmatch: Double, value: String, confidence: Double) {
      self.region = region
      self.inmatch = inmatch
      self.value = value
      self.confidence = confidence
    }

    init(from decoder: Decoder) throws {
      try rejectUnknownKeys(
        from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
        context: "event-detect OCR candidate")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      region = try container.decode(String.self, forKey: .region)
      inmatch = try container.decode(Double.self, forKey: .inmatch)
      value = try container.decode(String.self, forKey: .value)
      confidence = try container.decode(Double.self, forKey: .confidence)
    }
  }

  struct ScheduledCandidate: Codable, Equatable, Sendable {
    let inmatch: Double
    let label: String

    private enum CodingKeys: String, CodingKey, CaseIterable { case inmatch, label }

    init(inmatch: Double, label: String) {
      self.inmatch = inmatch
      self.label = label
    }

    init(from decoder: Decoder) throws {
      try rejectUnknownKeys(
        from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
        context: "event-detect scheduled candidate")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      inmatch = try container.decode(Double.self, forKey: .inmatch)
      label = try container.decode(String.self, forKey: .label)
    }
  }
}

struct EventDetectResult: Codable, Equatable, Sendable {
  static let schema =
    "https://kaito-tokyo.github.io/unite-analysis-swift/event-detect.output.schema.json"

  let matchId: String
  let duration: Double
  let candidates: [Candidate]

  struct Candidate: Codable, Equatable, Sendable {
    let startInmatch: Double
    let endInmatch: Double
    let representativeInmatch: Double
    let constituents: [Constituent]
  }

  struct Constituent: Codable, Equatable, Sendable {
    let source: String
    let inmatch: Double
    let score: Double?
    let value: String?
    let confidence: Double?
  }

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case matchId, duration, candidates
  }

  init(matchId: String, duration: Double, candidates: [Candidate]) {
    self.matchId = matchId
    self.duration = duration
    self.candidates = candidates
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    matchId = try container.decode(String.self, forKey: .matchId)
    duration = try container.decode(Double.self, forKey: .duration)
    candidates = try container.decode([Candidate].self, forKey: .candidates)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schema, forKey: .schema)
    try container.encode(matchId, forKey: .matchId)
    try container.encode(duration, forKey: .duration)
    try container.encode(candidates, forKey: .candidates)
  }
}

enum EventCandidateGenerator {
  private static let audioPercentile = 95.0
  private static let primaryChromaPercentile = 99.5
  private static let secondaryChromaPercentile = 99.0
  private static let audioClusterWidth = 5.0
  private static let mergeDistance = 2.0

  struct Point: Equatable {
    let representativeInmatch: Double
    let constituents: [EventDetectResult.Constituent]
  }

  static func run(manifestURL: URL) throws -> EventDetectResult {
    let decoder = JSONDecoder()
    let manifest = try decoder.decode(EventDetectManifest.self, from: Data(contentsOf: manifestURL))
    let base = manifestURL.deletingLastPathComponent()
    let audio = try decoder.decode(
      AudioPeakDetectionResult.self,
      from: Data(contentsOf: resolve(manifest.audioPeaks, relativeTo: base)))
    try validateDuration(audio.duration)

    let audioPoints = try clusteredAudioPoints(audio.peaks, duration: audio.duration)
    var chromaByRegion: [(String, [ChromaEventSample])] = []
    let chromaInputs = manifest.chromaEvents.sorted { ($0.region, $0.path) < ($1.region, $1.path) }
    guard Set(chromaInputs.map(\.region)).count == chromaInputs.count else {
      throw ValidationError("chromaEvents region names must be unique")
    }
    for input in chromaInputs {
      let region = input.region
      guard !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("chromaEvents region names must be nonempty")
      }
      let result = try decoder.decode(
        ChromaEventResult.self, from: Data(contentsOf: resolve(input.path, relativeTo: base)))
      chromaByRegion.append((region, result.samples))
    }

    let chromaPoints = try selectedChromaPoints(
      chromaByRegion, audioConstituents: audioPoints.flatMap(\.constituents),
      duration: audio.duration)
    let ocrPoints = try manifest.ocrCandidates.map { candidate -> Point in
      try validate(candidate.inmatch, duration: audio.duration, name: "OCR inmatch")
      guard !candidate.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("OCR region names must be nonempty")
      }
      guard candidate.confidence.isFinite, (0...1).contains(candidate.confidence) else {
        throw ValidationError("OCR confidence must be finite and between zero and one")
      }
      return Point(
        representativeInmatch: candidate.inmatch,
        constituents: [
          .init(
            source: "ocr:\(candidate.region)", inmatch: candidate.inmatch, score: nil,
            value: candidate.value, confidence: candidate.confidence)
        ])
    }
    let scheduledPoints = try manifest.scheduledCandidates.map { candidate -> Point in
      try validate(candidate.inmatch, duration: audio.duration, name: "scheduled inmatch")
      guard !candidate.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw ValidationError("scheduled labels must be nonempty")
      }
      return Point(
        representativeInmatch: candidate.inmatch,
        constituents: [
          .init(
            source: "scheduled", inmatch: candidate.inmatch, score: nil,
            value: candidate.label, confidence: nil)
        ])
    }

    return EventDetectResult(
      matchId: audio.matchId, duration: audio.duration,
      candidates: merge(audioPoints + chromaPoints + ocrPoints + scheduledPoints))
  }

  static func nearestRankThreshold<T: BinaryFloatingPoint>(_ values: [T], percentile: Double) throws
    -> T?
  {
    guard percentile.isFinite, percentile > 0, percentile <= 100 else {
      throw ValidationError("percentile must be finite and in (0, 100]")
    }
    guard !values.isEmpty else { return nil }
    guard values.allSatisfy(\.isFinite) else {
      throw ValidationError("candidate scores must be finite")
    }
    let sorted = values.sorted()
    let rank = Int(ceil(percentile / 100 * Double(sorted.count)))
    return sorted[rank - 1]
  }

  static func clusteredAudioPoints(_ peaks: [AudioPeak], duration: Double) throws -> [Point] {
    for peak in peaks {
      try validate(peak.inmatch, duration: duration, name: "audio peak inmatch")
      guard peak.score.isFinite, peak.score >= 0 else {
        throw ValidationError("audio peak scores must be finite and nonnegative")
      }
    }
    guard
      let threshold = try nearestRankThreshold(
        peaks.map(\.score), percentile: audioPercentile)
    else { return [] }
    let selected = peaks.filter { $0.score >= threshold }.sorted {
      ($0.inmatch, -$0.score) < ($1.inmatch, -$1.score)
    }
    var clusters: [[AudioPeak]] = []
    for peak in selected {
      if let first = clusters.last?.first, peak.inmatch - first.inmatch < audioClusterWidth {
        clusters[clusters.count - 1].append(peak)
      } else {
        clusters.append([peak])
      }
    }
    return clusters.map { cluster in
      let representative = cluster.min {
        $0.score == $1.score ? $0.inmatch < $1.inmatch : $0.score > $1.score
      }!
      return Point(
        representativeInmatch: representative.inmatch,
        constituents: cluster.map {
          .init(source: "audio", inmatch: $0.inmatch, score: $0.score, value: nil, confidence: nil)
        })
    }
  }

  static func selectedChromaPoints(
    _ regions: [(String, [ChromaEventSample])],
    audioConstituents: [EventDetectResult.Constituent], duration: Double
  ) throws -> [Point] {
    var primary: [(String, ChromaEventSample)] = []
    var secondary: [(String, ChromaEventSample)] = []
    for (region, samples) in regions {
      for sample in samples {
        try validate(sample.requestedInmatch, duration: duration, name: "chroma inmatch")
        guard sample.score >= 0 else { throw ValidationError("chroma scores must be nonnegative") }
      }
      guard
        let primaryThreshold = try nearestRankThreshold(
          samples.map { Double($0.score) }, percentile: primaryChromaPercentile),
        let secondaryThreshold = try nearestRankThreshold(
          samples.map { Double($0.score) }, percentile: secondaryChromaPercentile)
      else { continue }
      for sample in samples {
        if Double(sample.score) >= primaryThreshold {
          primary.append((region, sample))
        } else if Double(sample.score) >= secondaryThreshold {
          secondary.append((region, sample))
        }
      }
    }
    let coveredTimes = primary.map { $0.1.requestedInmatch } + audioConstituents.map(\.inmatch)
    let admitted = secondary.filter { candidate in
      coveredTimes.allSatisfy { abs(candidate.1.requestedInmatch - $0) > mergeDistance }
    }
    return (primary + admitted).map { region, sample in
      Point(
        representativeInmatch: sample.requestedInmatch,
        constituents: [
          .init(
            source: "chroma:\(region)", inmatch: sample.requestedInmatch,
            score: Double(sample.score), value: nil, confidence: nil)
        ])
    }
  }

  static func merge(_ points: [Point]) -> [EventDetectResult.Candidate] {
    let sorted = points.sorted {
      if $0.representativeInmatch != $1.representativeInmatch {
        return $0.representativeInmatch < $1.representativeInmatch
      }
      return $0.constituents.map(\.source).joined() < $1.constituents.map(\.source).joined()
    }
    var groups: [[Point]] = []
    for point in sorted {
      if let previous = groups.last?.last,
        point.representativeInmatch - previous.representativeInmatch <= mergeDistance
      {
        groups[groups.count - 1].append(point)
      } else {
        groups.append([point])
      }
    }
    return groups.map { group in
      let constituents = group.flatMap(\.constituents).sorted {
        ($0.inmatch, $0.source) < ($1.inmatch, $1.source)
      }
      return .init(
        startInmatch: constituents.map(\.inmatch).min()!,
        endInmatch: constituents.map(\.inmatch).max()!,
        representativeInmatch: group.first!.representativeInmatch,
        constituents: constituents)
    }
  }

  private static func resolve(_ path: String, relativeTo base: URL) -> URL {
    URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
  }

  private static func validateDuration(_ duration: Double) throws {
    guard duration.isFinite, duration > 0 else {
      throw ValidationError("audio duration must be positive and finite")
    }
  }

  private static func validate(_ time: Double, duration: Double, name: String) throws {
    guard time.isFinite, time >= 0, time <= duration else {
      throw ValidationError("\(name) must be finite and inside [0, duration]")
    }
  }
}
