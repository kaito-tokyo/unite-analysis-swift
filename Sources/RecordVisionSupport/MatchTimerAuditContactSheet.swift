// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CoreMedia
import CoreText
import Foundation
import LDTXRecordingSupport

public struct MatchTimerAuditContactSheetDefinition: Equatable, Sendable {
  public struct Cell: Equatable, Sendable {
    public let recordingTimelineMilliseconds: Int64
    public let output: String
    public let confidence: Float?
    public let disposition: String
    public let reason: String
  }

  public static let columns = 4
  public let cells: [Cell]

  public init(diagnostics: [MatchTimerDiagnostic]) {
    cells = diagnostics.sorted {
      if $0.recordingTimelineMilliseconds != $1.recordingTimelineMilliseconds {
        return $0.recordingTimelineMilliseconds < $1.recordingTimelineMilliseconds
      }
      return $0.output < $1.output
    }.map {
      .init(
        recordingTimelineMilliseconds: $0.recordingTimelineMilliseconds, output: $0.output,
        confidence: $0.confidence, disposition: $0.disposition, reason: $0.reason)
    }
  }
}

public struct MatchTimerAuditContactSheetResult: Codable, Equatable, Sendable {
  public let output: String
  public let observationCount: Int
  public let columns: Int
  public let rows: Int
}

public enum MatchTimerAuditContactSheet {
  private static let cellWidth = 320
  private static let labelHeight = 78
  private static let gutter = 4

  public static func render(
    videoURL: URL,
    gameScreen: GameScreenRectangle,
    layout: MatchTimerLayout,
    diagnostics: [MatchTimerDiagnostic],
    outputURL: URL,
    quality: Double = 0.85,
    force: Bool
  ) async throws -> MatchTimerAuditContactSheetResult {
    guard quality.isFinite, (0...1).contains(quality) else {
      throw Error.message("Timer audit JPEG quality must be between 0 and 1")
    }
    guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
      throw Error.message("Output already exists: \(outputURL.path). Pass --force to overwrite.")
    }
    let definition = MatchTimerAuditContactSheetDefinition(diagnostics: diagnostics)
    let columns = min(MatchTimerAuditContactSheetDefinition.columns, max(1, definition.cells.count))
    let rows = max(1, Int(ceil(Double(definition.cells.count) / Double(columns))))
    let timer = MatchTimerVideoOCR.timerRectangle(gameScreen: gameScreen, layout: layout)
    let imageHeight = max(60, Int((Double(cellWidth) * timer.height / timer.width).rounded()))
    let cellHeight = imageHeight + labelHeight
    let width = columns * cellWidth + max(0, columns - 1) * gutter
    let height = rows * cellHeight + max(0, rows - 1) * gutter
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Error.message("Could not allocate timer audit contact sheet") }
    context.setFillColor(CGColor(red: 0.055, green: 0.071, blue: 0.09, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    if definition.cells.isEmpty {
      drawText(
        "No timer observations", at: CGPoint(x: 16, y: CGFloat(height / 2) - 8),
        size: 18, color: CGColor(gray: 1, alpha: 1), context: context)
    } else {
      let extractor = try await VideoFrameExtractor(videoURL: videoURL)
      let times = definition.cells.map {
        CMTime(value: $0.recordingTimelineMilliseconds, timescale: 1_000)
      }
      try extractor.extractFrames(at: times) { index, frame, actualTime in
        let cell = definition.cells[index]
        let column = index % columns
        let row = index / columns
        let x = column * (cellWidth + gutter)
        let y = height - (row + 1) * cellHeight - row * gutter
        let crop = try VideoFrameSupport.cropped(frame, rect: timer)
        context.interpolationQuality = .high
        context.draw(
          crop,
          in: CGRect(x: x, y: y + labelHeight, width: cellWidth, height: imageHeight))
        drawLabel(
          cell, actualMilliseconds: Int64((actualTime.seconds * 1_000).rounded()),
          frame: CGRect(x: x, y: y, width: cellWidth, height: labelHeight), context: context)
      }
    }

    guard let image = context.makeImage() else {
      throw Error.message("Could not finalize timer audit contact sheet")
    }
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let temporaryURL = outputURL.deletingLastPathComponent().appendingPathComponent(
      ".\(outputURL.lastPathComponent).\(UUID().uuidString).tmp.jpg")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    try VideoFrameSupport.writeBaselineJPEG(image, to: temporaryURL, quality: quality)
    if FileManager.default.fileExists(atPath: outputURL.path) {
      _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
    } else {
      try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
    }
    return .init(
      output: outputURL.path, observationCount: definition.cells.count, columns: columns, rows: rows
    )
  }

  private static func drawLabel(
    _ cell: MatchTimerAuditContactSheetDefinition.Cell,
    actualMilliseconds: Int64,
    frame: CGRect,
    context: CGContext
  ) {
    let accepted = cell.disposition == "accepted"
    context.setFillColor(
      accepted
        ? CGColor(red: 0.055, green: 0.31, blue: 0.18, alpha: 1)
        : CGColor(red: 0.36, green: 0.08, blue: 0.08, alpha: 1))
    context.fill(frame)
    let confidence =
      cell.confidence.map {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0)
      } ?? "null"
    let selected = cell.output.isEmpty ? "<no text>" : cell.output
    let lines = [
      "requested \(format(milliseconds: cell.recordingTimelineMilliseconds))  actual \(format(milliseconds: actualMilliseconds))",
      "OCR \(selected)  confidence \(confidence)",
      "\(cell.disposition): \(cell.reason)",
    ]
    for (index, line) in lines.enumerated() {
      drawText(
        line, at: CGPoint(x: frame.minX + 6, y: frame.maxY - 20 - CGFloat(index * 22)),
        size: 12, color: CGColor(gray: 1, alpha: 1), context: context)
    }
  }

  private static func drawText(
    _ value: String, at point: CGPoint, size: CGFloat, color: CGColor, context: CGContext
  ) {
    let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(
        string: value,
        attributes: [
          kCTFontAttributeName as NSAttributedString.Key: font,
          kCTForegroundColorAttributeName as NSAttributedString.Key: color,
        ]))
    context.textPosition = point
    CTLineDraw(line, context)
  }

  private static func format(milliseconds: Int64) -> String {
    String(
      format: "%.3fs", locale: Locale(identifier: "en_US_POSIX"),
      Double(milliseconds) / 1_000)
  }

  public enum Error: Swift.Error, CustomStringConvertible {
    case message(String)

    public var description: String {
      switch self {
      case .message(let value): value
      }
    }
  }
}
