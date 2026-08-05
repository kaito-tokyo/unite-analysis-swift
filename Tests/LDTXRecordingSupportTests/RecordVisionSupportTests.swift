// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation
import LDTXRecordingSupport
import Testing

@testable import RecordVisionSupport

@Test func videoDecodingFailureIncludesSandboxRecoveryGuidance() {
  let message = VideoFrameSupport.decodingFailureMessage("Cannot Decode")
  #expect(message.contains("VideoToolbox"))
  #expect(message.contains("outside an application sandbox"))
  #expect(message.contains("before treating the media as invalid"))
}

private func audioPeakTestBundle(info: [String: Any], files: [String]) throws -> URL {
  let bundle = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathComponent("sample.ldtxrecord")
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  let data = try PropertyListSerialization.data(
    fromPropertyList: info, format: .xml, options: 0)
  try data.write(to: bundle.appendingPathComponent("Info.plist"))
  for file in files {
    FileManager.default.createFile(
      atPath: bundle.appendingPathComponent(file).path, contents: Data())
  }
  return bundle
}

private func writeSilentVideoWithoutAudio(to url: URL) async throws {
  let writer = try AVAssetWriter(url: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: 16,
      AVVideoHeightKey: 16,
    ])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: 16,
      kCVPixelBufferHeightKey as String: 16,
    ])
  #expect(writer.canAdd(input))
  writer.add(input)
  #expect(writer.startWriting())
  writer.startSession(atSourceTime: .zero)
  var pixelBuffer: CVPixelBuffer?
  let status = CVPixelBufferCreate(
    nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
  #expect(status == kCVReturnSuccess)
  guard let pixelBuffer else { return }
  #expect(adaptor.append(pixelBuffer, withPresentationTime: .zero))
  input.markAsFinished()
  await writer.finishWriting()
  #expect(writer.status == .completed)
}

@Test func audioPeakInputUsesFixedV2MainMediaWithoutMainMixMetadata() throws {
  let bundle = try audioPeakTestBundle(
    info: [
      "LDTXRecordingFormatVersion": 2,
      "LDTXRecordingMainMediaFile": "main.fragmented.mp4",
    ],
    files: ["main.fragmented.mp4"])
  #expect(
    try AudioPeakDetector.audioURL(in: bundle)
      == bundle.appendingPathComponent("main.fragmented.mp4"))
}

@Test func audioPeakInputUsesV2FixedNameInsteadOfConflictingMetadata() throws {
  let bundle = try audioPeakTestBundle(
    info: [
      "LDTXRecordingFormatVersion": 2,
      "LDTXRecordingMainMediaFile": "unexpected.mp4",
      "LDTXRecordingAudioTracks": [
        ["Identifier": "main-mix", "MediaFile": "legacy.m4a"]
      ],
    ],
    files: ["main.fragmented.mp4", "unexpected.mp4", "legacy.m4a"])
  #expect(
    try AudioPeakDetector.audioURL(in: bundle)
      == bundle.appendingPathComponent("main.fragmented.mp4"))
}

@Test func audioPeakInputRejectsV1MainMixRecording() throws {
  let bundle = try audioPeakTestBundle(
    info: [
      "LDTXRecordingFormatVersion": 1,
      "LDTXRecordingAudioTracks": [
        ["Identifier": "other", "MediaFile": "other.m4a"],
        ["Identifier": "main-mix", "MediaFile": "main-mix.m4a"],
      ],
    ],
    files: ["main-mix.m4a"])
  #expect(throws: AudioPeakDetectorError.self) {
    try AudioPeakDetector.audioURL(in: bundle)
  }
  do {
    _ = try AudioPeakDetector.audioURL(in: bundle)
    Issue.record("Expected recording format v1 to be rejected")
  } catch {
    #expect(
      String(describing: error)
        == "audio-peaks requires LDTX recording format version 2: \(bundle.appendingPathComponent("Info.plist").path)"
    )
  }
}

@Test func audioPeakDetectorDiagnosesV2MainMediaWithoutAudioTrack() async throws {
  let bundle = try audioPeakTestBundle(
    info: ["LDTXRecordingFormatVersion": 2], files: [])
  let videoURL = bundle.appendingPathComponent("main.fragmented.mp4")
  try await writeSilentVideoWithoutAudio(to: videoURL)
  let resolvedURL = try AudioPeakDetector.audioURL(in: bundle)
  do {
    _ = try await AudioPeakDetector.detect(
      audioURL: resolvedURL,
      globalId: "test",
      matchStartPTS: .zero,
      inmatchStart: 0,
      duration: 0.01,
      gain: 1)
    Issue.record("Expected video without audio to be rejected")
  } catch {
    #expect(String(describing: error) == "No audio track: \(videoURL.path)")
  }
}

@Test func drawTextScriptReturnExpressionUsesSharedContext() throws {
  let value = try DrawTextScriptEngine.evaluate(
    script:
      "'#' + (FRAME.index + 1) + ' / ' + FRAME.actualInmatch + ' / ' + MATCH.duration + ' / ' + RECORD.globalId + ' / ' + VIDEO.width",
    index: 2,
    inmatch: 45.25,
    beforeStart: nil,
    afterEnd: nil,
    actualInmatch: 44.5,
    matchDuration: 600,
    recordGlobalID: "record-01",
    videoWidth: 1920,
    videoHeight: 1080,
    videoFrameRate: 60,
    videoDuration: 681.383333
  )
  #expect(value == "#3 / 44.5 / 600 / record-01 / 1920")
}

@Test func contactSheetDefinitionDecodesScriptReturnObject() throws {
  let data = Data(
    """
    {
      "cell": { "width": 100, "height": 50 },
      "columns": 1,
      "placements": [{
        "drawText": {
          "script": { "return": "FRAME.index" },
          "x": 0, "y": 0, "fontSize": 12,
          "backgroundColor": "#00000099", "borderColor": "#FFFFFFFF"
        }
      }],
      "frames": [{ "inmatch": 0 }]
    }
    """.utf8)
  let definition = try JSONDecoder().decode(ContactSheetDefinition.self, from: data)
  #expect(definition.placements[0].drawText?.script?.return == "FRAME.index")
  #expect(definition.placements[0].drawText?.backgroundColor == "#00000099")
  #expect(definition.placements[0].drawText?.borderColor == "#FFFFFFFF")
}

@Test func contactSheetFramesResolveInStrictSourceOrder() throws {
  let data = Data(
    """
    {
      "cell": { "width": 100, "height": 50 },
      "columns": 1,
      "placements": [{ "drawText": { "text": ".", "x": 0, "y": 0, "fontSize": 1 } }],
      "frames": [
        { "beforeStart": 5 },
        { "beforeStart": 1 },
        { "inmatch": 0 },
        { "afterEnd": 1 }
      ]
    }
    """.utf8)
  let definition = try JSONDecoder().decode(ContactSheetDefinition.self, from: data)
  let offsets = try ContactSheetGenerator.validatedOffsets(frames: definition.frames, duration: 600)
  #expect(offsets == [-5, -1, 0, 601])
}

@Test func contactSheetRejectsDuplicateOrReverseSourceTimes() throws {
  for frames in [
    "[{ \"inmatch\": 1 }, { \"inmatch\": 1 }]",
    "[{ \"inmatch\": 2 }, { \"inmatch\": 1 }]",
  ] {
    let data = Data(
      """
      {
        "cell": { "width": 100, "height": 50 },
        "columns": 1,
        "placements": [{ "drawText": { "text": ".", "x": 0, "y": 0, "fontSize": 1 } }],
        "frames": \(frames)
      }
      """.utf8)
    let definition = try JSONDecoder().decode(ContactSheetDefinition.self, from: data)
    do {
      _ = try ContactSheetGenerator.validatedOffsets(frames: definition.frames, duration: 600)
      Issue.record("Expected non-increasing frames to be rejected")
    } catch {
      #expect(String(describing: error).contains("strictly increasing source times"))
    }
  }
}

@Test func continuousOCRDefinitionIgnoresSchemaAndDecodesSource() throws {
  let data = Data(
    """
    {
      "$schema": "/tmp/continuous-ocr.schema.json",
      "source": { "x": 300, "y": 80, "width": 1030, "height": 300 },
      "recognitionLanguages": ["ja-JP"],
      "customWords": ["カイオーガ", "うみれおん"]
    }
    """.utf8)
  let definition = try JSONDecoder().decode(ContinuousOCRDefinition.self, from: data)
  #expect(definition.source == .init(x: 300, y: 80, width: 1030, height: 300))
  #expect(definition.recognitionLanguages == ["ja-JP"])
  #expect(definition.customWords == ["カイオーガ", "うみれおん"])
}

@Test func continuousOCRDefinitionRequiresRecognitionLanguages() {
  let data = Data(
    """
    {
      "source": { "x": 300, "y": 80, "width": 1030, "height": 300 }
    }
    """.utf8)
  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(ContinuousOCRDefinition.self, from: data)
  }
}

@Test func continuousOCRUsesFixedTwoFPSOffsets() {
  #expect(ContinuousOCR.sampleOffsets(duration: 1.2) == [0.25, 0.75, 1.1999999999999997])
}

@Test func chromaEventUsesIndependentOtsuThresholds() {
  #expect(ChromaEventDetector.otsuThreshold([0, 0, 0, 8, 8, 8]) == 0)
  #expect(ChromaEventDetector.otsuThreshold([4, 4, 4]) == nil)
  let result = ChromaEventDetector.analyze(
    previous: .init(cb: [0, 0, 0, 0], cr: [0, 0, 0, 0]),
    current: .init(cb: [0, 0, 8, 8], cr: [0, 0, 0, 0])
  )
  #expect(result.cbThreshold == 0)
  #expect(result.crThreshold == 0)
  #expect(result.cbChangedPixelCount == 2)
  #expect(result.crChangedPixelCount == 0)
  #expect(result.bothChangedPixelCount == 0)
  #expect(result.changedPixelCount == 2)
}

@Test func chromaEventCandidatesExpandAroundSelectedSamples() throws {
  let samples = [
    ChromaEventSample(
      requestedInmatch: 1, actualInmatch: 1.1, score: 59, cbThreshold: 59, crThreshold: 10,
      cbChangedPixelCount: 0, crChangedPixelCount: 0, bothChangedPixelCount: 0, changedPixelCount: 0
    ),
    ChromaEventSample(
      requestedInmatch: 4, actualInmatch: 4.1, score: 60, cbThreshold: 60, crThreshold: 10,
      cbChangedPixelCount: 0, crChangedPixelCount: 0, bothChangedPixelCount: 0, changedPixelCount: 0
    ),
  ]
  #expect(
    try ChromaEventDetector.expandedCandidateTimes(samples, minimumScore: 60, duration: 5) == [
      3.5, 4, 4.5,
    ])
}

@Test func continuousOCRUsesNativeSourceGeometry() {
  #expect(ContinuousOCR.sourcePadding == 0)
  #expect(ContinuousOCR.recognitionScale == 1)
  #expect(ContinuousOCR.recognitionTolerance == 0.2)
  #expect(ContinuousOCR.acceptedObservationCenterX == 0.45...0.55)
  #expect(ContinuousOCR.recognitionBatchSize == 12)
  #expect(ContinuousOCR.recognitionBatchSeparatorPixels == 8)
  #expect(
    ContinuousOCR.expandedSourceRect(
      .init(x: 100, y: 50, width: 200, height: 80),
      videoWidth: 400,
      videoHeight: 200
    ) == CGRect(x: 100, y: 50, width: 200, height: 80))
  #expect(
    ContinuousOCR.expandedSourceRect(
      .init(x: 0, y: 0, width: 100, height: 50),
      videoWidth: 120,
      videoHeight: 60
    ) == CGRect(x: 0, y: 0, width: 100, height: 50))
}

@Test func continuousOCRUnitesAdjacentSimilarSamples() {
  func sample(_ time: Double, _ text: String, _ confidence: Float) -> ContinuousOCRSample {
    ContinuousOCRSample(
      requestedInmatch: time,
      actualInmatch: time,
      observations: [
        .init(
          text: text,
          confidence: confidence,
          boundingBox: .init(x: 0, y: 0, width: 1, height: 1)
        )
      ]
    )
  }
  let intervals = ContinuousOCR.mergedIntervals(samples: [
    sample(1.0, "かなりリードしているぞ!", 0.8),
    sample(1.5, "かなりリードしているぞ！", 0.9),
    sample(3.0, "接戦だ!", 0.7),
  ])
  #expect(intervals.count == 2)
  #expect(intervals[0].inmatchStart == 1.0)
  #expect(intervals[0].inmatchEnd == 2.0)
  #expect(intervals[0].sampleCount == 2)
  #expect(intervals[0].representativeText == "かなりリードしているぞ！")
  #expect(intervals[1].representativeText == "接戦だ!")
}

@Test func continuousOCRRendersReadableMatchClockTextWithoutVisionMetadata() {
  let box = ContinuousOCRObservation.Rectangle(x: 0.1, y: 0.2, width: 0.3, height: 0.1)
  let result = ContinuousOCRResult(
    globalId: "record-match-01",
    samplesPerSecond: 2,
    source: .init(x: 0, y: 0, width: 100, height: 50),
    scannedSampleCount: 1200,
    samples: [],
    intervals: [
      .init(
        inmatchStart: 299.25, inmatchEnd: 303.25, representativeText: "かなり苦しい戦いだ", confidence: 1,
        sampleCount: 8, boundingBox: box),
      .init(
        inmatchStart: 299.25, inmatchEnd: 303.25, representativeText: "注目", confidence: 0.5,
        sampleCount: 4, boundingBox: box),
    ]
  )
  let text = ContinuousOCR.renderText(result, matchDuration: 600)
  #expect(text.contains("[05:00.750–04:56.750] かなり苦しい戦いだ / 注目"))
  #expect(!text.contains("confidence"))
  #expect(!text.contains("boundingBox"))
}

@Test func audioPeakDetectorFindsAndMergesFixedPowerRise() {
  var energies = Array(repeating: Int64(100_000), count: 120)
  energies[50] = 10_000_000
  energies[51] = 10_000_000
  energies[80] = 8_000_000
  energies[81] = 8_000_000
  let times = energies.indices.map { Double($0) * 0.01 }

  let indices = AudioPeakDetector.peakIndices(
    blockEnergies: energies,
    samplesPerBlock: 1,
    blockPTS: times,
    requestedStart: 0,
    requestedEnd: 1.2
  )

  #expect(indices.count == 1)
  #expect(indices.first.map { (50...54).contains($0) } == true)
}

@Test func audioPeakDetectorKeepsPeaksFartherThanFixedSeparation() {
  var energies = Array(repeating: Int64(100_000), count: 180)
  energies[50] = 10_000_000
  energies[51] = 10_000_000
  energies[140] = 10_000_000
  energies[141] = 10_000_000
  let times = energies.indices.map { Double($0) * 0.01 }

  let indices = AudioPeakDetector.peakIndices(
    blockEnergies: energies,
    samplesPerBlock: 1,
    blockPTS: times,
    requestedStart: 0,
    requestedEnd: 1.8
  )

  #expect(indices.count == 2)
}

@Test func audioPeakDetectorFixedDomainConstants() {
  #expect(AudioPeakDetector.blockDuration == 0.010)
  #expect(AudioPeakDetector.fastBlockCount == 5)
  #expect(AudioPeakDetector.slowBlockCount == 20)
  #expect(AudioPeakDetector.minimumNormalizedRise == 0.000_005)
  #expect(AudioPeakDetector.minimumPeakSeparation == 0.75)
  #expect(AudioPeakDetector.peakDilation == 0.5)
}

@Test func audioPeakDetectorDilatesAndUnionsPeakIntervals() {
  let peaks = [
    AudioPeak(recordingPTS: 110, inmatch: 10, score: 0.2),
    AudioPeak(recordingPTS: 111, inmatch: 11, score: 0.7),
    AudioPeak(recordingPTS: 115, inmatch: 15, score: 0.4),
  ]

  let intervals = AudioPeakDetector.dilatedIntervals(
    peaks: peaks,
    matchStartSeconds: 100,
    requestedInmatchStart: 0,
    requestedInmatchEnd: 20
  )

  #expect(intervals.count == 2)
  #expect(intervals[0].inmatchStart == 9.5)
  #expect(intervals[0].inmatchEnd == 11.5)
  #expect(intervals[0].recordingPTSStart == 109.5)
  #expect(intervals[0].recordingPTSEnd == 111.5)
  #expect(intervals[0].peakCount == 2)
  #expect(intervals[0].strongestPeakInmatch == 11)
  #expect(intervals[0].strongestPeakScore == 0.7)
  #expect(intervals[1].inmatchStart == 14.5)
  #expect(intervals[1].inmatchEnd == 15.5)
  #expect(intervals[1].peakCount == 1)
}

@Test func audioPeakDetectorClipsDilatedIntervalsToRequestedRange() {
  let peaks = [
    AudioPeak(recordingPTS: 105.2, inmatch: 5.2, score: 0.3),
    AudioPeak(recordingPTS: 109.8, inmatch: 9.8, score: 0.4),
  ]

  let intervals = AudioPeakDetector.dilatedIntervals(
    peaks: peaks,
    matchStartSeconds: 100,
    requestedInmatchStart: 5,
    requestedInmatchEnd: 10
  )

  #expect(intervals.count == 2)
  #expect(intervals[0].inmatchStart == 5)
  #expect(intervals[0].inmatchEnd == 5.7)
  #expect(intervals[1].inmatchStart == 9.3)
  #expect(intervals[1].inmatchEnd == 10)
}

@Test func audioPeakDetectorHonorsRequestedInterval() {
  var energies = Array(repeating: Int64(100_000), count: 220)
  energies[50] = 10_000_000
  energies[51] = 10_000_000
  energies[180] = 10_000_000
  energies[181] = 10_000_000
  let times = energies.indices.map { Double($0) * 0.01 }

  let indices = AudioPeakDetector.peakIndices(
    blockEnergies: energies,
    samplesPerBlock: 1,
    blockPTS: times,
    requestedStart: 1.5,
    requestedEnd: 2.0
  )

  #expect(indices.count == 1)
  #expect(indices.first.map { (180...184).contains($0) } == true)
}
