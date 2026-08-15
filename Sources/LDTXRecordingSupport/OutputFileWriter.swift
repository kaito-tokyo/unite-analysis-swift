// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum OutputFileError: Error, CustomStringConvertible {
  case alreadyExists(String)

  public var description: String {
    switch self {
    case .alreadyExists(let path):
      return "Output already exists: \(path). Pass --force to overwrite."
    }
  }
}

public enum OutputFileWriter {
  public static func validate(_ outputURL: URL?, force: Bool) throws {
    guard let outputURL else { return }
    guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
      throw OutputFileError.alreadyExists(outputURL.path)
    }
  }

  public static func write(_ data: Data, to outputURL: URL, force: Bool) throws {
    try validate(outputURL, force: force)
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporaryURL = temporaryURL(for: outputURL)
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try data.write(to: temporaryURL)
    try install(temporaryURL, at: outputURL, force: force)
  }

  public static func install(_ temporaryURL: URL, at outputURL: URL, force: Bool) throws {
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if force {
      if FileManager.default.fileExists(atPath: outputURL.path) {
        _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
      } else {
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
      }
      return
    }
    do {
      try FileManager.default.linkItem(at: temporaryURL, to: outputURL)
      try FileManager.default.removeItem(at: temporaryURL)
    } catch {
      if FileManager.default.fileExists(atPath: outputURL.path) {
        throw OutputFileError.alreadyExists(outputURL.path)
      }
      throw error
    }
  }

  public static func temporaryURL(for outputURL: URL, suffix: String = ".tmp") -> URL {
    outputURL.deletingLastPathComponent().appendingPathComponent(
      ".\(outputURL.lastPathComponent).\(UUID().uuidString)\(suffix)")
  }
}
