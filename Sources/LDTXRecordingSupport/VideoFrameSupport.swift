// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VideoFrameSupportError: Error, CustomStringConvertible {
  case message(String)

  public var description: String {
    switch self {
    case .message(let value): value
    }
  }
}

public final class VideoFrameExtractor {
  private let asset: AVURLAsset
  private let track: AVAssetTrack
  private let transform: CGAffineTransform
  private let context: CIContext
  public let duration: CMTime
  public let naturalSize: CGSize
  public let nominalFrameRate: Float

  public init(videoURL: URL) async throws {
    let asset = AVURLAsset(url: videoURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else {
      throw VideoFrameSupportError.message("No video track: \(videoURL.path)")
    }
    self.asset = asset
    self.track = track
    self.transform = try await track.load(.preferredTransform)
    self.context = CIContext()
    self.duration = try await asset.load(.duration)
    self.naturalSize = try await track.load(.naturalSize)
    self.nominalFrameRate = try await track.load(.nominalFrameRate)
  }

  public func extractFrame(at time: CMTime) throws -> CGImage {
    var result: CGImage?
    try extractFrames(at: [time]) { _, image in result = image }
    guard let result else {
      throw VideoFrameSupportError.message("No source-video frame at requested time")
    }
    return result
  }

  /// Retrieves independent approximate frames without sequentially decoding the interval between requests.
  /// The returned presentation time is the generator's actual selected frame; callers must not treat it as exact.
  public func extractApproximateFrames(
    at times: [CMTime],
    handler: (_ index: Int, _ image: CGImage, _ actualTime: CMTime) throws -> Void
  ) async throws {
    guard !times.isEmpty else { return }
    for index in 1..<times.count {
      guard CMTimeCompare(times[index], times[index - 1]) > 0 else {
        throw VideoFrameSupportError.message("Frame times must be in strictly ascending order")
      }
    }

    let generator = AVAssetImageGenerator(asset: asset)
    generator.apertureMode = .encodedPixels
    generator.appliesPreferredTrackTransform = false
    var renderedIndices = Set<Int>()
    for await result in generator.images(for: times) {
      switch result {
      case .success(let requestedTime, let image, let actualTime):
        guard let index = times.firstIndex(where: { CMTimeCompare($0, requestedTime) == 0 }),
          renderedIndices.insert(index).inserted
        else {
          throw VideoFrameSupportError.message(
            "Source-video image generation returned an unknown or duplicate requested time: \(requestedTime.seconds)s"
          )
        }
        try handler(index, image, actualTime)
      case .failure(let requestedTime, let error):
        throw VideoFrameSupportError.message(
          "Source-video image generation failed at \(requestedTime.seconds)s: \(error.localizedDescription)"
        )
      }
    }
    guard renderedIndices.count == times.count else {
      throw VideoFrameSupportError.message(
        "Source-video image generation returned \(renderedIndices.count) of \(times.count) requested frames"
      )
    }
  }

  /// Decodes a short sequential preroll and returns the first presentation sample at or after time.
  /// The returned presentation PTS is the precise, inspectable result of this single-frame request.
  public func extractPreciseFrame(at time: CMTime) throws -> (
    image: CGImage, presentationTime: CMTime
  ) {
    let reader = try AVAssetReader(asset: asset)
    let requestedPreroll = CMTimeSubtract(time, CMTime(seconds: 2, preferredTimescale: 600))
    let prerollStart = CMTimeCompare(requestedPreroll, .zero) > 0 ? requestedPreroll : .zero
    reader.timeRange = CMTimeRange(start: prerollStart, end: duration)
    let output = try makeOutput(reader: reader)
    guard reader.startReading() else {
      throw reader.error
        ?? VideoFrameSupportError.message("Could not start precise source-video decoding")
    }
    while let sample = output.copyNextSampleBuffer() {
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
      guard CMTimeCompare(presentationTime, time) >= 0,
        let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
      else { continue }
      return (
        try VideoFrameSupport.normalizedImage(pixelBuffer, transform: transform, context: context),
        presentationTime
      )
    }
    throw reader.error
      ?? VideoFrameSupportError.message("Source-video decoding ended before precise frame request")
  }

  public func extractFrames(
    at times: [CMTime],
    handler: (_ index: Int, _ image: CGImage) throws -> Void
  ) throws {
    guard !times.isEmpty else { return }
    for index in 1..<times.count {
      guard CMTimeCompare(times[index], times[index - 1]) > 0 else {
        throw VideoFrameSupportError.message("Frame times must be in strictly ascending order")
      }
    }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: times[0], end: duration)
    let output = try makeOutput(reader: reader)
    guard reader.startReading() else {
      throw reader.error ?? VideoFrameSupportError.message("Could not start source-video decoding")
    }
    var targetIndex = 0
    while targetIndex < times.count, let sample = output.copyNextSampleBuffer() {
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
      guard CMTimeCompare(presentationTime, times[targetIndex]) >= 0,
        let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
      else { continue }
      let image = try VideoFrameSupport.normalizedImage(
        pixelBuffer, transform: transform, context: context)
      repeat {
        try handler(targetIndex, image)
        targetIndex += 1
      } while targetIndex < times.count && CMTimeCompare(presentationTime, times[targetIndex]) >= 0
    }
    guard targetIndex == times.count else {
      throw reader.error
        ?? VideoFrameSupportError.message(
          "Source-video decoding ended after \(targetIndex) of \(times.count) requested frames"
        )
    }
  }

  private func makeOutput(reader: AVAssetReader) throws -> AVAssetReaderTrackOutput {
    let output = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
      ]
    )
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw VideoFrameSupportError.message("Could not configure source-video decoder")
    }
    reader.add(output)
    return output
  }
}

public enum VideoFrameSupport {
  public static func normalizedImage(
    _ pixelBuffer: CVPixelBuffer,
    transform: CGAffineTransform,
    context: CIContext
  ) throws -> CGImage {
    var image = CIImage(cvPixelBuffer: pixelBuffer).transformed(by: transform)
    let extent = image.extent
    if extent.minX != 0 || extent.minY != 0 {
      image = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
    }
    guard let result = context.createCGImage(image, from: image.extent) else {
      throw VideoFrameSupportError.message("Could not create a frame image")
    }
    return result
  }

  public static func extractFrame(from videoURL: URL, at time: CMTime) async throws -> CGImage {
    try await VideoFrameExtractor(videoURL: videoURL).extractFrame(at: time)
  }

  public static func cropped(_ image: CGImage, rect: CGRect) throws -> CGImage {
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard bounds.contains(rect), rect.width > 0, rect.height > 0,
      let cropped = image.cropping(to: rect)
    else {
      throw VideoFrameSupportError.message(
        "Crop \(rect) is outside decoded frame \(image.width)x\(image.height)")
    }
    return cropped
  }

  public static func writeBaselineJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
    guard
      let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
      )
    else {
      throw VideoFrameSupportError.message("Could not create JPEG destination: \(url.path)")
    }
    CGImageDestinationAddImage(
      destination, image,
      [
        kCGImageDestinationLossyCompressionQuality: quality,
        kCGImagePropertyJFIFIsProgressive: false,
      ] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
      throw VideoFrameSupportError.message("Could not write JPEG: \(url.path)")
    }
    // ImageIO can add an EXIF orientation block even though this CGImage has
    // already been normalized. Keep only JFIF and JPEG coding segments so
    // consumers such as Google Docs do not need to interpret sidecar metadata.
    try stripApplicationMetadata(from: url)
  }

  private static func stripApplicationMetadata(from url: URL) throws {
    let source = try Data(contentsOf: url)
    let bytes = [UInt8](source)
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
      throw VideoFrameSupportError.message("JPEG writer produced invalid data: \(url.path)")
    }
    var result = Data(bytes[0...1])
    var index = 2
    while index + 3 < bytes.count {
      guard bytes[index] == 0xFF else {
        throw VideoFrameSupportError.message("JPEG header is malformed: \(url.path)")
      }
      let marker = bytes[index + 1]
      if marker == 0xDA {  // Start of Scan: entropy data follows unchanged.
        result.append(contentsOf: bytes[index...])
        try result.write(to: url, options: .atomic)
        return
      }
      let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
      let end = index + 2 + length
      guard length >= 2, end <= bytes.count else {
        throw VideoFrameSupportError.message("JPEG segment is malformed: \(url.path)")
      }
      // Preserve APP0 (JFIF) and remove APP1...APP15 (EXIF, XMP, ICC, etc.).
      if marker < 0xE1 || marker > 0xEF {
        result.append(contentsOf: bytes[index..<end])
      }
      index = end
    }
    throw VideoFrameSupportError.message("JPEG has no scan data: \(url.path)")
  }
}
