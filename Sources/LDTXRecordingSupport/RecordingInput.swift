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

public struct VisionIndexRecord: Sendable, Equatable {
  public let visionID: String
  public let recordingTimelineMilliseconds: Int64
  public let output: String
  public let jsonURL: URL
  public let imageURL: URL?
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

  public func visionIndexRecords() -> [VisionIndexRecord] {
    guard let bundleURL else { return [] }
    let visionsURL = bundleURL.appendingPathComponent("Visions", isDirectory: true)
    guard
      let enumerator = FileManager.default.enumerator(
        at: visionsURL,
        includingPropertiesForKeys: [.isRegularFileKey],
        options: [.skipsHiddenFiles]
      )
    else { return [] }

    var records: [VisionIndexRecord] = []
    for case let jsonURL as URL in enumerator where jsonURL.pathExtension.lowercased() == "json" {
      guard let data = try? Data(contentsOf: jsonURL),
        let object = try? JSONSerialization.jsonObject(with: data),
        let dictionary = object as? [String: Any],
        let milliseconds = (dictionary["recordingTimelineMilliseconds"] as? NSNumber)?.int64Value,
        let output = dictionary["output"] as? String
      else { continue }
      let visionID =
        (dictionary["visionID"] as? String) ?? jsonURL.deletingLastPathComponent().lastPathComponent
      let imageName = dictionary["imageFileName"] as? String
      let imageURL = imageName.map {
        jsonURL.deletingLastPathComponent().appendingPathComponent($0)
      }
      records.append(
        VisionIndexRecord(
          visionID: visionID,
          recordingTimelineMilliseconds: milliseconds,
          output: output,
          jsonURL: jsonURL,
          imageURL: imageURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
        ))
    }
    return records.sorted {
      if $0.recordingTimelineMilliseconds != $1.recordingTimelineMilliseconds {
        return $0.recordingTimelineMilliseconds < $1.recordingTimelineMilliseconds
      }
      return $0.visionID < $1.visionID
    }
  }
}

public func findExecutable(_ name: String) -> URL? {
  let searchPath =
    ProcessInfo.processInfo.environment["PATH"]
    ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  for directory in searchPath.split(separator: ":") {
    let candidate = URL(fileURLWithPath: String(directory)).appendingPathComponent(name)
    if FileManager.default.isExecutableFile(atPath: candidate.path) {
      return candidate
    }
  }
  return nil
}
