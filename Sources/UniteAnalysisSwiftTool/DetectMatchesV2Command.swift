// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import RecordVisionSupport

struct DetectMatchesV2: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "detect-matches-v2",
    abstract: "Detect standard, surrendered, and declared five-minute matches.",
    discussion: """
      VERSION. This is a new v2 command and output contract. detect-matches-v1 remains unchanged and continues to emit only completed standard ten-minute matches.

      INPUT. --input, --layout, and --sample-interval have the same direct source-video OCR behavior as detect-matches-v1. --end-evidence is a strict match-end-evidence-v1 JSON document containing human- or tool-confirmed visual or audio evidence. The command never reads LDTX Vision metadata or a contact-sheet image.

      MODES. v2 initially supports standard10Minute and quick5Minute. A standard ten-minute interval is completed from its corroborated timer countdown. It is shortened only by one unambiguous surrender evidence item. A quick five-minute interval requires one unambiguous matchEnd or surrender evidence item. Other modes remain unsupported and their evidence is excluded.

      EVIDENCE. Every item declares a unique evidenceId, source recording PTS, kind (matchEnd or surrender), medium (visual or audio), mode, and a non-empty source description. Missing, conflicting, unsupported, and unused evidence is retained with a machine-readable reason. Timer sequences that cannot be classified are retained as unclassifiedCandidates rather than assigned a guessed end.

      OUTPUT. Pretty-printed, sorted JSON is written to stdout and optionally atomically to --output. Existing output requires --force. Matches never overlap and receive contiguous match-01, match-02 identifiers.

      SCHEMAS. Print the contracts with `unite-analysis-swift schema match-layout-v1.schema.json`, `unite-analysis-swift schema match-end-evidence-v1.schema.json`, and `unite-analysis-swift schema match-detection-v2.output.schema.json`.

      LIMITS. quick5Minute is the only initially supported nonstandard mode. Timer OCR does not identify a map or ruleset. Evidence for any other mode remains excluded, and ambiguous sequences remain unclassified.
      """.reflowedHelp())

  @Option(help: "Recording format v2 .ldtxrecord path.") var input: String
  @Option(help: "Fixed match UI layout JSON path.") var layout: String
  @Option(help: "Strict declared visual/audio match-end evidence JSON path.")
  var endEvidence: String
  @Option(help: "Timer sampling interval in seconds.") var sampleInterval = 5.0
  @Option(help: "Optional JSON output path; stdout always receives the same result.")
  var output: String?
  @Flag(help: "Allow --output to be replaced atomically.") var force = false

  struct Output: Encodable, Sendable {
    let schema =
      "https://kaito-tokyo.github.io/unite-analysis-swift/match-detection-v2.output.schema.json"
    let source = "videoOCR+declaredEndEvidence"
    let mainMediaFile: String
    let layoutId: String
    let gameScreen: GameScreenRectangle
    let supportedModes = MatchIntervalDetectionV2.supportedModes
    let matches: [DetectedMatchV2]
    let timerDiagnostics: [MatchTimerDiagnostic]
    let endEvidenceDiagnostics: [MatchEndEvidenceDiagnostic]
    let unclassifiedCandidates: [UnclassifiedMatchCandidate]

    private enum CodingKeys: String, CodingKey {
      case schema = "$schema"
      case source, mainMediaFile, layoutId, gameScreen, supportedModes, matches,
        timerDiagnostics, endEvidenceDiagnostics, unclassifiedCandidates
    }
  }

  func outputRecords() -> AsyncThrowingStream<Output, Error> {
    commandOutputStream { continuation in continuation.yield(try await result()) }
  }

  private func result() async throws -> Output {
    try validateOutputPath(output.map(resolvePath), force: force)
    let evidence: MatchEndEvidenceDocument
    do {
      evidence = try JSONDecoder().decode(
        MatchEndEvidenceDocument.self, from: Data(contentsOf: resolvePath(endEvidence)))
    } catch {
      throw UniteAnalysisSwiftToolError.message("Invalid match end evidence JSON: \(error)")
    }
    guard evidence.schema == MatchEndEvidenceDocument.schemaURL else {
      throw UniteAnalysisSwiftToolError.message(
        "match end evidence $schema must be '\(MatchEndEvidenceDocument.schemaURL)'")
    }
    var evidenceIds = Set<String>()
    for value in evidence.evidence {
      guard !value.evidenceId.isEmpty, evidenceIds.insert(value.evidenceId).inserted,
        value.recordingPTS.isFinite, value.recordingPTS >= 0,
        ["matchEnd", "surrender"].contains(value.kind),
        ["visual", "audio"].contains(value.medium),
        !value.mode.isEmpty, !value.source.isEmpty
      else {
        throw UniteAnalysisSwiftToolError.message(
          "Match end evidence requires unique non-empty IDs, finite nonnegative PTS, declared kind, medium, mode, and source"
        )
      }
    }

    var v1 = DetectMatches()
    v1.input = input
    v1.layout = layout
    v1.sampleInterval = sampleInterval
    v1.output = nil
    v1.auditId = nil
    v1.force = false
    let base = try await v1.result()
    let detection = MatchIntervalDetectionV2(
      standardMatches: base.matches, timerDiagnostics: base.diagnostics,
      endEvidence: evidence)
    return Output(
      mainMediaFile: base.mainMediaFile, layoutId: base.layoutId,
      gameScreen: base.gameScreen, matches: detection.matches,
      timerDiagnostics: detection.timerDiagnostics,
      endEvidenceDiagnostics: detection.endEvidenceDiagnostics,
      unclassifiedCandidates: detection.unclassifiedCandidates)
  }
}
