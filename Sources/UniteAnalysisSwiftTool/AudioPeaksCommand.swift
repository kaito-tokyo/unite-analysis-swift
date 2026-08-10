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

struct AudioPeaks: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "audio-peaks",
    abstract: "Print visually interesting recording-audio SE peak times as JSON.",
    discussion: """
      EXECUTION ENVIRONMENT. This command must run outside a sandbox because AVFoundation audio decoding is unavailable in the sandboxed execution environment.

      INPUT. --record-spec is required and identifies one match. Run the command with the recording format v2 .ldtxrecord root as the current directory; this caller responsibility is not checked separately. The command reads the audio track embedded in main.fragmented.mp4. That filename is fixed by format v2; LDTXRecordingMainMediaFile normally contains the same name but cannot select another input. Other format versions are rejected.

      COMPLETE EXAMPLE.

      unite-analysis-swift audio-peaks --record-spec _PokemonUniteMatches/match-01/record-spec.json --gain 1.0 --output _PokemonUniteAnalysis/matches/match-01/candidates/audio-peaks.json

      RANGE. The full record-spec match is always analyzed. There are no start or duration options. The detector reads 200ms before match start to preserve FIR history and 20ms after match end for local-maximum detection, but reports only peaks inside the match.

      DETECTOR. Audio is converted into a contiguous 10ms integer power grid and processed with a fixed 50ms-versus-200ms FIR. If decoded audio skips one or more grid blocks, the missing blocks receive zero energy at their derived timestamps so the FIR windows retain their fixed durations. --gain is a positive finite linear gain applied before Int16 power calculation; there is no automatic gain control. Detector windows, threshold, and peak separation are intentionally not configurable.

      CANDIDATES. Each detected peak is expanded by 0.5 seconds in both directions. Overlapping expanded ranges are united and clipped to the match. Peaks and merged ranges are only seek candidates for later source-video or contact-sheet analysis; they are never classified as KO, ping, announcement, or another event.

      OUTPUT. Pretty-printed JSON containing the original peaks and merged candidate ranges is always written to stdout. With --output, the identical complete JSON is also written atomically to the specified path after successful analysis. Existing output is rejected unless --force is supplied. Relative paths use the current working directory.

      COMPLETE OUTPUT EXAMPLE.

      {
        "$schema": "https://kaito-tokyo.github.io/unite-analysis-swift/audio-peaks.output.schema.json",
        "dilation": 0.5,
        "duration": 600,
        "gain": 1,
        "matchId": "match-01",
        "inmatchStart": 0,
        "intervals": [
          {
            "inmatchEnd": 46.6,
            "inmatchStart": 44.75,
            "peakCount": 2,
            "recordingPTSEnd": 59.1,
            "recordingPTSStart": 57.25,
            "strongestPeakInmatch": 46.1,
            "strongestPeakScore": 0.000031
          }
        ],
        "peaks": [
          {
            "inmatch": 45.25,
            "recordingPTS": 57.75,
            "score": 0.000018
          },
          {
            "inmatch": 46.1,
            "recordingPTS": 58.6,
            "score": 0.000031
          }
        ]
      }

      SCHEMA. Print the output schema with `unite-analysis-swift schema audio-peaks.output.schema.json`.

      DIAGNOSTICS. Resolved record-spec.json and audio paths and unfinished-recording warnings are written to stderr. Missing metadata or media, a v2 main media file without an audio track, and undecodable audio are errors.
      """.reflowedHelp()
  )

  @Option(help: "Required record-spec.json path. Run from the .ldtxrecord root.")
  var recordSpec: String

  @Option(help: "Fixed linear input gain applied before power calculation.")
  var gain = 1.0

  @Option(help: "JSON output path. The complete result is also written to stdout.")
  var output: String?

  @Flag(help: "Allow --output to replace an existing file atomically.")
  var force = false

  func validate() throws {
    guard gain.isFinite, gain > 0 else {
      throw ValidationError("--gain must be a finite value greater than zero")
    }
  }

}

extension AudioPeaks {
  typealias OutputRecord = AudioPeakDetectionResult

  func outputRecords() -> AsyncThrowingStream<OutputRecord, Error> {
    commandOutputStream { continuation in
      let command = self
      continuation.yield(try await command.result())
    }
  }

  private func result() async throws -> OutputRecord {
    let recordSpecURL = resolveRecordSpec(recordSpec)
    let spec = try JSONDecoder().decode(RecordSpec.self, from: Data(contentsOf: recordSpecURL))
    RecordVisionInputLogger.recordSpec(recordSpecURL)
    guard spec.startPTS.timescale > 0 else {
      throw UniteAnalysisSwiftToolError.message("startPTS.timescale must be positive")
    }
    guard spec.duration.isFinite, spec.duration > 0 else {
      throw UniteAnalysisSwiftToolError.message(
        "record-spec duration must be a positive finite value")
    }

    let bundleURL = try recordingBundle(above: recordSpecURL)
    if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path)
    {
      RecordVisionInputLogger.unfinishedRecording(bundleURL)
    }
    let audioURL = try AudioPeakDetector.audioURL(in: bundleURL)
    RecordVisionInputLogger.sourceAudio(audioURL)
    let result = try await AudioPeakDetector.detect(
      audioURL: audioURL,
      matchId: spec.matchId,
      matchStartPTS: CMTime(value: spec.startPTS.value, timescale: spec.startPTS.timescale),
      inmatchStart: 0,
      duration: spec.duration,
      gain: gain
    )
    return result
  }
}
