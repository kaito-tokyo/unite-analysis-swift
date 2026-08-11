// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct MatchTimerObservation: Codable, Sendable {
  public let recordingTimelineMilliseconds: Int64
  public let output: String
  public let imageFileName: String?
  public let confidence: Float?

  public init(
    recordingTimelineMilliseconds: Int64, output: String, imageFileName: String? = nil,
    confidence: Float? = nil
  ) {
    self.recordingTimelineMilliseconds = recordingTimelineMilliseconds
    self.output = output
    self.imageFileName = imageFileName
    self.confidence = confidence
  }
}

public struct MatchTimerDiagnostic: Codable, Sendable {
  public let recordingTimelineMilliseconds: Int64
  public let output: String
  public let imageFileName: String?
  public let confidence: Float?
  public let remainingSeconds: Int?
  public let startCandidate: Double?
  public let disposition: String
  public let reason: String
}

public struct DetectedMatch: Codable, Sendable {
  public let matchId: String
  public let recordingPTSStart: Double
  public let recordingPTSEnd: Double
  public let duration: Double
  public let observationCount: Int
}

public struct MatchTimerDetection: Codable, Sendable {
  public let matches: [DetectedMatch]
  public let diagnostics: [MatchTimerDiagnostic]

  public init(records: [MatchTimerObservation]) {
    struct Parsed {
      let index: Int
      let record: MatchTimerObservation
      let remaining: Int
      let candidate: Double
    }
    var diagnostics = records.map {
      MatchTimerDiagnostic(
        recordingTimelineMilliseconds: $0.recordingTimelineMilliseconds, output: $0.output,
        imageFileName: $0.imageFileName, confidence: $0.confidence, remainingSeconds: nil,
        startCandidate: nil,
        disposition: "excluded",
        reason: "invalidMMSS")
    }
    var parsed: [Parsed] = []
    for (index, record) in records.enumerated() {
      guard let remaining = Self.parseTimer(record.output) else { continue }
      let candidate = Double(record.recordingTimelineMilliseconds) / 1000 - Double(600 - remaining)
      diagnostics[index] = .init(
        recordingTimelineMilliseconds: record.recordingTimelineMilliseconds, output: record.output,
        imageFileName: record.imageFileName, confidence: record.confidence,
        remainingSeconds: remaining, startCandidate: candidate,
        disposition: "excluded",
        reason: candidate < 0
          ? "startBeforeRecording"
          : remaining == 600 ? "isolatedStartRequiresCorroboration" : "noConsistentCluster")
      guard candidate >= 0 else { continue }
      parsed.append(.init(index: index, record: record, remaining: remaining, candidate: candidate))
    }

    var clusters: [[Parsed]] = []
    for value in parsed.sorted(by: { $0.candidate < $1.candidate }) {
      if let last = clusters.indices.last,
        abs(Self.median(clusters[last].map(\.candidate)) - value.candidate) <= 2.0
      {
        clusters[last].append(value)
      } else {
        clusters.append([value])
      }
    }
    let accepted = clusters.filter { cluster in
      cluster.count >= 2 && cluster.contains { $0.remaining < 600 }
    }.sorted { Self.median($0.map(\.candidate)) < Self.median($1.map(\.candidate)) }

    var matches: [DetectedMatch] = []
    for cluster in accepted {
      let clusterStart = Self.median(cluster.map(\.candidate))
      let corroboratedStarts = parsed.filter { value in
        value.remaining == 600 && abs(value.candidate - clusterStart) <= 5
          && !cluster.contains(where: { $0.index == value.index })
      }
      let start = corroboratedStarts.map(\.candidate).min() ?? clusterStart
      // Do not let overlapping candidate clusters describe the same match.
      guard matches.last.map({ start - $0.recordingPTSStart >= 600 }) ?? true else { continue }
      matches.append(
        .init(
          matchId: String(format: "match-%02d", matches.count + 1), recordingPTSStart: start,
          recordingPTSEnd: start + 600, duration: 600,
          observationCount: cluster.count + corroboratedStarts.count))
      for value in cluster + corroboratedStarts {
        diagnostics[value.index] = .init(
          recordingTimelineMilliseconds: value.record.recordingTimelineMilliseconds,
          output: value.record.output, imageFileName: value.record.imageFileName,
          confidence: value.record.confidence, remainingSeconds: value.remaining,
          startCandidate: value.candidate, disposition: "accepted",
          reason: "consistentStandardMatchCluster")
      }
    }
    self.matches = matches
    self.diagnostics = diagnostics
  }

  private static func parseTimer(_ value: String) -> Int? {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
      parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
      let minutes = Int(parts[0]), let seconds = Int(parts[1]),
      (0...10).contains(minutes), (0...59).contains(seconds),
      !(minutes == 10 && seconds != 0)
    else { return nil }
    return minutes * 60 + seconds
  }

  private static func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
  }
}

public struct MatchTimerLayout: Codable, Equatable, Sendable {
  private struct AnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  private static func rejectUnknownKeys<Key: CodingKey & CaseIterable>(
    from decoder: Decoder, keys: Key.Type, context: String
  ) throws where Key.AllCases: Sequence {
    let container = try decoder.container(keyedBy: AnyCodingKey.self)
    let allowed = Set(keys.allCases.map(\.stringValue))
    let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed)
    guard unknown.isEmpty else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath,
          debugDescription: "Unknown \(context) keys: \(unknown.sorted().joined(separator: ", "))"))
    }
  }

  public struct Size: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
      self.width = width
      self.height = height
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case width, height }

    public init(from decoder: Decoder) throws {
      try MatchTimerLayout.rejectUnknownKeys(from: decoder, keys: CodingKeys.self, context: "size")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      width = try container.decode(Int.self, forKey: .width)
      height = try container.decode(Int.self, forKey: .height)
    }
  }

  public struct Rectangle: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
      self.x = x
      self.y = y
      self.width = width
      self.height = height
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case x, y, width, height }

    public init(from decoder: Decoder) throws {
      try MatchTimerLayout.rejectUnknownKeys(
        from: decoder, keys: CodingKeys.self, context: "rectangle")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      x = try container.decode(Int.self, forKey: .x)
      y = try container.decode(Int.self, forKey: .y)
      width = try container.decode(Int.self, forKey: .width)
      height = try container.decode(Int.self, forKey: .height)
    }
  }

  public struct Regions: Codable, Equatable, Sendable {
    public let matchTimer: Rectangle

    public init(matchTimer: Rectangle) {
      self.matchTimer = matchTimer
    }

    private enum CodingKeys: String, CodingKey, CaseIterable { case matchTimer }

    public init(from decoder: Decoder) throws {
      try MatchTimerLayout.rejectUnknownKeys(
        from: decoder, keys: CodingKeys.self, context: "regions")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      matchTimer = try container.decode(Rectangle.self, forKey: .matchTimer)
    }
  }

  public let schema: String
  public let layoutId: String
  public let referenceSize: Size
  public let regions: Regions

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schema = "$schema"
    case layoutId, referenceSize, regions
  }

  public init(schema: String, layoutId: String, referenceSize: Size, regions: Regions) {
    self.schema = schema
    self.layoutId = layoutId
    self.referenceSize = referenceSize
    self.regions = regions
  }

  public init(from decoder: Decoder) throws {
    try Self.rejectUnknownKeys(from: decoder, keys: CodingKeys.self, context: "layout")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(String.self, forKey: .schema)
    layoutId = try container.decode(String.self, forKey: .layoutId)
    referenceSize = try container.decode(Size.self, forKey: .referenceSize)
    regions = try container.decode(Regions.self, forKey: .regions)
  }

  public func validate() throws {
    guard schema == Self.schemaURL else { throw ValidationError.invalidSchema(schema) }
    guard !layoutId.isEmpty else { throw ValidationError.emptyLayoutId }
    let size = referenceSize
    let timer = regions.matchTimer
    guard size.width > 0, size.height > 0 else { throw ValidationError.invalidReferenceSize }
    guard timer.x >= 0, timer.y >= 0, timer.width > 0, timer.height > 0,
      timer.x <= size.width - timer.width, timer.y <= size.height - timer.height
    else { throw ValidationError.invalidMatchTimer }
  }

  public static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/match-layout-v1.schema.json"

  public enum ValidationError: Error, CustomStringConvertible {
    case invalidSchema(String)
    case emptyLayoutId
    case invalidReferenceSize
    case invalidMatchTimer

    public var description: String {
      switch self {
      case .invalidSchema(let value): "Unsupported match layout $schema: \(value)"
      case .emptyLayoutId: "Match layout layoutId must not be empty"
      case .invalidReferenceSize: "Match layout referenceSize must be positive"
      case .invalidMatchTimer: "Match layout matchTimer is outside referenceSize"
      }
    }
  }
}

public struct GameScreenRectangle: Codable, Equatable, Sendable {
  public let x: Int
  public let y: Int
  public let width: Int
  public let height: Int

  public init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  public static func resolve(
    customFields: [String: String], videoWidth: Int, videoHeight: Int
  ) throws -> Self {
    guard videoWidth > 0, videoHeight > 0 else { throw ResolutionError.invalidVideoDimensions }
    func value(_ name: String, default fallback: Int) throws -> Int {
      guard let raw = customFields["unite-analysis-swift.\(name)"] else { return fallback }
      guard let result = Int(raw) else { throw ResolutionError.invalidValue(name, raw) }
      return result
    }
    let x = try value("x", default: 0)
    let y = try value("y", default: 0)
    let width = try value("width", default: videoWidth - x)
    let height = try value("height", default: videoHeight - y)
    guard x >= 0, y >= 0, width > 0, height > 0,
      x <= videoWidth - width, y <= videoHeight - height
    else { throw ResolutionError.outOfBounds(x, y, width, height, videoWidth, videoHeight) }
    return .init(x: x, y: y, width: width, height: height)
  }

  public enum ResolutionError: Error, CustomStringConvertible {
    case invalidVideoDimensions
    case invalidValue(String, String)
    case outOfBounds(Int, Int, Int, Int, Int, Int)

    public var description: String {
      switch self {
      case .invalidVideoDimensions: "Main video has invalid display dimensions"
      case .invalidValue(let key, let value):
        "Invalid unite-analysis-swift.\(key) value: \(value)"
      case .outOfBounds(let x, let y, let width, let height, let videoWidth, let videoHeight):
        "Game-screen rectangle (\(x),\(y),\(width),\(height)) is outside display video \(videoWidth)x\(videoHeight)"
      }
    }
  }
}
