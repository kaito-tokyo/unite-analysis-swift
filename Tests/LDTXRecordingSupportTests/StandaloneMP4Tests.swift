// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import ArgumentParser
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import LDTXRecordingSupport
import RecordVisionSupport
import Testing

@testable import UniteAnalysisSwiftCommands

@Test func standaloneDetectionRequiresExplicitDirectory() throws {
  for command in ["detect-matches-v1", "detect-matches-v2"] {
    let evidence = command.hasSuffix("v2") ? ["--end-evidence", "end.json"] : []
    let base = [command, "--input", "video.mp4", "--layout", "layout.json"] + evidence
    #expect(throws: (any Error).self) {
      _ = try UniteAnalysisSwiftCommand.parseAsRoot(base + ["--standalone-mp4"])
    }
    #expect(throws: (any Error).self) {
      _ = try UniteAnalysisSwiftCommand.parseAsRoot(base + ["--output-dir", "analysis"])
    }
    #expect(throws: (any Error).self) {
      _ = try UniteAnalysisSwiftCommand.parseAsRoot(
        base + ["--standalone-mp4", "--output-dir", "analysis", "--output", "result.json"])
    }
    _ = try UniteAnalysisSwiftCommand.parseAsRoot(
      base + ["--standalone-mp4", "--output-dir", "analysis"])
  }
}

@Test func standaloneMatchCommandsRequireBothVideoAndSpec() throws {
  let commands = [
    ["batch-frame", "jobs.jsonl"],
    ["contact-sheet", "jobs.jsonl"],
    ["frame-burst", "jobs.jsonl"],
    ["audio-peaks-v1"],
    ["eval-draw-text-script", "VIDEO.width", "--inmatch", "0"],
    ["extract-clip", "--output", "clip.mp4"],
    [
      "precise-frame", "--match-timestamp", "1", "--x", "0", "--y", "0", "--width", "16",
      "--height", "16", "--output", "frame.jpg",
    ],
    [
      "sample-frames", "--crop-x", "0", "--crop-y", "0", "--crop-width", "16", "--crop-height",
      "16", "--fps", "1", "--scale-x", "16", "--scale-y", "16", "--output", "frame-%06d.jpg",
    ],
  ]
  for command in commands {
    #expect(throws: (any Error).self) {
      _ = try UniteAnalysisSwiftCommand.parseAsRoot(
        command + ["--standalone-mp4", "--input", "video.mp4"])
    }
    #expect(throws: (any Error).self) {
      _ = try UniteAnalysisSwiftCommand.parseAsRoot(
        command + ["--standalone-mp4", "--record-spec", "record-spec.json"])
    }
    #expect(throws: (any Error).self) {
      _ = try UniteAnalysisSwiftCommand.parseAsRoot(
        command + ["--input", "video.mp4", "--record-spec", "record-spec.json"])
    }
    _ = try UniteAnalysisSwiftCommand.parseAsRoot(
      command + ["--standalone-mp4", "--input", "video.mp4", "--record-spec", "record-spec.json"])
    _ = try UniteAnalysisSwiftCommand.parseAsRoot(command + ["--record-spec", "record-spec.json"])
  }
}

@Test func standaloneLoadoutsRequireOutputAndRetainLegacyMode() throws {
  for command in [
    ["recognize-draft-loadout-v1", "--final-prep-time=-2", "--vs-time=-1"],
    ["recognize-blind-loadout-v1", "--prep-time=-1"],
  ] {
    let standalone =
      command + ["--standalone-mp4", "--input", "video.mp4", "--record-spec", "record-spec.json"]
    #expect(throws: (any Error).self) {
      _ = try UniteAnalysisSwiftCommand.parseAsRoot(standalone)
    }
    _ = try UniteAnalysisSwiftCommand.parseAsRoot(standalone + ["--output", "loadout.json"])
    _ = try UniteAnalysisSwiftCommand.parseAsRoot(command + ["--input", "legacy.ldtxrecord"])
    _ = try UniteAnalysisSwiftCommand.parseAsRoot(command + ["--record-spec", "record-spec.json"])
    #expect(throws: (any Error).self) {
      _ = try UniteAnalysisSwiftCommand.parseAsRoot(
        command + ["--input", "legacy.ldtxrecord", "--record-spec", "record-spec.json"])
    }
  }
}

@Test func standaloneGameScreenDefaultsAndBounds() throws {
  var options = try StandaloneDetectionOptions.parse([
    "--standalone-mp4", "--output-dir", "analysis",
  ])
  #expect(
    try options.rectangle(videoWidth: 1920, videoHeight: 1080)
      == .init(x: 0, y: 0, width: 1920, height: 1080))
  options.gameScreenX = 10
  #expect(throws: (any Error).self) { try options.validate() }
  options.gameScreenY = 20
  options.gameScreenWidth = 100
  options.gameScreenHeight = 60
  #expect(
    try options.rectangle(videoWidth: 1920, videoHeight: 1080)
      == .init(x: 10, y: 20, width: 100, height: 60))
  options.gameScreenWidth = 1920
  #expect(throws: (any Error).self) {
    _ = try options.rectangle(videoWidth: 1920, videoHeight: 1080)
  }
}

@Test func standaloneSourceRequiresRegularMP4AndIgnoresBundleMetadata() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let video = root.appendingPathComponent("video.MP4")
  try Data().write(to: video)
  try Data("invalid plist".utf8).write(to: root.appendingPathComponent("Info.plist"))
  let resolved = try MatchVideoInput.standaloneMP4(video).resolve(
    recordSpecURL: root.appendingPathComponent("record-spec.json"))
  #expect(resolved.videoURL == video)
  #expect(resolved.bundleURL == nil)
  for invalid in [
    root, root.appendingPathComponent("missing.mp4"), root.appendingPathComponent("audio.wav"),
  ] {
    #expect(throws: (any Error).self) {
      _ = try MatchVideoInput.standaloneMP4(invalid).resolve(recordSpecURL: video)
    }
  }
}

@Test func standaloneOutputCannotReplaceSourcesIncludingAliases() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let video = root.appendingPathComponent("video.mp4")
  let spec = root.appendingPathComponent("record-spec.json")
  try Data().write(to: video)
  try Data().write(to: spec)
  let source = MatchVideoInput.standaloneMP4(video)
  for output in [video, spec] {
    #expect(throws: (any Error).self) { try source.validateOutput(output, recordSpecURL: spec) }
  }
  let alias = root.appendingPathComponent("alias.mp4")
  try FileManager.default.linkItem(at: video, to: alias)
  #expect(throws: (any Error).self) { try source.validateOutput(alias, recordSpecURL: spec) }
  #expect(throws: (any Error).self) {
    try validateStandaloneDestination(root, force: true, protectedInputs: [video])
  }
  let linked = root.appendingPathComponent("linked")
  try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
  #expect(throws: (any Error).self) {
    try validateStandaloneDestination(linked, force: true, protectedInputs: [video])
  }
}

@Test func standaloneDetectionPublishesSpecsAsOneDirectory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let destination = root.appendingPathComponent("analysis")
  let rectangle = GameScreenRectangle(x: 10, y: 20, width: 1280, height: 720)
  let specs = [
    StandaloneMatchSpec(matchId: "match-01", start: 12.345, duration: 600, gameScreen: rectangle),
    StandaloneMatchSpec(matchId: "match-02", start: 700, duration: 275, gameScreen: rectangle),
  ]
  let staged = try stageStandaloneDirectory(at: destination)
  try writeStandaloneDetection(
    ["source": "test"], specs: specs, staged: staged, destination: destination, force: false,
    protectedInputs: [])
  for expected in specs {
    let spec = try JSONDecoder().decode(
      RecordVisionRecordSpec.self,
      from: Data(
        contentsOf: destination.appendingPathComponent(expected.matchId + "/record-spec.json")))
    #expect(spec.version == 2)
    #expect(spec.matchId == expected.matchId)
    #expect(spec.startPTS.timescale == 600_000)
    #expect(spec.startPTS.value == expected.startPTS.value)
    #expect(spec.duration == expected.duration)
    let screen = try #require(spec.videoComponents.first)
    #expect(screen.name == "game-screen")
    #expect(screen.x == rectangle.x && screen.y == rectangle.y)
    #expect(screen.width == rectangle.width && screen.height == rectangle.height)
  }
  #expect(throws: (any Error).self) {
    try validateStandaloneDestination(destination, force: false, protectedInputs: [])
  }
  let replacement = try stageStandaloneDirectory(at: destination)
  try writeStandaloneDetection(
    ["source": "empty"], specs: [], staged: replacement, destination: destination, force: true,
    protectedInputs: [])
  #expect(
    try FileManager.default.contentsOfDirectory(atPath: destination.path) == [
      "match-detection.json"
    ])
}

@Test func standaloneMediaMatchesBundleExtractionAndKeepsItsSource() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let bundle = root.appendingPathComponent("fixture.ldtxrecord", isDirectory: true)
  try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
  let bundledVideo = bundle.appendingPathComponent("main.fragmented.mp4")
  try await writeStandaloneFixtureVideo(to: bundledVideo)
  try PropertyListSerialization.data(
    fromPropertyList: ["LDTXRecordingFormatVersion": 2], format: .xml, options: 0
  ).write(to: bundle.appendingPathComponent("Info.plist"))
  try Data().write(to: bundle.appendingPathComponent(".finalized"))
  let video = root.appendingPathComponent("video.mp4")
  try FileManager.default.copyItem(at: bundledVideo, to: video)
  let specData = try prettyPrintedJSONData(
    StandaloneMatchSpec(
      matchId: "match-01", start: 0.1, duration: 1,
      gameScreen: .init(x: 0, y: 0, width: 16, height: 16)))
  let standaloneSpec = root.appendingPathComponent("record-spec.json")
  let bundledSpec = bundle.appendingPathComponent("record-spec.json")
  try specData.write(to: standaloneSpec)
  try specData.write(to: bundledSpec)
  let standalone = MatchVideoInput.standaloneMP4(video)
  var context = try await RecordingMediaContext.prepare(
    recordSpecURL: standaloneSpec, source: standalone)
  context = try await context.refreshedIfUnfinished()
  #expect(context.recording.videoURL == video)
  #expect(context.recording.bundleURL == nil)
  let normalContext = try await RecordingMediaContext.prepare(recordSpecURL: bundledSpec)
  let crop = FrameSource(x: 0, y: 0, width: 16, height: 16)
  var frameFiles: [URL] = []
  for (index, media) in [context, normalContext].enumerated() {
    let output = root.appendingPathComponent("frame-\(index).jpg")
    _ = try await renderFrames(
      context: media,
      requests: [.init(scene: .matchRelative(0.25), source: crop, outputURL: output)], quality: 0.6,
      force: false)
    frameFiles.append(output)
  }
  #expect(try Data(contentsOf: frameFiles[0]) == Data(contentsOf: frameFiles[1]))
  var preciseFiles: [URL] = []
  var clipDurations: [Double] = []
  for (index, source) in [standalone, .recordingBundle].enumerated() {
    let spec = index == 0 ? standaloneSpec : bundledSpec
    let output = root.appendingPathComponent("precise-\(index).jpg")
    _ = try await renderPreciseFrame(
      recordSpecURL: spec, videoInput: source, scene: .matchRelative(0.25), source: crop,
      outputURL: output, quality: 0.6, force: false)
    preciseFiles.append(output)
    let clip = root.appendingPathComponent("clip-\(index).mp4")
    _ = try await extractClip(
      recordSpecURL: spec, source: source, start: 0, end: 0.5, outputURL: clip, force: false)
    clipDurations.append(try await AVURLAsset(url: clip).load(.duration).seconds)
  }
  #expect(try Data(contentsOf: preciseFiles[0]) == Data(contentsOf: preciseFiles[1]))
  #expect(abs(clipDurations[0] - clipDurations[1]) < 0.000_001)
  #expect(abs(clipDurations[0] - 0.5) < 0.001)
  let prepared = try await ContactSheetGenerator.prepare(
    recordSpecURL: standaloneSpec, source: standalone)
  let refreshed = try await ContactSheetGenerator.refreshIfUnfinished(prepared)
  let definition = Data(
    #"{"cell":{"width":16,"height":16},"columns":1,"placements":[{"source":{"x":0,"y":0,"width":16,"height":16},"destination":{"x":0,"y":0,"width":16,"height":16}}],"matchTimestamps":[0.25]}"#
      .utf8)
  let sheet = root.appendingPathComponent("sheet.jpg")
  try await ContactSheetGenerator.run(
    definitionData: definition, prepared: refreshed, outputURL: sheet, quality: 0.6, force: false)
  #expect(FileManager.default.fileExists(atPath: sheet.path))
  #expect(try Data(contentsOf: video) == Data(contentsOf: bundledVideo))
}

private func writeStandaloneFixtureVideo(
  to url: URL, width: Int = 16, height: Int = 16, transform: CGAffineTransform = .identity
) async throws {
  let writer = try AVAssetWriter(url: url, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
    ])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
    ])
  input.transform = transform
  writer.add(input)
  try #require(writer.startWriting())
  writer.startSession(atSourceTime: .zero)
  var buffer: CVPixelBuffer?
  try #require(
    CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
      == kCVReturnSuccess)
  let pixels = try #require(buffer)
  CVPixelBufferLockBaseAddress(pixels, [])
  let address = try #require(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(
    to: UInt8.self)
  for y in 0..<height {
    for x in 0..<width {
      let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
      address[offset] = x < width / 2 ? 0 : 255
      address[offset + 1] = 0
      address[offset + 2] = x < width / 2 ? 255 : 0
      address[offset + 3] = 255
    }
  }
  CVPixelBufferUnlockBaseAddress(pixels, [])
  let deadline = ContinuousClock.now.advanced(by: .seconds(10))
  for index in 0..<90 {
    while !input.isReadyForMoreMediaData {
      try #require(ContinuousClock.now < deadline)
      try await Task.sleep(for: .milliseconds(1))
    }
    try #require(
      adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
  }
  input.markAsFinished()
  await writer.finishWriting()
  try #require(writer.status == .completed)
}

@Test func standaloneSpecsUseFinalV2EvidenceAndExcludeUnclassifiedCandidates() throws {
  let observations: [MatchTimerObservation] = [
    .init(recordingTimelineMilliseconds: 100_000, output: "10:00"),
    .init(recordingTimelineMilliseconds: 110_000, output: "09:50"),
    .init(recordingTimelineMilliseconds: 800_000, output: "05:00"),
    .init(recordingTimelineMilliseconds: 810_000, output: "04:50"),
  ]
  let v1 = MatchTimerDetection(records: observations, recordingDuration: 1200)
  let evidence = try JSONDecoder().decode(
    MatchEndEvidenceDocument.self,
    from: Data(
      #"{"$schema":"https://kaito-tokyo.github.io/unite-analysis-swift/match-end-evidence-v1.schema.json","evidence":[{"evidenceId":"surrender","recordingPTS":430,"kind":"surrender","medium":"visual","mode":"standard10Minute","source":"frame-430.jpg"}]}"#
        .utf8))
  let v2 = MatchIntervalDetectionV2(
    timerDiagnostics: v1.diagnostics, endEvidence: evidence, recordingDuration: 1200)
  let game = GameScreenRectangle(x: 0, y: 0, width: 1920, height: 1080)
  let v1Specs = v1.matches.map { StandaloneMatchSpec($0, gameScreen: game) }
  let v2Specs = v2.matches.map { StandaloneMatchSpec($0, gameScreen: game) }
  #expect(v1Specs.count == 1 && v1Specs[0].duration == 600)
  #expect(v2Specs.count == 1 && v2Specs[0].duration == 330)
  #expect(v2Specs[0].startPTS.value == 60_000_000)
  #expect(v2.unclassifiedCandidates.count == 1)
}

@Test func rotatedStandaloneConsumersUseDisplayCoordinates() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  let video = root.appendingPathComponent("rotated.mp4")
  try await writeStandaloneFixtureVideo(
    to: video, width: 32, height: 16, transform: .init(a: 0, b: 1, c: -1, d: 0, tx: 16, ty: 0))
  let source = MatchVideoInput.standaloneMP4(video)
  let spec = root.appendingPathComponent("record-spec.json")
  let rectangle = GameScreenRectangle(x: 0, y: 0, width: 16, height: 32)
  try prettyPrintedJSONData(
    StandaloneMatchSpec(matchId: "match-01", start: 0, duration: 1, gameScreen: rectangle)
  ).write(to: spec)
  let media = try await RecordingMediaContext.prepare(recordSpecURL: spec, source: source)
  let fullFrame = root.appendingPathComponent("full.jpg")
  _ = try await renderFrames(
    context: media,
    requests: [
      .init(
        scene: .matchRelative(0), source: .init(x: 0, y: 0, width: 16, height: 32),
        outputURL: fullFrame)
    ], quality: 1, force: false)
  let imageSource = try #require(CGImageSourceCreateWithURL(fullFrame as CFURL, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
  #expect(image.width == 16 && image.height == 32)
  let crop = FrameSource(x: 0, y: 0, width: 16, height: 16)
  let precise = root.appendingPathComponent("precise.jpg")
  _ = try await renderPreciseFrame(
    recordSpecURL: spec, videoInput: source, scene: .matchRelative(0), source: crop,
    outputURL: precise, quality: 1, force: false)
  let batch = root.appendingPathComponent("batch.jpg")
  _ = try await renderFrames(
    context: media, requests: [.init(scene: .matchRelative(0), source: crop, outputURL: batch)],
    quality: 1, force: false)
  _ = try await renderSampleFrames(
    recordSpecURL: spec, videoInput: source,
    request: .init(
      source: crop, fps: 1, scaleX: 16, scaleY: 16,
      outputPattern: root.appendingPathComponent("sample-%06d.jpg").path), quality: 1, force: false)
  let prepared = try await ContactSheetGenerator.prepare(recordSpecURL: spec, source: source)
  let definition = Data(
    #"{"cell":{"width":16,"height":16},"columns":1,"placements":[{"source":{"x":0,"y":0,"width":16,"height":16},"destination":{"x":0,"y":0,"width":16,"height":16}}],"matchTimestamps":[0]}"#
      .utf8)
  let sheet = root.appendingPathComponent("sheet.jpg")
  try await ContactSheetGenerator.run(
    definitionData: definition, prepared: prepared, outputURL: sheet, quality: 1, force: false)
  let expected = try meanRGB(precise)
  #expect(expected[0] > 200 && expected[2] < 30)
  for url in [batch, sheet, root.appendingPathComponent("sample-000001.jpg")] {
    let actual = try meanRGB(url)
    #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 20 })
  }
  let extractor = try await LDTXRecordingSupport.VideoFrameExtractor(
    videoURL: video, displayOrientedFrames: true)
  var frames = 0
  try extractor.extractConsecutiveFrames(startingAt: .zero, count: 60) { _, image, _ in
    #expect(image.width == 16 && image.height == 32)
    if frames == 0 {
      let first = root.appendingPathComponent("consecutive.jpg")
      try VideoFrameSupport.writeBaselineJPEG(
        VideoFrameSupport.cropped(image, rect: crop.rect), to: first, quality: 1, force: false)
      let actual = try meanRGB(first)
      #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 20 })
    }
    frames += 1
  }
  #expect(frames == 60)
  let command = try EvaluateDrawText.parse([
    "VIDEO.width + 'x' + VIDEO.height", "--standalone-mp4", "--input", video.path, "--record-spec",
    spec.path, "--inmatch", "0",
  ])
  for try await record in command.outputRecords() { #expect(record.text == "16x32") }
  let text = try await DrawTextScriptEngine.evaluate(
    script: "VIDEO.width + 'x' + VIDEO.height", recordSpecURL: spec, index: 0, inmatch: 0,
    beforeStart: nil, afterEnd: nil, source: source)
  #expect(text == "16x32")
}

private func meanRGB(_ url: URL) throws -> [Double] {
  let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
  let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
  var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
  return try pixels.withUnsafeMutableBytes { bytes in
    let context = try #require(
      CGContext(
        data: bytes.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
        bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (0..<3).map { channel in
      stride(from: channel, to: bytes.count, by: 4).reduce(0.0) { $0 + Double(bytes[$1]) }
        / Double(image.width * image.height)
    }
  }
}
