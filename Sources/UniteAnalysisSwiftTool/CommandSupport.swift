// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import ArgumentParser
import CoreGraphics
import CoreMedia
import Foundation
import LDTXRecordingSupport
import RecordVisionSupport
import ResultScannerSupport
import UniteAnalysisConfiguration

enum UniteAnalysisSwiftToolError: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let value):
      return value
    }
  }
}

func commandOutputStream<Output>(
  _ operation:
    @escaping @Sendable (
      AsyncThrowingStream<Output, Error>.Continuation
    ) async throws -> Void
) -> AsyncThrowingStream<Output, Error> {
  let (stream, continuation) = AsyncThrowingStream<Output, Error>.makeStream()
  let task = Task {
    do {
      try Task.checkCancellation()
      try await operation(continuation)
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
  continuation.onTermination = { _ in task.cancel() }
  return stream
}

package typealias RecordSpec = RecordVisionRecordSpec

enum Scene {
  case matchRelative(Double)
  case inmatch(Double)
  case beforeStart(Double)
  case afterEnd(Double)
}

struct AnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

func rejectUnknownKeys(
  from decoder: Decoder, allowedKeys: Set<String>, context: String
) throws {
  let container = try decoder.container(keyedBy: AnyCodingKey.self)
  let unknownKeys = Set(container.allKeys.map(\.stringValue)).subtracting(allowedKeys)
  guard unknownKeys.isEmpty else {
    throw DecodingError.dataCorrupted(
      .init(
        codingPath: decoder.codingPath,
        debugDescription: "Unknown \(context) keys: \(unknownKeys.sorted().joined(separator: ", "))"
      ))
  }
}

struct FrameSource: Codable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case x, y, width, height
  }

  init(x: Int, y: Int, width: Int, height: Int) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  init(from decoder: Decoder) throws {
    try rejectUnknownKeys(
      from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)), context: "source")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    x = try container.decode(Int.self, forKey: .x)
    y = try container.decode(Int.self, forKey: .y)
    width = try container.decode(Int.self, forKey: .width)
    height = try container.decode(Int.self, forKey: .height)
  }

  var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

  func validate() throws {
    guard x >= 0, y >= 0, width > 0, height > 0 else {
      throw UniteAnalysisSwiftToolError.message(
        "source must be a positive top-left-origin rectangle")
    }
  }
}

struct FrameRequest {
  let scene: Scene
  let source: FrameSource
  let outputURL: URL
}

struct BatchFrameJob: Decodable {
  let jobId: String
  let matchTimestamps: [Double]
  let source: FrameSource
  let outputPrefix: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case jobId, matchTimestamps, source, outputPrefix, frames, frame, output, inmatch, beforeStart,
      afterEnd
  }

  init(from decoder: Decoder) throws {
    try rejectUnknownKeys(
      from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)), context: "batch-frame")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.frames) || container.contains(.frame) || container.contains(.output)
      || container.contains(.inmatch)
      || container.contains(.beforeStart)
      || container.contains(.afterEnd)
    {
      throw DecodingError.dataCorruptedError(
        forKey: .matchTimestamps,
        in: container,
        debugDescription:
          "Legacy frame fields are no longer supported; use matchTimestamps and outputPrefix")
    }
    jobId = try container.decode(String.self, forKey: .jobId)
    matchTimestamps = try container.decode([Double].self, forKey: .matchTimestamps)
    source = try container.decode(FrameSource.self, forKey: .source)
    outputPrefix = try container.decode(String.self, forKey: .outputPrefix)
  }

  func validatedMatchTimestamps() throws -> [Double] {
    guard !jobId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw UniteAnalysisSwiftToolError.message("Each batch-frame job requires a non-empty jobId")
    }
    guard !matchTimestamps.isEmpty else {
      throw UniteAnalysisSwiftToolError.message(
        "Each batch-frame job requires at least one matchTimestamp")
    }
    guard !outputPrefix.isEmpty else {
      throw UniteAnalysisSwiftToolError.message(
        "Each batch-frame job requires a non-empty outputPrefix")
    }
    guard matchTimestamps.allSatisfy(\.isFinite) else {
      throw UniteAnalysisSwiftToolError.message(
        "Each batch-frame matchTimestamp must be a finite match-relative value")
    }
    for index in matchTimestamps.indices.dropFirst()
    where matchTimestamps[index] <= matchTimestamps[index - 1] {
      throw UniteAnalysisSwiftToolError.message(
        "Each batch-frame matchTimestamps array must be strictly increasing")
    }
    return matchTimestamps
  }
}

struct JSONLInputLine {
  let number: Int
  let data: Data
}

struct JSONLJobFailure {
  let line: Int
  let jobId: String?
  let error: Error
}

func forEachJSONLInputLine(
  _ input: String,
  body: (JSONLInputLine) async throws -> Void
) async throws -> Int {
  var processedCount = 0
  func process(_ value: String, lineNumber: Int) async throws {
    try Task.checkCancellation()
    guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    processedCount += 1
    try await body(JSONLInputLine(number: lineNumber, data: Data(value.utf8)))
  }
  if input == "-" {
    var lineNumber = 0
    while let line = readLine(strippingNewline: true) {
      lineNumber += 1
      try await process(line, lineNumber: lineNumber)
    }
  } else {
    let contents = try String(contentsOf: resolvePath(input), encoding: .utf8)
    for (index, line) in contents.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
    {
      try await process(String(line), lineNumber: index + 1)
    }
  }
  return processedCount
}

func jsonlJobID(in data: Data) -> String? {
  guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
    return nil
  }
  return object["jobId"] as? String
}

struct JSONLJobError: Encodable {
  struct Detail: Encodable {
    let line: Int
    let message: String
  }

  let schema: String
  let jobId: String?
  let ok = false
  let error: Detail

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case jobId, ok, error
  }
}

final class JSONLResponseWriter {
  private let outputURL: URL?
  private let temporaryURL: URL?
  private let force: Bool
  private var outputHandle: FileHandle?
  private var finished = false
  private let encoder: JSONEncoder

  init(output: String? = nil, force: Bool = false) throws {
    outputURL = output.map(resolvePath)
    self.force = force
    try validateOutputPath(outputURL, force: force)
    temporaryURL = outputURL.map { outputURL in
      outputURL.deletingLastPathComponent().appendingPathComponent(
        ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
    }
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    if let temporaryURL {
      guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil) else {
        throw UniteAnalysisSwiftToolError.message(
          "Could not create temporary JSONL output: \(temporaryURL.path)")
      }
      outputHandle = try FileHandle(forWritingTo: temporaryURL)
    }
  }

  deinit {
    try? outputHandle?.close()
    if !finished, let temporaryURL {
      try? FileManager.default.removeItem(at: temporaryURL)
    }
  }

  func write<T: Encodable>(_ value: T) throws {
    var line = try encoder.encode(value)
    line.append(0x0A)
    if let outputHandle {
      try outputHandle.write(contentsOf: line)
    } else {
      try FileHandle.standardOutput.write(contentsOf: line)
    }
  }

  func finish() throws {
    guard let outputURL, let temporaryURL else { return }
    try outputHandle?.close()
    outputHandle = nil
    try installTemporaryOutput(temporaryURL, at: outputURL, force: force)
    finished = true
  }
}

func validateOutputPath(_ outputURL: URL?, force: Bool) throws {
  guard let outputURL else { return }
  guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
    throw UniteAnalysisSwiftToolError.message(
      "Output already exists: \(outputURL.path). Pass --force to overwrite.")
  }
}

func writeOutputData(_ data: Data, to outputURL: URL, force: Bool) throws {
  try validateOutputPath(outputURL, force: force)
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
    ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp")
  defer { try? FileManager.default.removeItem(at: temporaryURL) }
  try data.write(to: temporaryURL)
  try installTemporaryOutput(temporaryURL, at: outputURL, force: force)
}

private func installTemporaryOutput(_ temporaryURL: URL, at outputURL: URL, force: Bool) throws {
  if force {
    if FileManager.default.fileExists(atPath: outputURL.path) {
      _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
    }
    return
  }
  do {
    try FileManager.default.linkItem(at: temporaryURL, to: outputURL)
    try FileManager.default.removeItem(at: temporaryURL)
  } catch {
    if FileManager.default.fileExists(atPath: outputURL.path) {
      throw UniteAnalysisSwiftToolError.message(
        "Output already exists: \(outputURL.path). Pass --force to overwrite.")
    }
    throw error
  }
}

func writeJSONLFailure(
  _ error: Error,
  line: JSONLInputLine,
  jobId: String?,
  schema: String,
  to writer: JSONLResponseWriter
) throws {
  let rawMessage = String(describing: error)
  let message =
    rawMessage.hasPrefix("Error Domain=") ? (error as NSError).localizedDescription : rawMessage
  let response = JSONLJobError(
    schema: schema,
    jobId: jobId,
    error: .init(line: line.number, message: message))
  try writer.write(response)
}

func writeJSONLFailure(
  _ failure: JSONLJobFailure,
  schema: String,
  to writer: JSONLResponseWriter
) throws {
  let line = JSONLInputLine(number: failure.line, data: Data())
  try writeJSONLFailure(
    failure.error, line: line, jobId: failure.jobId, schema: schema, to: writer)
}

struct SampleFramesRequest {
  let source: FrameSource
  let fps: Double
  let scaleX: Int
  let scaleY: Int
  let outputPattern: String

  func validate() throws {
    try source.validate()
    guard fps.isFinite, fps > 0 else {
      throw UniteAnalysisSwiftToolError.message("sample-frames fps must be positive and finite")
    }
    guard scaleX > 0, scaleY > 0 else {
      throw UniteAnalysisSwiftToolError.message(
        "sample-frames scale-x and scale-y must be positive")
    }
    let patternParts = outputPattern.components(separatedBy: "%06d")
    guard patternParts.count == 2, !patternParts.joined().contains("%") else {
      throw UniteAnalysisSwiftToolError.message(
        "sample-frames output must contain exactly one %06d placeholder and no other % characters")
    }
  }
}

func cwdURL() -> URL {
  URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

func resolvePath(_ path: String) -> URL {
  if path.hasPrefix("/") { return URL(fileURLWithPath: path).standardizedFileURL }
  return cwdURL().appendingPathComponent(path).standardizedFileURL
}

func resolveRecordSpec(_ path: String) -> URL {
  resolvePath(path)
}

func loadOCROptions(_ path: String) throws -> [String: OCRRecognitionOptions] {
  let document = try JSONDecoder().decode(
    OCRRecognitionOptionsDocument.self, from: Data(contentsOf: resolvePath(path))
  )
  guard document.schema == OCRRecognitionOptionsDocument.schemaURL else {
    throw UniteAnalysisSwiftToolError.message(
      "ocr-options $schema must be '\(OCRRecognitionOptionsDocument.schemaURL)'")
  }
  return document.regions
}

func requiredOCROptions(
  named name: String, in options: [String: OCRRecognitionOptions]
) throws -> OCRRecognitionOptions {
  guard let value = options[name] else {
    throw UniteAnalysisSwiftToolError.message("ocr-options has no required region '\(name)'")
  }
  guard !value.recognitionLanguages.isEmpty,
    value.recognitionLanguages.allSatisfy({
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
  else {
    throw UniteAnalysisSwiftToolError.message(
      "ocr-options region '\(name)' recognitionLanguages must contain non-empty strings")
  }
  guard
    (value.customWords ?? []).allSatisfy({
      !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    })
  else {
    throw UniteAnalysisSwiftToolError.message(
      "ocr-options region '\(name)' customWords must contain only non-empty strings")
  }
  return value
}

extension String {
  func reflowedHelp() -> String {
    return components(separatedBy: "\n\n")
      .map { paragraph in
        let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
          return trimmed
        }
        return paragraph.split(whereSeparator: \.isWhitespace).joined(separator: " ")
      }
      .joined(separator: "\n\n")
  }
}

func recordingBundle(above recordSpecURL: URL) throws -> URL {
  var candidate = recordSpecURL.deletingLastPathComponent()
  while candidate.path != "/" {
    if candidate.pathExtension == "ldtxrecord" { return candidate }
    candidate.deleteLastPathComponent()
  }
  throw UniteAnalysisSwiftToolError.message(
    "record-spec.json must be inside a .ldtxrecord bundle: \(recordSpecURL.path)")
}

func canonicalSeconds(_ value: Double) -> String {
  String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
}

func renderFrames(
  recordSpecURL: URL,
  requests frameRequests: [FrameRequest],
  quality: Double,
  force: Bool
) async throws -> [String] {
  guard !frameRequests.isEmpty else {
    throw UniteAnalysisSwiftToolError.message("At least one frame request is required")
  }
  let spec = try JSONDecoder().decode(RecordSpec.self, from: Data(contentsOf: recordSpecURL))
  RecordVisionInputLogger.recordSpec(recordSpecURL)
  guard spec.startPTS.timescale > 0 else {
    throw UniteAnalysisSwiftToolError.message("startPTS.timescale must be positive")
  }
  let start = CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale)
  let bundleURL = try recordingBundle(above: recordSpecURL)
  if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path) {
    RecordVisionInputLogger.unfinishedRecording(bundleURL)
  }
  let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
  RecordVisionInputLogger.sourceVideo(recording.videoURL)
  let extractor = try await VideoFrameExtractor(videoURL: recording.videoURL)
  let videoDurationSeconds = CMTimeGetSeconds(extractor.duration)
  guard videoDurationSeconds.isFinite, videoDurationSeconds > 0 else {
    throw UniteAnalysisSwiftToolError.message(
      "Could not determine a positive source-video duration: \(recording.videoURL.path)")
  }
  var requests: [(time: CMTime, source: FrameSource, url: URL)] = []
  for frameRequest in frameRequests {
    try frameRequest.source.validate()
    let scene = frameRequest.scene
    let offset: Double
    switch scene {
    case .matchRelative(let seconds):
      guard seconds.isFinite else {
        throw UniteAnalysisSwiftToolError.message("frame seconds must be finite")
      }
      offset = seconds
    case .inmatch(let seconds):
      guard seconds.isFinite, seconds >= 0 else {
        throw UniteAnalysisSwiftToolError.message(
          "inmatch seconds must be a finite value greater than or equal to zero")
      }
      offset = seconds
    case .beforeStart(let seconds):
      guard seconds.isFinite, seconds >= 0 else {
        throw UniteAnalysisSwiftToolError.message(
          "before-start seconds must be a finite value greater than or equal to zero")
      }
      offset = -seconds
    case .afterEnd(let seconds):
      guard seconds.isFinite, seconds >= 0 else {
        throw UniteAnalysisSwiftToolError.message(
          "after-end seconds must be a finite value greater than or equal to zero")
      }
      offset = spec.duration + seconds
    }
    let requestedTime = CMTimeAdd(
      start, CMTime(seconds: offset, preferredTimescale: spec.startPTS.timescale))
    let requestedSeconds = CMTimeGetSeconds(requestedTime)
    guard requestedSeconds.isFinite, requestedSeconds >= 0, requestedSeconds < videoDurationSeconds
    else {
      throw UniteAnalysisSwiftToolError.message(
        "Requested frame time \(canonicalSeconds(requestedSeconds))s is outside source-video range [0.000, \(canonicalSeconds(videoDurationSeconds)))s: \(frameRequest.outputURL.path)"
      )
    }
    try FileManager.default.createDirectory(
      at: frameRequest.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    requests.append((requestedTime, frameRequest.source, frameRequest.outputURL))
  }
  var seenPaths = Set<String>()
  for request in requests {
    guard
      force
        || (seenPaths.insert(request.url.path).inserted
          && !FileManager.default.fileExists(atPath: request.url.path))
    else {
      throw UniteAnalysisSwiftToolError.message(
        "Output collision: \(request.url.path). Pass --force to overwrite.")
    }
  }
  let orderedRequests = requests.sorted { CMTimeCompare($0.time, $1.time) < 0 }
  try await extractor.extractApproximateFrames(at: orderedRequests.map(\.time)) {
    index, frame, actualTime in
    let request = orderedRequests[index]
    let image = try VideoFrameSupport.cropped(frame, rect: request.source.rect)
    let outputURL = request.url
    try VideoFrameSupport.writeBaselineJPEG(image, to: outputURL, quality: quality)
    FileHandle.standardError.write(
      Data(
        "unite-analysis-swift: batch frame requested PTS \(canonicalSeconds(request.time.seconds))s, actual PTS \(canonicalSeconds(actualTime.seconds))s\n"
          .utf8
      ))
  }
  return frameRequests.map(\.outputURL.path)
}

func renderSampleFrames(
  recordSpecURL: URL,
  request: SampleFramesRequest,
  quality: Double,
  force: Bool
) async throws -> [String] {
  let spec = try JSONDecoder().decode(RecordSpec.self, from: Data(contentsOf: recordSpecURL))
  RecordVisionInputLogger.recordSpec(recordSpecURL)
  guard spec.startPTS.timescale > 0, spec.duration.isFinite, spec.duration > 0 else {
    throw UniteAnalysisSwiftToolError.message(
      "record-spec.json must have a positive startPTS timescale and duration")
  }
  let bundleURL = try recordingBundle(above: recordSpecURL)
  if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path) {
    RecordVisionInputLogger.unfinishedRecording(bundleURL)
  }
  let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
  RecordVisionInputLogger.sourceVideo(recording.videoURL)
  let extractor = try await VideoFrameExtractor(videoURL: recording.videoURL)
  let start = CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale)

  struct OutputRequest {
    let outputURL: URL
    let requestedInmatch: Double
  }
  try request.validate()
  let offsets = try SampleFrameSequence.sampleOffsets(duration: spec.duration, fps: request.fps)
  let absolutePattern = resolvePath(request.outputPattern).path
  var requestsByTime: [CMTime: OutputRequest] = [:]
  for (index, offset) in offsets.enumerated() {
    let frameNumber = String(format: "%06d", index + 1)
    let outputURL = URL(
      fileURLWithPath: absolutePattern.replacingOccurrences(of: "%06d", with: frameNumber)
    ).standardizedFileURL
    guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
      throw UniteAnalysisSwiftToolError.message(
        "Output collision: \(outputURL.path). Pass --force to overwrite.")
    }
    let time = CMTimeAdd(start, CMTime(seconds: offset, preferredTimescale: 60_000))
    requestsByTime[time] = OutputRequest(outputURL: outputURL, requestedInmatch: offset)
  }
  let times = requestsByTime.keys.sorted { CMTimeCompare($0, $1) < 0 }
  var outputs: [String] = []
  try await extractor.extractApproximateFrames(at: times) { index, frame, actualTime in
    try Task.checkCancellation()
    let time = times[index]
    guard let outputRequest = requestsByTime[time] else { return }
    let cropped = try VideoFrameSupport.cropped(frame, rect: request.source.rect)
    let resized = try VideoFrameSupport.resized(
      cropped, width: request.scaleX, height: request.scaleY)
    try FileManager.default.createDirectory(
      at: outputRequest.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try VideoFrameSupport.writeBaselineJPEG(resized, to: outputRequest.outputURL, quality: quality)
    FileHandle.standardError.write(
      Data(
        "unite-analysis-swift: sample frame requested match time \(canonicalSeconds(outputRequest.requestedInmatch))s, actual PTS \(canonicalSeconds(actualTime.seconds))s\n"
          .utf8))
    outputs.append(outputRequest.outputURL.path)
  }
  return outputs
}

func renderPreciseFrame(
  recordSpecURL: URL,
  scene: Scene,
  source: FrameSource,
  outputURL: URL,
  quality: Double,
  force: Bool
) async throws -> String {
  guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
    throw UniteAnalysisSwiftToolError.message(
      "Output collision: \(outputURL.path). Pass --force to overwrite.")
  }
  let spec = try JSONDecoder().decode(RecordSpec.self, from: Data(contentsOf: recordSpecURL))
  RecordVisionInputLogger.recordSpec(recordSpecURL)
  guard spec.startPTS.timescale > 0 else {
    throw UniteAnalysisSwiftToolError.message("record-spec.json has no usable startPTS")
  }
  try source.validate()
  let offset: Double
  switch scene {
  case .matchRelative(let value): offset = value
  case .inmatch(let value): offset = value
  case .beforeStart(let value): offset = -value
  case .afterEnd(let value): offset = spec.duration + value
  }
  let requestedTime = CMTimeAdd(
    CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale),
    CMTime(seconds: offset, preferredTimescale: spec.startPTS.timescale))
  let bundleURL = try recordingBundle(above: recordSpecURL)
  if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path) {
    RecordVisionInputLogger.unfinishedRecording(bundleURL)
  }
  let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
  RecordVisionInputLogger.sourceVideo(recording.videoURL)
  let extractor = try await VideoFrameExtractor(videoURL: recording.videoURL)
  guard CMTimeCompare(requestedTime, .zero) >= 0,
    CMTimeCompare(requestedTime, extractor.duration) < 0
  else {
    throw UniteAnalysisSwiftToolError.message(
      "Requested precise frame is outside the source-video range: \(canonicalSeconds(requestedTime.seconds))s"
    )
  }
  let frame = try extractor.extractPreciseFrame(at: requestedTime)
  let image = try VideoFrameSupport.cropped(frame.image, rect: source.rect)
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try VideoFrameSupport.writeBaselineJPEG(image, to: outputURL, quality: quality)
  FileHandle.standardError.write(
    Data(
      "unite-analysis-swift: precise frame requested PTS \(canonicalSeconds(requestedTime.seconds))s, decoded PTS \(canonicalSeconds(frame.presentationTime.seconds))s\n"
        .utf8))
  return outputURL.path
}
