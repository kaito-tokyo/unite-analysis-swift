// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum SampleFrameSequenceError: Error, CustomStringConvertible {
  case message(String)

  public var description: String {
    switch self {
    case .message(let value): value
    }
  }
}

public enum SampleFrameSequence {
  public static let maximumSampleCount = 10_000

  public static func sampleOffsets(duration: Double, fps: Double) throws -> [Double] {
    guard duration.isFinite, duration > 0 else {
      throw SampleFrameSequenceError.message("duration must be positive and finite")
    }
    guard fps.isFinite, fps > 0 else {
      throw SampleFrameSequenceError.message("fps must be positive and finite")
    }
    let sampleCount = ceil(duration * fps)
    guard sampleCount <= Double(maximumSampleCount) else {
      throw SampleFrameSequenceError.message(
        "duration and fps must produce at most \(maximumSampleCount) samples")
    }
    return (0..<Int(sampleCount)).map { Double($0) / fps }
  }
}
