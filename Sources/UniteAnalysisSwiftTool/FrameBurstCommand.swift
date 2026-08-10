// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoreGraphics
import CoreMedia
import Foundation
import LDTXRecordingSupport
import RecordVisionSupport

struct FrameBurstJob: Decodable {
  static let maximumOutputDimension = 32_768
  static let maximumOutputPixels = 64_000_000
  static let maximumFrameCount = 600

  let jobId: String
  let matchTimestamp: Double
  let source: FrameSource
  let frameCount: Int
  let decimate: Int?
  let columns: Int
  let cellWidth: Int
  let output: String

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case jobId, matchTimestamp, source, frameCount, decimate, columns, cellWidth, output
  }

  init(from decoder: Decoder) throws {
    try rejectUnknownKeys(
      from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
      context: "frame-burst")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    jobId = try container.decode(String.self, forKey: .jobId)
    matchTimestamp = try container.decode(Double.self, forKey: .matchTimestamp)
    source = try container.decode(FrameSource.self, forKey: .source)
    frameCount = try container.decode(Int.self, forKey: .frameCount)
    decimate = try container.decodeIfPresent(Int.self, forKey: .decimate)
    columns = try container.decode(Int.self, forKey: .columns)
    cellWidth = try container.decode(Int.self, forKey: .cellWidth)
    output = try container.decode(String.self, forKey: .output)
  }

  var decimation: Int { decimate ?? 1 }

  func validate() throws {
    guard !jobId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw UniteAnalysisSwiftToolError.message("Each frame-burst job requires a non-empty jobId")
    }
    guard matchTimestamp.isFinite else {
      throw UniteAnalysisSwiftToolError.message("matchTimestamp must be finite")
    }
    try source.validate()
    guard (1...Self.maximumFrameCount).contains(frameCount) else {
      throw UniteAnalysisSwiftToolError.message(
        "frameCount must be from 1 through \(Self.maximumFrameCount)")
    }
    guard decimation > 0 else {
      throw UniteAnalysisSwiftToolError.message("decimate must be positive")
    }
    guard columns > 0 else {
      throw UniteAnalysisSwiftToolError.message("columns must be positive")
    }
    guard cellWidth > 0 else {
      throw UniteAnalysisSwiftToolError.message("cellWidth must be positive")
    }
    guard columns <= Self.maximumOutputDimension,
      cellWidth <= Self.maximumOutputDimension
    else {
      throw UniteAnalysisSwiftToolError.message(
        "columns and cellWidth must not exceed \(Self.maximumOutputDimension)")
    }
    guard !output.isEmpty else {
      throw UniteAnalysisSwiftToolError.message("output must not be empty")
    }
    _ = try layoutDimensions()
  }

  func layoutDimensions() throws -> (cellHeight: Int, rows: Int, width: Int, height: Int) {
    let scaledHeight = Double(cellWidth) * Double(source.height) / Double(source.width)
    guard scaledHeight.isFinite, scaledHeight <= Double(Self.maximumOutputDimension) else {
      throw UniteAnalysisSwiftToolError.message("Derived cell height is too large")
    }
    let cellHeight = max(1, Int(scaledHeight.rounded()))
    let retainedCount = (frameCount - 1) / decimation + 1
    let rows = (retainedCount - 1) / columns + 1
    let gutter = 4
    let (cellWidthTotal, cellWidthOverflow) = columns.multipliedReportingOverflow(by: cellWidth)
    let (gutterWidth, gutterWidthOverflow) = (columns - 1).multipliedReportingOverflow(by: gutter)
    let (width, widthOverflow) = cellWidthTotal.addingReportingOverflow(gutterWidth)
    let (cellHeightTotal, cellHeightOverflow) = rows.multipliedReportingOverflow(by: cellHeight)
    let (gutterHeight, gutterHeightOverflow) = (rows - 1).multipliedReportingOverflow(by: gutter)
    let (height, heightOverflow) = cellHeightTotal.addingReportingOverflow(gutterHeight)
    guard !cellWidthOverflow, !gutterWidthOverflow, !widthOverflow,
      !cellHeightOverflow, !gutterHeightOverflow, !heightOverflow,
      width <= Self.maximumOutputDimension, height <= Self.maximumOutputDimension
    else {
      throw UniteAnalysisSwiftToolError.message(
        "Frame burst dimensions exceed \(Self.maximumOutputDimension)x\(Self.maximumOutputDimension)"
      )
    }
    let (pixelCount, pixelCountOverflow) = width.multipliedReportingOverflow(by: height)
    guard !pixelCountOverflow, pixelCount <= Self.maximumOutputPixels else {
      throw UniteAnalysisSwiftToolError.message(
        "Frame burst pixel count exceeds \(Self.maximumOutputPixels)")
    }
    return (cellHeight, rows, width, height)
  }
}

struct FrameBurstJobOutput: Encodable {
  static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/frame-burst.output.schema.json"

  struct Result: Encodable { let output: String }

  let schema = schemaURL
  let jobId: String
  let ok = true
  let result: Result

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case jobId, ok, result
  }
}

struct FrameBurst: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "frame-burst",
    abstract: "Render consecutive decoded source-frame bursts from JSONL jobs.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because AVFoundation source-video decoding is unavailable in the sandboxed execution environment.

      INPUT. Supply one jobs.jsonl path, or - for standard input. Each non-empty line is one JSON object requiring jobId, matchTimestamp, source, frameCount, columns, cellWidth, and output. decimate is optional and defaults to 1. Relative paths use the current working directory. stdin is processed one line at a time without waiting for EOF.

      COMPLETE jobs.jsonl EXAMPLE.

      {"jobId":"absol-499.2","matchTimestamp":499.2,"source":{"x":0,"y":0,"width":1632,"height":918},"frameCount":60,"decimate":2,"columns":8,"cellWidth":320,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/absol-499.2.jpg"}

      JOB-ID. jobId is a required non-empty caller-defined correlation string and must be unique within the input stream. It is returned unchanged and is never used to derive the output filename.

      PURPOSE. Use frame bursts to inspect sub-second motion such as facing changes, aim corrections, move startup, and hit confirmation. Every source-video sample is decoded in sequence; the command does not issue approximate seeks for individual cells.

      DECIMATION. frameCount is the number of consecutive source samples decoded and therefore defines the covered time span. decimate N retains source indices 0, N, 2N, and so on for display without changing that decoded span. Frames fill left to right and then top to bottom. Cell height is derived from source and cellWidth without distortion. A fixed 4px magenta gutter separates cells.

      TIMING. matchTimestamp is relative to match start. The first cell is the first decoded source sample at or after that time; every following cell is the next decoded video sample. Requested, first, and last source PTS are written to stderr.

      OUTPUT. Each job writes one baseline 8-bit RGB JPEG. One JSON response line containing jobId, ok, and either result.output or error is written to stdout before the next job is read. One failed job does not stop later jobs or make the process fail; callers must inspect ok on every response. Existing output is rejected unless --force is supplied. stdout contains JSONL responses only.

      SCHEMAS. Print the per-line input schema with `unite-analysis-swift schema frame-burst.schema.json` and the response schema with `unite-analysis-swift schema frame-burst.output.schema.json`.
      """.reflowedHelp()
  )

  @Argument(help: "jobs.jsonl path, or - to process standard input line by line.") var jobs: String
  @Option(help: "Required record-spec.json path. Run from the .ldtxrecord root.")
  var recordSpec: String
  @Option(help: "JPEG quality from 0 through 1.") var quality: Double = 0.8
  @Flag(help: "Overwrite an existing output file.") var force = false

  func validate() throws {
    guard quality.isFinite, (0...1).contains(quality) else {
      throw ValidationError("--quality must be a finite value from 0 through 1")
    }
  }

}

extension FrameBurst {
  enum OutputRecord {
    case success(FrameBurstJobOutput)
    case failure(JSONLJobFailure)
  }

  func outputRecords() -> AsyncThrowingStream<OutputRecord, Error> {
    commandOutputStream { continuation in
      let command = self
      let media = try await RecordingMediaContext.prepare(
        recordSpecURL: resolveRecordSpec(command.recordSpec))
      var jobIds = Set<String>()
      let count = try await forEachJSONLInputLine(command.jobs) { line in
        let recoveredJobId = jsonlJobID(in: line.data)
        do {
          if let recoveredJobId, !jobIds.insert(recoveredJobId).inserted {
            throw UniteAnalysisSwiftToolError.message("Duplicate jobId '\(recoveredJobId)'")
          }
          let job = try JSONDecoder().decode(FrameBurstJob.self, from: line.data)
          try job.validate()
          let outputURL = resolvePath(job.output)
          try await renderFrameBurst(
            job: job, media: media, outputURL: outputURL,
            quality: command.quality, force: command.force)
          continuation.yield(
            .success(FrameBurstJobOutput(jobId: job.jobId, result: .init(output: outputURL.path))))
        } catch {
          continuation.yield(
            .failure(.init(line: line.number, jobId: recoveredJobId, error: error)))
        }
      }
      guard count > 0 else { throw ValidationError("jobs.jsonl contains no jobs") }
    }
  }
}

private func renderFrameBurst(
  job: FrameBurstJob, media: RecordingMediaContext, outputURL: URL, quality: Double, force: Bool
) async throws {
  guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
    throw UniteAnalysisSwiftToolError.message(
      "Output collision: \(outputURL.path). Pass --force to overwrite.")
  }
  let spec = media.spec
  let extractor = media.extractor
  let requestedTime = CMTimeAdd(
    CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale),
    CMTime(seconds: job.matchTimestamp, preferredTimescale: spec.startPTS.timescale))
  guard CMTimeCompare(requestedTime, .zero) >= 0,
    CMTimeCompare(requestedTime, extractor.duration) < 0
  else { throw UniteAnalysisSwiftToolError.message("Frame burst starts outside the video range") }

  let layout = try job.layoutDimensions()
  let cellHeight = layout.cellHeight
  let rows = layout.rows
  let gutter = 4
  let width = layout.width
  let height = layout.height
  guard
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
  else { throw UniteAnalysisSwiftToolError.message("Could not allocate frame burst image") }
  context.setFillColor(CGColor(red: 0.063, green: 0.094, blue: 0.125, alpha: 1))
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
  for column in 1..<job.columns {
    let x = column * job.cellWidth + (column - 1) * gutter
    context.fill(CGRect(x: x, y: 0, width: gutter, height: height))
  }
  for row in 1..<rows {
    let y = row * cellHeight + (row - 1) * gutter
    context.fill(CGRect(x: 0, y: y, width: width, height: gutter))
  }

  var firstPTS: CMTime?
  var lastPTS: CMTime?
  try extractor.extractConsecutiveFrames(startingAt: requestedTime, count: job.frameCount) {
    index, frame, presentationTime in
    firstPTS = firstPTS ?? presentationTime
    lastPTS = presentationTime
    guard index.isMultiple(of: job.decimation) else { return }
    let cropped = try VideoFrameSupport.cropped(frame, rect: job.source.rect)
    let outputIndex = index / job.decimation
    let column = outputIndex % job.columns
    let row = outputIndex / job.columns
    let destination = CGRect(
      x: column * (job.cellWidth + gutter),
      y: height - (row + 1) * cellHeight - row * gutter,
      width: job.cellWidth, height: cellHeight)
    context.interpolationQuality = .high
    context.draw(cropped, in: destination)
  }
  guard let image = context.makeImage(), let firstPTS, let lastPTS else {
    throw UniteAnalysisSwiftToolError.message("Could not finalize frame burst image")
  }
  try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
  try VideoFrameSupport.writeBaselineJPEG(image, to: outputURL, quality: quality)
  FileHandle.standardError.write(
    Data(
      "unite-analysis-swift: frame burst requested PTS \(canonicalSeconds(requestedTime.seconds))s, first PTS \(canonicalSeconds(firstPTS.seconds))s, last PTS \(canonicalSeconds(lastPTS.seconds))s\n"
        .utf8))
}
