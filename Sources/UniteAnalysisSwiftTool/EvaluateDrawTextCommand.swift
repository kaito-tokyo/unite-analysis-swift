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

struct EvaluateDrawText: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "eval-draw-text-script",
    abstract: "Evaluate one drawText JSC expression and print its resulting string.",
    discussion: """
      PURPOSE. Evaluate the exact JavaScript expression used as drawText.script.return without rendering a contact sheet. The converted string is written to stdout.

      COMPLETE EXAMPLE.

      unite-analysis-swift eval-draw-text-script '"#" + (FRAME.index + 1) + " / " + MATCH.duration' --record-spec _PokemonUniteMatches/match-01/record-spec.json --index 0 --inmatch 45.5

      INPUT. Pass the expression as the script argument, or pass - to read it from stdin. --record-spec is required. Run from the .ldtxrecord root; this caller responsibility is not checked separately.

      TIME. Specify exactly one of --inmatch, --before-start, or --after-end. Values are seconds in the corresponding match-relative domain.

      GLOBALS. The expression receives the same JSC globals as contact-sheet drawText.script: FRAME (index, inmatch, beforeStart, afterEnd), MATCH (duration), RECORD (matchId), and VIDEO (width, height, frameRate, duration). FRAME.index is set by --index and is zero-based.
      """.reflowedHelp()
  )

  @Argument(
    help:
      "JavaScript expression whose result is converted to text, or - to read from standard input.")
  var script: String
  @Option(help: "Required record-spec.json path. Run from the .ldtxrecord root.")
  var recordSpec: String
  @Option(help: "Zero-based FRAME.index.") var index = 0
  @Option(help: "Seconds elapsed from the match start.") var inmatch: Double?
  @Option(help: "Seconds before the match start.") var beforeStart: Double?
  @Option(help: "Seconds after the match end.") var afterEnd: Double?

  mutating func run() async throws {
    guard index >= 0 else { throw ValidationError("--index must be non-negative") }
    let result = try await DrawTextScriptEngine.evaluate(
      script: script == "-"
        ? String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) : script,
      recordSpecURL: resolveRecordSpec(recordSpec),
      index: index,
      inmatch: inmatch,
      beforeStart: beforeStart,
      afterEnd: afterEnd
    )
    print(result)
  }
}
