// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RecordVisionSupport
import Testing

private func timer(_ milliseconds: Int64, _ output: String) -> MatchTimerObservation {
  .init(recordingTimelineMilliseconds: milliseconds, output: output)
}

private func endEvidence(_ items: String = "") throws -> MatchEndEvidenceDocument {
  try JSONDecoder().decode(
    MatchEndEvidenceDocument.self,
    from: Data(
      """
      {"$schema":"https://kaito-tokyo.github.io/unite-analysis-swift/match-end-evidence-v1.schema.json","evidence":[\(items)]}
      """.utf8))
}

private func detectV2(
  _ records: [MatchTimerObservation], evidence: MatchEndEvidenceDocument,
  recordingDuration: Double = .infinity
) -> MatchIntervalDetectionV2 {
  let timerDetection = MatchTimerDetection(records: records, recordingDuration: recordingDuration)
  return MatchIntervalDetectionV2(
    timerDiagnostics: timerDetection.diagnostics,
    endEvidence: evidence,
    recordingDuration: recordingDuration)
}

@Test func matchLayoutValidatesAndScalesTimerRectangle() throws {
  let layout = MatchTimerLayout(
    schema: MatchTimerLayout.schemaURL,
    layoutId: "ja.20260811.match.timer",
    referenceSize: .init(width: 1920, height: 1080),
    regions: .init(matchTimer: .init(x: 900, y: 20, width: 120, height: 60)))
  try layout.validate()
  #expect(
    MatchTimerVideoOCR.timerRectangle(
      gameScreen: .init(x: 0, y: 0, width: 1632, height: 918), layout: layout)
      == .init(x: 765, y: 17, width: 102, height: 51))
}

@Test func matchLayoutRejectsOutOfBoundsTimer() {
  let layout = MatchTimerLayout(
    schema: MatchTimerLayout.schemaURL,
    layoutId: "ja.20260811.match.timer",
    referenceSize: .init(width: 1920, height: 1080),
    regions: .init(matchTimer: .init(x: 1900, y: 20, width: 120, height: 60)))
  #expect(throws: MatchTimerLayout.ValidationError.self) {
    try layout.validate()
  }
}

@Test func timerRectangleClampsIntegralRoundingToGameScreen() {
  let layout = MatchTimerLayout(
    schema: MatchTimerLayout.schemaURL,
    layoutId: "edge-touching",
    referenceSize: .init(width: 6, height: 6),
    regions: .init(matchTimer: .init(x: 1, y: 0, width: 5, height: 6)))
  #expect(
    MatchTimerVideoOCR.timerRectangle(
      gameScreen: .init(x: 0, y: 0, width: 7, height: 7), layout: layout)
      == .init(x: 1, y: 0, width: 6, height: 7))
}

@Test func matchLayoutRejectsUnknownKeysAtEveryLevel() {
  let documents = [
    #"{"$schema":"https://kaito-tokyo.github.io/unite-analysis-swift/match-layout-v1.schema.json","layoutId":"ja.20260811.match.timer","referenceSize":{"width":1920,"height":1080},"regions":{"matchTimer":{"x":0,"y":0,"width":1,"height":1}},"engine":"ignored"}"#,
    #"{"$schema":"https://kaito-tokyo.github.io/unite-analysis-swift/match-layout-v1.schema.json","layoutId":"ja.20260811.match.timer","referenceSize":{"width":1920,"height":1080,"extra":1},"regions":{"matchTimer":{"x":0,"y":0,"width":1,"height":1}}}"#,
    #"{"$schema":"https://kaito-tokyo.github.io/unite-analysis-swift/match-layout-v1.schema.json","layoutId":"ja.20260811.match.timer","referenceSize":{"width":1920,"height":1080},"regions":{"matchTimer":{"x":0,"y":0,"width":1,"height":1,"extra":1}}}"#,
  ]
  for document in documents {
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(MatchTimerLayout.self, from: Data(document.utf8))
    }
  }
}

@Test func timerSamplingAvoidsTheAssetEndAndRejectsSubMillisecondIntervals() throws {
  #expect(try MatchTimerVideoOCR.sampleTimes(duration: 10.1, interval: 5).map(\.seconds) == [0, 5])
  #expect(try MatchTimerVideoOCR.sampleTimes(duration: 2, interval: 5).map(\.seconds) == [0])
  #expect(throws: MatchTimerVideoOCR.Error.self) {
    _ = try MatchTimerVideoOCR.sampleTimes(duration: 10, interval: 0.0005)
  }
}

@Test func timerOCRPrefersValidTimerBeforeConfidence() throws {
  let candidate = try #require(
    MatchTimerVideoOCR.preferredCandidate(from: [
      ("fragment", 0.99), (" 09:55 ", 0.75), ("09:54", 0.70),
    ]))
  #expect(candidate.string == "09:55")
  #expect(candidate.confidence == 0.75)
}

@Test func detectsOneStandardMatchWithMissingObservations() throws {
  let result = MatchTimerDetection(records: [
    timer(100_000, "10:00"), timer(110_000, "09:50"), timer(125_000, "09:35"),
    timer(145_000, "09:15"),
  ])
  let match = try #require(result.matches.first)
  #expect(result.matches.count == 1)
  #expect(match.recordingPTSStart == 100)
  #expect(match.recordingPTSEnd == 700)
  #expect(match.observationCount == 4)
}

@Test func v2PreservesCompletedStandardMatchWithoutEndEvidence() throws {
  let result = detectV2(
    [timer(100_000, "10:00"), timer(110_000, "09:50"), timer(400_000, "05:00")],
    evidence: try endEvidence())
  let match = try #require(result.matches.first)
  #expect(result.matches.count == 1)
  #expect(match.mode == "standard10Minute")
  #expect(match.completion == "completed")
  #expect(match.recordingPTSStart == 100)
  #expect(match.recordingPTSEnd == 700)
  #expect(result.unclassifiedCandidates.isEmpty)
}

@Test func v2RequiresDeclaredSurrenderEvidenceToShortenStandardMatch() throws {
  let result = detectV2(
    [timer(100_000, "10:00"), timer(110_000, "09:50")],
    evidence: try endEvidence(
      #"{"evidenceId":"surrender-1","recordingPTS":430,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-430.jpg"}"#
    ))
  let match = try #require(result.matches.first)
  #expect(match.completion == "surrendered")
  #expect(match.recordingPTSEnd == 430)
  #expect(match.duration == 330)
  #expect(match.endEvidenceIds == ["surrender-1"])
  #expect(result.endEvidenceDiagnostics[0].disposition == "adopted")
}

@Test func v2RejectsSurrenderContradictedByLaterTimerObservation() throws {
  let result = detectV2(
    [timer(100_000, "10:00"), timer(110_000, "09:50"), timer(300_000, "06:40")],
    evidence: try endEvidence(
      #"{"evidenceId":"early-surrender","recordingPTS":200,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-200.jpg"}"#
    ))
  let match = try #require(result.matches.first)
  #expect(match.completion == "completed")
  #expect(match.recordingPTSEnd == 700)
  #expect(result.endEvidenceDiagnostics[0].reason == "contradictoryEvidence")
}

@Test func v2RejectsQuickMatchEndContradictedByLaterTimerObservation() throws {
  let result = detectV2(
    [timer(100_000, "05:00"), timer(110_000, "04:50"), timer(395_000, "00:05")],
    evidence: try endEvidence(
      #"{"evidenceId":"early-end","recordingPTS":390,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame-390.jpg"}"#
    ))
  #expect(result.matches.isEmpty)
  #expect(result.unclassifiedCandidates.map(\.reason) == ["contradictoryEvidence"])
  #expect(result.endEvidenceDiagnostics[0].reason == "contradictoryEvidence")
}

@Test func v2RetainsFilteredEvidenceReasonWhenAdoptingLaterSurrender() throws {
  let result = detectV2(
    [timer(100_000, "10:00"), timer(110_000, "09:50"), timer(300_000, "06:40")],
    evidence: try endEvidence(
      #"{"evidenceId":"early","recordingPTS":200,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-200.jpg"},{"evidenceId":"valid","recordingPTS":400,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-400.jpg"}"#
    ))
  let match = try #require(result.matches.first)
  #expect(match.recordingPTSEnd == 400)
  #expect(
    result.endEvidenceDiagnostics.map(\.reason) == ["contradictoryEvidence", "definesMatchEnd"])
}

@Test func v2ReevaluatesStandardMatchAfterPreviousSurrender() throws {
  let result = detectV2(
    [
      timer(100_000, "10:00"), timer(110_000, "09:50"),
      timer(450_000, "10:00"), timer(460_000, "09:50"),
    ],
    evidence: try endEvidence(
      #"{"evidenceId":"surrender","recordingPTS":430,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-430.jpg"}"#
    ))
  #expect(result.matches.map(\.recordingPTSStart) == [100, 450])
  #expect(result.matches.map(\.recordingPTSEnd) == [430, 1_050])
  #expect(result.matches.map(\.matchId) == ["match-01", "match-02"])
}

@Test func v2UsesCorroboratedTenMinuteAnchorWhenReevaluatingStandardMatch() throws {
  let result = detectV2(
    [timer(100_000, "10:00"), timer(108_000, "09:55"), timer(113_000, "09:50")],
    evidence: try endEvidence())
  let match = try #require(result.matches.first)
  #expect(match.recordingPTSStart == 100)
  #expect(match.recordingPTSEnd == 700)
}

@Test func v2AcceptsDiagnosticsFromReevaluatedAnchoredCluster() throws {
  let result = detectV2(
    [
      timer(100_000, "10:00"), timer(110_000, "09:50"),
      timer(450_000, "10:00"), timer(458_000, "09:55"), timer(463_000, "09:50"),
    ],
    evidence: try endEvidence(
      #"{"evidenceId":"surrender","recordingPTS":430,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-430.jpg"}"#
    ))
  #expect(result.matches.map(\.recordingPTSStart) == [100, 450])
  #expect(result.matches[1].observationCount == 3)
  #expect(result.timerDiagnostics.suffix(3).allSatisfy { $0.disposition == "accepted" })
}

@Test func v2DoesNotAcceptOffClusterTimerAfterSurrender() throws {
  let result = detectV2(
    [timer(100_000, "10:00"), timer(110_000, "09:50"), timer(300_000, "06:35")],
    evidence: try endEvidence(
      #"{"evidenceId":"surrender","recordingPTS":200,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-200.jpg"}"#
    ))
  #expect(try #require(result.matches.first).recordingPTSEnd == 200)
  #expect(result.timerDiagnostics.last?.disposition == "excluded")
}

@Test func v2DoesNotAcceptPreEndTimerOutsideAdoptedCluster() throws {
  let result = detectV2(
    [timer(100_000, "10:00"), timer(110_000, "09:50"), timer(295_000, "06:48")],
    evidence: try endEvidence(
      #"{"evidenceId":"surrender","recordingPTS":300,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-300.jpg"}"#
    ))
  #expect(result.timerDiagnostics.last?.disposition == "excluded")
}

@Test func v2BoundsSurrenderEvidenceAtNextSameModeCandidate() throws {
  let result = detectV2(
    [
      timer(100_000, "10:00"), timer(110_000, "09:50"),
      timer(350_000, "10:00"), timer(360_000, "09:50"),
    ],
    evidence: try endEvidence(
      #"{"evidenceId":"first","recordingPTS":300,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-300.jpg"},{"evidenceId":"second","recordingPTS":500,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-500.jpg"}"#
    ))
  #expect(result.matches.map(\.recordingPTSEnd) == [300, 500])
  #expect(result.matches.map(\.matchId) == ["match-01", "match-02"])
}

@Test func v2LeavesConflictingCrossModeInterpretationsUnclassified() throws {
  let result = detectV2(
    [timer(400_000, "05:00"), timer(410_000, "04:50")],
    evidence: try endEvidence(
      #"{"evidenceId":"standard-end","recordingPTS":430,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-430.jpg"},{"evidenceId":"quick-end","recordingPTS":700,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame-700.jpg"}"#
    ))
  #expect(result.matches.isEmpty)
  #expect(result.unclassifiedCandidates.count == 2)
  #expect(result.unclassifiedCandidates.allSatisfy { $0.reason == "contradictoryEvidence" })
}

@Test func v2BoundsMatchEndEvidenceAtNextQuickCandidate() throws {
  let result = detectV2(
    [
      timer(100_000, "05:00"), timer(110_000, "04:50"),
      timer(395_000, "05:00"), timer(405_000, "04:50"),
    ],
    evidence: try endEvidence(
      #"{"evidenceId":"displaced","recordingPTS":400,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame-400.jpg"},{"evidenceId":"second","recordingPTS":695,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame-695.jpg"}"#
    ))
  #expect(result.matches.map(\.recordingPTSStart) == [395])
  #expect(result.matches.map(\.recordingPTSEnd) == [695])
}

@Test func v2AnchorsQuickMatchToCorroboratingFiveMinuteObservation() throws {
  let result = detectV2(
    [timer(100_000, "05:00"), timer(108_000, "04:55"), timer(113_000, "04:50")],
    evidence: try endEvidence(
      #"{"evidenceId":"end","recordingPTS":400,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame-400.jpg"}"#
    ))
  let match = try #require(result.matches.first)
  #expect(match.recordingPTSStart == 100)
  #expect(match.observationCount == 3)
}

@Test func v2RetainsQuickCandidateAfterSurrenderedStandardMatch() throws {
  let result = detectV2(
    [
      timer(100_000, "10:00"), timer(110_000, "09:50"),
      timer(450_000, "05:00"), timer(460_000, "04:50"),
    ],
    evidence: try endEvidence(
      #"{"evidenceId":"surrender","recordingPTS":430,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-430.jpg"}"#
    ))
  #expect(result.matches.map(\.recordingPTSEnd) == [430])
  #expect(result.unclassifiedCandidates.map(\.mode) == ["quick5Minute"])
  #expect(result.unclassifiedCandidates.map(\.reason) == ["missingEndEvidence"])
}

@Test func v2BoundsPreliminaryStandardIntervalsAtNextCandidate() throws {
  let result = detectV2(
    [
      timer(100_000, "10:00"), timer(110_000, "09:50"),
      timer(350_000, "10:00"), timer(360_000, "09:50"),
      timer(550_000, "05:00"), timer(560_000, "04:50"),
    ],
    evidence: try endEvidence(
      #"{"evidenceId":"first","recordingPTS":300,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-300.jpg"},{"evidenceId":"second","recordingPTS":500,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-500.jpg"}"#
    ))
  #expect(result.matches.map(\.recordingPTSEnd) == [300, 500])
  #expect(result.unclassifiedCandidates.map(\.mode) == ["quick5Minute"])
  #expect(result.unclassifiedCandidates.map(\.reason) == ["missingEndEvidence"])
}

@Test func v2DiscardsContradictedEvidenceBeforeModeArbitration() throws {
  let result = detectV2(
    [timer(390_000, "05:10"), timer(400_000, "05:00"), timer(410_000, "04:50")],
    evidence: try endEvidence(
      #"{"evidenceId":"contradicted","recordingPTS":405,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-405.jpg"},{"evidenceId":"quick-end","recordingPTS":700,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame-700.jpg"}"#
    ))
  let match = try #require(result.matches.first)
  #expect(match.mode == "standard10Minute")
  #expect(match.completion == "completed")
  #expect(result.endEvidenceDiagnostics[0].reason == "contradictoryEvidence")
}

@Test func v2IncludesCompletedStandardInCrossModeArbitration() throws {
  let result = detectV2(
    [timer(390_000, "05:10"), timer(400_000, "05:00"), timer(410_000, "04:50")],
    evidence: try endEvidence(
      #"{"evidenceId":"quick-end","recordingPTS":700,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame-700.jpg"}"#
    ))
  #expect(result.matches.isEmpty)
  #expect(result.unclassifiedCandidates.count == 2)
  #expect(result.unclassifiedCandidates.allSatisfy { $0.reason == "contradictoryEvidence" })
  #expect(result.timerDiagnostics.allSatisfy { $0.disposition == "excluded" })
  #expect(result.timerDiagnostics.allSatisfy { $0.reason == "contradictoryEvidence" })
}

@Test func v2AdmitsSurrenderAtLastLateTimerTimestamp() throws {
  let result = detectV2(
    [timer(410_000, "04:50"), timer(420_000, "04:40")],
    evidence: try endEvidence(
      #"{"evidenceId":"surrender","recordingPTS":420,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-420.jpg"}"#
    ))
  let match = try #require(result.matches.first)
  #expect(match.mode == "standard10Minute")
  #expect(match.recordingPTSEnd == 420)
}

@Test func v2UsesDeclaredModeToRecoverLateStandardCountdown() throws {
  let result = detectV2(
    [timer(410_000, "04:50"), timer(420_000, "04:40")],
    evidence: try endEvidence(
      #"{"evidenceId":"late-surrender","recordingPTS":430,"kind":"surrender","medium":"audio","mode":"standard10Minute","source":"audio:429-431"}"#
    ))
  let match = try #require(result.matches.first)
  #expect(match.mode == "standard10Minute")
  #expect(match.recordingPTSStart == 100)
  #expect(match.recordingPTSEnd == 430)
  #expect(result.unclassifiedCandidates.isEmpty)
}

@Test func v2ClassifiesFiveMinuteModeOnlyWithEndEvidence() throws {
  let records = [timer(100_000, "05:00"), timer(110_000, "04:50"), timer(125_000, "04:35")]
  let missing = detectV2(records, evidence: try endEvidence())
  #expect(missing.matches.isEmpty)
  #expect(missing.unclassifiedCandidates.map(\.reason) == ["missingEndEvidence"])

  let completed = detectV2(
    records,
    evidence: try endEvidence(
      #"{"evidenceId":"quick-end","recordingPTS":400,"kind":"matchEnd","medium":"audio","mode":"quick5Minute","source":"audio:399-401"}"#
    ))
  let match = try #require(completed.matches.first)
  #expect(match.mode == "quick5Minute")
  #expect(match.completion == "completed")
  #expect(match.recordingPTSStart == 100)
  #expect(match.recordingPTSEnd == 400)
  #expect(completed.timerDiagnostics.allSatisfy { $0.disposition == "accepted" })
  #expect(completed.timerDiagnostics.allSatisfy { $0.reason == "consistentQuickMatchCluster" })
}

@Test func v2EndEvidenceRejectsUnknownKeys() {
  let documents = [
    #"{"$schema":"https://kaito-tokyo.github.io/unite-analysis-swift/match-end-evidence-v1.schema.json","evidence":[],"extra":true}"#,
    #"{"$schema":"https://kaito-tokyo.github.io/unite-analysis-swift/match-end-evidence-v1.schema.json","evidence":[{"evidenceId":"end","recordingPTS":300,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame.jpg","extra":true}]}"#,
  ]
  for document in documents {
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(MatchEndEvidenceDocument.self, from: Data(document.utf8))
    }
  }
}

@Test func v2DoesNotGuessContradictoryNonstandardEnd() throws {
  let result = detectV2(
    [timer(100_000, "05:00"), timer(110_000, "04:50")],
    evidence: try endEvidence(
      #"{"evidenceId":"visual-end","recordingPTS":400,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame-400.jpg"},{"evidenceId":"audio-end","recordingPTS":401,"kind":"matchEnd","medium":"audio","mode":"quick5Minute","source":"audio:400-402"}"#
    ))
  #expect(result.matches.isEmpty)
  #expect(result.unclassifiedCandidates.map(\.reason) == ["contradictoryEvidence"])
  #expect(result.endEvidenceDiagnostics.allSatisfy { $0.reason == "contradictoryEvidence" })
}

@Test func v2RetainsUnsupportedEvidenceWithoutClassifyingMatch() throws {
  let result = detectV2(
    [timer(100_000, "05:00"), timer(110_000, "04:50")],
    evidence: try endEvidence(
      #"{"evidenceId":"unsupported","recordingPTS":400,"kind":"matchEnd","medium":"visual","mode":"eventMode","source":"frame-400.jpg"}"#
    ))
  #expect(result.matches.isEmpty)
  #expect(result.endEvidenceDiagnostics[0].reason == "unsupportedMode")
  #expect(result.unclassifiedCandidates.map(\.reason) == ["missingEndEvidence"])
}

@Test func v2SeparatesSurrenderAndAdjacentQuickMatchWithContiguousIDs() throws {
  let result = detectV2(
    [
      timer(100_000, "10:00"), timer(110_000, "09:50"),
      timer(450_000, "05:00"), timer(460_000, "04:50"),
    ],
    evidence: try endEvidence(
      #"{"evidenceId":"surrender","recordingPTS":430,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-430.jpg"},{"evidenceId":"quick-end","recordingPTS":750,"kind":"matchEnd","medium":"visual","mode":"quick5Minute","source":"frame-750.jpg"}"#
    ))
  #expect(result.matches.map(\.matchId) == ["match-01", "match-02"])
  #expect(result.matches.map(\.recordingPTSStart) == [100, 450])
  #expect(result.matches.map(\.recordingPTSEnd) == [430, 750])
}

@Test func separatesMatchesAndRejectsResetAdjacentOutlier() throws {
  let result = MatchTimerDetection(records: [
    timer(584_806, "10:00"), timer(589_806, "09:55"), timer(604_806, "09:40"),
    timer(1_984_806, "10:00"), timer(1_989_805, "00:01"), timer(1_994_806, "09:50"),
    timer(2_009_806, "09:35"),
  ])
  #expect(result.matches.map(\.recordingPTSStart) == [584.806, 1_984.806])
  let outlier = try #require(
    result.diagnostics.first { $0.recordingTimelineMilliseconds == 1_989_805 })
  #expect(outlier.disposition == "excluded")
  #expect(outlier.reason == "noConsistentCluster")
}

@Test func laterTenMinuteOutlierDoesNotMoveClusterStart() throws {
  let result = MatchTimerDetection(records: [
    timer(104_000, "10:00"), timer(105_000, "09:55"), timer(110_000, "09:50"),
  ])
  #expect(try #require(result.matches.first).recordingPTSStart == 100)
  #expect(result.diagnostics[0].reason == "isolatedStartRequiresCorroboration")
}

@Test func inClusterTenMinuteObservationAnchorsStart() throws {
  let result = MatchTimerDetection(records: [
    timer(100_000, "10:00"), timer(107_000, "09:55"), timer(112_000, "09:50"),
  ])
  #expect(try #require(result.matches.first).recordingPTSStart == 100)
}

@Test func frozenTimerDoesNotFormAStandardMatch() {
  let result = MatchTimerDetection(records: [timer(400_000, "05:00"), timer(401_000, "05:00")])
  #expect(result.matches.isEmpty)
  #expect(result.diagnostics.allSatisfy { $0.reason == "noConsistentCluster" })
}

@Test func fiveMinuteCountdownDoesNotFormAStandardMatch() {
  let result = MatchTimerDetection(records: [
    timer(1_000_000, "05:00"), timer(1_005_000, "04:55"), timer(1_010_000, "04:50"),
  ])
  #expect(result.matches.isEmpty)
  #expect(result.diagnostics.allSatisfy { $0.reason == "noConsistentCluster" })
}

@Test func acceptedObservationIsNotReusedByLaterCluster() {
  let result = MatchTimerDetection(records: [
    timer(100_000, "10:00"), timer(101_000, "09:59"),
    timer(109_000, "09:55"), timer(110_000, "09:54"),
  ])
  #expect(result.matches.count == 1)
  #expect(result.diagnostics[0].disposition == "accepted")
  #expect(result.diagnostics[1].disposition == "accepted")
  #expect(result.diagnostics[2].reason == "overlapsPreviousMatch")
  #expect(result.diagnostics[3].reason == "overlapsPreviousMatch")
}

@Test func rejectsNegativeAndOverlappingMatchesWithoutSkippingIdentifiers() {
  let result = MatchTimerDetection(records: [
    timer(0, "05:00"), timer(5_000, "04:55"),
    timer(700_000, "10:00"), timer(705_000, "09:55"), timer(710_000, "09:50"),
    timer(1_100_000, "10:00"), timer(1_105_000, "09:55"),
    timer(1_400_000, "10:00"), timer(1_405_000, "09:55"),
  ])
  #expect(result.matches.map(\.recordingPTSStart) == [700, 1_400])
  #expect(result.matches.map(\.matchId) == ["match-01", "match-02"])
  #expect(result.diagnostics[0].reason == "startBeforeRecording")
  #expect(result.diagnostics[1].reason == "startBeforeRecording")
  #expect(result.diagnostics[5].reason == "overlapsPreviousMatch")
  #expect(result.diagnostics[6].reason == "overlapsPreviousMatch")
}

@Test func rejectsMatchesThatEndAfterTheRecording() {
  let result = MatchTimerDetection(
    records: [timer(700_000, "10:00"), timer(705_000, "09:55")],
    recordingDuration: 1_000)
  #expect(result.matches.isEmpty)
  #expect(result.diagnostics.allSatisfy { $0.reason == "endAfterRecording" })
}

@Test func corroboratedTenMinuteFrameAnchorsDelayedTimerSeries() throws {
  let result = MatchTimerDetection(records: [
    timer(584_806, "10:00"), timer(589_805, "09:58"), timer(594_806, "09:53"),
    timer(599_806, "09:48"),
  ])
  #expect(result.matches.map(\.recordingPTSStart) == [584.806])
  #expect(result.diagnostics[0].disposition == "accepted")
}

@Test func rejectsInvalidTimersAndIsolatedTenMinutes() throws {
  let result = MatchTimerDetection(records: [
    timer(1_000, "10:00"), timer(2_000, "10:01"), timer(3_000, "9:59"),
    timer(4_000, "00:60"), timer(5_000, "hello"),
  ])
  #expect(result.matches.isEmpty)
  #expect(result.diagnostics[0].reason == "isolatedStartRequiresCorroboration")
  #expect(result.diagnostics.dropFirst().allSatisfy { $0.reason == "invalidMMSS" })
}

@Test func timerAuditDefinitionOrdersEveryDiagnosticDeterministically() {
  let detection = MatchTimerDetection(records: [
    timer(105_000, "invalid"), timer(100_000, "10:00"), timer(110_000, "09:50"),
  ])
  let definition = MatchTimerAuditContactSheetDefinition(diagnostics: detection.diagnostics)
  #expect(definition.cells.map(\.recordingTimelineMilliseconds) == [100_000, 105_000, 110_000])
  #expect(definition.cells.map(\.output) == ["10:00", "invalid", "09:50"])
  #expect(definition.cells.map(\.disposition) == ["accepted", "excluded", "accepted"])
  #expect(definition.cells[1].reason == "invalidMMSS")
}

@Test func timerAuditRendersZeroObservationArtifactAndProtectsExistingOutput() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let output = directory.appendingPathComponent("timer-audit.jpg")
  let layout = MatchTimerLayout(
    schema: MatchTimerLayout.schemaURL,
    layoutId: "test",
    referenceSize: .init(width: 1920, height: 1080),
    regions: .init(matchTimer: .init(x: 900, y: 20, width: 120, height: 60)))
  let result = try await MatchTimerAuditContactSheet.render(
    videoURL: directory.appendingPathComponent("unused.mp4"),
    gameScreen: .init(x: 0, y: 0, width: 1920, height: 1080), layout: layout,
    diagnostics: [], outputPrefixURL: output, force: false)
  #expect(result.outputs == [output.path + "-000001.jpg"])
  #expect(result.observationCount == 0)
  #expect(result.columns == 1)
  #expect(result.pageCount == 1)
  #expect(FileManager.default.fileExists(atPath: result.outputs[0]))
  await #expect(throws: MatchTimerAuditContactSheet.Error.self) {
    try await MatchTimerAuditContactSheet.render(
      videoURL: directory.appendingPathComponent("unused.mp4"),
      gameScreen: .init(x: 0, y: 0, width: 1920, height: 1080), layout: layout,
      diagnostics: [], outputPrefixURL: output, force: false)
  }
}

@Test func timerAuditInstallationRollsBackEarlierPages() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let staged = (1...2).map { directory.appendingPathComponent("staged-\($0).jpg") }
  let outputs = (1...2).map { directory.appendingPathComponent("output-\($0).jpg") }
  for url in staged { try Data("staged".utf8).write(to: url) }
  try Data("collision".utf8).write(to: outputs[1])

  #expect(throws: MatchTimerAuditContactSheet.Error.self) {
    try MatchTimerAuditContactSheet.installStagedPages(staged, at: outputs, force: false)
  }
  #expect(!FileManager.default.fileExists(atPath: outputs[0].path))
  #expect(try Data(contentsOf: outputs[1]) == Data("collision".utf8))
}

@Test func forcedTimerAuditInstallationRestoresEarlierPages() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let staged = (1...2).map { directory.appendingPathComponent("staged-\($0).jpg") }
  let outputs = (1...2).map { directory.appendingPathComponent("output-\($0).jpg") }
  try Data("new".utf8).write(to: staged[0])
  for (index, url) in outputs.enumerated() {
    try Data("old-\(index)".utf8).write(to: url)
  }

  #expect(throws: (any Swift.Error).self) {
    try MatchTimerAuditContactSheet.installStagedPages(staged, at: outputs, force: true)
  }
  #expect(try Data(contentsOf: outputs[0]) == Data("old-0".utf8))
  #expect(try Data(contentsOf: outputs[1]) == Data("old-1".utf8))
}

@Test func forcedTimerAuditRemovesDifferentlyCasedObsoletePages() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let values = try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
  guard values.volumeSupportsCaseSensitiveNames != true else { return }
  let obsolete = directory.appendingPathComponent("Audit-000002.jpg")
  try Data("obsolete".utf8).write(to: obsolete)
  let layout = MatchTimerLayout(
    schema: MatchTimerLayout.schemaURL, layoutId: "test",
    referenceSize: .init(width: 1920, height: 1080),
    regions: .init(matchTimer: .init(x: 900, y: 20, width: 120, height: 60)))

  _ = try await MatchTimerAuditContactSheet.render(
    videoURL: directory.appendingPathComponent("unused.mp4"),
    gameScreen: .init(x: 0, y: 0, width: 1920, height: 1080), layout: layout,
    diagnostics: [], outputPrefixURL: directory.appendingPathComponent("audit"), force: true)
  #expect(!FileManager.default.fileExists(atPath: obsolete.path))
}

@Test func timerAuditRejectsDirectoryDestinationWhenForced() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let prefix = directory.appendingPathComponent("audit")
  let destination = MatchTimerAuditContactSheet.pageOutputURL(prefix: prefix, index: 1)
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
  try Data("evidence".utf8).write(to: destination.appendingPathComponent("evidence.txt"))
  let layout = MatchTimerLayout(
    schema: MatchTimerLayout.schemaURL, layoutId: "test",
    referenceSize: .init(width: 1920, height: 1080),
    regions: .init(matchTimer: .init(x: 900, y: 20, width: 120, height: 60)))

  await #expect(throws: MatchTimerAuditContactSheet.Error.self) {
    try await MatchTimerAuditContactSheet.render(
      videoURL: directory.appendingPathComponent("unused.mp4"),
      gameScreen: .init(x: 0, y: 0, width: 1920, height: 1080), layout: layout,
      diagnostics: [], outputPrefixURL: prefix, force: true)
  }
  #expect(
    FileManager.default.fileExists(atPath: destination.appendingPathComponent("evidence.txt").path))
}

@Test func timerAuditRejectsOversizedDerivedDimensions() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: directory) }
  let layout = MatchTimerLayout(
    schema: MatchTimerLayout.schemaURL, layoutId: "test",
    referenceSize: .init(width: 1920, height: 1080),
    regions: .init(matchTimer: .init(x: 0, y: 0, width: 1, height: 1080)))

  await #expect(throws: MatchTimerAuditContactSheet.Error.self) {
    try await MatchTimerAuditContactSheet.render(
      videoURL: directory.appendingPathComponent("unused.mp4"),
      gameScreen: .init(x: 0, y: 0, width: 1920, height: 1080), layout: layout,
      diagnostics: [], outputPrefixURL: directory.appendingPathComponent("audit"), force: false)
  }
}

@Test func gameScreenRectangleDefaultsAndPartialFields() throws {
  #expect(
    try GameScreenRectangle.resolve(customFields: [:], videoWidth: 1632, videoHeight: 918)
      == .init(x: 0, y: 0, width: 1632, height: 918))
  #expect(
    try GameScreenRectangle.resolve(
      customFields: ["unite-analysis-swift.x": "32", "unite-analysis-swift.y": "18"],
      videoWidth: 1632, videoHeight: 918)
      == .init(x: 32, y: 18, width: 1600, height: 900))
  #expect(
    try GameScreenRectangle.resolve(
      customFields: ["unite-analysis-swift.width": "1280"], videoWidth: 1632,
      videoHeight: 918)
      == .init(x: 0, y: 0, width: 1280, height: 918))
}

@Test func gameScreenRectangleRejectsInvalidAndOutOfBoundsValues() {
  #expect(throws: GameScreenRectangle.ResolutionError.self) {
    try GameScreenRectangle.resolve(
      customFields: ["unite-analysis-swift.x": "not-an-integer"], videoWidth: 100,
      videoHeight: 100)
  }
  #expect(throws: GameScreenRectangle.ResolutionError.self) {
    try GameScreenRectangle.resolve(
      customFields: ["unite-analysis-swift.x": "90", "unite-analysis-swift.width": "11"],
      videoWidth: 100, videoHeight: 100)
  }
  #expect(throws: GameScreenRectangle.ResolutionError.self) {
    try GameScreenRectangle.resolve(
      customFields: ["unite-analysis-swift.height": "0"], videoWidth: 100,
      videoHeight: 100)
  }
  #expect(throws: GameScreenRectangle.ResolutionError.self) {
    try GameScreenRectangle.resolve(
      customFields: ["unite-analysis-swift.x": String(Int.min)], videoWidth: 100,
      videoHeight: 100)
  }
}
