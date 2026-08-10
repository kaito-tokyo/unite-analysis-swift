// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation

package func prettyPrintedJSONData<T: Encodable>(_ value: T) throws -> Data {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  var data = try encoder.encode(value)
  data.append(0x0A)
  return data
}

package func builtInCLIOutput(arguments: [String]) -> String? {
  if arguments.last == "--version" || arguments == ["-v"] {
    return UniteAnalysisSwiftCommand.configuration.version
  }
  let helpRequested = arguments.last == "--help" || arguments.last == "-h"
  let helpPath: [String]
  if arguments.first == "help" {
    helpPath = Array(arguments.dropFirst())
  } else if helpRequested {
    helpPath = Array(arguments.dropLast())
  } else {
    return nil
  }
  let commandType: ParsableCommand.Type? =
    switch helpPath {
    case []: UniteAnalysisSwiftCommand.self
    case ["batch-frame"]: BatchFrame.self
    case ["sample-frames"]: SampleFrames.self
    case ["precise-frame"]: PreciseFrame.self
    case ["contact-sheet"]: ContactSheet.self
    case ["frame-burst"]: FrameBurst.self
    case ["detect-chroma-events"]: DetectChromaEvents.self
    case ["audio-peaks"]: AudioPeaks.self
    case ["extract-clip"]: ExtractClip.self
    case ["ocr"]: OCRCommand.self
    case ["scan-result"]: ScanResultCommand.self
    case ["recognize-draft-loadout"]: RecognizeDraftLoadout.self
    case ["recognize-blind-loadout"]: RecognizeBlindLoadout.self
    case ["eval-draw-text-script"]: EvaluateDrawText.self
    case ["schema"]: Schema.self
    case ["config"]: Config.self
    case ["config", "get"]: ConfigGet.self
    case ["config", "set"]: ConfigSet.self
    case ["config", "unset"]: ConfigUnset.self
    case ["config", "path"]: ConfigPath.self
    case ["mcp"]: MCPCommand.self
    default: nil
    }
  guard let commandType else { return nil }
  if commandType == UniteAnalysisSwiftCommand.self {
    return UniteAnalysisSwiftCommand.helpMessage()
  }
  return UniteAnalysisSwiftCommand.helpMessage(for: commandType)
}

package func executeCLI(_ parsed: any ParsableCommand) async throws {
  switch parsed {
  case let command as AudioPeaks:
    try validateOutputPath(command.output.map(resolvePath), force: command.force)
    for try await record in command.outputRecords() {
      let data = try prettyPrintedJSONData(record)
      if let output = command.output {
        try writeOutputData(data, to: resolvePath(output), force: command.force)
      }
      try FileHandle.standardOutput.write(contentsOf: data)
    }

  case let command as BatchFrame:
    let writer = try JSONLResponseWriter()
    for try await record in command.outputRecords() {
      switch record {
      case .success(let output):
        try writer.write(output)
      case .failure(let failure):
        try writeJSONLFailure(failure, schema: BatchFrameJobOutput.schemaURL, to: writer)
      }
    }

  case let command as SampleFrames:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.output)\n".utf8))
    }

  case let command as PreciseFrame:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.output)\n".utf8))
    }

  case let command as ContactSheet:
    let writer = try JSONLResponseWriter()
    for try await record in command.outputRecords() {
      switch record {
      case .success(let output):
        try writer.write(output)
      case .failure(let failure):
        try writeJSONLFailure(failure, schema: ContactSheetJobOutput.schemaURL, to: writer)
      }
    }

  case let command as FrameBurst:
    let writer = try JSONLResponseWriter()
    for try await record in command.outputRecords() {
      switch record {
      case .success(let output):
        try writer.write(output)
      case .failure(let failure):
        try writeJSONLFailure(failure, schema: FrameBurstJobOutput.schemaURL, to: writer)
      }
    }

  case let command as DetectChromaEvents:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.output)\n".utf8))
    }

  case let command as ExtractClip:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.output)\n".utf8))
    }

  case let command as OCRCommand:
    let writer = try JSONLResponseWriter(output: command.output, force: command.force)
    for try await record in command.outputRecords() {
      switch record {
      case .success(let output):
        try writer.write(output)
      case .failure(let failure):
        try writeJSONLFailure(failure, schema: OCRCommandOutput.schemaURL, to: writer)
      }
    }
    try writer.finish()

  case let command as ScanResultCommand:
    try validateOutputPath(command.output.map(resolvePath), force: command.force)
    for try await record in command.outputRecords() {
      let data = try prettyPrintedJSONData(record)
      if let output = command.output {
        try writeOutputData(data, to: resolvePath(output), force: command.force)
      } else {
        try FileHandle.standardOutput.write(contentsOf: data)
      }
    }

  case let command as RecognizeDraftLoadout:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.output)\n".utf8))
    }

  case let command as RecognizeBlindLoadout:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.output)\n".utf8))
    }

  case let command as EvaluateDrawText:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.text)\n".utf8))
    }

  case let command as Schema:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: record.data)
      if record.data.last != 0x0A {
        try FileHandle.standardOutput.write(contentsOf: Data("\n".utf8))
      }
    }

  case let command as ConfigGet:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.value)\n".utf8))
    }

  case let command as ConfigSet:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.value)\n".utf8))
    }

  case let command as ConfigUnset:
    for try await _ in command.outputRecords() {}

  case let command as ConfigPath:
    for try await record in command.outputRecords() {
      try FileHandle.standardOutput.write(contentsOf: Data("\(record.value)\n".utf8))
    }

  case is MCPCommand:
    try await executeMCPServer()

  default:
    throw ValidationError("Unsupported command type: \(String(describing: type(of: parsed)))")
  }
}
