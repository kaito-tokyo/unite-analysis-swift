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
  package static let basenames = [
    "audio-peaks.output.schema.json",
    "batch-frame.schema.json",
    "batch-frame.output.schema.json",
    "chroma-events.output.schema.json",
    "event-detect.input.schema.json",
    "event-detect.output.schema.json",
    "contact-sheet.schema.json",
    "contact-sheet.output.schema.json",
    "frame-burst.schema.json",
    "frame-burst.output.schema.json",
    "loadout.output.schema.json",
    "ocr.schema.json",
    "ocr.output.schema.json",
    "ocr-options.schema.json",
    "publication.schema.json",
    "ranked-seasons.schema.json",
    "scan-result.output.schema.json",
  ]

  package static func data(basename: String) -> Data? {
    schemas[basename].map { Data($0.utf8) }
  }

  package static var storedBasenames: [String] { schemas.keys.sorted() }

  private static let schemas = [
    "ranked-seasons.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/ranked-seasons.schema.json",
      "title": "ポケモンユナイト ranked season registry",
      "type": "object",
      "additionalProperties": false,
      "required": ["$schema", "schemaVersion", "updatedAt", "timezone", "seasons"],
      "properties": {
        "$schema": { "const": "https://kaito-tokyo.github.io/unite-analysis-swift/ranked-seasons.schema.json" },
        "schemaVersion": { "const": 1 },
        "updatedAt": { "type": "string", "format": "date" },
        "timezone": { "const": "Asia/Tokyo" },
        "seasons": { "type": "array", "items": { "$ref": "#/$defs/season" } }
      },
      "$defs": {
        "season": {
          "type": "object",
          "additionalProperties": false,
          "required": ["season", "startsAt", "endsAt", "mapFormat", "folderName"],
          "properties": {
            "season": { "type": "integer", "minimum": 1 },
            "startsAt": { "type": "string", "format": "date-time" },
            "endsAt": { "type": "string", "format": "date-time" },
            "mapFormat": { "enum": ["groudon", "kyogre", "other"] },
            "folderName": {
              "type": "string",
              "pattern": "^Season-[1-9][0-9]*-[A-Za-z][A-Za-z0-9-]*$"
            }
          }
        }
      }
    }
    """#,
    "event-detect.input.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/event-detect.input.schema.json",
      "title": "unite-analysis-swift event-detect input",
      "type": "object",
      "additionalProperties": false,
      "required": ["audioPeaks", "chromaEvents", "ocrCandidates", "scheduledCandidates"],
      "properties": {
        "$schema": { "const": "https://kaito-tokyo.github.io/unite-analysis-swift/event-detect.input.schema.json" },
        "audioPeaks": { "type": "string", "minLength": 1 },
        "chromaEvents": { "type": "array", "items": { "$ref": "#/$defs/chromaInput" } },
        "ocrCandidates": { "type": "array", "items": { "$ref": "#/$defs/ocrCandidate" } },
        "scheduledCandidates": { "type": "array", "items": { "$ref": "#/$defs/scheduledCandidate" } }
      },
      "$defs": {
        "chromaInput": {
          "type": "object",
          "additionalProperties": false,
          "required": ["region", "path"],
          "properties": {
            "region": { "type": "string", "minLength": 1 },
            "path": { "type": "string", "minLength": 1 }
          }
        },
        "ocrCandidate": {
          "type": "object",
          "additionalProperties": false,
          "required": ["region", "inmatch", "value", "confidence"],
          "properties": {
            "region": { "type": "string", "minLength": 1 },
            "inmatch": { "type": "number", "minimum": 0 },
            "value": { "type": "string" },
            "confidence": {
              "type": "number",
              "minimum": 0,
              "maximum": 1,
              "description": "Apple Vision recognition confidence for this OCR observation, from 0 through 1."
            }
          }
        },
        "scheduledCandidate": {
          "type": "object",
          "additionalProperties": false,
          "required": ["inmatch", "label"],
          "properties": {
            "inmatch": { "type": "number", "minimum": 0 },
            "label": { "type": "string", "minLength": 1 }
          }
        }
      }
    }
    """#,
    "event-detect.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/event-detect.output.schema.json",
      "title": "unite-analysis-swift event-detect output",
      "type": "object",
      "required": ["$schema", "matchId", "duration", "candidates"],
      "properties": {
        "$schema": { "const": "https://kaito-tokyo.github.io/unite-analysis-swift/event-detect.output.schema.json" },
        "matchId": { "type": "string", "minLength": 1 },
        "duration": { "type": "number", "exclusiveMinimum": 0 },
        "candidates": { "type": "array", "items": { "$ref": "#/$defs/candidate" } }
      },
      "$defs": {
        "candidate": {
          "type": "object",
          "required": ["startInmatch", "endInmatch", "representativeInmatch", "constituents"],
          "properties": {
            "startInmatch": { "type": "number", "minimum": 0 },
            "endInmatch": { "type": "number", "minimum": 0 },
            "representativeInmatch": { "type": "number", "minimum": 0 },
            "constituents": { "type": "array", "minItems": 1, "items": { "$ref": "#/$defs/constituent" } }
          }
        },
        "constituent": {
          "type": "object",
          "required": ["source", "inmatch"],
          "properties": {
            "source": { "type": "string", "pattern": "^(audio|scheduled|chroma:.+|ocr:.+)$" },
            "inmatch": { "type": "number", "minimum": 0 },
            "score": {
              "type": "number",
              "minimum": 0,
              "description": "Source-native nonnegative ranking score for audio or chroma constituents; omitted for OCR and scheduled constituents. Scores from different sources or chroma regions are not comparable."
            },
            "value": { "type": "string" },
            "confidence": {
              "type": "number",
              "minimum": 0,
              "maximum": 1,
              "description": "Apple Vision recognition confidence for OCR constituents, from 0 through 1; omitted for audio, chroma, and scheduled constituents."
            }
          }
        }
      }
    }
    """#,
    "frame-burst.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/frame-burst.schema.json",
      "title": "unite-analysis-swift frame burst job",
      "type": "object",
      "additionalProperties": false,
      "required": ["jobId", "matchTimestamp", "source", "frameCount", "columns", "cellWidth", "output"],
      "properties": {
        "jobId": { "type": "string", "minLength": 1, "pattern": "\\S" },
        "matchTimestamp": { "type": "number" },
        "source": { "$ref": "#/$defs/rectangle" },
        "frameCount": { "type": "integer", "minimum": 1, "maximum": 600 },
        "decimate": { "type": "integer", "minimum": 1, "default": 1 },
        "labelFrames": {
          "type": "boolean",
          "default": false,
          "description": "Overlay each retained source index and actual match-relative timestamp."
        },
        "columns": { "type": "integer", "minimum": 1, "maximum": 32768 },
        "cellWidth": { "type": "integer", "minimum": 1, "maximum": 32768 },
        "output": { "type": "string", "minLength": 1 }
      },
      "$defs": {
        "rectangle": {
          "type": "object",
          "additionalProperties": false,
          "required": ["x", "y", "width", "height"],
          "properties": {
            "x": { "type": "integer", "minimum": 0 },
            "y": { "type": "integer", "minimum": 0 },
            "width": { "type": "integer", "minimum": 1 },
            "height": { "type": "integer", "minimum": 1 }
          }
        }
      }
    }
    """#,
    "frame-burst.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/frame-burst.output.schema.json",
      "title": "unite-analysis-swift frame-burst JSONL response",
      "oneOf": [{ "$ref": "#/$defs/success" }, { "$ref": "#/$defs/failure" }],
      "$defs": {
        "success": {
          "type": "object",
          "required": ["$schema", "jobId", "ok", "result"],
          "properties": {
            "$schema": { "const": "https://kaito-tokyo.github.io/unite-analysis-swift/frame-burst.output.schema.json" },
            "jobId": { "type": "string", "minLength": 1 },
            "ok": { "const": true },
            "result": {
              "type": "object",
              "required": ["output"],
              "properties": { "output": { "type": "string", "minLength": 1 } }
            }
          }
        },
        "failure": {
          "type": "object",
          "required": ["$schema", "ok", "error"],
          "properties": {
            "$schema": { "const": "https://kaito-tokyo.github.io/unite-analysis-swift/frame-burst.output.schema.json" },
            "jobId": { "type": "string" },
            "ok": { "const": false },
            "error": {
              "type": "object",
              "required": ["line", "message"],
              "properties": {
                "line": { "type": "integer", "minimum": 1 },
                "message": { "type": "string" }
              }
            }
          }
        }
      }
    }
    """#,
    "loadout.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/loadout.output.schema.json",
      "title": "ポケモンユナイト recognized loadout",
      "type": "object",
      "required": ["$schema", "format", "match_format", "video", "time_basis", "recognizer", "allies", "enemies"],
      "properties": {
        "$schema": { "const": "https://kaito-tokyo.github.io/unite-analysis-swift/loadout.output.schema.json" },
        "format": { "enum": ["pokemon-unite-draft-loadout-2", "pokemon-unite-blind-loadout-1"] },
        "match_format": { "enum": ["draft", "blind"] },
        "video": { "type": "string", "minLength": 1 },
        "final_prep_time": { "type": ["number", "null"] },
        "versus_time": { "type": ["number", "null"] },
        "prep_time": { "type": ["number", "null"] },
        "final_prep_presentation_time": { "type": ["number", "null"] },
        "versus_presentation_time": { "type": ["number", "null"] },
        "prep_presentation_time": { "type": ["number", "null"] },
        "time_basis": { "enum": ["match-relative", "recording-timeline"] },
        "recognizer": { "$ref": "#/$defs/recognizer" },
        "allies": { "type": "array", "items": { "$ref": "#/$defs/ally" } },
        "enemies": { "type": "array", "items": { "$ref": "#/$defs/enemy" } }
      },
      "$defs": {
        "recognizer": {
          "type": "object",
          "required": ["matching", "held_knn_ratio", "battle_knn_ratio", "selection_mode", "database_id", "database_created_at"],
          "properties": {
            "matching": { "type": "string" },
            "held_knn_ratio": { "type": "number" },
            "battle_knn_ratio": { "type": "number" },
            "selection_mode": { "type": "string" },
            "database_id": { "type": "string", "format": "uuid" },
            "database_created_at": { "type": "string", "format": "date-time" }
          }
        },
        "candidate": {
          "type": "object",
          "required": ["name", "score"],
          "properties": {
            "name": { "type": "string" },
            "score": {
              "type": "number",
              "description": "Unnormalized sum of surviving Lowe-ratio descriptor votes. Each vote is 1 - nearestDistance / secondNearestDistance; this orders candidates within one crop but is not a probability or a calibrated value comparable across crops or database revisions."
            }
          }
        },
        "recognizedItem": {
          "type": "object",
          "required": ["candidates"],
          "properties": {
            "name": {
              "type": ["string", "null"],
              "description": "Top candidate name, or null when evidence is below one vote, the top score is less than twice the runner-up score, or an allied player's independently accepted held-item slots select the same item."
            },
            "score": {
              "type": ["number", "null"],
              "description": "Top candidate unnormalized vote sum, retained even when name is null; null only when there are no candidates."
            },
            "candidates": { "type": "array", "items": { "$ref": "#/$defs/candidate" } }
          }
        },
        "declaredRoute": {
          "type": "object",
          "required": ["method", "chromatic_fraction"],
          "properties": {
            "name": {
              "type": ["string", "null"],
              "description": "Declared route, or null for low chromatic coverage or a median hue farther than 24.5 OpenCV hue units from every route reference."
            },
            "method": { "const": "hsv" },
            "median_hue": { "type": ["number", "null"] },
            "chromatic_fraction": { "type": "number" }
          }
        },
        "ally": {
          "type": "object",
          "required": ["slot", "held_items", "battle_item", "declared_route"],
          "properties": {
            "slot": { "type": "integer", "minimum": 1 },
            "held_items": { "type": "array", "items": { "$ref": "#/$defs/recognizedItem" } },
            "battle_item": { "$ref": "#/$defs/recognizedItem" },
            "declared_route": { "$ref": "#/$defs/declaredRoute" }
          }
        },
        "enemy": {
          "type": "object",
          "required": ["slot", "battle_item"],
          "properties": {
            "slot": { "type": "integer", "minimum": 1 },
            "battle_item": { "$ref": "#/$defs/recognizedItem" }
          }
        }
      }
    }
    """#,
    "publication.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/publication.schema.json",
      "title": "ポケモンユナイト match publication state",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "$schema",
        "schemaVersion",
        "updatedAt"
      ],
      "properties": {
        "$schema": {
          "const": "https://kaito-tokyo.github.io/unite-analysis-swift/publication.schema.json"
        },
        "schemaVersion": {
          "const": 1
        },
        "updatedAt": {
          "type": "string",
          "format": "date-time"
        },
        "obsidianMatchReports": {
          "$ref": "#/$defs/filePublication"
        },
        "googleDrive": {
          "$ref": "#/$defs/googleDrivePublication"
        }
      },
      "$defs": {
        "filePublication": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "lastRelativePath",
            "syncedAt",
            "sourceReportUpdatedAt"
          ],
          "properties": {
            "lastRelativePath": {
              "type": "string",
              "minLength": 1
            },
            "syncedAt": {
              "type": "string",
              "format": "date-time"
            },
            "sourceReportUpdatedAt": {
              "type": "string",
              "format": "date-time"
            }
          }
        },
        "googleDrivePublication": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "documentId",
            "lastRelativePath",
            "syncedAt",
            "sourceReportUpdatedAt"
          ],
          "properties": {
            "documentId": {
              "type": "string",
              "minLength": 1
            },
            "lastRelativePath": {
              "type": "string",
              "minLength": 1
            },
            "syncedAt": {
              "type": "string",
              "format": "date-time"
            },
            "sourceReportUpdatedAt": {
              "type": "string",
              "format": "date-time"
            },
            "validatedAt": {
              "type": "string",
              "format": "date-time"
            },
            "dailyPdfValidatedAt": {
              "type": "string",
              "format": "date-time"
            }
          }
        }
      }
    }
    """#,
    "scan-result.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/scan-result.output.schema.json",
      "title": "unite-analysis-swift scan-result output",
      "type": "object",
      "required": ["$schema", "input", "generatedAt", "ocrOptions", "screens", "warnings"],
      "properties": {
        "$schema": {
          "const": "https://kaito-tokyo.github.io/unite-analysis-swift/scan-result.output.schema.json"
        },
        "input": { "type": "string", "minLength": 1 },
        "generatedAt": { "type": "string", "format": "date-time" },
        "ocrOptions": {
          "type": "object",
          "patternProperties": { ".*": { "$ref": "#/$defs/ocrOptions" } }
        },
        "screens": {
          "type": "array",
          "minItems": 1,
          "items": { "$ref": "#/$defs/screen" }
        },
        "warnings": { "type": "array", "items": { "type": "string" } }
      },
      "$defs": {
        "ocrOptions": {
          "type": "object",
          "required": ["recognitionLanguages"],
          "properties": {
            "recognitionLanguages": {
              "type": "array",
              "minItems": 1,
              "items": { "type": "string", "minLength": 1 }
            },
            "customWords": { "type": "array", "items": { "type": "string" } }
          }
        },
        "box": {
          "type": "object",
          "required": ["x", "y", "width", "height"],
          "properties": {
            "x": { "type": "number" },
            "y": { "type": "number" },
            "width": { "type": "number" },
            "height": { "type": "number" }
          }
        },
        "observation": {
          "type": "object",
          "required": ["text", "confidence", "box"],
          "properties": {
            "text": { "type": "string" },
            "confidence": {
              "type": "number",
              "minimum": 0,
              "maximum": 1,
              "description": "Apple Vision recognition confidence for the raw text observation, from 0 through 1."
            },
            "box": { "$ref": "#/$defs/box" }
          }
        },
        "cell": {
          "type": "object",
          "required": ["alternatives", "inferred"],
          "properties": {
            "text": { "type": "string" },
            "confidence": {
              "type": "number",
              "minimum": 0,
              "maximum": 1,
              "description": "Maximum Apple Vision recognition confidence across all observations in the cell crop, from 0 through 1; it may belong to a different observation than the selected text and is omitted when unavailable or inferred."
            },
            "alternatives": { "type": "array", "items": { "type": "string" } },
            "inferred": {
              "type": "boolean",
              "description": "True only when the value was inferred rather than observed by OCR."
            }
          }
        },
        "battleDataRow": {
          "type": "object",
          "required": ["side", "row", "name", "damageDealt", "damageTaken", "healing"],
          "properties": {
            "side": { "type": "string" },
            "row": { "type": "integer" },
            "name": { "$ref": "#/$defs/cell" },
            "damageDealt": { "$ref": "#/$defs/cell" },
            "damageTaken": { "$ref": "#/$defs/cell" },
            "healing": { "$ref": "#/$defs/cell" }
          }
        },
        "summaryRow": {
          "type": "object",
          "required": ["side", "row", "name", "scored", "knockouts", "assists", "rating"],
          "properties": {
            "side": { "type": "string" },
            "row": { "type": "integer" },
            "name": { "$ref": "#/$defs/cell" },
            "scored": { "$ref": "#/$defs/cell" },
            "knockouts": { "$ref": "#/$defs/cell" },
            "assists": { "$ref": "#/$defs/cell" },
            "rating": { "$ref": "#/$defs/cell" }
          }
        },
        "screen": {
          "type": "object",
          "required": ["kind", "detectionScore", "rawText"],
          "properties": {
            "kind": { "enum": ["summary", "battleData"] },
            "detectionScore": {
              "type": "integer",
              "description": "Unnormalized screen-layout evidence score from recognized keywords and numeric-token count; it is diagnostic and not a probability."
            },
            "rawText": { "type": "array", "items": { "$ref": "#/$defs/observation" } },
            "battleData": {
              "type": "array",
              "items": { "$ref": "#/$defs/battleDataRow" }
            },
            "summary": { "type": "array", "items": { "$ref": "#/$defs/summaryRow" } }
          }
        }
      }
    }
    """#,
    "audio-peaks.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/audio-peaks.output.schema.json",
      "title": "unite-analysis-swift audio-peaks output",
      "type": "object",
      "required": [
        "$schema",
        "matchId",
        "inmatchStart",
        "duration",
        "gain",
        "dilation",
        "peaks",
        "intervals"
      ],
      "properties": {
        "$schema": {
          "const": "https://kaito-tokyo.github.io/unite-analysis-swift/audio-peaks.output.schema.json"
        },
        "matchId": {
          "type": "string",
          "minLength": 1
        },
        "inmatchStart": {
          "type": "number"
        },
        "duration": {
          "type": "number",
          "exclusiveMinimum": 0
        },
        "gain": {
          "type": "number",
          "exclusiveMinimum": 0
        },
        "dilation": {
          "const": 0.5
        },
        "peaks": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/peak"
          }
        },
        "intervals": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/interval"
          }
        }
      },
      "$defs": {
        "peak": {
          "type": "object",
          "required": [
            "recordingPTS",
            "inmatch",
            "score"
          ],
          "properties": {
            "recordingPTS": {
              "type": "number",
              "minimum": 0
            },
            "inmatch": {
              "type": "number"
            },
            "score": {
              "type": "number",
              "minimum": 0,
              "description": "Nonnegative fixed-window audio power-rise score after applying gain; it ranks peaks within this analysis and is not an event probability."
            }
          }
        },
        "interval": {
          "type": "object",
          "required": [
            "recordingPTSStart",
            "recordingPTSEnd",
            "inmatchStart",
            "inmatchEnd",
            "peakCount",
            "strongestPeakInmatch",
            "strongestPeakScore"
          ],
          "properties": {
            "recordingPTSStart": {
              "type": "number",
              "minimum": 0
            },
            "recordingPTSEnd": {
              "type": "number",
              "minimum": 0
            },
            "inmatchStart": {
              "type": "number"
            },
            "inmatchEnd": {
              "type": "number"
            },
            "peakCount": {
              "type": "integer",
              "minimum": 1
            },
            "strongestPeakInmatch": {
              "type": "number"
            },
            "strongestPeakScore": {
              "type": "number",
              "minimum": 0
            }
          }
        }
      }
    }
    """#,
    "batch-frame.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/batch-frame.schema.json",
      "title": "unite-analysis-swift batch frame job",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "jobId",
        "matchTimestamps",
        "source",
        "outputPrefix"
      ],
      "properties": {
        "jobId": {
          "type": "string",
          "minLength": 1,
          "pattern": "\\S"
        },
        "matchTimestamps": {
          "type": "array",
          "minItems": 1,
          "description": "Finite, strictly increasing seconds relative to match start; negative values select pre-match frames and values above match duration select post-match frames.",
          "items": {
            "type": "number"
          }
        },
        "source": {
          "$ref": "#/$defs/rectangle"
        },
        "outputPrefix": {
          "type": "string",
          "minLength": 1
        }
      },
      "$defs": {
        "rectangle": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "x",
            "y",
            "width",
            "height"
          ],
          "properties": {
            "x": {
              "type": "integer",
              "minimum": 0
            },
            "y": {
              "type": "integer",
              "minimum": 0
            },
            "width": {
              "type": "integer",
              "minimum": 1
            },
            "height": {
              "type": "integer",
              "minimum": 1
            }
          }
        }
      }
    }
    """#,
    "batch-frame.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/batch-frame.output.schema.json",
      "title": "unite-analysis-swift batch-frame JSONL response",
      "oneOf": [
        {
          "$ref": "#/$defs/success"
        },
        {
          "$ref": "#/$defs/failure"
        }
      ],
      "$defs": {
        "success": {
          "type": "object",
          "required": [
            "$schema",
            "jobId",
            "ok",
            "result"
          ],
          "properties": {
            "$schema": {
              "const": "https://kaito-tokyo.github.io/unite-analysis-swift/batch-frame.output.schema.json"
            },
            "jobId": {
              "type": "string",
              "minLength": 1
            },
            "ok": {
              "const": true
            },
            "result": {
              "type": "object",
              "required": [
                "outputs"
              ],
              "properties": {
                "outputs": {
                  "type": "array",
                  "minItems": 1,
                  "items": {
                    "type": "string"
                  }
                }
              }
            }
          }
        },
        "failure": {
          "$ref": "#/$defs/failureBase"
        },
        "failureBase": {
          "type": "object",
          "required": [
            "$schema",
            "ok",
            "error"
          ],
          "properties": {
            "$schema": {
              "const": "https://kaito-tokyo.github.io/unite-analysis-swift/batch-frame.output.schema.json"
            },
            "jobId": {
              "type": "string"
            },
            "ok": {
              "const": false
            },
            "error": {
              "type": "object",
              "required": [
                "line",
                "message"
              ],
              "properties": {
                "line": {
                  "type": "integer",
                  "minimum": 1
                },
                "message": {
                  "type": "string"
                }
              }
            }
          }
        }
      }
    }
    """#,
    "contact-sheet.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/contact-sheet.schema.json",
      "title": "unite-analysis-swift contact sheet job",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "jobId",
        "cell",
        "columns",
        "placements",
        "matchTimestamps",
        "output"
      ],
      "properties": {
        "jobId": {
          "type": "string",
          "minLength": 1,
          "pattern": "\\S"
        },
        "cell": {
          "$ref": "#/$defs/size"
        },
        "columns": {
          "type": "integer",
          "minimum": 1
        },
        "backgroundColor": {
          "type": "string",
          "pattern": "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"
        },
        "placements": {
          "type": "array",
          "minItems": 1,
          "items": {
            "$ref": "#/$defs/placement"
          }
        },
        "matchTimestamps": {
          "type": "array",
          "minItems": 1,
          "description": "Finite, strictly increasing seconds relative to match start; negative values select pre-match frames and values above match duration select post-match frames.",
          "items": {
            "type": "number"
          }
        },
        "output": {
          "type": "string",
          "minLength": 1
        }
      },
      "$defs": {
        "size": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "width",
            "height"
          ],
          "properties": {
            "width": {
              "type": "integer",
              "minimum": 1
            },
            "height": {
              "type": "integer",
              "minimum": 1
            }
          }
        },
        "rectangle": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "x",
            "y",
            "width",
            "height"
          ],
          "properties": {
            "x": {
              "type": "integer",
              "minimum": 0
            },
            "y": {
              "type": "integer",
              "minimum": 0
            },
            "width": {
              "type": "integer",
              "minimum": 1
            },
            "height": {
              "type": "integer",
              "minimum": 1
            }
          }
        },
        "placement": {
          "oneOf": [
            {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "source",
                "destination"
              ],
              "properties": {
                "source": {
                  "$ref": "#/$defs/rectangle"
                },
                "destination": {
                  "$ref": "#/$defs/rectangle"
                }
              }
            },
            {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "drawText"
              ],
              "properties": {
                "drawText": {
                  "$ref": "#/$defs/drawText"
                }
              }
            }
          ]
        },
        "drawText": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "x",
            "y",
            "fontSize"
          ],
          "properties": {
            "text": {
              "type": "string"
            },
            "script": {
              "type": "object",
              "additionalProperties": false,
              "required": [
                "return"
              ],
              "properties": {
                "return": {
                  "type": "string"
                }
              }
            },
            "x": {
              "type": "integer",
              "minimum": 0
            },
            "y": {
              "type": "integer",
              "minimum": 0
            },
            "fontSize": {
              "type": "number",
              "exclusiveMinimum": 0
            },
            "color": {
              "type": "string",
              "pattern": "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"
            },
            "backgroundColor": {
              "type": "string",
              "pattern": "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"
            },
            "borderColor": {
              "type": "string",
              "pattern": "^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"
            },
            "fontName": {
              "type": "string"
            }
          },
          "oneOf": [
            {
              "required": [
                "text"
              ]
            },
            {
              "required": [
                "script"
              ]
            }
          ]
        }
      }
    }
    """#,
    "contact-sheet.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/contact-sheet.output.schema.json",
      "title": "unite-analysis-swift contact-sheet JSONL response",
      "oneOf": [
        {
          "$ref": "#/$defs/success"
        },
        {
          "$ref": "#/$defs/failure"
        }
      ],
      "$defs": {
        "success": {
          "type": "object",
          "required": [
            "$schema",
            "jobId",
            "ok",
            "result"
          ],
          "properties": {
            "$schema": {
              "const": "https://kaito-tokyo.github.io/unite-analysis-swift/contact-sheet.output.schema.json"
            },
            "jobId": {
              "type": "string",
              "minLength": 1
            },
            "ok": {
              "const": true
            },
            "result": {
              "type": "object",
              "required": [
                "output"
              ],
              "properties": {
                "output": {
                  "type": "string",
                  "minLength": 1
                }
              }
            }
          }
        },
        "failure": {
          "type": "object",
          "required": [
            "$schema",
            "ok",
            "error"
          ],
          "properties": {
            "$schema": {
              "const": "https://kaito-tokyo.github.io/unite-analysis-swift/contact-sheet.output.schema.json"
            },
            "jobId": {
              "type": "string"
            },
            "ok": {
              "const": false
            },
            "error": {
              "type": "object",
              "required": [
                "line",
                "message"
              ],
              "properties": {
                "line": {
                  "type": "integer",
                  "minimum": 1
                },
                "message": {
                  "type": "string"
                }
              }
            }
          }
        }
      }
    }
    """#,
    "ocr.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/ocr.schema.json",
      "title": "unite-analysis-swift OCR job",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "jobId",
        "input",
        "source",
        "region",
        "type"
      ],
      "properties": {
        "jobId": {
          "type": "string",
          "minLength": 1,
          "pattern": "\\S"
        },
        "input": {
          "type": "string",
          "minLength": 1
        },
        "source": {
          "$ref": "#/$defs/rectangle"
        },
        "region": {
          "type": "string",
          "minLength": 1
        },
        "type": {
          "enum": [
            "text",
            "player-name",
            "numeric"
          ]
        }
      },
      "$defs": {
        "rectangle": {
          "type": "object",
          "additionalProperties": false,
          "required": [
            "x",
            "y",
            "width",
            "height"
          ],
          "properties": {
            "x": {
              "type": "integer",
              "minimum": 0
            },
            "y": {
              "type": "integer",
              "minimum": 0
            },
            "width": {
              "type": "integer",
              "minimum": 1
            },
            "height": {
              "type": "integer",
              "minimum": 1
            }
          }
        }
      }
    }
    """#,
    "ocr.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/ocr.output.schema.json",
      "title": "unite-analysis-swift OCR JSONL response",
      "oneOf": [
        {
          "$ref": "#/$defs/success"
        },
        {
          "$ref": "#/$defs/failure"
        }
      ],
      "$defs": {
        "rectangle": {
          "type": "object",
          "required": [
            "x",
            "y",
            "width",
            "height"
          ],
          "properties": {
            "x": {
              "type": "integer",
              "minimum": 0
            },
            "y": {
              "type": "integer",
              "minimum": 0
            },
            "width": {
              "type": "integer",
              "minimum": 1
            },
            "height": {
              "type": "integer",
              "minimum": 1
            }
          }
        },
        "box": {
          "type": "object",
          "description": "Normalized coordinates within source, with a bottom-left origin as returned by Apple Vision.",
          "required": [
            "x",
            "y",
            "width",
            "height"
          ],
          "properties": {
            "x": {
              "type": "number",
              "minimum": 0,
              "maximum": 1
            },
            "y": {
              "type": "number",
              "minimum": 0,
              "maximum": 1
            },
            "width": {
              "type": "number",
              "minimum": 0,
              "maximum": 1
            },
            "height": {
              "type": "number",
              "minimum": 0,
              "maximum": 1
            }
          }
        },
        "observation": {
          "type": "object",
          "required": [
            "text",
            "confidence",
            "box"
          ],
          "properties": {
            "text": {
              "type": "string"
            },
            "confidence": {
              "type": "number",
              "minimum": 0,
              "maximum": 1,
              "description": "Apple Vision recognition confidence for the raw text observation, from 0 through 1."
            },
            "box": {
              "$ref": "#/$defs/box"
            }
          }
        },
        "result": {
          "type": "object",
          "required": [
            "input",
            "source",
            "region",
            "type",
            "observations",
            "values"
          ],
          "properties": {
            "input": {
              "type": "string",
              "minLength": 1
            },
            "source": {
              "$ref": "#/$defs/rectangle"
            },
            "region": {
              "type": "string",
              "minLength": 1
            },
            "type": {
              "enum": [
                "text",
                "player-name",
                "numeric"
              ]
            },
            "observations": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/observation"
              }
            },
            "values": {
              "type": "array",
              "items": {
                "type": "string"
              }
            }
          }
        },
        "success": {
          "type": "object",
          "required": [
            "$schema",
            "jobId",
            "ok",
            "result"
          ],
          "properties": {
            "$schema": {
              "const": "https://kaito-tokyo.github.io/unite-analysis-swift/ocr.output.schema.json"
            },
            "jobId": {
              "type": "string",
              "minLength": 1
            },
            "ok": {
              "const": true
            },
            "result": {
              "$ref": "#/$defs/result"
            }
          }
        },
        "failure": {
          "type": "object",
          "required": [
            "$schema",
            "ok",
            "error"
          ],
          "properties": {
            "$schema": {
              "const": "https://kaito-tokyo.github.io/unite-analysis-swift/ocr.output.schema.json"
            },
            "jobId": {
              "type": "string"
            },
            "ok": {
              "const": false
            },
            "error": {
              "type": "object",
              "required": [
                "line",
                "message"
              ],
              "properties": {
                "line": {
                  "type": "integer",
                  "minimum": 1
                },
                "message": {
                  "type": "string"
                }
              }
            }
          }
        }
      }
    }
    """#,
    "ocr-options.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/ocr-options.schema.json",
      "title": "unite-analysis-swift named OCR region options",
      "type": "object",
      "additionalProperties": false,
      "required": [
        "$schema"
      ],
      "properties": {
        "$schema": {
          "const": "https://kaito-tokyo.github.io/unite-analysis-swift/ocr-options.schema.json"
        }
      },
      "patternProperties": {
        "^(?!\\$schema$).+$": {
          "$ref": "#/$defs/options"
        }
      },
      "$defs": {
        "options": {
          "type": "object",
          "required": [
            "recognitionLanguages"
          ],
          "properties": {
            "recognitionLanguages": {
              "type": "array",
              "minItems": 1,
              "items": {
                "type": "string",
                "minLength": 1
              }
            },
            "customWords": {
              "type": "array",
              "items": {
                "type": "string",
                "minLength": 1
              }
            }
          }
        }
      }
    }
    """#,
    "chroma-events.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/chroma-events.output.schema.json",
      "title": "unite-analysis-swift detect-chroma-events output",
      "type": "object",
      "required": [
        "$schema",
        "inputSampleDirectory",
        "inputSampleCount",
        "firstInputFilename",
        "lastInputFilename",
        "fps",
        "sampledWidth",
        "sampledHeight",
        "samples"
      ],
      "properties": {
        "$schema": {
          "const": "https://kaito-tokyo.github.io/unite-analysis-swift/chroma-events.output.schema.json"
        },
        "inputSampleDirectory": {
          "type": "string",
          "minLength": 1
        },
        "inputSampleCount": {
          "type": "integer",
          "minimum": 2
        },
        "firstInputFilename": {
          "type": "string",
          "minLength": 1
        },
        "lastInputFilename": {
          "type": "string",
          "minLength": 1
        },
        "fps": {
          "type": "number",
          "exclusiveMinimum": 0
        },
        "sampledWidth": {
          "type": "integer",
          "minimum": 1
        },
        "sampledHeight": {
          "type": "integer",
          "minimum": 1
        },
        "samples": {
          "type": "array",
          "minItems": 1,
          "items": {
            "$ref": "#/$defs/sample"
          }
        }
      },
      "$defs": {
        "sample": {
          "type": "object",
          "required": [
            "requestedInmatch",
            "actualInmatch",
            "score",
            "cbThreshold",
            "crThreshold",
            "cbChangedPixelCount",
            "crChangedPixelCount",
            "bothChangedPixelCount",
            "changedPixelCount"
          ],
          "properties": {
            "requestedInmatch": {
              "type": "number",
              "minimum": 0,
              "description": "Validated JPEG sequence-grid time derived as (filename index - 1) / fps."
            },
            "actualInmatch": {
              "type": "number",
              "minimum": 0,
              "description": "The same validated sequence-grid time as requestedInmatch, not a decoder-reported timestamp."
            },
            "score": {
              "type": "integer",
              "minimum": 0,
              "description": "Maximum of the independently computed Cb and Cr Otsu thresholds for this adjacent JPEG pair; it is comparable only within the same sampled region and run."
            },
            "cbThreshold": {
              "type": "integer",
              "minimum": 0
            },
            "crThreshold": {
              "type": "integer",
              "minimum": 0
            },
            "cbChangedPixelCount": {
              "type": "integer",
              "minimum": 0
            },
            "crChangedPixelCount": {
              "type": "integer",
              "minimum": 0
            },
            "bothChangedPixelCount": {
              "type": "integer",
              "minimum": 0
            },
            "changedPixelCount": {
              "type": "integer",
              "minimum": 0
            }
          }
        }
      }
    }
    """#,
  ]
}
