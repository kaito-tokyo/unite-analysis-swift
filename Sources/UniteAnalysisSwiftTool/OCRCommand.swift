// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoreGraphics
import Foundation
import ResultScannerSupport

private struct OCRJob: Decodable {
  let jobId: String
  let input: String
  let source: FrameSource
  let region: String
  let type: OCRInputType

  func validate() throws {
    guard !jobId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw UniteAnalysisSwiftToolError.message("Each OCR job requires a non-empty jobId")
    }
    guard !input.isEmpty else {
      throw UniteAnalysisSwiftToolError.message("Each OCR job requires a non-empty input")
    }
    guard !region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw UniteAnalysisSwiftToolError.message("Each OCR job requires a non-empty region")
    }
    try source.validate()
  }
}

private struct OCRJobResult: Encodable {
  let input: String
  let source: FrameSource
  let region: String
  let type: OCRInputType
  let observations: [TextObservation]
  let values: [String]
}

private struct OCRCommandOutput: Encodable {
  static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/ocr.output.schema.json"

  let schema = schemaURL
  let jobId: String
  let ok = true
  let result: OCRJobResult

  private enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case jobId, ok, result
  }
}

struct OCRCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "ocr",
    abstract: "Recognize named still-image regions from JSONL jobs.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because Apple Vision text recognition is unavailable in the sandboxed execution environment.

      INPUT. Supply one jobs.jsonl path, or - for standard input. Each non-empty line is one JSON object requiring jobId, input, source, region, and type. Relative paths use the current working directory. stdin is processed one line at a time without waiting for EOF.

      COMPLETE jobs.jsonl EXAMPLE.

      {"jobId":"event-000001","input":"frames/event-000001.jpg","source":{"x":300,"y":80,"width":1030,"height":300},"region":"event-banner","type":"text"}
      {"jobId":"player-000001","input":"frames/result-000001.jpg","source":{"x":124,"y":210,"width":280,"height":52},"region":"player-name","type":"player-name"}

      JOB-ID. jobId is a required non-empty caller-defined correlation string and must be unique within the input stream. It is returned unchanged and is never used to derive paths or OCR settings.

      SOURCE. source is a top-left-origin {x,y,width,height} rectangle in input-image pixels. It must fit completely inside the decoded still image. PNG, JPEG, HEIC, TIFF, BMP, and GIF inputs are accepted. For an animated image, only image index 0 is read.

      REGION OPTIONS. region selects the same globally unique key from --ocr-options. Every selected entry requires recognitionLanguages and may contain customWords. There is no fallback. Unrelated option entries and unrecognized fields in them are ignored.

      TYPE. text returns recognized lines in reading order. player-name joins the recognized text and applies the shared player-name cleanup. numeric returns numeric tokens. Every result also retains the raw Vision observations and confidence values.

      OUTPUT. One JSON response line containing jobId, ok, and either result or error is written before the next job is read. A malformed line has no jobId when it cannot be recovered. One failed job does not stop later jobs or make the process fail; callers must inspect ok on every response. Each successful result records the absolute input path, source, region, type, raw observations, and interpreted values. Observation boxes are normalized within source and use Apple Vision's bottom-left origin; source itself uses top-left-origin input-image pixels. stdout is used when --output is omitted; otherwise all response lines are atomically written to that path after EOF.

      SCHEMAS. Print the per-line input schema with `unite-analysis-swift schema ocr.schema.json`, the response schema with `unite-analysis-swift schema ocr.output.schema.json`, and OCR option schema with `unite-analysis-swift schema ocr-options.schema.json`.
      """.reflowedHelp()
  )

  @Argument(help: "jobs.jsonl path, or - to process standard input line by line.")
  var jobs: String

  @Option(help: "Required path to ocr-options.json. Relative paths use the current directory.")
  var ocrOptions: String

  @Option(
    help: "JSONL path to replace atomically after EOF. Writes responses to stdout when omitted.")
  var output: String?

  mutating func run() async throws {
    let namedOptions = try loadOCROptions(ocrOptions)
    let writer = try JSONLResponseWriter(output: output)
    var jobIds = Set<String>()
    let count = try await forEachJSONLInputLine(jobs) { line in
      let recoveredJobId = jsonlJobID(in: line.data)
      do {
        if let recoveredJobId, !jobIds.insert(recoveredJobId).inserted {
          throw UniteAnalysisSwiftToolError.message("Duplicate jobId '\(recoveredJobId)'")
        }
        let job = try JSONDecoder().decode(OCRJob.self, from: line.data)
        try job.validate()
        let options = try requiredOCROptions(named: job.region, in: namedOptions)
        let inputURL = resolvePath(job.input)
        let image = try StillImageInput.load(inputURL)
        let rect = job.source.rect.integral
        guard rect.maxX <= CGFloat(image.width), rect.maxY <= CGFloat(image.height),
          let crop = image.cropping(to: rect)
        else {
          throw UniteAnalysisSwiftToolError.message(
            "OCR source is outside input image bounds: \(inputURL.path)")
        }
        let recognized = try OCRInput.recognize(crop, type: job.type, options: options)
        let result = OCRJobResult(
          input: inputURL.path,
          source: job.source,
          region: job.region,
          type: job.type,
          observations: recognized.observations,
          values: recognized.values
        )
        try writer.write(OCRCommandOutput(jobId: job.jobId, result: result))
      } catch {
        try writeJSONLFailure(
          error, line: line, jobId: recoveredJobId, schema: OCRCommandOutput.schemaURL,
          to: writer)
      }
    }
    guard count > 0 else { throw ValidationError("jobs.jsonl contains no jobs") }
    try writer.finish()
  }
}
