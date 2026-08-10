// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import RecordVisionSupport
import Testing

@testable import UniteAnalysisSwiftCommands

@Test func nearestRankThresholdAdmitsAllTiesAtTheRank() throws {
  let values = [1.0, 2, 3, 3]
  let result = try EventCandidateGenerator.nearestRankThreshold(values, percentile: 75)
  let threshold = try #require(result)

  #expect(threshold == 3)
  #expect(values.filter { $0 >= threshold } == [3, 3])
}

@Test func audioClustersUseTheFirstPointAsTheFixedWidthAnchor() throws {
  let peaks = [
    AudioPeak(recordingPTS: 0, inmatch: 0, score: 1),
    AudioPeak(recordingPTS: 4, inmatch: 4, score: 1),
    AudioPeak(recordingPTS: 8, inmatch: 8, score: 1),
  ]

  let points = try EventCandidateGenerator.clusteredAudioPoints(peaks, duration: 10)

  #expect(points.map(\.representativeInmatch) == [0, 8])
  #expect(points.map { $0.constituents.map(\.inmatch) } == [[0, 4], [8]])
}

@Test func chromaPercentilesAreIndependentAndSecondaryCoverageIsGlobal() throws {
  let regionA = (1...200).map { index in
    chromaSample(time: Double(index), score: index)
  }
  let regionB = (1...200).map { index in
    chromaSample(
      time: index == 198 ? 400 : (index == 199 ? 450 : Double(index) + 300),
      score: index * 10)
  }
  let audio = [
    EventDetectResult.Constituent(
      source: "audio", inmatch: 198, score: 1, value: nil, confidence: nil)
  ]

  let points = try EventCandidateGenerator.selectedChromaPoints(
    [("a", regionA), ("b", regionB)], audioConstituents: audio, duration: 600)

  #expect(points.map(\.representativeInmatch) == [199, 200, 450, 500, 400])
  #expect(
    points.map { $0.constituents[0].source }
      == ["chroma:a", "chroma:a", "chroma:b", "chroma:b", "chroma:b"])
}

@Test func finalMergeIsTransitiveAndRetainsEveryProvenancePoint() {
  let points = [
    point(time: 0, source: "audio"),
    point(time: 2, source: "chroma:top"),
    point(time: 4, source: "ocr:top"),
    point(time: 6.1, source: "scheduled"),
  ]

  let candidates = EventCandidateGenerator.merge(points)

  #expect(candidates.count == 2)
  #expect(candidates[0].startInmatch == 0)
  #expect(candidates[0].endInmatch == 4)
  #expect(candidates[0].constituents.map(\.source) == ["audio", "chroma:top", "ocr:top"])
  #expect(candidates[1].constituents.map(\.source) == ["scheduled"])
}

@Test func manifestRunResolvesInputsAndMergesSupplementalCandidates() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let encoder = JSONEncoder()
  let audio = AudioPeakDetectionResult(
    matchId: "match-01", inmatchStart: 0, duration: 600, gain: 1, dilation: 0.5,
    peaks: [], intervals: [])
  try encoder.encode(audio).write(to: directory.appendingPathComponent("audio.json"))
  let manifest = EventDetectManifest(
    audioPeaks: "audio.json", chromaEvents: [],
    ocrCandidates: [.init(region: "banner", inmatch: 10, value: "KO", confidence: 0.9)],
    scheduledCandidates: [.init(inmatch: 12, label: "objective")])
  let manifestURL = directory.appendingPathComponent("manifest.json")
  try encoder.encode(manifest).write(to: manifestURL)

  let result = try EventCandidateGenerator.run(manifestURL: manifestURL)

  #expect(result.matchId == "match-01")
  #expect(result.candidates.count == 1)
  #expect(result.candidates[0].constituents.map(\.source) == ["ocr:banner", "scheduled"])
}

private func chromaSample(time: Double, score: Int) -> ChromaEventSample {
  ChromaEventSample(
    requestedInmatch: time, actualInmatch: time, score: score, cbThreshold: score,
    crThreshold: 0, cbChangedPixelCount: 0, crChangedPixelCount: 0,
    bothChangedPixelCount: 0, changedPixelCount: 0)
}

private func point(time: Double, source: String) -> EventCandidateGenerator.Point {
  .init(
    representativeInmatch: time,
    constituents: [.init(source: source, inmatch: time, score: nil, value: nil, confidence: nil)])
}
