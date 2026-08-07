// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct SampleFrames: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "sample-frames",
    abstract: "Write one FFmpeg-shaped fixed-rate JPEG sequence.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because AVFoundation source-video decoding is unavailable in the sandboxed execution environment.

      PURPOSE. Generate one seek-image sequence before detect-chroma-events. The options intentionally correspond to one FFmpeg crop, fps, and scale filter chain. This command only extracts images; it does not measure chroma differences or select event candidates.

      COMPLETE EXAMPLE.

      unite-analysis swift sample-frames --record-spec _PokemonUniteMatches/match-01/record-spec.json --crop-x 430 --crop-y 105 --crop-width 800 --crop-height 115 --fps 2 --scale-x 400 --scale-y 58 --output sampled/top-event-banner/frame-%06d.jpg --quality 0.95

      INPUT. --record-spec identifies one match. Run from the .ldtxrecord root; this caller responsibility is not checked separately. Relative output paths use the current directory.

      FILTERS. --crop-x, --crop-y, --crop-width, and --crop-height map to FFmpeg crop=width:height:x:y in native main-video pixels. --fps maps to fps=fps. --scale-x and --scale-y are the exact output width and height and map to scale=scale-x:scale-y. A differing aspect ratio is intentionally stretched.

      TIMING. The complete record-spec match is sampled at index / fps, beginning at 0. AVAssetImageGenerator and FFmpeg may select adjacent source frames; approximate timing compatibility is sufficient.

      OUTPUT. --output must contain exactly one %06d placeholder and no other % character, directly matching an FFmpeg image-sequence output pattern. Numbering begins at 1. Output is baseline 8-bit RGB JPEG. --quality accepts a finite value from 0 through 1 and defaults to 0.95. Every collision is checked before decoding. Without --force, an existing output is an error. --force overwrites every generated path. Written paths go to standard output; requested match times and actual source PTS values go to standard error.

      EQUIVALENT FFMPEG SHAPE.

      -vf "crop=800:115:430:105,fps=2,scale=400:58" -start_number 1 sampled/top-event-banner/frame-%06d.jpg

      Using FFmpeg instead is supported. Both paths produce similarly framed JPEGs at the exact requested dimensions. FFmpeg quality can be adjusted with -q:v. Encoder, color-conversion, scaling, and seeking differences mean pixel values, JPEG bytes, and selected source frames are not guaranteed to be identical.
      """.reflowedHelp()
  )

  @Option(help: "Required record-spec.json path. Run from the .ldtxrecord root.")
  var recordSpec: String

  @Option(help: "Crop left edge; maps to crop x.") var cropX: Int
  @Option(help: "Crop top edge; maps to crop y.") var cropY: Int
  @Option(help: "Crop width; maps to crop width.") var cropWidth: Int
  @Option(help: "Crop height; maps to crop height.") var cropHeight: Int
  @Option(help: "Positive sampling rate; maps to the fps filter.") var fps: Double
  @Option(help: "Exact output width; maps to scale width.") var scaleX: Int
  @Option(help: "Exact output height; maps to scale height.") var scaleY: Int
  @Option(help: "JPEG sequence pattern containing exactly one %06d placeholder.")
  var output: String
  @Option(help: "JPEG quality from 0 through 1.") var quality = 0.95
  @Flag(help: "Overwrite every generated output path.") var force = false

  mutating func run() async throws {
    guard quality.isFinite, (0...1).contains(quality) else {
      throw ValidationError("--quality must be a finite value from 0 through 1")
    }
    try await renderSampleFrames(
      recordSpecURL: resolveRecordSpec(recordSpec),
      request: SampleFramesRequest(
        source: FrameSource(
          x: cropX, y: cropY, width: cropWidth, height: cropHeight),
        fps: fps,
        scaleX: scaleX,
        scaleY: scaleY,
        outputPattern: output),
      quality: quality,
      force: force)
  }
}
