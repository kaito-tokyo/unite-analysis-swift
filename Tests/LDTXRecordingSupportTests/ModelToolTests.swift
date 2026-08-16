// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import Foundation
import Testing
import UniteAnalysisModelCommands

@Test func modelToolVersionIsHandledAsBuiltInOutput() {
  #expect(modelBuiltInCLIOutput(arguments: ["--version"]) == "0.2.3")
}

@Test func modelToolHelpDescribesBuildCommand() {
  let help = UniteAnalysisModelCommand.helpMessage()
  #expect(help.contains("USAGE: unite-analysis-model-tool <subcommand>"))
  #expect(help.contains("build"))
}

@Test func modelBuildHelpDescribesTransferCompression() {
  let help = BuildDescriptorDatabase.helpMessage()
  #expect(help.contains("--xz-output"))
  #expect(help.contains("xz --threads=1 -9e"))
}

@Test func descriptorDatabaseIDRequiresUUIDVersion4() throws {
  #expect(throws: ValidationError.self) {
    try resolveDescriptorDatabaseID("00000000-0000-1000-8000-000000000000")
  }
  #expect(
    try resolveDescriptorDatabaseID("123e4567-e89b-42d3-a456-426614174000")
      == "123e4567-e89b-42d3-a456-426614174000")
}

@Test func descriptorDatabaseRequiresTwoDescriptorsPerPopulatedCategory() throws {
  #expect(throws: ValidationError.self) {
    try validateDescriptorCategoryCounts(held: 1, battle: 0)
  }
  #expect(throws: ValidationError.self) {
    try validateDescriptorCategoryCounts(held: 0, battle: 1)
  }
  try validateDescriptorCategoryCounts(held: 0, battle: 0)
  try validateDescriptorCategoryCounts(held: 2, battle: 2)
}

@Test func descriptorOutputsMustBeDistinct() {
  let output = URL(fileURLWithPath: "/tmp/same.pb")
  #expect(throws: ValidationError.self) {
    try validateDescriptorOutputPaths(output: output, xzOutput: output)
  }
}

@Test func descriptorDatabaseHonorsLoaderByteLimit() throws {
  try validateDescriptorDatabaseByteCount(64 * 1024 * 1024)
  #expect(throws: ValidationError.self) {
    try validateDescriptorDatabaseByteCount(64 * 1024 * 1024 + 1)
  }
}

@Test func descriptorEntryHonorsLoaderRowLimit() throws {
  try validateDescriptorEntryRows(1_000_000)
  #expect(throws: ValidationError.self) {
    try validateDescriptorEntryRows(1_000_001)
  }
}
