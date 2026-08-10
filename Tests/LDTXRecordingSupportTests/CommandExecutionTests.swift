// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import MCP
import RecordVisionSupport
import Testing

@testable import UniteAnalysisModelCommands
@testable import UniteAnalysisSwiftCommands

@Test func rootParserReturnsTypedCommandWithoutRunningIt() throws {
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot([
    "schema", "publication.schema.json",
  ])
  #expect(parsed is Schema)
}

@Test func schemaCommandProducesSemanticOutputRecord() async throws {
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot([
    "schema", "publication.schema.json",
  ])
  let command = try #require(parsed as? Schema)
  var records: [Schema.OutputRecord] = []
  for try await record in command.outputRecords() {
    records.append(record)
  }
  let record = try #require(records.first)
  #expect(records.count == 1)
  #expect(String(decoding: record.data, as: UTF8.self).contains("publication.schema.json"))
}

@Test(arguments: [
  #"{"jobId":"job","matchTimestamps":[0],"source":{"x":0,"y":0,"width":1,"height":1},"outputPrefix":"frame","extra":true}"#,
  #"{"jobId":"job","matchTimestamps":[0],"source":{"x":0,"y":0,"width":1,"height":1,"extra":true},"outputPrefix":"frame"}"#,
])
func batchFrameJobRejectsUnknownKeys(json: String) {
  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(BatchFrameJob.self, from: Data(json.utf8))
  }
}

@Test func contactSheetDefinitionRejectsUnknownKeys() {
  let documents = [
    #"{"cell":{"width":1,"height":1},"columns":1,"placements":[],"matchTimestamps":[0],"extra":true}"#,
    #"{"cell":{"width":1,"height":1,"extra":true},"columns":1,"placements":[],"matchTimestamps":[0]}"#,
    #"{"cell":{"width":1,"height":1},"columns":1,"placements":[{"drawText":{"text":"x","x":0,"y":0,"fontSize":1,"extra":true}}],"matchTimestamps":[0]}"#,
  ]
  for document in documents {
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(ContactSheetDefinition.self, from: Data(document.utf8))
    }
  }
}

@Test func frameBurstJobRejectsUnknownTopLevelKey() {
  let data = Data(
    #"{"jobId":"job","matchTimestamp":0,"source":{"x":0,"y":0,"width":1,"height":1},"frameCount":1,"columns":1,"cellWidth":1,"output":"out.jpg","extra":true}"#
      .utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(FrameBurstJob.self, from: data)
  }
}

@Test func ocrJobRejectsUnknownTopLevelKey() {
  let data = Data(
    #"{"jobId":"job","input":"in.jpg","source":{"x":0,"y":0,"width":1,"height":1},"region":"test","type":"generic","extra":true}"#
      .utf8
  )
  #expect(throws: DecodingError.self) {
    _ = try JSONDecoder().decode(OCRJob.self, from: data)
  }
}

@Test func eventDetectManifestRejectsUnknownKeys() {
  let documents = [
    #"{"audioPeaks":"audio.json","chromaEvents":[],"ocrCandidates":[],"scheduledCandidates":[],"extra":true}"#,
    #"{"audioPeaks":"audio.json","chromaEvents":[{"region":"top","path":"chroma.json","extra":true}],"ocrCandidates":[],"scheduledCandidates":[]}"#,
    #"{"audioPeaks":"audio.json","chromaEvents":[],"ocrCandidates":[{"region":"score","inmatch":1,"value":"1","confidence":1,"extra":true}],"scheduledCandidates":[]}"#,
    #"{"audioPeaks":"audio.json","chromaEvents":[],"ocrCandidates":[],"scheduledCandidates":[{"inmatch":1,"label":"goal","extra":true}]}"#,
  ]
  for document in documents {
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(EventDetectManifest.self, from: Data(document.utf8))
    }
  }
}

@Test func modelParserReturnsTypedCommandWithoutRunningIt() throws {
  let parsed = try UniteAnalysisModelCommand.parseAsRoot([
    "build", "manifest.json", "--output", "descriptors.pb",
  ])
  #expect(parsed is BuildDescriptorDatabase)
}

@Test func mcpIsARegularParsableSubcommand() throws {
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot(["mcp"])
  #expect(parsed is MCPCommand)
  #expect(!(parsed is any AsyncParsableCommand))
}

@Test func mcpClipResultIncludesPlayableResourceLink() throws {
  let clipURL = URL(fileURLWithPath: "/tmp/highlight clip.mp4")
  let result = mcpToolResult("{\"records\":[]}", mediaURLs: [clipURL])
  let data = try JSONEncoder().encode(result)
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  let content = try #require(object["content"] as? [[String: Any]])

  #expect(content.count == 2)
  #expect(content[0]["type"] as? String == "text")
  #expect(content[1]["type"] as? String == "resource_link")
  #expect(content[1]["uri"] as? String == clipURL.absoluteString)
  #expect(content[1]["name"] as? String == "highlight clip.mp4")
  #expect(content[1]["mimeType"] as? String == "video/mp4")
}

@Test func mcpMediaResourceStoreServesRegisteredClip() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let clipURL = directory.appendingPathComponent("highlight.mp4")
  let clipData = Data([0, 1, 2, 3])
  try clipData.write(to: clipURL)

  let store = MCPMediaResourceStore()
  await store.register([clipURL])
  let resources = await store.resources()
  let content = try await store.content(for: clipURL.absoluteString)

  #expect(resources.count == 1)
  #expect(resources[0].uri == clipURL.absoluteString)
  #expect(resources[0].mimeType == "video/mp4")
  #expect(content.uri == clipURL.absoluteString)
  #expect(content.mimeType == "video/mp4")
  #expect(content.blob == clipData.base64EncodedString())
}

@Test func mcpInterpretsBuiltInCLIOptionsBeforeParsingCommands() throws {
  let help = try #require(try builtInMCPOutput(arguments: ["--help"]))
  let helpObject = try #require(
    JSONSerialization.jsonObject(with: Data(help.utf8)) as? [String: Any])
  let helpRecords = try #require(helpObject["records"] as? [[String: String]])
  #expect(helpRecords.first?["text"]?.contains("USAGE: unite-analysis-swift") == true)

  let version = try #require(try builtInMCPOutput(arguments: ["--version"]))
  let versionObject = try #require(
    JSONSerialization.jsonObject(with: Data(version.utf8)) as? [String: Any])
  let versionRecords = try #require(versionObject["records"] as? [[String: String]])
  #expect(versionRecords == [["text": UniteAnalysisSwiftCommand.configuration.version]])
}

@Test(arguments: ["ocr", "scan-result"])
func writingCommandsParseForceFlag(commandName: String) throws {
  let arguments =
    commandName == "ocr"
    ? [
      "ocr", "jobs.jsonl", "--ocr-options", "ocr-options.json", "--output", "result.jsonl",
      "--force",
    ]
    : [
      "scan-result", "result.jpg", "--type", "summary", "--ocr-options", "ocr-options.json",
      "--output", "result.json", "--force",
    ]
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot(arguments)

  if let command = parsed as? OCRCommand {
    #expect(command.force)
  } else {
    #expect(try #require(parsed as? ScanResultCommand).force)
  }
}

@Test func audioPeaksParsesPersistentOutputOptions() throws {
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot([
    "audio-peaks", "--record-spec", "record-spec.json", "--output", "audio-peaks.json",
    "--force",
  ])
  let command = try #require(parsed as? AudioPeaks)

  #expect(command.output == "audio-peaks.json")
  #expect(command.force)
}

@Test func prettyJSONOutputPreservesLargeArraysAndZeroResults() throws {
  struct Output: Encodable {
    let peaks: [Int]
    let intervals: [Int]
  }
  let data = try prettyPrintedJSONData(
    Output(peaks: Array(0..<10_000), intervals: []))
  let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: [Int]])

  #expect(object["peaks"] == Array(0..<10_000))
  #expect(object["intervals"] == [])
  #expect(data.last == 0x0A)
}

@Test func audioPeaksRejectsExistingOutputBeforeDecoding() async throws {
  let output = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: output) }
  try Data("original\n".utf8).write(to: output)
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot([
    "audio-peaks", "--record-spec", "missing.json", "--output", output.path,
  ])

  await #expect(throws: UniteAnalysisSwiftToolError.self) {
    try await executeCLI(parsed)
  }
  #expect(try Data(contentsOf: output) == Data("original\n".utf8))
}

@Test func mcpAudioPeaksRejectsExistingOutputBeforeDecoding() async throws {
  let output = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: output) }
  try Data("original\n".utf8).write(to: output)
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot([
    "audio-peaks", "--record-spec", "missing.json", "--output", output.path,
  ])

  await #expect(throws: UniteAnalysisSwiftToolError.self) {
    _ = try await executeForMCP(parsed)
  }
  #expect(try Data(contentsOf: output) == Data("original\n".utf8))
}

@Test func jsonlOutputRequiresForceBeforeReplacingExistingFile() throws {
  let output = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("jsonl")
  defer { try? FileManager.default.removeItem(at: output) }
  try Data("original\n".utf8).write(to: output)

  #expect(throws: UniteAnalysisSwiftToolError.self) {
    _ = try JSONLResponseWriter(output: output.path)
  }
  #expect(try Data(contentsOf: output) == Data("original\n".utf8))

  let writer = try JSONLResponseWriter(output: output.path, force: true)
  try writer.write(["ok": true])
  try writer.finish()
  #expect(String(decoding: try Data(contentsOf: output), as: UTF8.self) == "{\"ok\":true}\n")
}

@Test func jsonlOutputRejectsDestinationCreatedAfterProcessingStarts() throws {
  let output = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
    .appendingPathExtension("jsonl")
  defer { try? FileManager.default.removeItem(at: output) }
  let writer = try JSONLResponseWriter(output: output.path)
  try writer.write(["ok": true])
  try Data("raced\n".utf8).write(to: output)

  #expect(throws: UniteAnalysisSwiftToolError.self) {
    try writer.finish()
  }
  #expect(try Data(contentsOf: output) == Data("raced\n".utf8))
}

@Test func dataOutputRejectsDestinationCreatedAfterPreflight() throws {
  let output = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: output) }
  try validateOutputPath(output, force: false)
  try Data("raced\n".utf8).write(to: output)

  #expect(throws: UniteAnalysisSwiftToolError.self) {
    try writeOutputData(Data("replacement\n".utf8), to: output, force: false)
  }
  #expect(try Data(contentsOf: output) == Data("raced\n".utf8))
}

@Test func dataOutputCreatesMissingParentDirectories() throws {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let output = root.appendingPathComponent("candidates/audio-peaks.json")
  let expected = Data("complete\n".utf8)

  try writeOutputData(expected, to: output, force: false)

  #expect(try Data(contentsOf: output) == expected)
}

@Test(arguments: ["ocr", "scan-result"])
func mcpWritingCommandsForwardForceFlag(commandName: String) async throws {
  let output = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: output) }
  try Data("original\n".utf8).write(to: output)
  let arguments =
    commandName == "ocr"
    ? [
      "ocr", "missing.jsonl", "--ocr-options", "missing.json", "--output", output.path,
      "--force",
    ]
    : [
      "scan-result", "missing.jpg", "--type", "summary", "--ocr-options", "missing.json",
      "--output", output.path, "--force",
    ]
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot(arguments)

  do {
    _ = try await executeForMCP(parsed)
    Issue.record("Expected missing input to fail")
  } catch {
    #expect(!String(describing: error).contains("Output already exists"))
  }
}

@Test(arguments: ["ocr", "scan-result"])
func mcpWritingCommandsRejectExistingOutputWithoutForce(commandName: String) async throws {
  let output = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: output) }
  try Data("original\n".utf8).write(to: output)
  let arguments =
    commandName == "ocr"
    ? ["ocr", "missing.jsonl", "--ocr-options", "missing.json", "--output", output.path]
    : [
      "scan-result", "missing.jpg", "--type", "summary", "--ocr-options", "missing.json",
      "--output", output.path,
    ]
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot(arguments)

  await #expect(throws: UniteAnalysisSwiftToolError.self) {
    _ = try await executeForMCP(parsed)
  }
  #expect(try Data(contentsOf: output) == Data("original\n".utf8))
}

@Test(arguments: ["ocr", "scan-result"])
func writingCommandsRejectExistingOutputBeforeProcessing(commandName: String) async throws {
  let output = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: output) }
  try Data("original\n".utf8).write(to: output)
  let arguments =
    commandName == "ocr"
    ? ["ocr", "missing.jsonl", "--ocr-options", "missing.json", "--output", output.path]
    : [
      "scan-result", "missing.jpg", "--type", "summary", "--ocr-options", "missing.json",
      "--output", output.path,
    ]
  let parsed = try UniteAnalysisSwiftCommand.parseAsRoot(arguments)

  await #expect(throws: UniteAnalysisSwiftToolError.self) {
    try await executeCLI(parsed)
  }
  #expect(try Data(contentsOf: output) == Data("original\n".utf8))
}
