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
      Pass the basename of a supported $schema URL, for example contact-sheet.schema.json. The exact bundled schema is written to standard output. Supported basenames are audio-peaks.output.schema.json, batch-frame.schema.json, batch-frame.output.schema.json, chroma-events.output.schema.json, contact-sheet.schema.json, contact-sheet.output.schema.json, ocr.schema.json, ocr.output.schema.json, and ocr-options.schema.json.
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

enum EmbeddedSchemas {
  static let basenames = [
    "audio-peaks.output.schema.json",
    "batch-frame.schema.json",
    "batch-frame.output.schema.json",
    "chroma-events.output.schema.json",
    "contact-sheet.schema.json",
    "contact-sheet.output.schema.json",
    "ocr.schema.json",
    "ocr.output.schema.json",
    "ocr-options.schema.json",
  ]

  static func data(basename: String) -> Data? {
    schemas[basename].map { Data($0.utf8) }
  }

  private static let schemas = [
    "audio-peaks.output.schema.json": #"""
    {
      "$schema": "https://json-schema.org/draft/2020-12/schema",
      "$id": "https://kaito-tokyo.github.io/unite-analysis-swift/audio-peaks.output.schema.json",
      "title": "unite-analysis-swift audio-peaks output",
      "type": "object",
      "additionalProperties": false,
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
          "additionalProperties": false,
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
          "additionalProperties": false,
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
          "additionalProperties": false,
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
              "additionalProperties": false,
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
          "additionalProperties": false,
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
              "additionalProperties": false,
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
      "additionalProperties": false,
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
          "additionalProperties": false,
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
          "additionalProperties": false,
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
              "additionalProperties": false,
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
              "additionalProperties": false,
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
          "additionalProperties": false,
          "properties": {
            "text": {
              "type": "string"
            },
            "script": {
              "type": "object",
              "required": [
                "return"
              ],
              "additionalProperties": false,
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
          "additionalProperties": false,
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
              "additionalProperties": false,
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
          "additionalProperties": false,
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
              "additionalProperties": false,
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
        "box": {
          "type": "object",
          "description": "Normalized coordinates within source, with a bottom-left origin as returned by Apple Vision.",
          "additionalProperties": false,
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
          "additionalProperties": false,
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
          "additionalProperties": false,
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
          "additionalProperties": false,
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
          "additionalProperties": false,
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
              "additionalProperties": false,
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
      "additionalProperties": false,
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
      "additionalProperties": false,
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
          "additionalProperties": false,
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
