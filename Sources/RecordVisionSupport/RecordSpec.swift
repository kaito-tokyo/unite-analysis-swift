// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct RecordVisionRecordSpec: Decodable {
  public struct StartPTS: Decodable {
    public let value: Int64
    public let timescale: Int32
  }

  public struct VideoComponent: Decodable {
    public let name: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
  }

  public let globalId: String
  public let isCompleted: Bool
  public let startPTS: StartPTS
  public let duration: Double
  public let videoComponents: [VideoComponent]
}
