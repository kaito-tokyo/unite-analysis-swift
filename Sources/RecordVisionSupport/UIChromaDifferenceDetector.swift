// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import ImageIO
import LDTXRecordingSupport

public enum ChromaEventError: Error, CustomStringConvertible {
  case message(String)

  public var description: String {
    switch self {
    case .message(let value): value
    }
  }
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

  package init(
    requestedInmatch: Double,
    actualInmatch: Double,
    score: Int,
    cbThreshold: Int,
    crThreshold: Int,
    cbChangedPixelCount: Int,
    crChangedPixelCount: Int,
    bothChangedPixelCount: Int,
    changedPixelCount: Int
  ) {
    self.requestedInmatch = requestedInmatch
    self.actualInmatch = actualInmatch
    self.score = score
    self.cbThreshold = cbThreshold
    self.crThreshold = crThreshold
    self.cbChangedPixelCount = cbChangedPixelCount
    self.crChangedPixelCount = crChangedPixelCount
    self.bothChangedPixelCount = bothChangedPixelCount
    self.changedPixelCount = changedPixelCount
  }
}

public struct ChromaEventResult: Codable, Equatable, Sendable {
  public static let schema =
    "https://kaito-tokyo.github.io/unite-analysis-swift/chroma-events.output.schema.json"

  public let inputSampleDirectory: String
  public let inputSampleCount: Int
  public let firstInputFilename: String
  public let lastInputFilename: String
  public let fps: Double
  public let sampledWidth: Int
  public let sampledHeight: Int
  public let samples: [ChromaEventSample]

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case inputSampleDirectory, inputSampleCount, firstInputFilename, lastInputFilename, fps,
      sampledWidth, sampledHeight, samples
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    inputSampleDirectory = try container.decode(String.self, forKey: .inputSampleDirectory)
    inputSampleCount = try container.decode(Int.self, forKey: .inputSampleCount)
    firstInputFilename = try container.decode(String.self, forKey: .firstInputFilename)
    lastInputFilename = try container.decode(String.self, forKey: .lastInputFilename)
    fps = try container.decode(Double.self, forKey: .fps)
    sampledWidth = try container.decode(Int.self, forKey: .sampledWidth)
    sampledHeight = try container.decode(Int.self, forKey: .sampledHeight)
    samples = try container.decode([ChromaEventSample].self, forKey: .samples)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schema, forKey: .schema)
    try container.encode(inputSampleDirectory, forKey: .inputSampleDirectory)
    try container.encode(inputSampleCount, forKey: .inputSampleCount)
    try container.encode(firstInputFilename, forKey: .firstInputFilename)
    try container.encode(lastInputFilename, forKey: .lastInputFilename)
    try container.encode(fps, forKey: .fps)
    try container.encode(sampledWidth, forKey: .sampledWidth)
    try container.encode(sampledHeight, forKey: .sampledHeight)
    try container.encode(samples, forKey: .samples)
  }

  init(
    inputSampleDirectory: String,
    inputSampleCount: Int,
    firstInputFilename: String,
    lastInputFilename: String,
    fps: Double,
    sampledWidth: Int,
    sampledHeight: Int,
    samples: [ChromaEventSample]
  ) {
    self.inputSampleDirectory = inputSampleDirectory
    self.inputSampleCount = inputSampleCount
    self.firstInputFilename = firstInputFilename
    self.lastInputFilename = lastInputFilename
    self.fps = fps
    self.sampledWidth = sampledWidth
    self.sampledHeight = sampledHeight
    self.samples = samples
  }
}

/// Each consecutive chroma-difference plane receives its own Otsu threshold. The maximum is exposed
/// as a scalar score so ordinary threshold-filter commands can consume this result directly.
public enum ChromaEventDetector {
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
    // Candidate expansion stays on the JPEG sequence's fixed sampling lattice.
    let times = samples.lazy
      .filter { $0.score >= minimumScore }
      .flatMap { sample in offsets.map { sample.requestedInmatch + $0 } }
      .filter { $0 >= 0 && $0 <= duration }
    return Array(Set(times)).sorted()
  }

  public static func jpegURLs(in directoryURL: URL) throws -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw ChromaEventError.message("JPEG input directory was not found: \(directoryURL.path)")
    }
    let urls = try FileManager.default.contentsOfDirectory(
      at: directoryURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    )
    .filter { ["jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    _ = try sequenceIndices(for: urls)
    return urls
  }

  package static func sequenceIndices(for imageURLs: [URL]) throws -> [Int] {
    var indices: [Int] = []
    var digitWidth: Int?
    for imageURL in imageURLs {
      let stem = imageURL.deletingPathExtension().lastPathComponent
      let digits = String(stem.reversed().prefix(while: { $0.isNumber }).reversed())
      guard digits.count >= 2, digits.first == "0", let index = Int(digits) else {
        throw ChromaEventError.message(
          "JPEG filename must end in a zero-padded sequence index: \(imageURL.lastPathComponent)"
        )
      }
      if let digitWidth, digits.count != digitWidth {
        throw ChromaEventError.message(
          "JPEG sequence index width changed at \(imageURL.lastPathComponent): expected \(digitWidth) digits, found \(digits.count)"
        )
      }
      digitWidth = digits.count
      let expected = indices.count + 1
      guard index == expected else {
        throw ChromaEventError.message(
          "JPEG sequence is not contiguous at \(imageURL.lastPathComponent): expected index \(expected), found \(index)"
        )
      }
      indices.append(index)
    }
    return indices
  }

  public static func run(
    inputSampleDirectoryURL: URL,
    fps: Double,
    outputURL: URL,
    force: Bool
  ) throws {
    guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
      throw ChromaEventError.message(
        "Output already exists: \(outputURL.path). Pass --force to overwrite.")
    }
    guard fps.isFinite, fps > 0 else {
      throw ChromaEventError.message("fps must be positive and finite")
    }
    let imageURLs = try jpegURLs(in: inputSampleDirectoryURL)
    guard imageURLs.count >= 2 else {
      throw ChromaEventError.message(
        "JPEG input directory must contain at least two .jpg or .jpeg files: \(inputSampleDirectoryURL.path)"
      )
    }
    let sequenceIndices = try sequenceIndices(for: imageURLs)
    var sampledWidth = 0
    var sampledHeight = 0
    var previous: ChromaPlane?
    var samples: [ChromaEventSample] = []
    for (offset, imageURL) in imageURLs.enumerated() {
      guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
      else {
        throw ChromaEventError.message("Could not decode JPEG: \(imageURL.path)")
      }
      if offset == 0 {
        sampledWidth = image.width
        sampledHeight = image.height
      } else if image.width != sampledWidth || image.height != sampledHeight {
        throw ChromaEventError.message(
          "JPEG dimensions changed at \(imageURL.path): expected \(sampledWidth)x\(sampledHeight), found \(image.width)x\(image.height)"
        )
      }
      let plane = try chromaPlane(
        image: image,
        source: CGRect(x: 0, y: 0, width: image.width, height: image.height),
        width: sampledWidth,
        height: sampledHeight
      )
      if let previous {
        let analysis = analyze(previous: previous, current: plane)
        let inmatch = Double(sequenceIndices[offset] - 1) / fps
        samples.append(
          ChromaEventSample(
            requestedInmatch: inmatch,
            actualInmatch: inmatch,
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
    let result = ChromaEventResult(
      inputSampleDirectory: inputSampleDirectoryURL.path,
      inputSampleCount: imageURLs.count,
      firstInputFilename: imageURLs[0].lastPathComponent,
      lastInputFilename: imageURLs[imageURLs.count - 1].lastPathComponent,
      fps: fps,
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

  package struct ChromaPlane {
    package let cb: [Int16]
    package let cr: [Int16]

    package init(cb: [Int16], cr: [Int16]) {
      self.cb = cb
      self.cr = cr
    }
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

  package static func analyze(previous: ChromaPlane, current: ChromaPlane) -> (
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
  package static func otsuThreshold(_ values: [Int]) -> Int? {
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

}
