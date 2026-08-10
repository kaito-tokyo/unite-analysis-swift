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

struct ContactSheetJobOutput: Encodable {
  static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/contact-sheet.output.schema.json"

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

struct ContactSheet: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "contact-sheet",
    abstract: "Render source-video contact sheets from JSONL jobs.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because AVFoundation source-video decoding is unavailable in the sandboxed execution environment.

      INPUT. Supply one jobs.jsonl path, or - for standard input. Each non-empty line is one JSON object requiring jobId, output, cell {width,height}, columns, placements, and matchTimestamps. backgroundColor is optional. Relative paths use the current working directory. stdin is processed one line at a time without waiting for EOF.

      COMPLETE jobs.jsonl EXAMPLE.

      {"jobId":"overview","output":"contact-sheet.jpg","cell":{"width":320,"height":202},"columns":3,"backgroundColor":"#202020","placements":[{"source":{"x":0,"y":0,"width":640,"height":360},"destination":{"x":0,"y":0,"width":320,"height":180}},{"drawText":{"script":{"return":"FRAME.actualInmatch.toFixed(3)+'s'"},"x":8,"y":184,"fontSize":14,"color":"#FFFFFF","backgroundColor":"#000000CC","borderColor":"#FFFFFF"}}],"matchTimestamps":[-1,0,30,60]}

      JOB-ID. jobId is a required non-empty caller-defined correlation string and must be unique within the input stream. It is returned unchanged and is never used to derive the output filename.

      LAYOUT. One timestamp produces one cell. Cells fill rows from left to right. A fixed 8px #FF00FF gutter separates them. Output size is derived from cell, columns, and the timestamp count. Image source uses main-video pixels; destination uses cell-local, top-left-origin pixels.

      TEXT PLACEMENT. drawText accepts either a literal text string or a script object. Colors accept #RRGGBB or #RRGGBBAA. Optional backgroundColor fits the text with 4px padding; borderColor adds a 1px border. Placements are composited in array order.

      TIMING. matchTimestamps must contain finite, strictly increasing seconds relative to match start. Negative values select pre-match frames. Values above the match duration select post-match frames. Duplicate or reverse values are rejected before decoding. After adding record-spec startPTS, every requested source time must be in the half-open source-video range [0, duration). The first out-of-range request is reported as a validation error before AVAssetImageGenerator decoding begins.

      SCRIPT LABELS. A drawText script return expression is evaluated by JSC once per cell. Available globals are FRAME, MATCH, RECORD, and VIDEO. Use FRAME.actualInmatch for the decoded timestamp. FRAME.index is zero-based.

      OUTPUT. The command shares one AVAssetImageGenerator within each job and writes a baseline 8-bit RGB JPEG. One JSON response line containing jobId, ok, and either result.output or error is written to stdout before the next job is read. A malformed line has no jobId when it cannot be recovered. One failed job does not stop later jobs or make the process fail; callers must inspect ok on every response. Existing output is rejected unless --force is supplied. The filename extension does not change the JPEG format. stdout contains JSONL responses only.

      SCHEMAS. Print the per-line input schema with `unite-analysis-swift schema contact-sheet.schema.json` and the response schema with `unite-analysis-swift schema contact-sheet.output.schema.json`.
      """.reflowedHelp()
  )

  @Argument(help: "jobs.jsonl path, or - to process standard input line by line.")
  var jobs: String
  @Option(help: "Required record-spec.json path. Run from the .ldtxrecord root.")
  var recordSpec: String
  @Option(help: "JPEG quality from 0 through 1.") var quality: Double = 0.6
  @Flag(help: "Allow overwriting an existing output file.") var force = false

  func validate() throws {
    guard quality.isFinite, (0...1).contains(quality) else {
      throw ValidationError("--quality must be a finite value from 0 through 1")
    }
  }

}

extension ContactSheet {
  enum OutputRecord {
    case success(ContactSheetJobOutput)
    case failure(JSONLJobFailure)
  }

  func outputRecords() -> AsyncThrowingStream<OutputRecord, Error> {
    commandOutputStream { continuation in
      let command = self
      let prepared = try await ContactSheetGenerator.prepare(
        recordSpecURL: resolveRecordSpec(command.recordSpec))
      var jobIds = Set<String>()
      let count = try await forEachJSONLInputLine(command.jobs) { line in
        let recoveredJobId = jsonlJobID(in: line.data)
        do {
          if let recoveredJobId, !jobIds.insert(recoveredJobId).inserted {
            throw UniteAnalysisSwiftToolError.message("Duplicate jobId '\(recoveredJobId)'")
          }
          let definition = try JSONDecoder().decode(ContactSheetDefinition.self, from: line.data)
          guard let jobId = definition.jobId,
            !jobId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          else {
            throw UniteAnalysisSwiftToolError.message(
              "Each contact-sheet job requires a non-empty jobId")
          }
          guard let output = definition.output, !output.isEmpty else {
            throw UniteAnalysisSwiftToolError.message("Each contact-sheet job requires output")
          }
          let outputURL = resolvePath(output)
          try await ContactSheetGenerator.run(
            definitionData: try JSONEncoder().encode(definition),
            prepared: prepared,
            outputURL: outputURL,
            quality: command.quality,
            force: command.force
          )
          continuation.yield(
            .success(ContactSheetJobOutput(jobId: jobId, result: .init(output: outputURL.path))))
        } catch {
          continuation.yield(
            .failure(.init(line: line.number, jobId: recoveredJobId, error: error)))
        }
      }
      guard count > 0 else { throw ValidationError("jobs.jsonl contains no jobs") }
    }
  }
}
