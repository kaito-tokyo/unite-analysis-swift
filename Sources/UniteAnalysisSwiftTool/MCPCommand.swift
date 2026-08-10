// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import MCP

struct MCPCommand: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Run the native stdio MCP server.")
}

package func mcpToolResult(
  _ text: String, mediaURLs: [URL] = [], isError: Bool = false
) -> CallTool.Result {
  let media = mediaURLs.map { url in
    Tool.Content.resourceLink(
      uri: url.absoluteString,
      name: url.lastPathComponent,
      description: "Generated playable video clip",
      mimeType: "video/mp4")
  }
  return .init(
    content: [.text(text: text, annotations: nil, _meta: nil)] + media,
    isError: isError)
}

private func encodedObject<T: Encodable>(_ value: T) throws -> Any {
  let data = try JSONEncoder().encode(value)
  return try JSONSerialization.jsonObject(with: data)
}

private func failureObject(_ failure: JSONLJobFailure) -> [String: Any] {
  [
    "ok": false,
    "line": failure.line,
    "jobId": failure.jobId ?? NSNull(),
    "error": String(describing: failure.error),
  ]
}

package func builtInMCPOutput(arguments: [String]) throws -> String? {
  guard let output = builtInCLIOutput(arguments: arguments) else { return nil }
  let data = try JSONSerialization.data(
    withJSONObject: ["records": [["text": output]]], options: [.sortedKeys])
  return String(decoding: data, as: UTF8.self)
}

package func executeForMCP(_ parsed: any ParsableCommand) async throws -> [Any] {
  var records: [Any] = []
  switch parsed {
  case let command as AudioPeaks:
    try validateOutputPath(command.output.map(resolvePath), force: command.force)
    for try await record in command.outputRecords() {
      if let output = command.output {
        try writeOutputData(
          try prettyPrintedJSONData(record), to: resolvePath(output), force: command.force)
      }
      records.append(try encodedObject(record))
    }
  case let command as BatchFrame:
    for try await record in command.outputRecords() {
      switch record {
      case .success(let output): records.append(try encodedObject(output))
      case .failure(let failure): records.append(failureObject(failure))
      }
    }
  case let command as SampleFrames:
    for try await record in command.outputRecords() { records.append(["output": record.output]) }
  case let command as PreciseFrame:
    for try await record in command.outputRecords() { records.append(["output": record.output]) }
  case let command as ContactSheet:
    for try await record in command.outputRecords() {
      switch record {
      case .success(let output): records.append(try encodedObject(output))
      case .failure(let failure): records.append(failureObject(failure))
      }
    }
  case let command as FrameBurst:
    for try await record in command.outputRecords() {
      switch record {
      case .success(let output): records.append(try encodedObject(output))
      case .failure(let failure): records.append(failureObject(failure))
      }
    }
  case let command as DetectChromaEvents:
    for try await record in command.outputRecords() { records.append(["output": record.output]) }
  case let command as EventDetect:
    for try await record in command.outputRecords() { records.append(["output": record.output]) }
  case let command as ExtractClip:
    for try await record in command.outputRecords() { records.append(["output": record.output]) }
  case let command as OCRCommand:
    let writer = try command.output.map {
      try JSONLResponseWriter(output: $0, force: command.force)
    }
    for try await record in command.outputRecords() {
      switch record {
      case .success(let output):
        try writer?.write(output)
        records.append(try encodedObject(output))
      case .failure(let failure):
        if let writer {
          try writeJSONLFailure(failure, schema: OCRCommandOutput.schemaURL, to: writer)
        }
        records.append(failureObject(failure))
      }
    }
    try writer?.finish()
  case let command as ScanResultCommand:
    try validateOutputPath(command.output.map(resolvePath), force: command.force)
    for try await record in command.outputRecords() {
      if let output = command.output {
        let data = try prettyPrintedJSONData(record)
        try writeOutputData(data, to: resolvePath(output), force: command.force)
      }
      records.append(try encodedObject(record))
    }
  case let command as RecognizeDraftLoadout:
    for try await record in command.outputRecords() { records.append(["output": record.output]) }
  case let command as RecognizeBlindLoadout:
    for try await record in command.outputRecords() { records.append(["output": record.output]) }
  case let command as EvaluateDrawText:
    for try await record in command.outputRecords() { records.append(["text": record.text]) }
  case let command as Schema:
    for try await record in command.outputRecords() {
      records.append(["schema": String(decoding: record.data, as: UTF8.self)])
    }
  case let command as ConfigGet:
    for try await record in command.outputRecords() { records.append(["value": record.value]) }
  case let command as ConfigSet:
    for try await record in command.outputRecords() { records.append(["value": record.value]) }
  case let command as ConfigUnset:
    for try await _ in command.outputRecords() { records.append(["completed": true]) }
  case let command as ConfigPath:
    for try await record in command.outputRecords() { records.append(["value": record.value]) }
  case is MCPCommand:
    throw ValidationError("The MCP server cannot invoke the mcp command recursively")
  default:
    throw ValidationError("Unsupported command type: \(String(describing: type(of: parsed)))")
  }
  return records
}

private actor MCPExecutionGate {
  private var isLocked = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func acquire() async {
    if !isLocked {
      isLocked = true
      return
    }
    await withCheckedContinuation { waiters.append($0) }
  }

  func release() {
    if waiters.isEmpty {
      isLocked = false
    } else {
      waiters.removeFirst().resume()
    }
  }
}

private struct MCPCommandRunnerOutput: Sendable {
  let text: String
  let mediaURLs: [URL]
}

private actor MCPCommandRunner {
  private let executionGate = MCPExecutionGate()

  func run(
    arguments: [String], currentDirectory: String?, standardInput: String?
  ) async throws -> MCPCommandRunnerOutput {
    await executionGate.acquire()
    do {
      let result = try await runExclusively(
        arguments: arguments, currentDirectory: currentDirectory, standardInput: standardInput)
      await executionGate.release()
      return result
    } catch {
      await executionGate.release()
      throw error
    }
  }

  private func runExclusively(
    arguments: [String], currentDirectory: String?, standardInput: String?
  ) async throws -> MCPCommandRunnerOutput {
    let originalDirectory = FileManager.default.currentDirectoryPath
    if let currentDirectory {
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: currentDirectory, isDirectory: &isDirectory),
        isDirectory.boolValue,
        FileManager.default.changeCurrentDirectoryPath(currentDirectory)
      else {
        throw ValidationError("Working directory does not exist: \(currentDirectory)")
      }
    }
    defer { _ = FileManager.default.changeCurrentDirectoryPath(originalDirectory) }

    if let output = try builtInMCPOutput(arguments: arguments) {
      return MCPCommandRunnerOutput(text: output, mediaURLs: [])
    }

    var parsedArguments = arguments
    var inputURL: URL?
    let usesDrawTextStandardInput = arguments.first == "eval-draw-text-script"
    if let standardInput, !usesDrawTextStandardInput {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      try Data(standardInput.utf8).write(to: url, options: .atomic)
      inputURL = url
      parsedArguments = parsedArguments.map { $0 == "-" ? url.path : $0 }
    }
    defer { if let inputURL { try? FileManager.default.removeItem(at: inputURL) } }

    let parsed = try UniteAnalysisSwiftCommand.parseAsRoot(parsedArguments)
    let requiresStandardInput =
      (parsed as? BatchFrame)?.jobs == "-"
      || (parsed as? ContactSheet)?.jobs == "-"
      || (parsed as? FrameBurst)?.jobs == "-"
      || (parsed as? OCRCommand)?.jobs == "-"
      || (parsed as? EvaluateDrawText)?.script == "-"
    if requiresStandardInput && standardInput == nil {
      throw ValidationError(
        "standardInput is required when an MCP command reads from standard input")
    }
    let command: any ParsableCommand
    if var evaluate = parsed as? EvaluateDrawText, evaluate.script == "-",
      let standardInput
    {
      evaluate.script = standardInput
      command = evaluate
    } else {
      command = parsed
    }
    let records = try await executeForMCP(command)
    let data = try JSONSerialization.data(
      withJSONObject: ["records": records], options: [.sortedKeys])
    let mediaURLs: [URL]
    if let extractClip = command as? ExtractClip {
      mediaURLs = [resolvePath(extractClip.output)]
    } else {
      mediaURLs = []
    }
    return MCPCommandRunnerOutput(
      text: String(decoding: data, as: UTF8.self), mediaURLs: mediaURLs)
  }
}

func executeMCPServer() async throws {
  let runner = MCPCommandRunner()
  let server = Server(
    name: "unite-analysis-swift",
    version: UniteAnalysisSwiftCommand.configuration.version,
    capabilities: .init(tools: .init()))

  await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: [
      Tool(
        name: "run_unite_analysis",
        description: "Run one native unite-analysis-swift command in process.",
        inputSchema: .object([
          "type": "object",
          "properties": .object([
            "arguments": .object([
              "type": "array", "items": .object(["type": "string"]),
              "description": "Arguments parsed into a typed ParsableCommand.",
            ]),
            "currentDirectory": .object(["type": "string"]),
            "standardInput": .object(["type": "string"]),
          ]),
          "required": ["arguments"],
          "additionalProperties": false,
        ]))
    ])
  }

  await server.withMethodHandler(CallTool.self) { request in
    guard request.name == "run_unite_analysis" else {
      return mcpToolResult("Unknown tool: \(request.name)", isError: true)
    }
    guard let values = request.arguments?["arguments"]?.arrayValue,
      values.allSatisfy({ $0.stringValue != nil })
    else {
      return mcpToolResult("arguments must be an array of strings", isError: true)
    }
    do {
      let result = try await runner.run(
        arguments: values.compactMap(\.stringValue),
        currentDirectory: request.arguments?["currentDirectory"]?.stringValue,
        standardInput: request.arguments?["standardInput"]?.stringValue)
      return mcpToolResult(result.text, mediaURLs: result.mediaURLs)
    } catch {
      return mcpToolResult(String(describing: error), isError: true)
    }
  }

  let transport = StdioTransport()
  try await server.start(transport: transport)
  await server.waitUntilCompleted()
}
