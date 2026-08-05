// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import LDTXRecordingSupport

public enum ChromaEventError: Error, CustomStringConvertible {
  case message(String)

  public var description: String {
    switch self {
    case .message(let value): value
    }
  }
}

public struct ChromaEventDefinition: Codable, Equatable, Sendable {
  public struct Rectangle: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
  }

  public let source: Rectangle
  /// Required by the command-line jobs interface; ignored by the detector itself.
  public let output: String?
}

public struct ChromaEventSample: Codable, Equatable, Sendable {
  public let requestedInmatch: Double
  public let actualInmatch: Double
  /// The default scalar suitable for a generic numeric threshold filter: max(cbThreshold, crThreshold).
  public let score: Int
  public let cbThreshold: Int
  public let crThreshold: Int
  public let cbChangedPixelCount: Int
  public let crChangedPixelCount: Int
  public let bothChangedPixelCount: Int
  public let changedPixelCount: Int
}

public struct ChromaEventResult: Codable, Equatable, Sendable {
  public let globalId: String
  public let source: ChromaEventDefinition.Rectangle
  public let sampledWidth: Int
  public let sampledHeight: Int
  public let samples: [ChromaEventSample]
}

/// Each consecutive chroma-difference plane receives its own Otsu threshold. The maximum is exposed
/// as a scalar score so ordinary threshold-filter commands can consume this result directly.
public enum ChromaEventDetector {
  static let downscale = 8
  public static let candidateContextSeconds = 0.5

  /// Expands each selected temporal difference to cover both its appearance and disappearance side.
  public static func expandedCandidateTimes(
    _ samples: [ChromaEventSample],
    minimumScore: Int,
    duration: Double
  ) throws -> [Double] {
    guard minimumScore >= 0 else {
      throw ChromaEventError.message("minimum score must be nonnegative")
    }
    guard duration.isFinite, duration > 0 else {
      throw ChromaEventError.message("match duration must be positive and finite")
    }
    let offsets = [-candidateContextSeconds, 0, candidateContextSeconds]
    // Decode requests stay on the detector's fixed sampling lattice. `actualInmatch` records the
    // AVAssetImageGenerator response for evidence, but re-requesting that arbitrary PTS is less
    // reliable for fragmented MP4 than the original requested time.
    let times = samples.lazy
      .filter { $0.score >= minimumScore }
      .flatMap { sample in offsets.map { sample.requestedInmatch + $0 } }
      .filter { $0 >= 0 && $0 <= duration }
    return Array(Set(times)).sorted()
  }

  public static func run(
    definitionData: Data,
    recordSpecURL: URL,
    outputURL: URL,
    force: Bool
  ) async throws {
    guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
      throw ChromaEventError.message(
        "Output already exists: \(outputURL.path). Pass --force to overwrite.")
    }
    let definition = try JSONDecoder().decode(ChromaEventDefinition.self, from: definitionData)
    guard definition.source.x >= 0, definition.source.y >= 0,
      definition.source.width >= downscale, definition.source.height >= downscale
    else {
      throw ChromaEventError.message(
        "source must be at least \(downscale)x\(downscale) with a nonnegative top-left origin")
    }

    let spec = try JSONDecoder().decode(
      RecordVisionRecordSpec.self, from: Data(contentsOf: recordSpecURL))
    RecordVisionInputLogger.recordSpec(recordSpecURL)
    guard spec.startPTS.timescale > 0, spec.duration.isFinite, spec.duration > 0 else {
      throw ChromaEventError.message(
        "record-spec must have a positive startPTS timescale and duration")
    }
    let bundleURL = try bundleURL(above: recordSpecURL)
    if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path)
    {
      RecordVisionInputLogger.unfinishedRecording(bundleURL)
    }
    let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
    RecordVisionInputLogger.sourceVideo(recording.videoURL)
    let asset = AVURLAsset(url: recording.videoURL)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw ChromaEventError.message("No video track: \(recording.videoURL.path)")
    }
    let size = try await track.load(.naturalSize)
    guard definition.source.x + definition.source.width <= Int(size.width),
      definition.source.y + definition.source.height <= Int(size.height)
    else {
      throw ChromaEventError.message(
        "source exceeds encoded video dimensions \(Int(size.width))x\(Int(size.height))")
    }

    let requestedOffsets = ContinuousOCR.sampleOffsets(duration: spec.duration)
    let start = CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale)
    let sourceTimes = requestedOffsets.map {
      CMTimeAdd(start, CMTime(seconds: $0, preferredTimescale: spec.startPTS.timescale))
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.apertureMode = .encodedPixels
    generator.appliesPreferredTrackTransform = false
    generator.maximumSize = CGSize(width: CGFloat(size.width) / CGFloat(downscale), height: 0)
    generator.requestedTimeToleranceBefore = CMTime(
      seconds: ContinuousOCR.recognitionTolerance, preferredTimescale: 600)
    generator.requestedTimeToleranceAfter = CMTime(
      seconds: ContinuousOCR.recognitionTolerance, preferredTimescale: 600)

    let sampledWidth = definition.source.width / downscale
    let sampledHeight = definition.source.height / downscale
    var previous: ChromaPlane?
    var samples: [ChromaEventSample] = []
    var renderedIndices = Set<Int>()
    for await result in generator.images(for: sourceTimes) {
      let requestedTime: CMTime
      let image: CGImage
      let actualTime: CMTime
      switch result {
      case .success(let request, let valueImage, let actual):
        requestedTime = request
        image = valueImage
        actualTime = actual
      case .failure(let requested, let error):
        throw ChromaEventError.message(
          "Source-video image generation failed at \(requested.seconds)s: \(error.localizedDescription)"
        )
      }
      guard let index = sourceTimes.firstIndex(where: { CMTimeCompare($0, requestedTime) == 0 }),
        renderedIndices.insert(index).inserted
      else {
        throw ChromaEventError.message(
          "Source-video image generation returned an unknown or duplicate requested time")
      }
      let plane = try chromaPlane(
        image: image,
        source: scaledRectangle(
          definition.source,
          image: image,
          encodedSize: size
        ),
        width: sampledWidth,
        height: sampledHeight
      )
      if let previous {
        let analysis = analyze(previous: previous, current: plane)
        samples.append(
          ChromaEventSample(
            requestedInmatch: requestedOffsets[index],
            actualInmatch: CMTimeSubtract(actualTime, start).seconds,
            score: max(analysis.cbThreshold, analysis.crThreshold),
            cbThreshold: analysis.cbThreshold,
            crThreshold: analysis.crThreshold,
            cbChangedPixelCount: analysis.cbChangedPixelCount,
            crChangedPixelCount: analysis.crChangedPixelCount,
            bothChangedPixelCount: analysis.bothChangedPixelCount,
            changedPixelCount: analysis.changedPixelCount
          ))
      }
      previous = plane
    }
    guard renderedIndices.count == sourceTimes.count else {
      throw ChromaEventError.message(
        "Source-video image generation returned \(renderedIndices.count) of \(sourceTimes.count) requested frames"
      )
    }
    let result = ChromaEventResult(
      globalId: spec.globalId,
      source: definition.source,
      sampledWidth: sampledWidth,
      sampledHeight: sampledHeight,
      samples: samples
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(result).write(to: outputURL, options: .atomic)
  }

  struct ChromaPlane {
    let cb: [Int16]
    let cr: [Int16]
  }

  static func scaledRectangle(
    _ source: ChromaEventDefinition.Rectangle,
    image: CGImage,
    encodedSize: CGSize
  ) -> CGRect {
    let scaleX = CGFloat(image.width) / encodedSize.width
    let scaleY = CGFloat(image.height) / encodedSize.height
    let minX = floor(CGFloat(source.x) * scaleX)
    let minY = floor(CGFloat(source.y) * scaleY)
    let maxX = ceil(CGFloat(source.x + source.width) * scaleX)
    let maxY = ceil(CGFloat(source.y + source.height) * scaleY)
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }

  static func chromaPlane(
    image: CGImage,
    source: CGRect,
    width: Int,
    height: Int
  ) throws -> ChromaPlane {
    let crop = try VideoFrameSupport.cropped(image, rect: source)
    var rgba = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
      else { return false }
      context.interpolationQuality = .none
      context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else {
      throw ChromaEventError.message("Could not allocate downscaled chroma buffer")
    }
    var cb: [Int16] = []
    var cr: [Int16] = []
    cb.reserveCapacity(width * height)
    cr.reserveCapacity(width * height)
    for index in 0..<(width * height) {
      let offset = index * 4
      let r = Int16(rgba[offset])
      let g = Int16(rgba[offset + 1])
      let b = Int16(rgba[offset + 2])
      cb.append(b - ((r + g) >> 1))
      cr.append(r - ((g + b) >> 1))
    }
    return ChromaPlane(cb: cb, cr: cr)
  }

  static func analyze(previous: ChromaPlane, current: ChromaPlane) -> (
    cbThreshold: Int,
    crThreshold: Int,
    cbChangedPixelCount: Int,
    crChangedPixelCount: Int,
    bothChangedPixelCount: Int,
    changedPixelCount: Int
  ) {
    precondition(previous.cb.count == current.cb.count && previous.cr.count == current.cr.count)
    let cb = zip(previous.cb, current.cb).map { UInt16(abs(Int($0.1) - Int($0.0))) }
    let cr = zip(previous.cr, current.cr).map { UInt16(abs(Int($0.1) - Int($0.0))) }
    let cbThreshold = otsuThreshold(cb.map(Int.init))
    let crThreshold = otsuThreshold(cr.map(Int.init))
    var cbChanged = 0
    var crChanged = 0
    var bothChanged = 0
    var changed = 0
    for values in zip(cb, cr) {
      let cbActive = cbThreshold.map { Int(values.0) > $0 } ?? false
      let crActive = crThreshold.map { Int(values.1) > $0 } ?? false
      if cbActive { cbChanged += 1 }
      if crActive { crChanged += 1 }
      if cbActive && crActive { bothChanged += 1 }
      if cbActive || crActive { changed += 1 }
    }
    return (cbThreshold ?? 0, crThreshold ?? 0, cbChanged, crChanged, bothChanged, changed)
  }

  /// Returns nil for a degenerate plane. Otsu must not invent foreground when every pixel has the same change.
  static func otsuThreshold(_ values: [Int]) -> Int? {
    guard let minimum = values.min(), let maximum = values.max(), minimum < maximum else {
      return nil
    }
    var histogram = [Int](repeating: 0, count: maximum + 1)
    for value in values { histogram[value] += 1 }
    let count = values.count
    let total = histogram.enumerated().reduce(0) { $0 + $1.offset * $1.element }
    var lowerCount = 0
    var lowerSum = 0
    var bestThreshold = minimum
    var bestVariance = -1.0
    for threshold in minimum..<maximum {
      lowerCount += histogram[threshold]
      lowerSum += threshold * histogram[threshold]
      let upperCount = count - lowerCount
      guard lowerCount > 0, upperCount > 0 else { continue }
      let difference = Double(lowerSum * upperCount - (total - lowerSum) * lowerCount)
      let variance = difference * difference / Double(lowerCount * upperCount)
      if variance > bestVariance {
        bestVariance = variance
        bestThreshold = threshold
      }
    }
    return bestThreshold
  }

  private static func bundleURL(above recordSpecURL: URL) throws -> URL {
    let matchURL = recordSpecURL.deletingLastPathComponent()
    let namespaceURL = matchURL.deletingLastPathComponent()
    let bundleURL = namespaceURL.deletingLastPathComponent()
    guard bundleURL.pathExtension == "ldtxrecord" else {
      throw ChromaEventError.message(
        "record-spec.json must be inside a .ldtxrecord bundle: \(recordSpecURL.path)")
    }
    return bundleURL
  }
}
