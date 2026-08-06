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

struct Config: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "config",
    abstract: "Manage user-specific unite-analysis-swift settings.",
    discussion: """
      Store optional user-specific publication destinations outside a recording bundle. These settings are not record-spec data and do not affect video extraction or analysis.

      COMPLETE EXAMPLES.

      unite-analysis swift config set obsidian-match-reports-root /Users/me/Obsidian/Matches

      unite-analysis swift config get obsidian-match-reports-root

      unite-analysis swift config unset obsidian-match-reports-root

      Use `unite-analysis swift config path` to print the configuration file path. set validates an Obsidian destination before saving it. get prints the stored value. unset removes it.
      """.reflowedHelp(),
    subcommands: [ConfigGet.self, ConfigSet.self, ConfigUnset.self, ConfigPath.self]
  )
}

enum ConfigKey: String, ExpressibleByArgument, CaseIterable {
  case obsidianMatchReportsRoot = "obsidian-match-reports-root"
  case obsidianStrategyBooksRoot = "obsidian-strategy-books-root"

  var obsidianDirectory: ObsidianDirectory {
    switch self {
    case .obsidianMatchReportsRoot: .matchReports
    case .obsidianStrategyBooksRoot: .strategyBooks
    }
  }
}

struct ConfigGet: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "get", abstract: "Print one configured value.")

  @Argument(help: "Configuration key: obsidian-match-reports-root or obsidian-strategy-books-root.")
  var key: ConfigKey

  func run() throws {
    let configuration = try UserConfigurationStore().load()
    let value: String?
    switch key {
    case .obsidianMatchReportsRoot:
      value = configuration.obsidianMatchReportsRoot
    case .obsidianStrategyBooksRoot:
      value = configuration.obsidianStrategyBooksRoot
    }
    guard let value else {
      throw UniteAnalysisSwiftToolError.message("\(key.rawValue) is not configured")
    }
    print(value)
  }
}

struct ConfigSet: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "set", abstract: "Validate and save one configured value.")

  @Argument(help: "Configuration key: obsidian-match-reports-root or obsidian-strategy-books-root.")
  var key: ConfigKey

  @Argument(help: "Value to save.")
  var value: String

  func run() throws {
    print(
      try UserConfigurationStore().setObsidianDirectory(key.obsidianDirectory, path: value).path)
  }
}

struct ConfigUnset: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "unset", abstract: "Remove one configured value.")

  @Argument(help: "Configuration key: obsidian-match-reports-root or obsidian-strategy-books-root.")
  var key: ConfigKey

  func run() throws {
    try UserConfigurationStore().unsetObsidianDirectory(key.obsidianDirectory)
  }
}

struct ConfigPath: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "path", abstract: "Print the user configuration file path.")

  func run() {
    print(UserConfigurationStore.defaultFileURL.path)
  }
}
