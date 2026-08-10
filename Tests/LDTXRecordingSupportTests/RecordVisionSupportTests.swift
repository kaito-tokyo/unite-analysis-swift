// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreGraphics
import Foundation
import LDTXRecordingSupport
import RecordVisionSupport
import ResultScannerSupport
import Testing

@Test func videoDecodingFailureIncludesSandboxRecoveryGuidance() {
  let message = VideoFrameSupport.decodingFailureMessage("Cannot Decode")
  #expect(message.contains("VideoToolbox"))
  #expect(message.contains("outside an application sandbox"))
  #expect(message.contains("before treating the media as invalid"))
}

@Test func scanResultEncodesOutputSchemaURL() throws {
  let result = ScanResult(
    input: "/tmp/result.jpg",
    generatedAt: "2026-08-06T00:00:00Z",
    ocrOptions: [:],
    screens: [
      ScreenResult(
        kind: "summary", detectionScore: 0, rawText: [], battleData: nil, summary: [])
    ],
    warnings: []
  )
  let object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])
  #expect(object["$schema"] as? String == ScanResult.schemaURL)
}

@Test func missingSummaryScoreIsMarkedAsInferred() throws {
  var cells = [
    OCRCell(text: nil, confidence: nil, alternatives: []),
    OCRCell(text: "3", confidence: 0.9, alternatives: ["3"]),
    OCRCell(text: "7", confidence: 0.8, alternatives: ["7"]),
    OCRCell(text: "82", confidence: 0.7, alternatives: ["82"]),
  ]

  supplementMissingScore(&cells)

  #expect(cells[0].text == "0")
  #expect(cells[0].confidence == nil)
  #expect(cells[0].alternatives.isEmpty)
  #expect(cells[0].inferred)
  #expect(cells.dropFirst().allSatisfy { !$0.inferred })
}

@Test func incompleteSummaryRowDoesNotInferScore() {
  var cells = [
    OCRCell(text: nil, confidence: nil, alternatives: []),
    OCRCell(text: "3", confidence: 0.9, alternatives: ["3"]),
    OCRCell(text: nil, confidence: nil, alternatives: []),
    OCRCell(text: "82", confidence: 0.7, alternatives: ["82"]),
  ]

  supplementMissingScore(&cells)

  #expect(cells[0].text == nil)
  #expect(!cells[0].inferred)
}

@Test func summaryNumericRowSeparatesAdjacentTwoDigitColumns() throws {
  let context = try #require(
    CGContext(
      data: nil,
      width: 1632,
      height: 918,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  let image = try #require(context.makeImage())
  let observation = TextObservation(
    text: "212",
    confidence: 0.9,
    box: NormalizedRect(
      x: 1250.0 / 1632.0,
      y: 1 - 438.0 / 918.0,
      width: 97.0 / 1632.0,
      height: 36.0 / 918.0))

  let cells = recognizedSummaryNumericRow(
    observations: [observation],
    image: image,
    centers: [1191, 1270, 1326, 1422],
    y: 420)

  #expect(cells.map(\.text) == [nil, "2", "12", nil])
}

@Test func playerNameOCRPreservesMixedWritingSystems() {
  let observations = [
    TextObservation(
      text: "うみれおん", confidence: 0.9,
      box: .init(x: 0.1, y: 0.5, width: 0.2, height: 0.1)),
    TextObservation(
      text: "우알이", confidence: 0.8,
      box: .init(x: 0.35, y: 0.5, width: 0.2, height: 0.1)),
    TextObservation(
      text: "KEIJI119", confidence: 0.85,
      box: .init(x: 0.6, y: 0.5, width: 0.25, height: 0.1)),
  ]

  #expect(
    OCRInput.interpreted(observations, type: .playerName).values
      == ["うみれおん 우알이 KEIJI119"])
}

@Test func playerNameOCRPrefersHighestConfidenceLanguagePass() {
  let combined = OCRCell(text: "9901", confidence: 0.3, alternatives: ["9901"])
  let korean = OCRCell(text: "우알이", confidence: 1, alternatives: ["우알이"])
  let english = OCRCell(text: "wooalli", confidence: 0.8, alternatives: ["wooalli"])

  #expect(preferredPlayerNameCell([combined, korean, english]).text == "우알이")
}

@Test func playerNameOCRPrefersCombinedLanguagePassOnConfidenceTies() {
  let partial = OCRCell(text: "Player", confidence: 1, alternatives: ["Player"])
  let combined = OCRCell(text: "Player名前", confidence: 1, alternatives: ["Player名前"])

  #expect(preferredPlayerNameCell([partial, combined]).text == "Player名前")
}

@Test func playerNameOCRPreservesLegitimateDelimiters() {
  let observations = [
    TextObservation(
      text: "<Ace>", confidence: 1,
      box: .init(x: 0.1, y: 0.5, width: 0.2, height: 0.1)),
    TextObservation(
      text: "(Player)", confidence: 1,
      box: .init(x: 0.4, y: 0.5, width: 0.3, height: 0.1)),
  ]

  #expect(
    OCRInput.interpreted(observations, type: .playerName).values
      == ["<Ace> (Player)"])
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

@Test func recordSpecVersion2RequiresMatchIdAndVideoComponents() throws {
  let data = Data(
    #"""
    {
      "version": 2,
      "matchId": "match-01",
      "startPTS": {"value": 180000, "timescale": 600},
      "duration": 600,
      "videoComponents": [
        {"name": "game-screen", "x": 0, "y": 0, "width": 1920, "height": 1080}
      ]
    }
    """#.utf8)
  let spec = try JSONDecoder().decode(RecordVisionRecordSpec.self, from: data)

  #expect(spec.version == 2)
  #expect(spec.matchId == "match-01")
  #expect(spec.videoComponents.map(\.name) == ["game-screen"])
}

@Test func recordSpecRejectsMissingVideoComponents() {
  let data = Data(
    #"""
    {
      "version": 2,
      "matchId": "match-01",
      "startPTS": {"value": 180000, "timescale": 600},
      "duration": 600
    }
    """#.utf8)

  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(RecordVisionRecordSpec.self, from: data)
  }
}

@Test func recordSpecVersion1UsesGlobalId() throws {
  let data = Data(
    #"""
    {
      "version": 1,
      "globalId": "LDTX-example-match-01",
      "startPTS": {"value": 180000, "timescale": 600},
      "duration": 600,
      "videoComponents": [
        {"name": "game-screen", "x": 0, "y": 0, "width": 1920, "height": 1080}
      ]
    }
    """#.utf8)
  let spec = try JSONDecoder().decode(RecordVisionRecordSpec.self, from: data)
  #expect(spec.version == 1)
  #expect(spec.matchId == "LDTX-example-match-01")
}

@Test func recordSpecRejectsMissingOrUnsupportedVersion() {
  let missing = Data(
    #"""
    {
      "matchId": "match-01",
      "startPTS": {"value": 180000, "timescale": 600},
      "duration": 600,
      "videoComponents": []
    }
    """#.utf8)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(RecordVisionRecordSpec.self, from: missing)
  }

  let unsupported = Data(
    #"""
    {
      "version": 3,
      "matchId": "match-01",
      "startPTS": {"value": 180000, "timescale": 600},
      "duration": 600,
      "videoComponents": []
    }
    """#.utf8)
  #expect(throws: DecodingError.self) {
    try JSONDecoder().decode(RecordVisionRecordSpec.self, from: unsupported)
  }
}

@Test func sampledFrameResizeUsesExactRequestedResolution() throws {
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let context = try #require(
    CGContext(
      data: nil,
      width: 2,
      height: 2,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
  let source = try #require(context.makeImage())

  let resized = try VideoFrameSupport.resized(source, width: 7, height: 3)

  #expect(resized.width == 7)
  #expect(resized.height == 3)
}

@Test func sampleFrameOffsetsMatchFFmpegFPSGrid() throws {
  #expect(try SampleFrameSequence.sampleOffsets(duration: 1.2, fps: 2) == [0, 0.5, 1.0])
  #expect(try SampleFrameSequence.sampleOffsets(duration: 1, fps: 4) == [0, 0.25, 0.5, 0.75])
}

@Test func namedOCROptionsIgnoreUnrelatedFields() throws {
  let data = Data(
    """
    {
      "$schema": "https://kaito-tokyo.github.io/unite-analysis-swift/ocr-options.schema.json",
      "result-screen.text": {
        "recognitionLanguages": ["ja-JP"],
        "customWords": ["バトルデータ"],
        "futureOption": true
      },
      "unrelated-region": {
        "recognitionLanguages": ["en-US"]
      }
    }
    """.utf8)
  let document = try JSONDecoder().decode(OCRRecognitionOptionsDocument.self, from: data)
  let options = document.regions

  #expect(document.schema == OCRRecognitionOptionsDocument.schemaURL)
  #expect(options["result-screen.text"]?.recognitionLanguages == ["ja-JP"])
  #expect(options["result-screen.text"]?.customWords == ["バトルデータ"])
  #expect(options["unrelated-region"]?.recognitionLanguages == ["en-US"])
}

@Test func playerNameOCRRegionIsSharedAcrossCommands() {
  #expect(ScanResultOCRRegion.playerName == "player-name")
}

@Test func genericOCRInterpretsEachTypeInReadingOrder() {
  let observations = [
    TextObservation(
      text: "I2O", confidence: 0.8,
      box: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.1)),
    TextObservation(
      text: "「Player", confidence: 0.9,
      box: .init(x: 0.1, y: 0.8, width: 0.2, height: 0.1)),
    TextObservation(
      text: "One", confidence: 0.85,
      box: .init(x: 0.4, y: 0.8, width: 0.2, height: 0.1)),
  ]
  #expect(
    OCRInput.interpreted(observations, type: .text).values == ["「Player", "One", "I2O"])
  #expect(
    OCRInput.interpreted(Array(observations.suffix(2)), type: .playerName).values == ["Player One"])
  #expect(OCRInput.interpreted([observations[0]], type: .numeric).values == ["120"])
}

@Test func genericOCRReadingOrderClustersRowsBeforeSortingColumns() {
  let observations = [
    TextObservation(
      text: "A", confidence: 1,
      box: .init(x: 0.1, y: 0.77, width: 0.1, height: 0.1)),
    TextObservation(
      text: "B", confidence: 1,
      box: .init(x: 0.2, y: 0.79, width: 0.1, height: 0.1)),
    TextObservation(
      text: "C", confidence: 1,
      box: .init(x: 0.3, y: 0.8, width: 0.1, height: 0.1)),
  ]

  #expect(OCRInput.readingOrder(observations).map(\.text) == ["B", "C", "A"])
}

@Test func scanResultDoesNotFallbackToUnrelatedOCRRegions() {
  #expect(throws: ScannerError.self) {
    try ResultScannerRunner.run(
      input: "missing.jpg",
      type: .summary,
      ocrOptions: [
        "unrelated-region": OCRRecognitionOptions(recognitionLanguages: ["ja-JP"])
      ])
  }
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
      matchId: "test",
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
      "'#' + (FRAME.index + 1) + ' / ' + FRAME.actualInmatch + ' / ' + MATCH.duration + ' / ' + RECORD.matchId + ' / ' + VIDEO.width",
    index: 2,
    inmatch: 45.25,
    beforeStart: nil,
    afterEnd: nil,
    actualInmatch: 44.5,
    matchDuration: 600,
    recordMatchId: "record-01",
    videoWidth: 1920,
    videoHeight: 1080,
    videoFrameRate: 60,
    videoDuration: 681.383333
  )
  #expect(value == "#3 / 44.5 / 600 / record-01 / 1920")
}

@Test func standardOverviewDrawTextScriptsEvaluateStandalone() throws {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let jobsURL = repositoryRoot.appendingPathComponent(
    ".apm/skills/review-unite-matches-ja/references/overview-contact-sheet-jobs.jsonl")
  let lines = try String(contentsOf: jobsURL, encoding: .utf8)
    .split(whereSeparator: \.isNewline)
  #expect(lines.count == 5)

  for line in lines {
    let definition = try JSONDecoder().decode(
      ContactSheetDefinition.self, from: Data(line.utf8))
    let scripts = definition.placements.compactMap { $0.drawText?.script?.return }
    #expect(scripts.count == 1)
    for script in scripts {
      let value = try DrawTextScriptEngine.evaluate(
        script: script,
        index: 2,
        inmatch: 45.25,
        beforeStart: nil,
        afterEnd: nil,
        actualInmatch: 44.5,
        matchDuration: 600,
        recordMatchId: "record-01",
        videoWidth: 1920,
        videoHeight: 1080,
        videoFrameRate: 60,
        videoDuration: 681.383333)
      #expect(value.contains("F002 | 44.500s"))
    }
  }
}

@Test func contactSheetDefinitionDecodesScriptReturnObject() throws {
  let data = Data(
    """
    {
      "cell": { "width": 100, "height": 50 },
      "jobId": "sheet-1",
      "columns": 1,
      "placements": [{
        "drawText": {
          "script": { "return": "FRAME.index" },
          "x": 0, "y": 0, "fontSize": 12,
          "backgroundColor": "#00000099", "borderColor": "#FFFFFFFF"
        }
      }],
      "matchTimestamps": [0]
    }
    """.utf8)
  let definition = try JSONDecoder().decode(ContactSheetDefinition.self, from: data)
  #expect(definition.jobId == "sheet-1")
  #expect(definition.placements[0].drawText?.script?.return == "FRAME.index")
  #expect(definition.placements[0].drawText?.backgroundColor == "#00000099")
  #expect(definition.placements[0].drawText?.borderColor == "#FFFFFFFF")
}

@Test func contactSheetMatchTimestampsResolveInStrictSourceOrder() throws {
  let data = Data(
    """
    {
      "cell": { "width": 100, "height": 50 },
      "columns": 1,
      "placements": [{ "drawText": { "text": ".", "x": 0, "y": 0, "fontSize": 1 } }],
      "matchTimestamps": [-5, -1, 0, 601]
    }
    """.utf8)
  let definition = try JSONDecoder().decode(ContactSheetDefinition.self, from: data)
  let offsets = try ContactSheetGenerator.validatedOffsets(
    matchTimestamps: definition.matchTimestamps)
  #expect(offsets == [-5, -1, 0, 601])
}

@Test func contactSheetRejectsDuplicateOrReverseSourceTimes() throws {
  for matchTimestamps in [
    "[1, 1]",
    "[2, 1]",
  ] {
    let data = Data(
      """
      {
        "cell": { "width": 100, "height": 50 },
        "columns": 1,
        "placements": [{ "drawText": { "text": ".", "x": 0, "y": 0, "fontSize": 1 } }],
        "matchTimestamps": \(matchTimestamps)
      }
      """.utf8)
    let definition = try JSONDecoder().decode(ContactSheetDefinition.self, from: data)
    do {
      _ = try ContactSheetGenerator.validatedOffsets(
        matchTimestamps: definition.matchTimestamps)
      Issue.record("Expected non-increasing frames to be rejected")
    } catch {
      #expect(String(describing: error).contains("strictly increasing"))
    }
  }
}

@Test(arguments: [-1.0, .nan, .infinity, -.infinity])
func contactSheetRejectsInvalidRecordDuration(duration: Double) {
  do {
    try ContactSheetGenerator.validate(duration: duration)
    Issue.record("Expected invalid record duration to be rejected")
  } catch {
    #expect(
      String(describing: error)
        == "record-spec.json duration must be a finite non-negative value")
  }
}

@Test func contactSheetRejectsFirstOutOfRangeSourceTimeBeforeDecode() {
  do {
    _ = try ContactSheetGenerator.validatedSourceTimes(
      start: CMTime(seconds: 12.5, preferredTimescale: 600), offsets: [-1, 0, 9, 10],
      videoDuration: CMTime(seconds: 21, preferredTimescale: 600))
    Issue.record("Expected the first out-of-range source time to be rejected")
  } catch {
    let message = String(describing: error)
    #expect(
      message
        == "Requested contact-sheet source time 21.500s for matchTimestamps[2] = 9.000s is outside source-video range [0.000, 21.000)s"
    )
    #expect(!message.contains("sandbox"))
    #expect(!message.contains("decode"))
  }
}

@Test func contactSheetAcceptsSourceTimesInsideHalfOpenDuration() throws {
  let sourceTimes = try ContactSheetGenerator.validatedSourceTimes(
    start: CMTime(seconds: 12.5, preferredTimescale: 600), offsets: [-12.5, 0, 8.499],
    videoDuration: CMTime(seconds: 21, preferredTimescale: 600))
  #expect(sourceTimes.count == 3)
}

@Test func contactSheetRejectsSourceTimeRoundedUpToDuration() {
  do {
    _ = try ContactSheetGenerator.validatedSourceTimes(
      start: CMTime(seconds: 21, preferredTimescale: 600), offsets: [-0.0001],
      videoDuration: CMTime(seconds: 21, preferredTimescale: 600))
    Issue.record("Expected a source time quantized to the duration to be rejected")
  } catch {
    #expect(String(describing: error).contains("outside source-video range"))
  }
}

@Test func contactSheetRejectsLegacyFramesField() {
  let data = Data(
    """
    {
      "cell": { "width": 100, "height": 50 },
      "columns": 1,
      "placements": [{ "drawText": { "text": ".", "x": 0, "y": 0, "fontSize": 1 } }],
      "frames": [0],
      "matchTimestamps": [0]
    }
    """.utf8)
  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(ContactSheetDefinition.self, from: data)
  }
}

@Test func chromaEventProcessesJPEGsInDictionaryOrder() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let context = try #require(
    CGContext(
      data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
  for (name, color) in [
    ("frame-000003.JPEG", CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
    ("frame-000001.jpg", CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
    ("frame-000002.jpg", CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
  ] {
    context.setFillColor(color)
    context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
    try VideoFrameSupport.writeBaselineJPEG(
      try #require(context.makeImage()), to: directory.appendingPathComponent(name), quality: 0.95)
  }
  FileManager.default.createFile(
    atPath: directory.appendingPathComponent("ignored.png").path, contents: Data())

  let ordered = try ChromaEventDetector.jpegURLs(in: directory)
  #expect(
    ordered.map(\.lastPathComponent) == [
      "frame-000001.jpg", "frame-000002.jpg", "frame-000003.JPEG",
    ])
  let output = directory.appendingPathComponent("events.json")
  try ChromaEventDetector.run(
    inputSampleDirectoryURL: directory, fps: 2, outputURL: output, force: false)
  let result = try JSONDecoder().decode(
    ChromaEventResult.self, from: Data(contentsOf: output))
  #expect(result.inputSampleDirectory == directory.path)
  #expect(result.inputSampleCount == 3)
  #expect(result.firstInputFilename == "frame-000001.jpg")
  #expect(result.lastInputFilename == "frame-000003.JPEG")
  #expect(result.sampledWidth == 4)
  #expect(result.sampledHeight == 4)
  #expect(result.samples.map(\.requestedInmatch) == [0.5, 1.0])
  #expect(result.samples.map(\.actualInmatch) == [0.5, 1.0])
  let object = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any])
  #expect(object["$schema"] as? String == ChromaEventResult.schema)
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

@Test func chromaEventRejectsTheFirstMissingSequenceIndex() {
  let urls = ["frame-000001.jpg", "frame-000003.jpg"].map {
    URL(fileURLWithPath: "/tmp/\($0)")
  }

  #expect(throws: ChromaEventError.self) {
    try ChromaEventDetector.sequenceIndices(for: urls)
  }
  do {
    _ = try ChromaEventDetector.sequenceIndices(for: urls)
  } catch {
    #expect(
      String(describing: error)
        == "JPEG sequence is not contiguous at frame-000003.jpg: expected index 2, found 3")
  }
}

@Test func chromaEventRejectsNonPaddedSequenceIndices() {
  let urls = [URL(fileURLWithPath: "/tmp/frame-1.jpg")]

  #expect(throws: ChromaEventError.self) {
    try ChromaEventDetector.sequenceIndices(for: urls)
  }
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

@Test func audioPeakDetectorZeroFillsMissingGridBlocks() {
  var energies: [Int64] = [40]
  var times = [0.105]

  AudioPeakDetector.appendZeroFilledGap(
    after: 10, before: 14, blockEnergies: &energies, blockPTS: &times)

  #expect(energies == [40, 0, 0, 0])
  #expect(times.count == 4)
  #expect(abs(times[1] - 0.115) < 0.000_000_1)
  #expect(abs(times[2] - 0.125) < 0.000_000_1)
  #expect(abs(times[3] - 0.135) < 0.000_000_1)
}

@Test func audioPeakDetectorDoesNotInsertAdjacentGridBlocks() {
  var energies: [Int64] = [40]
  var times = [0.105]

  AudioPeakDetector.appendZeroFilledGap(
    after: 10, before: 11, blockEnergies: &energies, blockPTS: &times)

  #expect(energies == [40])
  #expect(times == [0.105])
}

@Test func audioPeakDetectorZeroFillsExpectedEdgeBlocks() {
  var energies: [Int64] = []
  var times: [Double] = []

  AudioPeakDetector.appendZeroFilledBlocks(
    from: 10, to: 13, blockEnergies: &energies, blockPTS: &times)

  #expect(energies == [0, 0, 0])
  #expect(times.count == 3)
  #expect(abs(times[0] - 0.105) < 0.000_000_1)
  #expect(abs(times[2] - 0.125) < 0.000_000_1)
}

@Test func audioPeakResultEncodesOutputSchemaURL() throws {
  let result = AudioPeakDetectionResult(
    matchId: "recording", inmatchStart: 0, duration: 600, gain: 1, dilation: 0.5,
    peaks: [], intervals: [])
  let object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: Any])

  #expect(object["$schema"] as? String == AudioPeakDetectionResult.schema)
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
