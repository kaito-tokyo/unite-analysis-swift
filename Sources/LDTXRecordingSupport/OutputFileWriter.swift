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
    let result = temporaryURL.withUnsafeFileSystemRepresentation { temporaryPath in
      outputURL.withUnsafeFileSystemRepresentation { outputPath in
        guard let temporaryPath, let outputPath else {
          errno = EINVAL
          return Int32(-1)
        }
        if force {
          return Darwin.rename(temporaryPath, outputPath)
        }
        return renameatx_np(AT_FDCWD, temporaryPath, AT_FDCWD, outputPath, UInt32(RENAME_EXCL))
      }
    }
    guard result != 0 else { return }
    let errorNumber = errno
    if !force, errorNumber == EEXIST {
      throw OutputFileError.alreadyExists(outputURL.path)
    }
    throw NSError(
      domain: NSPOSIXErrorDomain, code: Int(errorNumber),
      userInfo: [NSFilePathErrorKey: outputURL.path])
  }

  public static func temporaryURL(for outputURL: URL, suffix: String = ".tmp") -> URL {
    outputURL.deletingLastPathComponent().appendingPathComponent(
      ".\(outputURL.lastPathComponent).\(UUID().uuidString)\(suffix)")
  }
}
