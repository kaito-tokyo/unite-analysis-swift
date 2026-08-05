// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum UserConfigurationError: Error, CustomStringConvertible {
  case invalidObsidianDirectory(String)

  public var description: String {
    switch self {
    case .invalidObsidianDirectory(let path):
      return "Obsidian directory must be an existing directory: \(path)"
    }
  }
}

public struct UserConfiguration: Codable, Equatable, Sendable {
  public var obsidianMatchReportsRoot: String?
  public var obsidianStrategyBooksRoot: String?

  public init(obsidianMatchReportsRoot: String? = nil, obsidianStrategyBooksRoot: String? = nil) {
    self.obsidianMatchReportsRoot = obsidianMatchReportsRoot
    self.obsidianStrategyBooksRoot = obsidianStrategyBooksRoot
  }
}

public enum ObsidianDirectory: Sendable {
  case matchReports
  case strategyBooks
}

public struct UserConfigurationStore: Sendable {
  public let fileURL: URL

  public init(fileURL: URL = Self.defaultFileURL) {
    self.fileURL = fileURL
  }

  public static var defaultFileURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".config", isDirectory: true)
      .appendingPathComponent("unite-analysis-swift", isDirectory: true)
      .appendingPathComponent("config.json")
  }

  public func load() throws -> UserConfiguration {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return UserConfiguration()
    }
    return try JSONDecoder().decode(UserConfiguration.self, from: Data(contentsOf: fileURL))
  }

  @discardableResult
  public func setObsidianDirectory(_ directory: ObsidianDirectory, path: String) throws -> URL {
    let expandedPath = NSString(string: path).expandingTildeInPath
    let resolvedURL = URL(fileURLWithPath: expandedPath, isDirectory: true)
      .standardizedFileURL.resolvingSymlinksInPath()
    var isDirectory: ObjCBool = false
    guard
      FileManager.default.fileExists(atPath: resolvedURL.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      throw UserConfigurationError.invalidObsidianDirectory(path)
    }

    var configuration = try load()
    switch directory {
    case .matchReports:
      configuration.obsidianMatchReportsRoot = resolvedURL.path
    case .strategyBooks:
      configuration.obsidianStrategyBooksRoot = resolvedURL.path
    }
    try save(configuration)
    return resolvedURL
  }

  public func unsetObsidianDirectory(_ directory: ObsidianDirectory) throws {
    var configuration = try load()
    switch directory {
    case .matchReports:
      configuration.obsidianMatchReportsRoot = nil
    case .strategyBooks:
      configuration.obsidianStrategyBooksRoot = nil
    }
    try save(configuration)
  }

  private func save(_ configuration: UserConfiguration) throws {
    try FileManager.default.createDirectory(
      at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    var data = try encoder.encode(configuration)
    data.append(0x0A)
    try data.write(to: fileURL, options: .atomic)
  }
}
