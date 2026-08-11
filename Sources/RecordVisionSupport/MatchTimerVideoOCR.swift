// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreMedia
import Foundation
import LDTXRecordingSupport
import Vision

public enum MatchTimerVideoOCR {
  public static func recognize(
    videoURL: URL,
    gameScreen: GameScreenRectangle,
    layout: MatchTimerLayout,
    sampleInterval: Double
  ) async throws -> [MatchTimerObservation] {
    try layout.validate()
    let extractor = try await VideoFrameExtractor(videoURL: videoURL)
    let duration = extractor.duration.seconds
    let times = try sampleTimes(duration: duration, interval: sampleInterval)

    var observations: [MatchTimerObservation] = []
    var observedPresentationMilliseconds = Set<Int64>()
    try extractor.extractFrames(at: times) { _, frame, presentationTime in
      let milliseconds = Int64((presentationTime.seconds * 1_000).rounded())
      guard observedPresentationMilliseconds.insert(milliseconds).inserted else { return }
      try autoreleasepool {
        let crop = try timerCrop(
          frame: frame, gameScreen: gameScreen, layout: layout)
        let recognitionImage = try VideoFrameSupport.resized(
          crop, width: crop.width * 4, height: crop.height * 4)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.automaticallyDetectsLanguage = false
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: recognitionImage, options: [:]).perform([request])
        let candidate = preferredCandidate(
          from: (request.results ?? []).flatMap { observation in
            observation.topCandidates(10).map { ($0.string, $0.confidence) }
          })
        observations.append(
          .init(
            recordingTimelineMilliseconds: milliseconds,
            output: candidate?.string ?? "", confidence: candidate?.confidence))
      }
    }
    return observations
  }

  package static func preferredCandidate(
    from candidates: [(string: String, confidence: Float)]
  ) -> (string: String, confidence: Float)? {
    candidates.map { candidate in
      (candidate.string.trimmingCharacters(in: .whitespacesAndNewlines), candidate.confidence)
    }.max { lhs, rhs in
      let lhsIsTimer = isValidTimer(lhs.0)
      let rhsIsTimer = isValidTimer(rhs.0)
      return lhsIsTimer == rhsIsTimer ? lhs.1 < rhs.1 : !lhsIsTimer && rhsIsTimer
    }
  }

  private static func isValidTimer(_ value: String) -> Bool {
    let parts = value.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
      parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
      let minutes = Int(parts[0]), let seconds = Int(parts[1]),
      (0...10).contains(minutes), (0...59).contains(seconds)
    else { return false }
    return minutes != 10 || seconds == 0
  }

  public static func sampleTimes(duration: Double, interval: Double) throws -> [CMTime] {
    guard interval.isFinite, interval >= 0.001 else {
      throw Error.message("Sample interval must be finite and at least 0.001 seconds")
    }
    guard duration.isFinite, duration > 0 else {
      throw Error.message("Main video duration must be finite and positive")
    }
    var times: [CMTime] = []
    var seconds = 0.0
    while seconds + interval <= duration {
      times.append(CMTime(seconds: seconds, preferredTimescale: 1_000))
      seconds += interval
    }
    if times.isEmpty { times.append(.zero) }
    return times
  }

  public static func timerRectangle(
    gameScreen: GameScreenRectangle, layout: MatchTimerLayout
  ) -> CGRect {
    let timer = layout.regions.matchTimer
    let reference = layout.referenceSize
    let scaleX = Double(gameScreen.width) / Double(reference.width)
    let scaleY = Double(gameScreen.height) / Double(reference.height)
    let scaledTimer = CGRect(
      x: Double(gameScreen.x) + Double(timer.x) * scaleX,
      y: Double(gameScreen.y) + Double(timer.y) * scaleY,
      width: Double(timer.width) * scaleX,
      height: Double(timer.height) * scaleY
    ).integral
    let gameScreenBounds = CGRect(
      x: gameScreen.x, y: gameScreen.y, width: gameScreen.width, height: gameScreen.height)
    return scaledTimer.intersection(gameScreenBounds)
  }

  private static func timerCrop(
    frame: CGImage, gameScreen: GameScreenRectangle, layout: MatchTimerLayout
  ) throws -> CGImage {
    try VideoFrameSupport.cropped(
      frame, rect: timerRectangle(gameScreen: gameScreen, layout: layout))
  }

  public enum Error: Swift.Error, CustomStringConvertible {
    case message(String)

    public var description: String {
      switch self {
      case .message(let value): value
      }
    }
  }
}
