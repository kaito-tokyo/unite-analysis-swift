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

package struct UniteAnalysisSwiftCommand: ParsableCommand {
  package static let configuration = CommandConfiguration(
    commandName: "unite-analysis-swift",
    abstract: "Extract and analyze ポケモンユナイト recording and still-image data.",
    discussion: """
      Run record-based commands with the .ldtxrecord root as the current directory; this is the caller's responsibility and is not checked separately. Record-based commands require --record-spec for one match's record-spec.json. That file is the physical match-to-recording mapping used to locate the
      enclosing .ldtxrecord and its main video. JSON frame values are seconds relative to match
      start: negative values are before the match, and values above match duration are after it.
      Requires macOS 26 or later. OCR uses Apple Vision locally and accepts still images, while
      record-based extraction reads the main video. Commands print machine-readable results or output paths to stdout and diagnostics,
      resolved inputs, timestamps, and unfinished-recording warnings to stderr.
      The macOS PKG does not add this executable to PATH. In examples,
      `unite-analysis-swift` denotes the complete path to the executable inside
      Kaito-Tokyo Unite Analysis.app/Contents/MacOS.
      Commands that accept jobs use one JSON object per non-empty jobs.jsonl line. Pass - to process
      stdin one line at a time; every job requires a unique jobId echoed by its JSONL response.
      Commands that use AVFoundation media access or Apple Vision text recognition must run outside a sandbox; their individual help identifies this requirement. Audio peak detection uses recording format v2 main-media audio to propose visually interesting times; it does not classify events. Run `batch-frame --help`, `sample-frames --help`, `precise-frame --help`,
      `contact-sheet --help`, `frame-burst --help`, `detect-chroma-events --help`,
      `audio-peaks --help`, `extract-clip --help`, `ocr --help`, `scan-result --help`,
      `recognize-draft-loadout --help`, `recognize-blind-loadout --help`,
      `eval-draw-text-script --help`, `schema --help`, or `config --help`
      for their JSON and output contracts.
      """.reflowedHelp(),
    version: "0.1.4",
    subcommands: [
      BatchFrame.self, SampleFrames.self, PreciseFrame.self, ContactSheet.self,
      FrameBurst.self,
      DetectChromaEvents.self, AudioPeaks.self, ExtractClip.self, OCRCommand.self,
      ScanResultCommand.self,
      RecognizeDraftLoadout.self, RecognizeBlindLoadout.self,
      EvaluateDrawText.self, Schema.self, Config.self, MCPCommand.self,
    ]
  )

  package init() {}
}
