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

struct ScanResultCommand: ParsableCommand {
  private enum ScreenType: String, ExpressibleByArgument, CaseIterable {
    case summary
    case battleData = "battle-data"
  }

  static let configuration = CommandConfiguration(
    commandName: "scan-result",
    abstract: "Scan Pokémon UNITE result and battle-data screens into JSON.",
    discussion: """
      INPUT. Supply one still image in which the cropped game screen fills the complete image. The OCR layout is scaled from its 1632x918 reference coordinates to the actual image dimensions. Resized game-screen images are accepted. Images containing margins or a surrounding composition remain invalid. PNG, JPEG, HEIC, TIFF, BMP, and GIF are accepted; only image index 0 is read. Videos and recording bundles are rejected.

      COMPLETE EXAMPLES.

      unite-analysis-swift scan-result result-summary.jpg --type summary --ocr-options ocr-options.json

      unite-analysis-swift scan-result battle-data.jpg --type battle-data --ocr-options ocr-options.json --output battle-data.json

      SCREEN TYPE. --type is required and selects summary or battle-data parsing. The command does not auto-detect a different type or emit both types. The requested type is returned even when its detection score is low; that condition is recorded in warnings.

      OCR OPTIONS. --ocr-options is a JSON dictionary keyed by globally unique OCR region names. scan-result requires result-screen.text, player-name, and result-screen.numeric. player-name is shared by every command that OCRs player names. Every selected entry requires a non-empty recognitionLanguages array of Apple Vision identifiers and may contain customWords. There is no fallback or implicit language list. Unrelated region entries and unrecognized fields are ignored. Relative paths use the current working directory.

      COMPLETE ocr-options.json EXAMPLE.

      {
        "$schema": "https://kaito-tokyo.github.io/unite-analysis-swift/ocr-options.schema.json",
        "result-screen.text": {
          "recognitionLanguages": ["ja-JP", "en-US"],
          "customWords": ["バトルデータ", "スコアの詳細"]
        },
        "player-name": {
          "recognitionLanguages": ["ja-JP", "en-US"],
          "customWords": ["うみれおん"]
        },
        "result-screen.numeric": {
          "recognitionLanguages": ["en-US"],
          "customWords": []
        }
      }

      SCHEMAS. Print the OCR options schema with `unite-analysis-swift schema ocr-options.schema.json` and the output schema with `unite-analysis-swift schema scan-result.output.schema.json`.

      OCR. Battle-data uses fixed-cell OCR. Summary combines full-screen and row OCR. Language correction is disabled for numeric and proper-name fields.

      ROWS. All recognized rows are returned. The highlighted cursor row is never treated as the operated player. A missing standalone score 0 is supplemented without confidence only when the other three values in the same row were recognized. Low-confidence player names must be verified from the image.

      OUTPUT. The result records its schema URL, absolute input path, generation time, selected OCR options, screen type, detection score, recognized values, confidence, raw OCR text, and warnings. Unrelated OCR option entries are not copied into the result. It does not invent video timestamps or scan metadata. Pretty-printed JSON is written to stdout when --output is omitted; otherwise the specified file is atomically replaced.

      COMPLETE OUTPUT SHAPE.

      {
        "$schema": "https://kaito-tokyo.github.io/unite-analysis-swift/scan-result.output.schema.json",
        "generatedAt": "2026-08-06T00:00:00Z",
        "input": "/recording/result-summary.jpg",
        "ocrOptions": {
          "player-name": {"customWords": ["うみれおん"], "recognitionLanguages": ["ja-JP", "en-US"]},
          "result-screen.numeric": {"customWords": [], "recognitionLanguages": ["en-US"]},
          "result-screen.text": {"customWords": ["スコアの詳細"], "recognitionLanguages": ["ja-JP", "en-US"]}
        },
        "screens": [{"detectionScore": 7, "kind": "summary", "rawText": [], "summary": []}],
        "warnings": ["The scanner returns all rows and never treats the highlighted cursor row as the local player."]
      }
      """.reflowedHelp()
  )

  @Argument(help: "Path to a still image filled by the cropped game screen.")
  var input: String

  @Option(help: "Screen layout to parse: summary or battle-data.")
  private var type: ScreenType

  @Option(help: "Required path to ocr-options.json. Relative paths use the current directory.")
  var ocrOptions: String

  @Option(help: "JSON path to replace atomically. Writes to stdout when omitted.")
  var output: String?

  mutating func run() throws {
    let options = try loadOCROptions(ocrOptions)
    _ = try requiredOCROptions(named: ScanResultOCRRegion.screenText, in: options)
    _ = try requiredOCROptions(named: ScanResultOCRRegion.playerName, in: options)
    _ = try requiredOCROptions(named: ScanResultOCRRegion.numeric, in: options)
    let resultType: ResultScreenType =
      switch type {
      case .summary: .summary
      case .battleData: .battleData
      }
    try ResultScannerRunner.run(
      input: input,
      type: resultType,
      ocrOptions: options,
      output: output)
  }
}
