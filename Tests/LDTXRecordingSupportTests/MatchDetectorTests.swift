// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RecordVisionSupport
import Testing

private func timer(_ milliseconds: Int64, _ output: String) -> MatchTimerObservation {
  .init(recordingTimelineMilliseconds: milliseconds, output: output)
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

@Test func frozenTimerDoesNotFormAStandardMatch() {
  let result = MatchTimerDetection(records: [timer(400_000, "05:00"), timer(401_000, "05:00")])
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
