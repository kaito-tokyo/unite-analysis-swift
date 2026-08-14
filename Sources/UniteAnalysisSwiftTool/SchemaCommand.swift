// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

struct Schema: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "schema",
    abstract: "Print a bundled JSON Schema selected by URL basename.",
    discussion: """
      Pass the basename of a supported $schema URL, for example contact-sheet.schema.json. The exact bundled schema is written to standard output. Use this command when the installed single binary must provide its own input or output contract without network access. An unknown basename is an error and lists every supported value.
      """.reflowedHelp()
  )

  @Argument(help: "Basename from a supported $schema URL.")
  var basename: String

  struct OutputRecord: @unchecked Sendable { let data: Data }

  func outputRecords() -> AsyncThrowingStream<OutputRecord, Error> {
    commandOutputStream { continuation in
      let command = self
      guard let data = EmbeddedSchemas.data(basename: command.basename) else {
        throw ValidationError(
          "Unknown schema basename '\(command.basename)'. Expected one of: "
            + EmbeddedSchemas.basenames.joined(separator: ", "))
      }
      continuation.yield(.init(data: data))
    }
  }
}

package enum EmbeddedSchemas {
  package static var basenames: [String] { schemas.keys.sorted() }

  package static func data(basename: String) -> Data? {
    schemas[basename].map { Data($0) }
  }

  private static let schemas: [String: [UInt8]] = [
    "asr-v1.input.schema.json": PackageResources.asr_v1_input_schema_json,
    "asr-v1.output.schema.json": PackageResources.asr_v1_output_schema_json,
    "audio-peaks-v1.output.schema.json": PackageResources.audio_peaks_v1_output_schema_json,
    "batch-frame.output.schema.json": PackageResources.batch_frame_output_schema_json,
    "batch-frame.schema.json": PackageResources.batch_frame_schema_json,
    "chroma-events-v1.output.schema.json": PackageResources.chroma_events_v1_output_schema_json,
    "contact-sheet.output.schema.json": PackageResources.contact_sheet_output_schema_json,
    "contact-sheet.schema.json": PackageResources.contact_sheet_schema_json,
    "event-detect-v1.input.schema.json": PackageResources.event_detect_v1_input_schema_json,
    "event-detect-v1.output.schema.json": PackageResources.event_detect_v1_output_schema_json,
    "frame-burst.output.schema.json": PackageResources.frame_burst_output_schema_json,
    "frame-burst.schema.json": PackageResources.frame_burst_schema_json,
    "loadout-v1.output.schema.json": PackageResources.loadout_v1_output_schema_json,
    "match-detection-v1.output.schema.json": PackageResources.match_detection_v1_output_schema_json,
    "match-layout-v1.schema.json": PackageResources.match_layout_v1_schema_json,
    "ocr-options-v1.schema.json": PackageResources.ocr_options_v1_schema_json,
    "ocr-v1.output.schema.json": PackageResources.ocr_v1_output_schema_json,
    "ocr-v1.schema.json": PackageResources.ocr_v1_schema_json,
    "publication.schema.json": PackageResources.publication_schema_json,
    "ranked-seasons.schema.json": PackageResources.ranked_seasons_schema_json,
    "scan-result-v1.output.schema.json": PackageResources.scan_result_v1_output_schema_json,
  ]
}
