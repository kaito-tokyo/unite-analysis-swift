// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

private struct MatchEvidenceCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int? = nil
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

private func rejectMatchEvidenceUnknownKeys<Key: CodingKey & CaseIterable>(
  from decoder: Decoder, keys: Key.Type, context: String
) throws where Key.AllCases: Sequence {
  let container = try decoder.container(keyedBy: MatchEvidenceCodingKey.self)
  let allowed = Set(keys.allCases.map(\.stringValue))
  let unknown = Set(container.allKeys.map(\.stringValue)).subtracting(allowed)
  guard unknown.isEmpty else {
    throw DecodingError.dataCorrupted(
      .init(
        codingPath: decoder.codingPath,
        debugDescription: "Unknown \(context) keys: \(unknown.sorted().joined(separator: ", "))"))
  }
}

public struct MatchEndEvidenceDocument: Codable, Sendable {
  public static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/match-end-evidence-v1.schema.json"

  public struct Evidence: Codable, Sendable {
    public let evidenceId: String
    public let recordingPTS: Double
    public let kind: String
    public let medium: String
    public let mode: String
    public let source: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
      case evidenceId, recordingPTS, kind, medium, mode, source
    }

    public init(from decoder: Decoder) throws {
      try rejectMatchEvidenceUnknownKeys(from: decoder, keys: CodingKeys.self, context: "evidence")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      evidenceId = try container.decode(String.self, forKey: .evidenceId)
      recordingPTS = try container.decode(Double.self, forKey: .recordingPTS)
      kind = try container.decode(String.self, forKey: .kind)
      medium = try container.decode(String.self, forKey: .medium)
      mode = try container.decode(String.self, forKey: .mode)
      source = try container.decode(String.self, forKey: .source)
    }
  }

  public let schema: String
  public let evidence: [Evidence]

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case schema = "$schema"
    case evidence
  }

  public init(from decoder: Decoder) throws {
    try rejectMatchEvidenceUnknownKeys(from: decoder, keys: CodingKeys.self, context: "document")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schema = try container.decode(String.self, forKey: .schema)
    evidence = try container.decode([Evidence].self, forKey: .evidence)
  }
}

public struct MatchEndEvidenceDiagnostic: Codable, Sendable {
  public let evidenceId: String
  public let recordingPTS: Double
  public let kind: String
  public let medium: String
  public let mode: String
  public let source: String
  public let disposition: String
  public let reason: String
}

public struct DetectedMatchV2: Codable, Sendable {
  public let matchId: String
  public let recordingPTSStart: Double
  public let recordingPTSEnd: Double
  public let duration: Double
  public let mode: String
  public let completion: String
  public let observationCount: Int
  public let endEvidenceIds: [String]
}

public struct UnclassifiedMatchCandidate: Codable, Sendable {
  public let recordingPTSStart: Double
  public let nominalDuration: Double
  public let mode: String
  public let observationCount: Int
  public let reason: String
}

public struct MatchIntervalDetectionV2: Codable, Sendable {
  public static let supportedModes = ["standard10Minute", "quick5Minute"]

  public let matches: [DetectedMatchV2]
  public let timerDiagnostics: [MatchTimerDiagnostic]
  public let endEvidenceDiagnostics: [MatchEndEvidenceDiagnostic]
  public let unclassifiedCandidates: [UnclassifiedMatchCandidate]

  public init(
    standardMatches: [DetectedMatch],
    timerDiagnostics: [MatchTimerDiagnostic],
    endEvidence: MatchEndEvidenceDocument
  ) {
    struct Candidate {
      let start: Double
      let nominalDuration: Double
      let mode: String
      let observationCount: Int
      let completedStandard: DetectedMatch?
    }

    let parsed = timerDiagnostics.compactMap { diagnostic -> (Double, Int)? in
      guard let candidate = diagnostic.startCandidate,
        let remaining = diagnostic.remainingSeconds
      else { return nil }
      return (candidate, remaining)
    }

    func clusters(_ values: [(Double, Int)]) -> [[(Double, Int)]] {
      var result: [[(Double, Int)]] = []
      for value in values.sorted(by: { $0.0 < $1.0 }) {
        let median = result.last.map { group -> Double in
          let sorted = group.map(\.0).sorted()
          let middle = sorted.count / 2
          return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        }
        if let median, abs(median - value.0) <= 2 {
          result[result.count - 1].append(value)
        } else {
          result.append([value])
        }
      }
      return result
    }

    func median(_ values: [Double]) -> Double {
      let sorted = values.sorted()
      let middle = sorted.count / 2
      return sorted.count.isMultiple(of: 2)
        ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }

    let standardClusters = clusters(parsed.filter { $0.0 >= 0 }).filter {
      $0.count >= 2 && Set($0.map(\.1)).count >= 2 && $0.contains { $0.1 > 300 }
    }
    var quickClusters = clusters(
      parsed.filter { $0.1 <= 300 && $0.0 + 300 >= 0 }.map { ($0.0 + 300, $0.1) }
    )
    .filter { $0.count >= 2 && Set($0.map(\.1)).count >= 2 && $0.contains { $0.1 < 300 } }

    var candidates = standardClusters.map { cluster in
      let clusterStart = median(cluster.map(\.0))
      let start =
        cluster.filter { $0.1 == 600 && $0.0 <= clusterStart }.map(\.0).min()
        ?? clusterStart
      let completed = standardMatches.first { abs($0.recordingPTSStart - start) <= 2 }
      return Candidate(
        start: start, nominalDuration: 600, mode: "standard10Minute",
        observationCount: cluster.count, completedStandard: completed)
    }
    let standardStarts = candidates.map { ($0.start, $0.start + $0.nominalDuration) }
    quickClusters.removeAll { cluster in
      let start = median(cluster.map(\.0))
      let hasDeclaredEnd = endEvidence.evidence.contains {
        $0.mode == "quick5Minute"
          && (($0.kind == "matchEnd" && abs($0.recordingPTS - (start + 300)) <= 10)
            || ($0.kind == "surrender" && $0.recordingPTS > start && $0.recordingPTS < start + 300))
      }
      return !hasDeclaredEnd && standardStarts.contains { start > $0.0 && start < $0.1 }
    }
    candidates += quickClusters.map { cluster in
      let clusterStart = median(cluster.map(\.0))
      let start =
        cluster.filter { $0.1 == 300 && $0.0 <= clusterStart }.map(\.0).min()
        ?? clusterStart
      return Candidate(
        start: start, nominalDuration: 300, mode: "quick5Minute",
        observationCount: cluster.count, completedStandard: nil)
    }
    candidates.sort {
      $0.start < $1.start || ($0.start == $1.start && $0.nominalDuration > $1.nominalDuration)
    }

    var evidenceDiagnostics = endEvidence.evidence.map {
      MatchEndEvidenceDiagnostic(
        evidenceId: $0.evidenceId, recordingPTS: $0.recordingPTS, kind: $0.kind,
        medium: $0.medium, mode: $0.mode, source: $0.source,
        disposition: "excluded",
        reason: Self.supportedModes.contains($0.mode) ? "noMatchingCandidate" : "unsupportedMode")
    }
    var usedEvidence = Set<Int>()
    var provisional: [(Candidate, Double, String, [String])] = []
    var unclassified: [UnclassifiedMatchCandidate] = []

    for candidate in candidates {
      let matching = endEvidence.evidence.indices.filter { index in
        let value = endEvidence.evidence[index]
        guard value.mode == candidate.mode, Self.supportedModes.contains(value.mode) else {
          return false
        }
        switch value.kind {
        case "surrender":
          return value.recordingPTS > candidate.start
            && value.recordingPTS < candidate.start + candidate.nominalDuration
        case "matchEnd":
          return candidate.mode == "quick5Minute"
            && abs(value.recordingPTS - (candidate.start + candidate.nominalDuration)) <= 10
        default: return false
        }
      }
      let surrender = matching.filter { endEvidence.evidence[$0].kind == "surrender" }
      let matchEnd = matching.filter { endEvidence.evidence[$0].kind == "matchEnd" }
      let selected: Int?
      let completion: String
      if surrender.count == 1 && matchEnd.isEmpty {
        selected = surrender[0]
        completion = "surrendered"
      } else if candidate.mode == "quick5Minute", matchEnd.count == 1, surrender.isEmpty {
        selected = matchEnd[0]
        completion = "completed"
      } else {
        selected = nil
        completion = "completed"
      }

      if let selected {
        let value = endEvidence.evidence[selected]
        provisional.append((candidate, value.recordingPTS, completion, [value.evidenceId]))
      } else if candidate.mode == "standard10Minute", let completed = candidate.completedStandard {
        provisional.append((candidate, completed.recordingPTSEnd, "completed", []))
        for index in matching {
          evidenceDiagnostics[index] = Self.diagnostic(
            endEvidence.evidence[index], reason: "contradictoryEvidence")
        }
      } else {
        unclassified.append(
          .init(
            recordingPTSStart: candidate.start,
            nominalDuration: candidate.nominalDuration,
            mode: candidate.mode,
            observationCount: candidate.observationCount,
            reason: matching.isEmpty ? "missingEndEvidence" : "contradictoryEvidence"))
        for index in matching {
          evidenceDiagnostics[index] = Self.diagnostic(
            endEvidence.evidence[index], reason: "contradictoryEvidence")
        }
      }
    }

    var accepted: [DetectedMatchV2] = []
    for (candidate, end, completion, evidenceIds) in provisional.sorted(by: {
      $0.0.start < $1.0.start
    }) {
      guard accepted.last.map({ candidate.start >= $0.recordingPTSEnd }) ?? true else {
        unclassified.append(
          .init(
            recordingPTSStart: candidate.start,
            nominalDuration: candidate.nominalDuration,
            mode: candidate.mode,
            observationCount: candidate.observationCount,
            reason: "overlapsPreviousMatch"))
        for evidenceId in evidenceIds {
          if let index = endEvidence.evidence.firstIndex(where: { $0.evidenceId == evidenceId }) {
            evidenceDiagnostics[index] = Self.diagnostic(
              endEvidence.evidence[index], reason: "overlapsPreviousMatch")
          }
        }
        continue
      }
      accepted.append(
        .init(
          matchId: String(format: "match-%02d", accepted.count + 1),
          recordingPTSStart: candidate.start, recordingPTSEnd: end,
          duration: end - candidate.start, mode: candidate.mode, completion: completion,
          observationCount: candidate.observationCount, endEvidenceIds: evidenceIds))
      for evidenceId in evidenceIds {
        if let index = endEvidence.evidence.firstIndex(where: { $0.evidenceId == evidenceId }) {
          usedEvidence.insert(index)
        }
      }
    }

    for index in usedEvidence {
      evidenceDiagnostics[index] = Self.diagnostic(
        endEvidence.evidence[index], disposition: "adopted", reason: "definesMatchEnd")
    }
    self.matches = accepted
    self.timerDiagnostics = timerDiagnostics.map { diagnostic in
      guard let remaining = diagnostic.remainingSeconds,
        let standardStart = diagnostic.startCandidate
      else { return diagnostic }
      let adopted = accepted.first { match in
        let candidate = match.mode == "quick5Minute" ? standardStart + 300 : standardStart
        return (match.mode != "quick5Minute" || remaining <= 300)
          && abs(candidate - match.recordingPTSStart) <= 2
      }
      guard let adopted else { return diagnostic }
      return MatchTimerDiagnostic(
        recordingTimelineMilliseconds: diagnostic.recordingTimelineMilliseconds,
        output: diagnostic.output, imageFileName: diagnostic.imageFileName,
        confidence: diagnostic.confidence, remainingSeconds: remaining,
        startCandidate: adopted.recordingPTSStart, disposition: "accepted",
        reason: adopted.mode == "quick5Minute"
          ? "consistentQuickMatchCluster" : "consistentStandardMatchCluster")
    }
    self.endEvidenceDiagnostics = evidenceDiagnostics
    self.unclassifiedCandidates = unclassified.sorted {
      $0.recordingPTSStart < $1.recordingPTSStart
    }
  }

  private static func diagnostic(
    _ value: MatchEndEvidenceDocument.Evidence,
    disposition: String = "excluded",
    reason: String
  ) -> MatchEndEvidenceDiagnostic {
    .init(
      evidenceId: value.evidenceId, recordingPTS: value.recordingPTS, kind: value.kind,
      medium: value.medium, mode: value.mode, source: value.source,
      disposition: disposition, reason: reason)
  }
}
