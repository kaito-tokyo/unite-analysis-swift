// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct RecordVisionRecordSpec: Decodable, Sendable {
  public static let currentVersion = 2

  public struct StartPTS: Decodable, Sendable {
    public let value: Int64
    public let timescale: Int32
  }

  public struct VideoComponent: Decodable, Sendable {
    public let name: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
  }

  public let version: Int
  public let matchId: String
  public let startPTS: StartPTS
  public let duration: Double
  public let videoComponents: [VideoComponent]

  private enum CodingKeys: String, CodingKey {
    case version, globalId, matchId, startPTS, duration, videoComponents
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    version = try container.decode(Int.self, forKey: .version)
    guard version == 1 || version == Self.currentVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .version,
        in: container,
        debugDescription:
          "Unsupported record-spec version \(version); expected 1 or \(Self.currentVersion)"
      )
    }
    switch version {
    case 1:
      matchId = try container.decode(String.self, forKey: .globalId)
      guard !container.contains(.matchId) else {
        throw DecodingError.dataCorruptedError(
          forKey: .matchId,
          in: container,
          debugDescription: "record-spec version 1 uses globalId, not matchId"
        )
      }
    case Self.currentVersion:
      matchId = try container.decode(String.self, forKey: .matchId)
      guard !container.contains(.globalId) else {
        throw DecodingError.dataCorruptedError(
          forKey: .globalId,
          in: container,
          debugDescription: "record-spec version 2 uses matchId, not globalId"
        )
      }
    default:
      preconditionFailure("Unsupported version was rejected above")
    }
    startPTS = try container.decode(StartPTS.self, forKey: .startPTS)
    duration = try container.decode(Double.self, forKey: .duration)
    videoComponents = try container.decode([VideoComponent].self, forKey: .videoComponents)
  }
}
