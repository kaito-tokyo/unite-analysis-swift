// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Darwin
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
      try installForced(temporaryURL, at: outputURL)
      return
    }
    let result = renameExclusively(temporaryURL, to: outputURL)
    guard result != 0 else { return }
    let errorNumber = errno
    if errorNumber == EEXIST {
      throw OutputFileError.alreadyExists(outputURL.path)
    }
    throw posixError(errorNumber, path: outputURL.path)
  }

  private static func installForced(_ temporaryURL: URL, at outputURL: URL) throws {
    var lastReplacementError: Error?
    for _ in 0..<8 {
      do {
        _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
        return
      } catch {
        lastReplacementError = error
        if FileManager.default.fileExists(atPath: outputURL.path) { continue }
      }

      let result = renameExclusively(temporaryURL, to: outputURL)
      guard result != 0 else { return }
      let errorNumber = errno
      guard errorNumber == EEXIST else {
        throw posixError(errorNumber, path: outputURL.path)
      }
    }
    throw lastReplacementError ?? posixError(EBUSY, path: outputURL.path)
  }

  private static func renameExclusively(_ sourceURL: URL, to destinationURL: URL) -> Int32 {
    sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
      destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
        guard let sourcePath, let destinationPath else {
          errno = EINVAL
          return Int32(-1)
        }
        return renameatx_np(
          AT_FDCWD, sourcePath, AT_FDCWD, destinationPath, UInt32(RENAME_EXCL))
      }
    }
  }

  private static func posixError(_ errorNumber: Int32, path: String) -> NSError {
    NSError(
      domain: NSPOSIXErrorDomain, code: Int(errorNumber), userInfo: [NSFilePathErrorKey: path])
  }

  public static func temporaryURL(for outputURL: URL, suffix: String = ".tmp") -> URL {
    outputURL.deletingLastPathComponent().appendingPathComponent(
      ".\(outputURL.lastPathComponent).\(UUID().uuidString)\(suffix)")
  }
}
