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

  mutating func run() throws {
    guard let data = EmbeddedSchemas.data(basename: basename) else {
      throw ValidationError(
        "Unknown schema basename '\(basename)'. Expected one of: "
          + EmbeddedSchemas.basenames.joined(separator: ", "))
    }
    FileHandle.standardOutput.write(data)
    if data.last != 0x0A {
      FileHandle.standardOutput.write(Data("\n".utf8))
    }
  }
}

package enum EmbeddedSchemas {
  package static let basenames = [
    "audio-peaks.output.schema.json",
    "batch-frame.schema.json",
    "batch-frame.output.schema.json",
    "chroma-events.output.schema.json",
    "contact-sheet.schema.json",
    "contact-sheet.output.schema.json",
    "frame-burst.schema.json",
    "frame-burst.output.schema.json",
    "loadout.output.schema.json",
    "ocr.schema.json",
    "ocr.output.schema.json",
    "ocr-options.schema.json",
    "publication.schema.json",
    "scan-result.output.schema.json",
  ]

  package static func data(basename: String) -> Data? {
    schemas[basename].map { Data($0.utf8) }
  }

  package static var storedBasenames: [String] { schemas.keys.sorted() }

  private static let schemas = [
    "frame-burst.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/frame-burst.schema.json",
      "title": "unite-analysis-swift frame burst job",
      "type": "object",
      "required": ["jobId", "matchTimestamp", "source", "frameCount", "columns", "cellWidth", "output"],
      "properties": {
        "jobId": { "type": "string", "minLength": 1, "pattern": "\\S" },
        "matchTimestamp": { "type": "number" },
        "source": { "$ref": "#/$defs/rectangle" },
        "frameCount": { "type": "integer", "minimum": 1, "maximum": 600 },
        "decimate": { "type": "integer", "minimum": 1, "default": 1 },
        "columns": { "type": "integer", "minimum": 1, "maximum": 32768 },
        "cellWidth": { "type": "integer", "minimum": 1, "maximum": 32768 },
        "output": { "type": "string", "minLength": 1 }
      },
      "$defs": {
        "rectangle": {
          "type": "object",
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
      "title": "Pokémon UNITE recognized loadout",
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
          "properties": { "name": { "type": "string" }, "score": { "type": "number" } }
        },
        "recognizedItem": {
          "type": "object",
          "required": ["candidates"],
          "properties": {
            "name": { "type": ["string", "null"] },
            "score": { "type": ["number", "null"] },
            "candidates": { "type": "array", "items": { "$ref": "#/$defs/candidate" } }
          }
        },
        "declaredRoute": {
          "type": "object",
          "required": ["method", "chromatic_fraction"],
          "properties": {
            "name": { "type": ["string", "null"] },
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
      "title": "Pokémon UNITE match publication state",
      "type": "object",
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
            "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
            "box": { "$ref": "#/$defs/box" }
          }
        },
        "cell": {
          "type": "object",
          "required": ["alternatives"],
          "properties": {
            "text": { "type": "string" },
            "confidence": { "type": "number", "minimum": 0, "maximum": 1 },
            "alternatives": { "type": "array", "items": { "type": "string" } }
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
            "detectionScore": { "type": "integer" },
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
              "minimum": 0
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
              "maximum": 1
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
              "minimum": 0
            },
            "actualInmatch": {
              "type": "number",
              "minimum": 0
            },
            "score": {
              "type": "integer",
              "minimum": 0
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
