// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
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
