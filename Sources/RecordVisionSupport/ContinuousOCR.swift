// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
import LDTXRecordingSupport
import UniformTypeIdentifiers
import Vision

public enum ContinuousOCRError: Error, CustomStringConvertible {
  case message(String)

  public var description: String {
    switch self {
    case .message(let value): value
    }
  }
}

public struct ContinuousOCRDefinition: Codable, Sendable {
  public struct Rectangle: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
  }

  public let source: Rectangle
  public let recognitionLanguages: [String]
  public let customWords: [String]?
  public let output: String?
  public let observationsOutput: String?
  public let chromaEvents: String?
  public let minimumScore: Int?

  private enum CodingKeys: String, CodingKey {
    case source, recognitionLanguages, customWords, output, observationsOutput, chromaEvents,
      minimumScore
  }
}

public struct ContinuousOCRObservation: Codable, Equatable, Sendable {
  public struct Rectangle: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
  }

  public let text: String
  public let confidence: Float
  public let boundingBox: Rectangle
}

public struct ContinuousOCRSample: Codable, Equatable, Sendable {
  public let requestedInmatch: Double
  public let actualInmatch: Double
  public let observations: [ContinuousOCRObservation]
}

public struct ContinuousOCRInterval: Codable, Equatable, Sendable {
  public let inmatchStart: Double
  public let inmatchEnd: Double
  public let representativeText: String
  public let confidence: Float
  public let sampleCount: Int
  public let boundingBox: ContinuousOCRObservation.Rectangle
}

public struct ContinuousOCRResult: Codable, Equatable, Sendable {
  public let globalId: String
  public let samplesPerSecond: Double
  public let source: ContinuousOCRDefinition.Rectangle
  public let scannedSampleCount: Int
  public let samples: [ContinuousOCRSample]
  public let intervals: [ContinuousOCRInterval]
}

public enum ContinuousOCR {
  public static let samplesPerSecond = 2.0
  static let sampleDuration = 1.0 / samplesPerSecond
  static let sourcePadding = 0
  static let recognitionScale = 1
  static let recognitionTolerance = 0.2
  static let acceptedObservationCenterX = 0.45...0.55
  static let recognitionBatchSize = 12
  static let recognitionBatchSeparatorPixels = 8

  private struct RecognitionBatchItem {
    let index: Int
    let actualTime: CMTime
    let image: CGImage
  }

  private final class RecognitionBatchCanvas {
    let cellWidth: Int
    let cellHeight: Int
    let totalHeight: Int
    let cellRects: [CGRect]
    let context: CGContext

    init(referenceImage: CGImage) throws {
      let calculatedCellWidth = referenceImage.width * ContinuousOCR.recognitionScale
      let calculatedCellHeight = referenceImage.height * ContinuousOCR.recognitionScale
      let calculatedTotalHeight =
        calculatedCellHeight * ContinuousOCR.recognitionBatchSize
        + ContinuousOCR.recognitionBatchSeparatorPixels * (ContinuousOCR.recognitionBatchSize - 1)
      let calculatedCellRects = (0..<ContinuousOCR.recognitionBatchSize).map { slot in
        CGRect(
          x: 0,
          y: slot * (calculatedCellHeight + ContinuousOCR.recognitionBatchSeparatorPixels),
          width: calculatedCellWidth,
          height: calculatedCellHeight
        )
      }
      guard
        let context = CGContext(
          data: nil,
          width: calculatedCellWidth,
          height: calculatedTotalHeight,
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
      else { throw ContinuousOCRError.message("Could not allocate the batched OCR image") }
      cellWidth = calculatedCellWidth
      cellHeight = calculatedCellHeight
      totalHeight = calculatedTotalHeight
      cellRects = calculatedCellRects
      self.context = context
      context.interpolationQuality = .high
    }

    func render(_ batch: [RecognitionBatchItem]) throws -> CGImage {
      guard
        batch.allSatisfy({
          $0.image.width * recognitionScale == cellWidth
            && $0.image.height * recognitionScale == cellHeight
        })
      else {
        throw ContinuousOCRError.message("OCR batch images must have identical dimensions")
      }
      context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: cellWidth, height: totalHeight))
      for slot in 0..<recognitionBatchSize {
        let rect = cellRects[slot]
        if slot < batch.count {
          context.draw(batch[slot].image, in: rect)
        }
        if slot < recognitionBatchSize - 1 {
          context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
          context.fill(
            CGRect(
              x: 0,
              y: Int(rect.maxY),
              width: cellWidth,
              height: recognitionBatchSeparatorPixels
            ))
        }
      }
      guard let image = context.makeImage() else {
        throw ContinuousOCRError.message("Could not finalize the batched OCR image")
      }
      return image
    }
  }

  public static func run(
    definitionData: Data,
    recordSpecURL: URL,
    outputURL: URL,
    observationsOutputURL: URL? = nil,
    inmatchTimes: [Double]? = nil,
    force: Bool
  ) async throws {
    guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
      throw ContinuousOCRError.message(
        "Output already exists: \(outputURL.path). Pass --force to overwrite.")
    }
    if let observationsOutputURL,
      !force && FileManager.default.fileExists(atPath: observationsOutputURL.path)
    {
      throw ContinuousOCRError.message(
        "Observation output already exists: \(observationsOutputURL.path). Pass --force to overwrite."
      )
    }
    let definition = try JSONDecoder().decode(ContinuousOCRDefinition.self, from: definitionData)
    guard definition.source.x >= 0, definition.source.y >= 0,
      definition.source.width > 0, definition.source.height > 0
    else { throw ContinuousOCRError.message("source must be a positive top-left-origin rectangle") }
    guard !definition.recognitionLanguages.isEmpty,
      definition.recognitionLanguages.allSatisfy({ !$0.isEmpty })
    else {
      throw ContinuousOCRError.message(
        "recognitionLanguages must contain at least one non-empty language identifier")
    }
    guard (definition.customWords ?? []).allSatisfy({ !$0.isEmpty }) else {
      throw ContinuousOCRError.message("customWords must not contain an empty string")
    }

    let spec = try JSONDecoder().decode(
      RecordVisionRecordSpec.self, from: Data(contentsOf: recordSpecURL))
    RecordVisionInputLogger.recordSpec(recordSpecURL)
    guard spec.startPTS.timescale > 0 else {
      throw ContinuousOCRError.message("startPTS.timescale must be positive")
    }
    guard spec.duration.isFinite, spec.duration > 0 else {
      throw ContinuousOCRError.message("record-spec duration must be positive and finite")
    }

    let bundleURL = try recordingBundle(above: recordSpecURL)
    if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path)
    {
      RecordVisionInputLogger.unfinishedRecording(bundleURL)
    }
    let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
    RecordVisionInputLogger.sourceVideo(recording.videoURL)
    let asset = AVURLAsset(url: recording.videoURL)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw ContinuousOCRError.message("No video track: \(recording.videoURL.path)")
    }
    let size = try await track.load(.naturalSize)
    guard definition.source.x + definition.source.width <= Int(size.width),
      definition.source.y + definition.source.height <= Int(size.height)
    else {
      throw ContinuousOCRError.message(
        "source exceeds encoded video dimensions \(Int(size.width))x\(Int(size.height))")
    }

    let requestedOffsets = try requestedInmatchTimes(inmatchTimes, duration: spec.duration)
    let start = CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale)
    let sourceTimes = requestedOffsets.map {
      CMTimeAdd(start, CMTime(seconds: $0, preferredTimescale: spec.startPTS.timescale))
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.apertureMode = .encodedPixels
    generator.appliesPreferredTrackTransform = false
    generator.requestedTimeToleranceBefore = CMTime(
      seconds: recognitionTolerance, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(
      seconds: recognitionTolerance, preferredTimescale: 600)
    let languages = definition.recognitionLanguages
    let customWords = definition.customWords ?? []
    let recognitionRequest = makeRecognitionRequest(languages: languages, customWords: customWords)
    var nonemptySamples: [ContinuousOCRSample] = []
    var renderedIndices = Set<Int>()
    var recognizedActualTimes: [CMTime] = []
    var recognitionBatch: [RecognitionBatchItem] = []
    var recognitionCanvas: RecognitionBatchCanvas?
    var maximumTimeError = 0.0

    func appendRecognizedBatch(_ batch: [RecognitionBatchItem]) throws {
      if recognitionCanvas == nil {
        recognitionCanvas = try RecognitionBatchCanvas(referenceImage: batch[0].image)
      }
      guard let recognitionCanvas else { return }
      for (item, observations) in try recognize(
        batch: batch, request: recognitionRequest, canvas: recognitionCanvas)
      where !observations.isEmpty {
        nonemptySamples.append(
          ContinuousOCRSample(
            requestedInmatch: requestedOffsets[item.index],
            actualInmatch: CMTimeSubtract(item.actualTime, start).seconds,
            observations: observations
          ))
      }
    }

    for await result in generator.images(for: sourceTimes) {
      let requestedTime: CMTime
      let image: CGImage
      let actualTime: CMTime
      switch result {
      case .success(let valueRequestedTime, let valueImage, let valueActualTime):
        requestedTime = valueRequestedTime
        image = valueImage
        actualTime = valueActualTime
      case .failure(let valueRequestedTime, let error):
        throw ContinuousOCRError.message(
          "Source-video image generation failed at \(valueRequestedTime.seconds)s: \(error.localizedDescription)"
        )
      }
      guard let index = sourceTimes.firstIndex(where: { CMTimeCompare($0, requestedTime) == 0 }),
        renderedIndices.insert(index).inserted
      else {
        throw ContinuousOCRError.message(
          "Source-video image generation returned an unknown or duplicate requested time")
      }
      maximumTimeError = max(
        maximumTimeError, abs(CMTimeSubtract(actualTime, requestedTime).seconds))
      if recognizedActualTimes.contains(where: { CMTimeCompare($0, actualTime) == 0 }) {
        continue
      }
      recognizedActualTimes.append(actualTime)

      let recognitionCrop = try recognitionCrop(image, source: definition.source)
      recognitionBatch.append(
        RecognitionBatchItem(index: index, actualTime: actualTime, image: recognitionCrop))
      if recognitionBatch.count == recognitionBatchSize {
        try appendRecognizedBatch(recognitionBatch)
        recognitionBatch.removeAll(keepingCapacity: true)
      }
    }
    if !recognitionBatch.isEmpty {
      try appendRecognizedBatch(recognitionBatch)
    }
    guard renderedIndices.count == sourceTimes.count else {
      throw ContinuousOCRError.message(
        "Source-video image generation returned \(renderedIndices.count) of \(sourceTimes.count) requested frames"
      )
    }
    RecordVisionInputLogger.continuousOCRFrames(
      requested: sourceTimes.count,
      distinct: recognizedActualTimes.count,
      maximumError: maximumTimeError
    )

    nonemptySamples.sort { $0.requestedInmatch < $1.requestedInmatch }
    let result = ContinuousOCRResult(
      globalId: spec.globalId,
      samplesPerSecond: samplesPerSecond,
      source: definition.source,
      scannedSampleCount: requestedOffsets.count,
      samples: nonemptySamples,
      intervals: mergedIntervals(samples: nonemptySamples)
    )
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(renderText(result, matchDuration: spec.duration).utf8).write(
      to: outputURL, options: .atomic)
    if let observationsOutputURL {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(result).write(to: observationsOutputURL, options: .atomic)
    }
  }

  static func requestedInmatchTimes(_ explicitTimes: [Double]?, duration: Double) throws -> [Double]
  {
    guard let explicitTimes else { return sampleOffsets(duration: duration) }
    guard !explicitTimes.isEmpty else {
      throw ContinuousOCRError.message("event selection produced no OCR times")
    }
    guard explicitTimes.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= duration }) else {
      throw ContinuousOCRError.message(
        "explicit OCR times must be finite and inside the match range")
    }
    return Array(Set(explicitTimes)).sorted()
  }

  public static func writeInputFrames(
    definitionData: Data,
    recordSpecURL: URL,
    inmatchTimes: [Double],
    outputDirectory: URL,
    force: Bool
  ) async throws -> [URL] {
    let definition = try JSONDecoder().decode(ContinuousOCRDefinition.self, from: definitionData)
    let spec = try JSONDecoder().decode(
      RecordVisionRecordSpec.self, from: Data(contentsOf: recordSpecURL))
    guard spec.startPTS.timescale > 0 else {
      throw ContinuousOCRError.message("startPTS.timescale must be positive")
    }
    guard inmatchTimes.allSatisfy({ $0.isFinite && $0 >= 0 && $0 < spec.duration }) else {
      throw ContinuousOCRError.message("Every preview time must be inside the match interval")
    }
    RecordVisionInputLogger.recordSpec(recordSpecURL)
    let bundleURL = try recordingBundle(above: recordSpecURL)
    if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path)
    {
      RecordVisionInputLogger.unfinishedRecording(bundleURL)
    }
    let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
    RecordVisionInputLogger.sourceVideo(recording.videoURL)
    let asset = AVURLAsset(url: recording.videoURL)
    let start = CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale)
    let orderedTimes = inmatchTimes.sorted()
    let sourceTimes = orderedTimes.map {
      CMTimeAdd(start, CMTime(seconds: $0, preferredTimescale: spec.startPTS.timescale))
    }
    let outputs = orderedTimes.map {
      outputDirectory.appendingPathComponent("inmatch-\(canonical($0))s-ocr-input.png")
    }
    for output in outputs where !force && FileManager.default.fileExists(atPath: output.path) {
      throw ContinuousOCRError.message(
        "Output already exists: \(output.path). Pass --force to overwrite.")
    }
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.apertureMode = .encodedPixels
    generator.appliesPreferredTrackTransform = false
    generator.requestedTimeToleranceBefore = CMTime(
      seconds: recognitionTolerance, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(
      seconds: recognitionTolerance, preferredTimescale: 600)
    var rendered = Set<Int>()
    for await result in generator.images(for: sourceTimes) {
      switch result {
      case .success(let requestedTime, let image, _):
        guard let index = sourceTimes.firstIndex(where: { CMTimeCompare($0, requestedTime) == 0 }),
          rendered.insert(index).inserted
        else {
          throw ContinuousOCRError.message(
            "Preview generation returned an unknown or duplicate requested time")
        }
        try writePNG(try recognitionInput(image, source: definition.source), to: outputs[index])
      case .failure(let requestedTime, let error):
        throw ContinuousOCRError.message(
          "Preview generation failed at \(requestedTime.seconds)s: \(error.localizedDescription)")
      }
    }
    guard rendered.count == sourceTimes.count else {
      throw ContinuousOCRError.message(
        "Preview generation returned \(rendered.count) of \(sourceTimes.count) frames")
    }
    return outputs
  }

  static func sampleOffsets(duration: Double) -> [Double] {
    let count = Int(ceil(duration * samplesPerSecond))
    // Sample at the center of each 0.5s bin. Besides halving the worst-case temporal error,
    // this avoids requesting the exact fragmented-MP4 match boundary.
    return (0..<count).map { min((Double($0) + 0.5) * sampleDuration, duration.nextDown) }
  }

  static func expandedSourceRect(
    _ source: ContinuousOCRDefinition.Rectangle,
    videoWidth: Int,
    videoHeight: Int
  ) -> CGRect {
    let x = max(0, source.x - sourcePadding)
    let y = max(0, source.y - sourcePadding)
    let maximumX = min(videoWidth, source.x + source.width + sourcePadding)
    let maximumY = min(videoHeight, source.y + source.height + sourcePadding)
    return CGRect(x: x, y: y, width: maximumX - x, height: maximumY - y)
  }

  static func mergedIntervals(samples: [ContinuousOCRSample]) -> [ContinuousOCRInterval] {
    struct Builder {
      var start: Double
      var end: Double
      var lastTime: Double
      var lastNormalizedText: String
      var lastBox: ContinuousOCRObservation.Rectangle
      var candidates: [(String, Float, ContinuousOCRObservation.Rectangle)]
      var count: Int
    }
    var builders: [Builder] = []
    for sample in samples {
      var usedBuilders = Set<Int>()
      for observation in sample.observations {
        let text = normalized(observation.text)
        guard !text.isEmpty else { continue }
        let match = builders.indices
          .filter {
            !usedBuilders.contains($0)
              && sample.requestedInmatch - builders[$0].lastTime <= sampleDuration * 1.5
              && spatiallyNear(observation.boundingBox, builders[$0].lastBox)
              && similar(text, builders[$0].lastNormalizedText)
          }
          .min { lhs, rhs in
            centerDistance(observation.boundingBox, builders[lhs].lastBox)
              < centerDistance(observation.boundingBox, builders[rhs].lastBox)
          }
        if let match {
          builders[match].end = sample.requestedInmatch + sampleDuration
          builders[match].lastTime = sample.requestedInmatch
          builders[match].lastNormalizedText = text
          builders[match].lastBox = observation.boundingBox
          builders[match].candidates.append(
            (observation.text, observation.confidence, observation.boundingBox))
          builders[match].count += 1
          usedBuilders.insert(match)
        } else {
          builders.append(
            Builder(
              start: sample.requestedInmatch,
              end: sample.requestedInmatch + sampleDuration,
              lastTime: sample.requestedInmatch,
              lastNormalizedText: text,
              lastBox: observation.boundingBox,
              candidates: [(observation.text, observation.confidence, observation.boundingBox)],
              count: 1
            ))
          usedBuilders.insert(builders.count - 1)
        }
      }
    }
    return builders.map { builder in
      let representative =
        builder.candidates.max { lhs, rhs in
          lhs.1 == rhs.1 ? lhs.0.count < rhs.0.count : lhs.1 < rhs.1
        } ?? ("", 0, .init(x: 0, y: 0, width: 0, height: 0))
      return ContinuousOCRInterval(
        inmatchStart: builder.start,
        inmatchEnd: builder.end,
        representativeText: representative.0,
        confidence: representative.1,
        sampleCount: builder.count,
        boundingBox: representative.2
      )
    }.sorted { lhs, rhs in
      lhs.inmatchStart == rhs.inmatchStart
        ? lhs.boundingBox.y > rhs.boundingBox.y
        : lhs.inmatchStart < rhs.inmatchStart
    }
  }

  static func renderText(_ result: ContinuousOCRResult, matchDuration: Double) -> String {
    struct Row {
      let start: Double
      let end: Double
      var texts: [String]
    }
    var rows: [Row] = []
    for interval in result.intervals {
      if let last = rows.indices.last,
        rows[last].start == interval.inmatchStart,
        rows[last].end == interval.inmatchEnd
      {
        if !rows[last].texts.contains(interval.representativeText) {
          rows[last].texts.append(interval.representativeText)
        }
      } else {
        rows.append(
          Row(
            start: interval.inmatchStart,
            end: interval.inmatchEnd,
            texts: [interval.representativeText]
          ))
      }
    }
    var lines = [
      "record: \(result.globalId)",
      "sampling: \(canonical(result.samplesPerSecond)) fps / \(result.scannedSampleCount) frames",
      "time: Pokémon UNITE match clock",
      "",
    ]
    lines += rows.map { row in
      let startClock = matchClock(matchDuration - row.start)
      let endClock = matchClock(matchDuration - row.end)
      return "[\(startClock)–\(endClock)] \(row.texts.joined(separator: " / "))"
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func canonical(_ value: Double) -> String {
    String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
  }

  private static func matchClock(_ seconds: Double) -> String {
    let milliseconds = Int64((max(0, seconds) * 1_000).rounded())
    let minutes = milliseconds / 60_000
    let remainingSeconds = (milliseconds / 1_000) % 60
    let remainingMilliseconds = milliseconds % 1_000
    return String(format: "%02lld:%02lld.%03lld", minutes, remainingSeconds, remainingMilliseconds)
  }

  private static func makeRecognitionRequest(
    languages: [String],
    customWords: [String]
  ) -> VNRecognizeTextRequest {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.usesLanguageCorrection = false
    request.customWords = customWords
    return request
  }

  private static func recognize(
    _ image: CGImage,
    request: VNRecognizeTextRequest
  ) throws -> [ContinuousOCRObservation] {
    let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
    try handler.perform([request])
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let box = observation.boundingBox
      return ContinuousOCRObservation(
        text: candidate.string,
        confidence: candidate.confidence,
        boundingBox: .init(x: box.minX, y: box.minY, width: box.width, height: box.height)
      )
    }.sorted {
      if abs($0.boundingBox.y - $1.boundingBox.y) > 0.03 {
        return $0.boundingBox.y > $1.boundingBox.y
      }
      return $0.boundingBox.x < $1.boundingBox.x
    }
  }

  private static func recognize(
    batch: [RecognitionBatchItem],
    request: VNRecognizeTextRequest,
    canvas: RecognitionBatchCanvas
  ) throws -> [(RecognitionBatchItem, [ContinuousOCRObservation])] {
    guard !batch.isEmpty else { return [] }
    let image = try canvas.render(batch)

    var observationsBySlot = Array(repeating: [ContinuousOCRObservation](), count: batch.count)
    for observation in try recognize(image, request: request) {
      let box = observation.boundingBox
      let compositeBox = CGRect(
        x: box.x * Double(canvas.cellWidth),
        y: box.y * Double(canvas.totalHeight),
        width: box.width * Double(canvas.cellWidth),
        height: box.height * Double(canvas.totalHeight)
      )
      guard
        let slot = canvas.cellRects[..<batch.count].firstIndex(where: {
          $0.contains(CGPoint(x: compositeBox.midX, y: compositeBox.midY))
        })
      else {
        continue
      }
      let cellRect = canvas.cellRects[slot]
      let localBox = ContinuousOCRObservation.Rectangle(
        x: (compositeBox.minX - cellRect.minX) / cellRect.width,
        y: (compositeBox.minY - cellRect.minY) / cellRect.height,
        width: compositeBox.width / cellRect.width,
        height: compositeBox.height / cellRect.height
      )
      guard acceptedObservationCenterX.contains(localBox.x + localBox.width / 2) else { continue }
      observationsBySlot[slot].append(
        ContinuousOCRObservation(
          text: observation.text,
          confidence: observation.confidence,
          boundingBox: localBox
        ))
    }
    return batch.enumerated().map { slot, item in
      let observations = observationsBySlot[slot].sorted {
        if abs($0.boundingBox.y - $1.boundingBox.y) > 0.03 {
          return $0.boundingBox.y > $1.boundingBox.y
        }
        return $0.boundingBox.x < $1.boundingBox.x
      }
      return (item, observations)
    }
  }

  private static func scaled(_ image: CGImage, factor: Int) throws -> CGImage {
    let width = image.width * factor
    let height = image.height * factor
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else { throw ContinuousOCRError.message("Could not allocate the enlarged OCR image") }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let result = context.makeImage() else {
      throw ContinuousOCRError.message("Could not finalize the enlarged OCR image")
    }
    return result
  }

  private static func recognitionInput(
    _ image: CGImage,
    source: ContinuousOCRDefinition.Rectangle
  ) throws -> CGImage {
    try scaled(recognitionCrop(image, source: source), factor: recognitionScale)
  }

  private static func recognitionCrop(
    _ image: CGImage,
    source: ContinuousOCRDefinition.Rectangle
  ) throws -> CGImage {
    let paddedSource = expandedSourceRect(
      source, videoWidth: image.width, videoHeight: image.height)
    return try VideoFrameSupport.cropped(image, rect: paddedSource)
  }

  private static func writePNG(_ image: CGImage, to url: URL) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
      )
    else { throw ContinuousOCRError.message("Could not create PNG destination: \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
      throw ContinuousOCRError.message("Could not write PNG: \(url.path)")
    }
  }

  private static func normalized(_ text: String) -> String {
    text.folding(
      options: [.widthInsensitive, .caseInsensitive], locale: Locale(identifier: "ja_JP")
    )
    .filter { !$0.isWhitespace && !$0.isPunctuation }
  }

  private static func similar(_ lhs: String, _ rhs: String) -> Bool {
    if lhs == rhs { return true }
    let left = Array(lhs)
    let right = Array(rhs)
    guard !left.isEmpty, !right.isEmpty else { return false }
    var previous = Array(0...right.count)
    for (i, l) in left.enumerated() {
      var current = [i + 1] + Array(repeating: 0, count: right.count)
      for (j, r) in right.enumerated() {
        current[j + 1] = min(
          min(current[j] + 1, previous[j + 1] + 1),
          previous[j] + (l == r ? 0 : 1)
        )
      }
      previous = current
    }
    let distance = previous[right.count]
    return 1 - Double(distance) / Double(max(left.count, right.count)) >= 0.6
  }

  private static func spatiallyNear(
    _ lhs: ContinuousOCRObservation.Rectangle,
    _ rhs: ContinuousOCRObservation.Rectangle
  ) -> Bool {
    centerDistance(lhs, rhs) <= max(0.12, max(lhs.height, rhs.height) * 2.5)
  }

  private static func centerDistance(
    _ lhs: ContinuousOCRObservation.Rectangle,
    _ rhs: ContinuousOCRObservation.Rectangle
  ) -> Double {
    hypot(
      (lhs.x + lhs.width / 2) - (rhs.x + rhs.width / 2),
      (lhs.y + lhs.height / 2) - (rhs.y + rhs.height / 2))
  }

  private static func recordingBundle(above recordSpecURL: URL) throws -> URL {
    var candidate = recordSpecURL.deletingLastPathComponent()
    while candidate.path != "/" {
      if candidate.pathExtension == "ldtxrecord" { return candidate }
      candidate.deleteLastPathComponent()
    }
    throw ContinuousOCRError.message(
      "record-spec.json must be inside a .ldtxrecord bundle: \(recordSpecURL.path)")
  }
}
