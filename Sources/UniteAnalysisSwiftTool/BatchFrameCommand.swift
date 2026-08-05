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

private struct BatchFrameJobOutput: Encodable {
  static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/batch-frame.output.schema.json"

  struct Result: Encodable { let outputs: [String] }

  let schema = schemaURL
  let jobId: String
  let ok = true
  let result: Result

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case jobId, ok, result
  }
}

struct BatchFrame: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "batch-frame",
    abstract: "Write source-video screenshots from JSONL frame jobs.",
    discussion: """
      INPUT. Supply one jobs.jsonl path, or - for standard input. Each non-empty line is one JSON object requiring jobId, matchTimestamps, source, and outputPrefix. Relative paths use the current working directory. stdin is processed one line at a time without waiting for EOF.

      COMPLETE jobs.jsonl EXAMPLE.

      {"jobId":"game-frames","matchTimestamps":[-2,0,45.5],"source":{"x":0,"y":0,"width":1632,"height":918},"outputPrefix":"screenshots/game"}

      JOB-ID. jobId is a required non-empty caller-defined correlation string and must be unique within the input stream. It is returned unchanged and is never used to derive output filenames.

      TIMING. matchTimestamps must contain finite, strictly increasing seconds relative to match start. Negative values select pre-match frames. Values above the match duration select post-match frames. Duplicate or reverse values within a job are rejected before decoding.

      SOURCE. source is a top-left-origin {x,y,width,height} rectangle in main-video pixels. It is cropped without resizing.

      DECODING. Frames use AVAssetImageGenerator with its default time tolerance, so extraction is fast but not frame-exact. Decode failures never fall back to another image source. An unfinished recording is allowed with a warning, but callers should request only finalized time ranges.

      OUTPUT. Each job writes baseline 8-bit RGB JPEGs named <outputPrefix>-000001.jpg, <outputPrefix>-000002.jpg, and so on in matchTimestamps order. One JSON response line containing jobId, ok, and either result.outputs or error is written to stdout before the next job is read. A malformed line has no jobId when it cannot be recovered. One failed job does not stop later jobs or make the process fail; callers must inspect ok on every response. Without --force, any existing output or duplicate generated path is an error. With --force, every colliding path is overwritten.

      DIAGNOSTICS. The resolved record-spec.json and main video, unfinished-recording warnings, and each requested and actual source PTS are written to stderr. stdout contains JSONL responses only.

      SCHEMAS. Print the per-line input schema with `unite-analysis-swift schema batch-frame.schema.json` and the response schema with `unite-analysis-swift schema batch-frame.output.schema.json`.
      """.reflowedHelp()
  )

  @Argument(help: "jobs.jsonl path, or - to process standard input line by line.") var jobs: String
  @Option(help: "Required record-spec.json path. Run from the .ldtxrecord root.")
  var recordSpec: String

  @Option(help: "JPEG quality from 0 through 1.")
  var quality: Double = 0.6

  @Flag(help: "Overwrite every existing or duplicate generated output path.")
  var force = false

  mutating func run() async throws {
    guard quality.isFinite, (0...1).contains(quality) else {
      throw ValidationError("--quality must be a finite value from 0 through 1")
    }
    let writer = try JSONLResponseWriter()
    var jobIds = Set<String>()
    let count = try await forEachJSONLInputLine(jobs) { line in
      let recoveredJobId = jsonlJobID(in: line.data)
      do {
        if let recoveredJobId, !jobIds.insert(recoveredJobId).inserted {
          throw UniteAnalysisSwiftToolError.message("Duplicate jobId '\(recoveredJobId)'")
        }
        let job = try JSONDecoder().decode(BatchFrameJob.self, from: line.data)
        _ = try job.validatedMatchTimestamps()
        let prefixURL = resolvePath(job.outputPrefix)
        let requests = job.matchTimestamps.enumerated().map { index, matchTimestamp in
          let suffix = String(format: "-%06d.jpg", index + 1)
          return FrameRequest(
            scene: .matchRelative(matchTimestamp),
            source: job.source,
            outputURL: URL(fileURLWithPath: prefixURL.path + suffix).standardizedFileURL)
        }
        let outputs = try await renderFrames(
          recordSpecURL: resolveRecordSpec(recordSpec),
          requests: requests,
          quality: quality,
          force: force
        )
        try writer.write(
          BatchFrameJobOutput(jobId: job.jobId, result: .init(outputs: outputs)))
      } catch {
        try writeJSONLFailure(
          error, line: line, jobId: recoveredJobId, schema: BatchFrameJobOutput.schemaURL,
          to: writer)
      }
    }
    guard count > 0 else { throw ValidationError("jobs.jsonl contains no jobs") }
  }
}
