// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreMedia
import Foundation

public enum AudioPeakDetectorError: Error, CustomStringConvertible {
  case message(String)

  public var description: String {
    switch self {
    case .message(let value): value
    }
  }
}

public struct AudioPeak: Codable, Equatable, Sendable {
  public let recordingPTS: Double
  public let inmatch: Double
  public let score: Double

  package init(recordingPTS: Double, inmatch: Double, score: Double) {
    self.recordingPTS = recordingPTS
    self.inmatch = inmatch
    self.score = score
  }
}

public struct AudioPeakInterval: Codable, Equatable, Sendable {
  public let recordingPTSStart: Double
  public let recordingPTSEnd: Double
  public let inmatchStart: Double
  public let inmatchEnd: Double
  public let peakCount: Int
  public let strongestPeakInmatch: Double
  public let strongestPeakScore: Double
}

public struct AudioPeakDetectionResult: Codable, Equatable, Sendable {
  public static let schema =
    "https://kaito-tokyo.github.io/unite-analysis-swift/audio-peaks.output.schema.json"

  public let matchId: String
  public let inmatchStart: Double
  public let duration: Double
  public let gain: Double
  public let dilation: Double
  public let peaks: [AudioPeak]
  public let intervals: [AudioPeakInterval]

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case matchId, inmatchStart, duration, gain, dilation, peaks, intervals
  }

  public init(
    matchId: String,
    inmatchStart: Double,
    duration: Double,
    gain: Double,
    dilation: Double,
    peaks: [AudioPeak],
    intervals: [AudioPeakInterval]
  ) {
    self.matchId = matchId
    self.inmatchStart = inmatchStart
    self.duration = duration
    self.gain = gain
    self.dilation = dilation
    self.peaks = peaks
    self.intervals = intervals
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    matchId = try container.decode(String.self, forKey: .matchId)
    inmatchStart = try container.decode(Double.self, forKey: .inmatchStart)
    duration = try container.decode(Double.self, forKey: .duration)
    gain = try container.decode(Double.self, forKey: .gain)
    dilation = try container.decode(Double.self, forKey: .dilation)
    peaks = try container.decode([AudioPeak].self, forKey: .peaks)
    intervals = try container.decode([AudioPeakInterval].self, forKey: .intervals)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(Self.schema, forKey: .schema)
    try container.encode(matchId, forKey: .matchId)
    try container.encode(inmatchStart, forKey: .inmatchStart)
    try container.encode(duration, forKey: .duration)
    try container.encode(gain, forKey: .gain)
    try container.encode(dilation, forKey: .dilation)
    try container.encode(peaks, forKey: .peaks)
    try container.encode(intervals, forKey: .intervals)
  }
}

public enum AudioPeakDetector {
  // ポケモンユナイト-specific fixed detector. These are deliberately not CLI settings.
  package static let blockDuration = 0.010
  package static let fastBlockCount = 5
  package static let slowBlockCount = 20
  package static let minimumNormalizedRise = 0.000_005
  package static let minimumPeakSeparation = 0.75
  package static let peakDilation = 0.5

  public static func audioURL(in bundleURL: URL) throws -> URL {
    let infoURL = bundleURL.appendingPathComponent("Info.plist")
    guard let data = try? Data(contentsOf: infoURL),
      let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dictionary = plist as? [String: Any]
    else {
      throw AudioPeakDetectorError.message(
        "Could not read LDTX recording metadata: \(infoURL.path)")
    }

    let formatVersion = (dictionary["LDTXRecordingFormatVersion"] as? NSNumber)?.intValue
    guard formatVersion == 2 else {
      throw AudioPeakDetectorError.message(
        "audio-peaks requires LDTX recording format version 2: \(infoURL.path)")
    }

    // Recording format v2 defines the main media name independently of whether the redundant
    // LDTXRecordingMainMediaFile metadata is present.
    let relativePath = "main.fragmented.mp4"
    let audioURL = bundleURL.appendingPathComponent(relativePath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: audioURL.path) else {
      throw AudioPeakDetectorError.message(
        "Recording format v2 main media file was not found: \(audioURL.path)")
    }
    return audioURL
  }

  public static func detect(
    audioURL: URL,
    matchId: String,
    matchStartPTS: CMTime,
    inmatchStart: Double,
    duration: Double,
    gain: Double
  ) async throws -> AudioPeakDetectionResult {
    let matchStartSeconds = matchStartPTS.seconds
    let requestedStart = matchStartSeconds + inmatchStart
    let requestedEnd = requestedStart + duration
    let readStart = max(0, requestedStart - Double(slowBlockCount) * blockDuration)

    let asset = AVURLAsset(url: audioURL)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw AudioPeakDetectorError.message("No audio track: \(audioURL.path)")
    }
    let assetDuration = try await asset.load(.duration).seconds
    guard assetDuration.isFinite, requestedEnd <= assetDuration + blockDuration else {
      throw AudioPeakDetectorError.message(
        "Requested audio range [\(requestedStart), \(requestedEnd)) exceeds source duration \(assetDuration): \(audioURL.path)"
      )
    }
    let readEnd = min(assetDuration, requestedEnd + 2 * blockDuration)
    let readDuration = readEnd - readStart

    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      throw AudioPeakDetectorError.message(
        "Could not configure main-mix PCM decoding: \(audioURL.path)")
    }
    reader.add(output)
    reader.timeRange = CMTimeRange(
      start: CMTime(seconds: readStart, preferredTimescale: 48_000),
      duration: CMTime(seconds: readDuration, preferredTimescale: 48_000)
    )
    guard reader.startReading() else {
      throw AudioPeakDetectorError.message(
        "Could not start main-mix decoding: \(reader.error?.localizedDescription ?? "unknown error")"
      )
    }

    var accumulator: PCMBlockAccumulator?
    while let sampleBuffer = output.copyNextSampleBuffer() {
      guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
        let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
        stream.mSampleRate.isFinite,
        stream.mSampleRate > 0
      else {
        throw AudioPeakDetectorError.message("Decoded audio has no valid stream description")
      }
      if accumulator == nil {
        accumulator = PCMBlockAccumulator(
          sampleRate: stream.mSampleRate, gain: gain, readStart: readStart, readEnd: readEnd)
      }
      guard accumulator?.sampleRate == stream.mSampleRate else {
        throw AudioPeakDetectorError.message("Main-mix sample rate changed during decoding")
      }
      try accumulator?.append(sampleBuffer: sampleBuffer)
    }
    guard reader.status == .completed else {
      throw AudioPeakDetectorError.message(
        "Main-mix decoding failed: \(reader.error?.localizedDescription ?? "unknown error")")
    }
    guard var accumulator else {
      throw AudioPeakDetectorError.message("Main-mix decoding produced no PCM samples")
    }
    accumulator.finish()

    let peakIndices = peakIndices(
      blockEnergies: accumulator.blockEnergies,
      samplesPerBlock: accumulator.samplesPerBlock,
      blockPTS: accumulator.blockPTS,
      requestedStart: requestedStart,
      requestedEnd: requestedEnd
    )
    let scores = normalizedRiseScores(
      blockEnergies: accumulator.blockEnergies,
      samplesPerBlock: accumulator.samplesPerBlock
    )
    let peaks = peakIndices.map { index in
      AudioPeak(
        recordingPTS: accumulator.blockPTS[index],
        inmatch: accumulator.blockPTS[index] - matchStartSeconds,
        score: scores[index]
      )
    }
    let intervals = dilatedIntervals(
      peaks: peaks,
      matchStartSeconds: matchStartSeconds,
      requestedInmatchStart: inmatchStart,
      requestedInmatchEnd: inmatchStart + duration
    )
    return AudioPeakDetectionResult(
      matchId: matchId,
      inmatchStart: inmatchStart,
      duration: duration,
      gain: gain,
      dilation: peakDilation,
      peaks: peaks,
      intervals: intervals
    )
  }

  package static func dilatedIntervals(
    peaks: [AudioPeak],
    matchStartSeconds: Double,
    requestedInmatchStart: Double,
    requestedInmatchEnd: Double
  ) -> [AudioPeakInterval] {
    guard let first = peaks.first else { return [] }

    var intervals: [AudioPeakInterval] = []
    var start = max(requestedInmatchStart, first.inmatch - peakDilation)
    var end = min(requestedInmatchEnd, first.inmatch + peakDilation)
    var peakCount = 1
    var strongestPeak = first

    func interval() -> AudioPeakInterval {
      AudioPeakInterval(
        recordingPTSStart: matchStartSeconds + start,
        recordingPTSEnd: matchStartSeconds + end,
        inmatchStart: start,
        inmatchEnd: end,
        peakCount: peakCount,
        strongestPeakInmatch: strongestPeak.inmatch,
        strongestPeakScore: strongestPeak.score
      )
    }

    for peak in peaks.dropFirst() {
      let dilatedStart = max(requestedInmatchStart, peak.inmatch - peakDilation)
      let dilatedEnd = min(requestedInmatchEnd, peak.inmatch + peakDilation)
      if dilatedStart <= end {
        end = max(end, dilatedEnd)
        peakCount += 1
        if peak.score > strongestPeak.score {
          strongestPeak = peak
        }
      } else {
        intervals.append(interval())
        start = dilatedStart
        end = dilatedEnd
        peakCount = 1
        strongestPeak = peak
      }
    }
    intervals.append(interval())
    return intervals
  }

  package static func normalizedRiseScores(
    blockEnergies: [Int64], samplesPerBlock: Int
  ) -> [Double] {
    guard blockEnergies.count >= slowBlockCount, samplesPerBlock > 0 else {
      return Array(repeating: 0, count: blockEnergies.count)
    }
    let fullScale = Double(Int16.max) * Double(Int16.max)
    let denominator = Double(slowBlockCount * samplesPerBlock) * fullScale
    var scores = Array(repeating: 0.0, count: blockEnergies.count)
    for index in (slowBlockCount - 1)..<blockEnergies.count {
      var fastSum: Int64 = 0
      var slowSum: Int64 = 0
      for offset in 0..<fastBlockCount {
        fastSum += blockEnergies[index - offset]
      }
      for offset in 0..<slowBlockCount {
        slowSum += blockEnergies[index - offset]
      }
      let scaledRise = 4 * fastSum - slowSum
      if scaledRise > 0 {
        scores[index] = Double(scaledRise) / denominator
      }
    }
    return scores
  }

  package static func peakIndices(
    blockEnergies: [Int64],
    samplesPerBlock: Int,
    blockPTS: [Double],
    requestedStart: Double,
    requestedEnd: Double
  ) -> [Int] {
    let scores = normalizedRiseScores(
      blockEnergies: blockEnergies, samplesPerBlock: samplesPerBlock)
    guard scores.count == blockPTS.count, scores.count >= 3 else { return [] }
    var peaks: [Int] = []
    for index in 1..<(scores.count - 1) {
      let pts = blockPTS[index]
      guard pts >= requestedStart, pts < requestedEnd,
        scores[index] >= minimumNormalizedRise,
        scores[index] >= scores[index - 1],
        scores[index] > scores[index + 1]
      else { continue }
      if let previous = peaks.last, pts - blockPTS[previous] <= minimumPeakSeparation {
        if scores[index] > scores[previous] { peaks[peaks.count - 1] = index }
      } else {
        peaks.append(index)
      }
    }
    return peaks
  }
}

private struct PCMBlockAccumulator {
  let sampleRate: Double
  let samplesPerBlock: Int
  let gain: Double
  var blockEnergies: [Int64] = []
  var blockPTS: [Double] = []
  private var currentEnergy: Int64 = 0
  private var currentSampleCount = 0
  private var currentBlockIndex: Int64?
  private let firstExpectedBlockIndex: Int64
  private let endExpectedBlockIndex: Int64
  private var hasAppendedLeadingPadding = false

  init(sampleRate: Double, gain: Double, readStart: Double, readEnd: Double) {
    self.sampleRate = sampleRate
    self.samplesPerBlock = max(1, Int((sampleRate * AudioPeakDetector.blockDuration).rounded()))
    self.gain = gain
    self.firstExpectedBlockIndex = Int64(floor(readStart / AudioPeakDetector.blockDuration))
    self.endExpectedBlockIndex = Int64(ceil(readEnd / AudioPeakDetector.blockDuration))
  }

  mutating func append(sampleBuffer: CMSampleBuffer) throws {
    var blockBuffer: CMBlockBuffer?
    var bufferList = AudioBufferList(
      mNumberBuffers: 1,
      mBuffers: AudioBuffer(mNumberChannels: 0, mDataByteSize: 0, mData: nil)
    )
    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      sampleBuffer,
      bufferListSizeNeededOut: nil,
      bufferListOut: &bufferList,
      bufferListSize: MemoryLayout<AudioBufferList>.size,
      blockBufferAllocator: kCFAllocatorDefault,
      blockBufferMemoryAllocator: kCFAllocatorDefault,
      flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
      blockBufferOut: &blockBuffer
    )
    guard status == noErr,
      bufferList.mNumberBuffers == 1,
      let rawData = bufferList.mBuffers.mData
    else {
      throw AudioPeakDetectorError.message("Could not access interleaved PCM data")
    }
    let channels = Int(bufferList.mBuffers.mNumberChannels)
    guard channels > 0 else {
      throw AudioPeakDetectorError.message("Decoded PCM has no channels")
    }
    let values = rawData.assumingMemoryBound(to: Float.self)
    let valueCount = Int(bufferList.mBuffers.mDataByteSize) / MemoryLayout<Float>.size
    guard valueCount % channels == 0 else {
      throw AudioPeakDetectorError.message("Decoded PCM has an incomplete interleaved frame")
    }
    let frameCount = valueCount / channels
    let sampleBufferPTS = sampleBuffer.presentationTimeStamp.seconds
    for frame in 0..<frameCount {
      let samplePTS = sampleBufferPTS + Double(frame) / sampleRate
      let blockIndex = Int64(floor(samplePTS / AudioPeakDetector.blockDuration))
      if !hasAppendedLeadingPadding {
        AudioPeakDetector.appendZeroFilledBlocks(
          from: firstExpectedBlockIndex,
          to: blockIndex,
          blockEnergies: &blockEnergies,
          blockPTS: &blockPTS
        )
        hasAppendedLeadingPadding = true
      }
      if let currentBlockIndex, blockIndex != currentBlockIndex {
        finishCurrentBlock()
        AudioPeakDetector.appendZeroFilledGap(
          after: currentBlockIndex,
          before: blockIndex,
          blockEnergies: &blockEnergies,
          blockPTS: &blockPTS
        )
      }
      if currentBlockIndex == nil {
        currentBlockIndex = blockIndex
      }
      var mono = 0.0
      for channel in 0..<channels {
        mono += Double(values[frame * channels + channel])
      }
      mono = min(1, max(-1, mono / Double(channels) * gain))
      let integer = Int64((mono * Double(Int16.max)).rounded())
      currentEnergy += integer * integer
      currentSampleCount += 1
    }
  }

  mutating func finish() {
    let lastDecodedBlockIndex = currentBlockIndex
    finishCurrentBlock()
    guard let lastDecodedBlockIndex else { return }
    AudioPeakDetector.appendZeroFilledBlocks(
      from: lastDecodedBlockIndex + 1,
      to: endExpectedBlockIndex,
      blockEnergies: &blockEnergies,
      blockPTS: &blockPTS
    )
  }

  private mutating func finishCurrentBlock() {
    guard let currentBlockIndex, currentSampleCount > 0 else { return }
    // Seeking can begin or end inside a 10ms bucket. Normalize those edge buckets to
    // the fixed block size so the block grid and score remain independent of read range.
    let normalizedEnergy = currentEnergy * Int64(samplesPerBlock) / Int64(currentSampleCount)
    blockEnergies.append(normalizedEnergy)
    blockPTS.append((Double(currentBlockIndex) + 0.5) * AudioPeakDetector.blockDuration)
    currentEnergy = 0
    currentSampleCount = 0
    self.currentBlockIndex = nil
  }
}

extension AudioPeakDetector {
  package static func appendZeroFilledBlocks(
    from firstBlockIndex: Int64,
    to endBlockIndex: Int64,
    blockEnergies: inout [Int64],
    blockPTS: inout [Double]
  ) {
    guard firstBlockIndex < endBlockIndex else { return }
    for blockIndex in firstBlockIndex..<endBlockIndex {
      blockEnergies.append(0)
      blockPTS.append((Double(blockIndex) + 0.5) * blockDuration)
    }
  }

  package static func appendZeroFilledGap(
    after previousBlockIndex: Int64,
    before nextBlockIndex: Int64,
    blockEnergies: inout [Int64],
    blockPTS: inout [Double]
  ) {
    appendZeroFilledBlocks(
      from: previousBlockIndex + 1,
      to: nextBlockIndex,
      blockEnergies: &blockEnergies,
      blockPTS: &blockPTS
    )
  }
}
