// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import UniteAnalysisConfiguration

@Test func storesAndUnsetsCanonicalObsidianDirectoriesIndependently() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let matchReports = root.appendingPathComponent("MatchReports", isDirectory: true)
  let strategyBooks = root.appendingPathComponent("StrategyBooks", isDirectory: true)
  try FileManager.default.createDirectory(at: matchReports, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: strategyBooks, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }

  let store = UserConfigurationStore(fileURL: root.appendingPathComponent("config/config.json"))
  let matchReportsURL = try store.setObsidianDirectory(
    .matchReports, path: matchReports.path + "/../MatchReports")
  let strategyBooksURL = try store.setObsidianDirectory(.strategyBooks, path: strategyBooks.path)

  #expect(matchReportsURL.path == matchReports.resolvingSymlinksInPath().path)
  #expect(strategyBooksURL.path == strategyBooks.resolvingSymlinksInPath().path)
  #expect(
    try store.load().obsidianMatchReportsRoot == matchReports.resolvingSymlinksInPath().path)
  #expect(
    try store.load().obsidianStrategyBooksRoot == strategyBooks.resolvingSymlinksInPath().path)

  try store.unsetObsidianDirectory(.matchReports)
  #expect(try store.load().obsidianMatchReportsRoot == nil)
  #expect(
    try store.load().obsidianStrategyBooksRoot == strategyBooks.resolvingSymlinksInPath().path)
}

@Test func rejectsMissingObsidianDirectory() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = UserConfigurationStore(fileURL: root.appendingPathComponent("config.json"))

  #expect(throws: UserConfigurationError.self) {
    try store.setObsidianDirectory(.matchReports, path: root.appendingPathComponent("missing").path)
  }
  #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
}

@Test func reportsInvalidConfigurationJSON() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let configurationURL = root.appendingPathComponent("config.json")
  try Data(#"{"obsidianMatchReportsRoot":42}"#.utf8).write(to: configurationURL)

  #expect(throws: DecodingError.self) {
    try UserConfigurationStore(fileURL: configurationURL).load()
  }
}

@Test func defaultConfigurationUsesBundleIdentifierApplicationSupportDirectory() {
  let expectedSuffix =
    "/Library/Application Support/tokyo.kaito.unite-analysis-swift/config.json"
  #expect(UserConfigurationStore.defaultFileURL.path.hasSuffix(expectedSuffix))
}

@Test func loadsLegacyConfigurationWhenApplicationSupportConfigurationIsAbsent() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let applicationSupport = root.appendingPathComponent("Application Support/config.json")
  let legacy = root.appendingPathComponent(".config/unite-analysis-swift/config.json")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(
    at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(#"{"obsidianMatchReportsRoot":"/reports"}"#.utf8).write(to: legacy)

  let store = UserConfigurationStore(fileURL: applicationSupport, legacyFileURL: legacy)

  #expect(try store.load().obsidianMatchReportsRoot == "/reports")
}
