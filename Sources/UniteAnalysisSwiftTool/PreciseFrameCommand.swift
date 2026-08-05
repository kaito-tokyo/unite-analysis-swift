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

struct PreciseFrame: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "precise-frame",
    abstract: "Write exactly one AVAssetReader-decoded explicit-source screenshot.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because AVFoundation source-video decoding is unavailable in the sandboxed execution environment.

      INPUT. This command accepts options only and writes exactly one frame; it does not use the jobs.jsonl interface. Specify --record-spec, --match-timestamp, --x, --y, --width, --height, and --output. Run it with the .ldtxrecord root as the current directory; this caller responsibility is not checked separately.

      COMPLETE EXAMPLE.

      unite-analysis-swift precise-frame --record-spec _PokemonUniteMatches/match-01/record-spec.json --match-timestamp 45.5 --x 0 --y 0 --width 640 --height 360 --output screenshots/precise.jpg

      TIMING. --match-timestamp is one finite second value relative to match start. Negative values select pre-match frames. Values above the match duration select post-match frames. The resolved recording time must remain inside the source video.

      SOURCE. --x, --y, --width, and --height define a top-left-origin rectangle in main-video pixels. The rectangle is cropped without resizing.

      DECODING. AVAssetReader starts up to two seconds before the requested recording time and reads forward to the first decoded sample at or after it. This is the frame-exact alternative to batch-frame. Decode failures never fall back to another image source.

      OUTPUT. The command writes one baseline 8-bit RGB JPEG. Progressive JPEG is not used. The default quality is 0.6. An existing output is an error unless --force is supplied; --force overwrites it. Relative output paths use the current working directory.

      DIAGNOSTICS. The resolved record-spec.json and main video, unfinished-recording warnings, and requested and decoded source PTS are written to stderr. The generated output path is printed to stdout.
      """.reflowedHelp()
  )

  @Option(help: "Required record-spec.json path. Run from the .ldtxrecord root.")
  var recordSpec: String
  @Option(help: "Required finite seconds relative to match start.") var matchTimestamp: Double
  @Option(help: "Required source rectangle x in main-video pixels.") var x: Int
  @Option(help: "Required source rectangle y in main-video pixels.") var y: Int
  @Option(help: "Required source rectangle width in main-video pixels.") var width: Int
  @Option(help: "Required source rectangle height in main-video pixels.") var height: Int
  @Option(help: "Required JPEG output path.") var output: String
  @Option(help: "JPEG quality from 0 through 1.") var quality: Double = 0.6
  @Flag(help: "Overwrite the output if it already exists.") var force = false

  mutating func run() async throws {
    guard quality.isFinite, (0...1).contains(quality) else {
      throw ValidationError("--quality must be a finite value from 0 through 1")
    }
    guard matchTimestamp.isFinite else {
      throw ValidationError("--match-timestamp must be finite")
    }
    try await renderPreciseFrame(
      recordSpecURL: resolveRecordSpec(recordSpec),
      scene: .matchRelative(matchTimestamp),
      source: FrameSource(x: x, y: y, width: width, height: height),
      outputURL: resolvePath(output),
      quality: quality,
      force: force
    )
  }
}
