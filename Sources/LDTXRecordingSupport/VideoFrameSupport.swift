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
  public let videoTrackEnd: CMTime
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
    self.videoTrackEnd = try await track.load(.timeRange).end
    self.naturalSize = try await track.load(.naturalSize)
    self.nominalFrameRate = try await track.load(.nominalFrameRate)
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
          VideoFrameSupport.decodingFailureMessage(
            "Source-video image generation failed at \(requestedTime.seconds)s: \(error.localizedDescription)"
          )
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
      throw VideoFrameSupportError.message(
        VideoFrameSupport.decodingFailureMessage(
          "Could not start precise source-video decoding: \(reader.error?.localizedDescription ?? "unknown error")"
        ))
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
    throw VideoFrameSupportError.message(
      VideoFrameSupport.decodingFailureMessage(
        "Source-video decoding ended before precise frame request: \(reader.error?.localizedDescription ?? "unknown error")"
      ))
  }

  /// Sequentially decodes source samples, beginning with the first sample at or after `time`.
  /// Unlike a list of time-based requests, this returns every decoded video sample in order.
  public func extractConsecutiveFrames(
    startingAt time: CMTime,
    count: Int,
    handler: (_ index: Int, _ image: CGImage, _ presentationTime: CMTime) throws -> Void
  ) throws {
    guard count > 0 else {
      throw VideoFrameSupportError.message("Consecutive frame count must be positive")
    }
    let reader = try AVAssetReader(asset: asset)
    let requestedPreroll = CMTimeSubtract(time, CMTime(seconds: 2, preferredTimescale: 600))
    let prerollStart = CMTimeCompare(requestedPreroll, .zero) > 0 ? requestedPreroll : .zero
    reader.timeRange = CMTimeRange(start: prerollStart, end: duration)
    let output = try makeOutput(reader: reader)
    guard reader.startReading() else {
      throw VideoFrameSupportError.message(
        VideoFrameSupport.decodingFailureMessage(
          "Could not start consecutive source-video decoding: \(reader.error?.localizedDescription ?? "unknown error")"
        ))
    }
    var index = 0
    while index < count, let sample = output.copyNextSampleBuffer() {
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
      guard CMTimeCompare(presentationTime, time) >= 0,
        let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
      else { continue }
      // FrameSource rectangles use encoded-pixel coordinates, matching contact-sheet.
      let image = try VideoFrameSupport.normalizedImage(
        pixelBuffer, transform: .identity, context: context)
      try handler(index, image, presentationTime)
      index += 1
    }
    guard index == count else {
      throw VideoFrameSupportError.message(
        VideoFrameSupport.decodingFailureMessage(
          "Source-video decoding ended after \(index) of \(count) consecutive frames: \(reader.error?.localizedDescription ?? "unknown error")"
        ))
    }
  }

  public func extractFrames(
    at times: [CMTime],
    handler: (_ index: Int, _ image: CGImage) throws -> Void
  ) throws {
    try extractFrames(at: times) { index, image, _ in
      try handler(index, image)
    }
  }

  /// Decodes the first source sample at or after each requested time.
  /// The presentation time identifies the decoded sample rather than the request.
  public func extractFrames(
    at times: [CMTime],
    handler: (_ index: Int, _ image: CGImage, _ presentationTime: CMTime) throws -> Void
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
      throw VideoFrameSupportError.message(
        VideoFrameSupport.decodingFailureMessage(
          "Could not start source-video decoding: \(reader.error?.localizedDescription ?? "unknown error")"
        ))
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
        try handler(targetIndex, image, presentationTime)
        targetIndex += 1
      } while targetIndex < times.count && CMTimeCompare(presentationTime, times[targetIndex]) >= 0
    }
    guard targetIndex == times.count else {
      throw VideoFrameSupportError.message(
        VideoFrameSupport.decodingFailureMessage(
          "Source-video decoding ended after \(targetIndex) of \(times.count) requested frames: \(reader.error?.localizedDescription ?? "unknown error")"
        ))
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
  public static let sandboxDecodingGuidance =
    "Video decoding uses VideoToolbox and generally requires execution outside an application sandbox. If decoding fails with \"Cannot Decode\" inside a sandbox, rerun the same command outside the sandbox before treating the media as invalid."

  public static func decodingFailureMessage(_ message: String) -> String {
    "\(message) \(sandboxDecodingGuidance)"
  }

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

  public static func resized(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
    guard width > 0, height > 0 else {
      throw VideoFrameSupportError.message("Output dimensions must be positive")
    }
    let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else {
      throw VideoFrameSupportError.message("Could not allocate \(width)x\(height) image")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let resized = context.makeImage() else {
      throw VideoFrameSupportError.message("Could not create \(width)x\(height) image")
    }
    return resized
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
    // already been normalized. Remove APP1 metadata while preserving colour
    // profiles and other application segments.
    try stripApplicationMetadata(from: url)
  }

  private static func stripApplicationMetadata(from url: URL) throws {
    let source = try Data(contentsOf: url)
    let result = try removingAPP1Metadata(from: source, sourceDescription: url.path)
    try result.write(to: url, options: .atomic)
  }

  package static func removingAPP1Metadata(
    from source: Data, sourceDescription: String = "JPEG data"
  ) throws -> Data {
    let bytes = [UInt8](source)
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
      throw VideoFrameSupportError.message(
        "JPEG writer produced invalid data: \(sourceDescription)")
    }
    var result = Data(bytes[0...1])
    var index = 2
    while index < bytes.count {
      let markerStart = index
      guard bytes[index] == 0xFF else {
        throw VideoFrameSupportError.message("JPEG header is malformed: \(sourceDescription)")
      }
      while index < bytes.count, bytes[index] == 0xFF {
        index += 1
      }
      guard index < bytes.count else {
        throw VideoFrameSupportError.message("JPEG header is malformed: \(sourceDescription)")
      }
      let marker = bytes[index]
      index += 1
      if marker == 0xDA {  // Start of Scan: entropy data follows unchanged.
        result.append(contentsOf: bytes[markerStart...])
        return result
      }
      guard index + 1 < bytes.count else {
        throw VideoFrameSupportError.message("JPEG segment is malformed: \(sourceDescription)")
      }
      let length = Int(bytes[index]) << 8 | Int(bytes[index + 1])
      let end = index + length
      guard length >= 2, end <= bytes.count else {
        throw VideoFrameSupportError.message("JPEG segment is malformed: \(sourceDescription)")
      }
      if marker != 0xE1 {
        result.append(contentsOf: bytes[markerStart..<end])
      }
      index = end
    }
    throw VideoFrameSupportError.message("JPEG has no scan data: \(sourceDescription)")
  }
}
