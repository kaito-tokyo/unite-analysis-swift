// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import RecordVisionSupport

struct DetectChromaEvents: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "detect-chroma-events",
    abstract: "Measure temporal Cb and Cr differences in a JPEG sequence.",
    discussion: """
      INPUT. --input-sample-dir is required and must contain at least two JPEG files. Files whose extension is .jpg or .jpeg, case-insensitively, are processed in filename dictionary order. Use zero-padded sequence numbers such as frame-000001.jpg so dictionary order is also chronological order. Hidden files and other formats are ignored. Relative paths use the current working directory.

      COMPLETE EXAMPLE.

      unite-analysis-swift detect-chroma-events --input-sample-dir sampled/top-event-banner --fps 2 --output top-event-banner.chroma-events.json

      TIMING. --fps must match the value used to create the sequence. File index 0 represents match-relative time 0; subsequent files represent index / fps. Because the JPEG sequence contains no decoder timestamp metadata, requestedInmatch and actualInmatch are both set to this sequence-grid time.

      DETECTION. Every JPEG must have identical dimensions. Consecutive images are compared in the Cb and Cr planes at their stored resolution. Each absolute-difference plane receives an independent Otsu threshold. score is max(cbThreshold, crThreshold), allowing a change in either chroma plane to remain visible. Pixel-count fields are diagnostics.

      CANDIDATES. The output contains unfiltered measurements and does not decide which samples are events. Apply thresholds, ranking, time expansion, sorting, and duplicate removal afterward. Every retained time remains an unclassified seek index and must be checked against the source video.

      OUTPUT. --output is required. Existing output is rejected unless --force is supplied. The result records its schema URL, absolute input directory, input count and boundary filenames, fps, JPEG dimensions, and per-pair measurements. The absolute output path is printed to standard output.

      COMPLETE OUTPUT EXAMPLE.

      {
        "$schema": "https://kaito-tokyo.github.io/unite-analysis-swift/chroma-events.output.schema.json",
        "firstInputFilename": "frame-000001.jpg",
        "fps": 2,
        "inputSampleCount": 1200,
        "inputSampleDirectory": "/recording/sampled/top-event-banner",
        "lastInputFilename": "frame-001200.jpg",
        "sampledHeight": 58,
        "sampledWidth": 400,
        "samples": [
          {
            "actualInmatch": 0.5,
            "bothChangedPixelCount": 42,
            "cbChangedPixelCount": 110,
            "cbThreshold": 18,
            "changedPixelCount": 163,
            "crChangedPixelCount": 95,
            "crThreshold": 27,
            "requestedInmatch": 0.5,
            "score": 27
          }
        ]
      }

      SCHEMA. Print the output schema with `unite-analysis-swift schema chroma-events.output.schema.json`.
      """.reflowedHelp()
  )

  @Option(help: "Required directory containing a zero-padded JPEG sequence in dictionary order.")
  var inputSampleDir: String

  @Option(help: "Positive sequence rate used to assign index / fps times.")
  var fps: Double

  @Option(help: "Required JSON output path.")
  var output: String

  @Flag(help: "Overwrite the output if it already exists.")
  var force = false

  mutating func run() throws {
    guard fps.isFinite, fps > 0 else {
      throw ValidationError("--fps must be positive and finite")
    }
    let outputURL = resolvePath(output)
    try ChromaEventDetector.run(
      inputSampleDirectoryURL: resolvePath(inputSampleDir), fps: fps, outputURL: outputURL,
      force: force)
    print(outputURL.path)
  }
}
