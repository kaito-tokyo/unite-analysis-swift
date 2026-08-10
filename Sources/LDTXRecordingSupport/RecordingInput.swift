// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum RecordingInputError: Error, CustomStringConvertible {
  case inputNotFound(String)
  case unfinishedRecording(String)
  case invalidInfoPlist(String)
  case mainMediaNotFound(String)

  public var description: String {
    switch self {
    case .inputNotFound(let path):
      return "Input not found: \(path)"
    case .unfinishedRecording(let path):
      return
        "Recording is not finalized (missing .finalized): \(path). Pass --allow-unfinished to override."
    case .invalidInfoPlist(let path):
      return "Could not read LDTX recording metadata: \(path)"
    case .mainMediaNotFound(let path):
      return "Main media file was not found for recording: \(path)"
    }
  }
}

public struct ResolvedRecordingInput: Sendable {
  public let inputURL: URL
  public let videoURL: URL
  public let bundleURL: URL?

  public static func resolve(_ path: String, allowUnfinished: Bool = false) throws -> Self {
    let inputURL = URL(fileURLWithPath: path).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: inputURL.path, isDirectory: &isDirectory) else {
      throw RecordingInputError.inputNotFound(inputURL.path)
    }
    guard isDirectory.boolValue else {
      return Self(inputURL: inputURL, videoURL: inputURL, bundleURL: nil)
    }

    if !allowUnfinished,
      !FileManager.default.fileExists(atPath: inputURL.appendingPathComponent(".finalized").path)
    {
      throw RecordingInputError.unfinishedRecording(inputURL.path)
    }

    let infoURL = inputURL.appendingPathComponent("Info.plist")
    if FileManager.default.fileExists(atPath: infoURL.path) {
      guard let data = try? Data(contentsOf: infoURL),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
        let dictionary = plist as? [String: Any]
      else {
        throw RecordingInputError.invalidInfoPlist(infoURL.path)
      }
      if let relativePath = dictionary["LDTXRecordingMainMediaFile"] as? String,
        !relativePath.isEmpty
      {
        let videoURL = inputURL.appendingPathComponent(relativePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
          throw RecordingInputError.mainMediaNotFound(videoURL.path)
        }
        return Self(inputURL: inputURL, videoURL: videoURL, bundleURL: inputURL)
      }
    }

    let fallback = inputURL.appendingPathComponent("output-video.mp4")
    guard FileManager.default.fileExists(atPath: fallback.path) else {
      throw RecordingInputError.mainMediaNotFound(inputURL.path)
    }
    return Self(inputURL: inputURL, videoURL: fallback, bundleURL: inputURL)
  }
}
