// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP

private let version = "0.1.4"

private func toolResult(_ text: String, isError: Bool = false) -> CallTool.Result {
  .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
}

private func runtimeExecutable() -> URL {
  let server = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
  return server.deletingLastPathComponent().appendingPathComponent("unite-analysis-swift")
}

private func runRuntime(arguments: [String], currentDirectory: String?, standardInput: String?)
  async
  -> CallTool.Result
{
  let executable = runtimeExecutable()
  guard FileManager.default.isExecutableFile(atPath: executable.path) else {
    return toolResult(
      "Bundled runtime is missing or is not executable: \(executable.path)", isError: true)
  }

  let process = Process()
  process.executableURL = executable
  process.arguments = arguments
  var environment = ProcessInfo.processInfo.environment
  environment["UNITE_ANALYSIS_DESCRIPTOR_DATABASE"] =
    executable.deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Resources/descriptors.pb").path
  process.environment = environment
  if let currentDirectory {
    let directory = URL(fileURLWithPath: currentDirectory, isDirectory: true)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      return toolResult("Working directory does not exist: \(currentDirectory)", isError: true)
    }
    process.currentDirectoryURL = directory
  }

  let stdout = Pipe()
  let stderr = Pipe()
  process.standardOutput = stdout
  process.standardError = stderr
  if let standardInput {
    let input = Pipe()
    process.standardInput = input
    input.fileHandleForWriting.write(Data(standardInput.utf8))
    try? input.fileHandleForWriting.close()
  }

  do {
    try process.run()
    async let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
    async let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let (capturedOutput, capturedError) = await (outputData, errorData)
    let result: [String: Any] = [
      "status": Int(process.terminationStatus),
      "stdout": String(decoding: capturedOutput, as: UTF8.self),
      "stderr": String(decoding: capturedError, as: UTF8.self),
    ]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    return toolResult(
      String(decoding: data, as: UTF8.self), isError: process.terminationStatus != 0)
  } catch {
    return toolResult("Could not launch bundled runtime: \(error)", isError: true)
  }
}

@main
enum UniteAnalysisMCPServer {
  static func main() async throws {
    if CommandLine.arguments.dropFirst().elementsEqual(["--version"]) {
      print(version)
      return
    }

    let server = Server(
      name: "unite-analysis-swift",
      version: version,
      capabilities: .init(tools: .init())
    )

    await server.withMethodHandler(ListTools.self) { _ in
      .init(tools: [
        Tool(
          name: "run_unite_analysis",
          description:
            "Run one command from the bundled unite-analysis-swift recording analysis runtime. Use the runtime's --help output to discover command-specific arguments.",
          inputSchema: .object([
            "type": "object",
            "properties": .object([
              "arguments": .object([
                "type": "array",
                "items": .object(["type": "string"]),
                "description": "Arguments passed directly to unite-analysis-swift.",
              ]),
              "currentDirectory": .object([
                "type": "string",
                "description": "Optional working directory, normally the .ldtxrecord root.",
              ]),
              "standardInput": .object([
                "type": "string",
                "description": "Optional UTF-8 standard input for commands that accept '-'.",
              ]),
            ]),
            "required": ["arguments"],
            "additionalProperties": false,
          ]))
      ])
    }

    await server.withMethodHandler(CallTool.self) { request in
      guard request.name == "run_unite_analysis" else {
        return toolResult("Unknown tool: \(request.name)", isError: true)
      }
      guard let argumentValues = request.arguments?["arguments"]?.arrayValue,
        argumentValues.allSatisfy({ $0.stringValue != nil })
      else {
        return toolResult("arguments must be an array of strings", isError: true)
      }
      return await runRuntime(
        arguments: argumentValues.compactMap(\.stringValue),
        currentDirectory: request.arguments?["currentDirectory"]?.stringValue,
        standardInput: request.arguments?["standardInput"]?.stringValue)
    }

    let transport = StdioTransport()
    try await server.start(transport: transport)
    try await Task.sleep(for: .seconds(60 * 60 * 24 * 365 * 100))
  }
}
