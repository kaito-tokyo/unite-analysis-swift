// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import UniteAnalysisSwiftTool

private struct CommandResult {
  let status: Int32
  let stdout: String
  let stderr: String
}

private func commandExecutableURL() throws -> URL {
  let testExecutableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    .standardizedFileURL
  let directory = testExecutableURL.deletingLastPathComponent()
  let candidates = [
    directory.appendingPathComponent("unite-analysis-swift"),
    directory.deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("unite-analysis-swift"),
    repositoryRoot.appendingPathComponent(".build/debug/unite-analysis-swift"),
  ]
  guard
    let executableURL = candidates.first(where: {
      FileManager.default.isExecutableFile(atPath: $0.path)
    })
  else {
    throw CocoaError(.fileNoSuchFile)
  }
  return executableURL
}

private func runCommand(_ arguments: [String]) throws -> CommandResult {
  let process = Process()
  let temporaryDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
  let standardOutputURL = temporaryDirectory.appendingPathComponent("stdout")
  let standardErrorURL = temporaryDirectory.appendingPathComponent("stderr")
  FileManager.default.createFile(atPath: standardOutputURL.path, contents: nil)
  FileManager.default.createFile(atPath: standardErrorURL.path, contents: nil)
  let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
  let standardError = try FileHandle(forWritingTo: standardErrorURL)
  defer {
    try? standardOutput.close()
    try? standardError.close()
  }
  process.executableURL = try commandExecutableURL()
  process.arguments = arguments
  process.currentDirectoryURL = repositoryRoot
  process.standardOutput = standardOutput
  process.standardError = standardError
  try process.run()
  process.waitUntilExit()
  try standardOutput.synchronize()
  try standardError.synchronize()
  return CommandResult(
    status: process.terminationStatus,
    stdout: String(decoding: try Data(contentsOf: standardOutputURL), as: UTF8.self),
    stderr: String(decoding: try Data(contentsOf: standardErrorURL), as: UTF8.self)
  )
}

@Test func everyCommandPrintsDetailedHelp() throws {
  let commands = [
    "batch-frame", "sample-frames", "precise-frame", "contact-sheet",
    "detect-chroma-events", "audio-peaks", "ocr", "scan-result",
    "eval-draw-text-script", "schema", "config",
  ]
  let root = try runCommand(["--help"])
  #expect(root.status == 0)
  #expect(root.stdout.contains("USAGE: unite-analysis-swift <subcommand>"))
  #expect(root.stderr.isEmpty)

  for command in commands {
    let result = try runCommand([command, "--help"])
    #expect(result.status == 0)
    #expect(result.stdout.contains("OVERVIEW:"))
    #expect(result.stdout.contains("USAGE: unite-analysis-swift \(command)"))
    #expect(result.stderr.isEmpty)
  }
}

@Test func schemaCommandPrintsEveryDocumentSchema() throws {
  let docsURL = repositoryRoot.appendingPathComponent("docs", isDirectory: true)
  for basename in EmbeddedSchemas.basenames {
    let result = try runCommand(["schema", basename])
    #expect(result.status == 0)
    #expect(result.stderr.isEmpty)
    let outputObject = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
    let documentObject = try JSONSerialization.jsonObject(
      with: Data(contentsOf: docsURL.appendingPathComponent(basename)))
    #expect((outputObject as AnyObject).isEqual(documentObject))
  }
}

@Test func schemaCommandDiagnosesUnknownBasename() throws {
  let result = try runCommand(["schema", "does-not-exist.schema.json"])
  #expect(result.status != 0)
  #expect(result.stdout.isEmpty)
  #expect(result.stderr.contains("Unknown schema basename 'does-not-exist.schema.json'"))
  #expect(result.stderr.contains("publication.schema.json"))
}

@Test func commandsDiagnoseMissingRequiredArguments() throws {
  let invocations = [
    ["batch-frame"], ["sample-frames"], ["precise-frame"], ["contact-sheet"],
    ["detect-chroma-events"], ["audio-peaks"], ["ocr"], ["scan-result"],
    ["eval-draw-text-script"], ["schema"], ["config", "get"], ["config", "set"],
    ["config", "unset"],
  ]
  for invocation in invocations {
    let result = try runCommand(invocation)
    #expect(result.status != 0)
    #expect(result.stdout.isEmpty)
    #expect(result.stderr.contains("Error: Missing expected argument"))
    #expect(result.stderr.contains("Usage:"))
  }
}

@Test func commandValidationFailsBeforeOpeningInputs() throws {
  let result = try runCommand([
    "detect-chroma-events",
    "--input-sample-dir", "/does/not/exist",
    "--fps", "0",
    "--output", "/does/not/exist/output.json",
  ])
  #expect(result.status != 0)
  #expect(result.stdout.isEmpty)
  #expect(result.stderr.contains("--fps must be positive and finite"))
  #expect(!result.stderr.contains("No such file"))
}

@Test func configPathCommandPrintsAnAbsolutePath() throws {
  let result = try runCommand(["config", "path"])
  #expect(result.status == 0)
  #expect(result.stderr.isEmpty)
  let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  #expect(path.hasPrefix("/"))
  #expect(path.hasSuffix("/unite-analysis-swift/config.json"))
}
