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
  public let auditId: String?
  public let outputs: [String]
  public let observationCount: Int
  public let columns: Int
  public let pageCount: Int

  public init(
    auditId: String? = nil, outputs: [String], observationCount: Int, columns: Int, pageCount: Int
  ) {
    self.auditId = auditId
    self.outputs = outputs
    self.observationCount = observationCount
    self.columns = columns
    self.pageCount = pageCount
  }
}

public enum MatchTimerAuditContactSheet {
  private static let cellWidth = 320
  private static let gutter = 4
  private static let labelLineHeight = 22
  private static let maximumJPEGDimension = 65_535
  private static let maximumBitmapPixels = 128_000_000
  public static let observationsPerPage = 120

  public static func render(
    videoURL: URL,
    gameScreen: GameScreenRectangle,
    layout: MatchTimerLayout,
    diagnostics: [MatchTimerDiagnostic],
    outputPrefixURL: URL,
    quality: Double = 0.85,
    force: Bool
  ) async throws -> MatchTimerAuditContactSheetResult {
    try layout.validate()
    guard gameScreen.width > 0, gameScreen.height > 0 else {
      throw Error.message("Game-screen dimensions must be positive")
    }
    guard quality.isFinite, (0...1).contains(quality) else {
      throw Error.message("Timer audit JPEG quality must be between 0 and 1")
    }
    let definition = MatchTimerAuditContactSheetDefinition(diagnostics: diagnostics)
    let pages =
      definition.cells.isEmpty
      ? [[]]
      : stride(from: 0, to: definition.cells.count, by: observationsPerPage).map {
        Array(definition.cells[$0..<min($0 + observationsPerPage, definition.cells.count)])
      }
    let outputURLs = pageOutputURLs(
      prefix: outputPrefixURL, observationCount: definition.cells.count)
    if !force,
      let collision = outputURLs.first(where: {
        FileManager.default.fileExists(atPath: $0.path)
      })
    {
      throw Error.message("Output already exists: \(collision.path). Pass --force to overwrite.")
    }
    if force {
      for outputURL in outputURLs where FileManager.default.fileExists(atPath: outputURL.path) {
        guard try outputURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        else {
          throw Error.message("Audit page destination is not a regular file: \(outputURL.path)")
        }
      }
    }
    let timer = MatchTimerVideoOCR.timerRectangle(gameScreen: gameScreen, layout: layout)
    guard timer.width.isFinite, timer.height.isFinite, timer.width > 0, timer.height > 0 else {
      throw Error.message("Resolved timer rectangle must be finite and positive")
    }
    let imageHeightValue = max(60, (Double(cellWidth) * timer.height / timer.width).rounded())
    let maximumLabelLines =
      definition.cells.map { labelLines($0, actualMilliseconds: 0).count }.max() ?? 1
    let labelHeightValue = Double(maximumLabelLines * labelLineHeight + 12)
    let cellHeightValue = imageHeightValue + labelHeightValue
    guard imageHeightValue.isFinite, cellHeightValue.isFinite,
      imageHeightValue <= Double(maximumJPEGDimension),
      cellHeightValue <= Double(maximumJPEGDimension)
    else {
      throw Error.message("Timer audit cell dimensions exceed the supported JPEG size")
    }
    let imageHeight = Int(imageHeightValue)
    let labelHeight = Int(labelHeightValue)
    let cellHeight = Int(cellHeightValue)
    let extractor =
      definition.cells.isEmpty ? nil : try await VideoFrameExtractor(videoURL: videoURL)
    let columns = min(MatchTimerAuditContactSheetDefinition.columns, max(1, definition.cells.count))
    let stagedURLs = outputURLs.map { outputURL in
      outputURL.deletingLastPathComponent().appendingPathComponent(
        ".\(outputURL.lastPathComponent).\(UUID().uuidString).staged.jpg")
    }
    defer { for url in stagedURLs { try? FileManager.default.removeItem(at: url) } }
    for (pageIndex, cells) in pages.enumerated() {
      try Task.checkCancellation()
      let rows = max(1, Int(ceil(Double(cells.count) / Double(columns))))
      let width = columns * cellWidth + max(0, columns - 1) * gutter
      let height = rows * cellHeight + max(0, rows - 1) * gutter
      guard height <= maximumJPEGDimension, width * height <= maximumBitmapPixels else {
        throw Error.message("Timer audit page dimensions exceed the supported image size")
      }
      try renderPage(
        cells: cells, extractor: extractor, timer: timer, imageHeight: imageHeight,
        labelHeight: labelHeight, cellHeight: cellHeight, columns: columns, width: width,
        height: height,
        outputURL: stagedURLs[pageIndex], quality: quality, force: true)
    }
    try installStagedPages(stagedURLs, at: outputURLs, force: force)
    if force { try removeObsoletePages(prefix: outputPrefixURL, keeping: Set(outputURLs)) }
    return .init(
      auditId: nil, outputs: outputURLs.map(\.path), observationCount: definition.cells.count,
      columns: columns, pageCount: pages.count)
  }

  private static func renderPage(
    cells: [MatchTimerAuditContactSheetDefinition.Cell], extractor: VideoFrameExtractor?,
    timer: CGRect, imageHeight: Int, labelHeight: Int, cellHeight: Int, columns: Int, width: Int,
    height: Int, outputURL: URL, quality: Double, force: Bool
  ) throws {
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { throw Error.message("Could not allocate timer audit contact sheet") }
    context.setFillColor(CGColor(red: 0.055, green: 0.071, blue: 0.09, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))

    if cells.isEmpty {
      drawText(
        "No timer observations", at: CGPoint(x: 16, y: CGFloat(height / 2) - 8),
        size: 18, color: CGColor(gray: 1, alpha: 1), context: context)
    } else {
      guard let extractor else { throw Error.message("Missing timer audit video extractor") }
      let milliseconds = Array(Set(cells.map(\.recordingTimelineMilliseconds))).sorted()
      let times = milliseconds.map { CMTime(value: max(0, $0 - 1), timescale: 1_000) }
      var frames: [Int64: (CGImage, CMTime)] = [:]
      try extractor.extractFrames(at: times) { index, frame, actualTime in
        try Task.checkCancellation()
        let crop = try autoreleasepool { try VideoFrameSupport.cropped(frame, rect: timer) }
        frames[milliseconds[index]] = (crop, actualTime)
      }
      for (index, cell) in cells.enumerated() {
        try Task.checkCancellation()
        guard let (frame, actualTime) = frames[cell.recordingTimelineMilliseconds] else {
          throw Error.message("Missing decoded timer audit frame")
        }
        let column = index % columns
        let row = index / columns
        let x = column * (cellWidth + gutter)
        let y = height - (row + 1) * cellHeight - row * gutter
        context.interpolationQuality = .high
        context.draw(
          frame,
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
    if force, FileManager.default.fileExists(atPath: outputURL.path) {
      _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: temporaryURL)
    } else if force {
      try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
    } else {
      do {
        try FileManager.default.linkItem(at: temporaryURL, to: outputURL)
        try FileManager.default.removeItem(at: temporaryURL)
      } catch {
        if FileManager.default.fileExists(atPath: outputURL.path) {
          throw Error.message(
            "Output already exists: \(outputURL.path). Pass --force to overwrite.")
        }
        throw error
      }
    }
  }

  public static func pageOutputURL(prefix: URL, index: Int) -> URL {
    URL(fileURLWithPath: String(format: "%@-%06d.jpg", prefix.path, index))
  }

  private static func installStagedPage(_ stagedURL: URL, at outputURL: URL, force: Bool) throws {
    if force, FileManager.default.fileExists(atPath: outputURL.path) {
      _ = try FileManager.default.replaceItemAt(outputURL, withItemAt: stagedURL)
    } else if force {
      try FileManager.default.moveItem(at: stagedURL, to: outputURL)
    } else {
      do {
        try FileManager.default.linkItem(at: stagedURL, to: outputURL)
        try FileManager.default.removeItem(at: stagedURL)
      } catch {
        if FileManager.default.fileExists(atPath: outputURL.path) {
          throw Error.message(
            "Output already exists: \(outputURL.path). Pass --force to overwrite.")
        }
        throw error
      }
    }
  }

  package static func installStagedPages(
    _ stagedURLs: [URL], at outputURLs: [URL], force: Bool
  ) throws {
    precondition(stagedURLs.count == outputURLs.count)
    var installedURLs: [URL] = []
    var attemptedIndices: [Int] = []
    var backupURLs: [Int: URL] = [:]
    defer { for url in backupURLs.values { try? FileManager.default.removeItem(at: url) } }
    if force {
      for index in outputURLs.indices
      where FileManager.default.fileExists(atPath: outputURLs[index].path) {
        let backupURL = outputURLs[index].deletingLastPathComponent().appendingPathComponent(
          ".\(outputURLs[index].lastPathComponent).\(UUID().uuidString).backup")
        try FileManager.default.linkItem(at: outputURLs[index], to: backupURL)
        backupURLs[index] = backupURL
      }
    }
    do {
      for index in outputURLs.indices {
        attemptedIndices.append(index)
        try installStagedPage(stagedURLs[index], at: outputURLs[index], force: force)
        installedURLs.append(outputURLs[index])
      }
    } catch let installationError {
      if force {
        do {
          for index in attemptedIndices.reversed() {
            if let backupURL = backupURLs[index] {
              if FileManager.default.fileExists(atPath: outputURLs[index].path) {
                try FileManager.default.removeItem(at: outputURLs[index])
              }
              try FileManager.default.moveItem(at: backupURL, to: outputURLs[index])
              backupURLs[index] = nil
            } else if installedURLs.contains(outputURLs[index]) {
              try FileManager.default.removeItem(at: outputURLs[index])
            }
          }
        } catch {
          throw Error.message(
            "Timer audit installation failed and rollback also failed: \(installationError); \(error)"
          )
        }
      } else {
        do {
          for url in installedURLs.reversed() {
            try FileManager.default.removeItem(at: url)
          }
        } catch {
          throw Error.message(
            "Timer audit installation failed and rollback also failed: \(installationError); \(error)"
          )
        }
      }
      throw installationError
    }
  }

  public static func pageOutputURLs(prefix: URL, observationCount: Int) -> [URL] {
    let count = max(1, Int(ceil(Double(observationCount) / Double(observationsPerPage))))
    return (1...count).map { pageOutputURL(prefix: prefix, index: $0) }
  }

  private static func removeObsoletePages(prefix: URL, keeping: Set<URL>) throws {
    let directory = prefix.deletingLastPathComponent()
    let caseSensitive =
      try directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
      .volumeSupportsCaseSensitiveNames ?? true
    let normalizedPrefix = normalizedFilename(
      prefix.lastPathComponent, caseSensitive: caseSensitive)
    let keepingFilenames = Set(
      keeping.map { normalizedFilename($0.lastPathComponent, caseSensitive: caseSensitive) })
    for url in try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isRegularFileKey])
    where !keepingFilenames.contains(
      normalizedFilename(url.lastPathComponent, caseSensitive: caseSensitive))
      && isAuditPageFilename(
        url.lastPathComponent, normalizedPrefix: normalizedPrefix, caseSensitive: caseSensitive)
    {
      guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
        throw Error.message("Obsolete audit page path is not a regular file: \(url.path)")
      }
      try FileManager.default.removeItem(at: url)
    }
  }

  private static func normalizedFilename(_ value: String, caseSensitive: Bool) -> String {
    let normalized = value.decomposedStringWithCanonicalMapping
    return caseSensitive ? normalized : normalized.lowercased()
  }

  private static func isAuditPageFilename(
    _ filename: String, normalizedPrefix: String, caseSensitive: Bool
  ) -> Bool {
    let normalized = normalizedFilename(filename, caseSensitive: caseSensitive)
    let expectedPrefix = normalizedPrefix + "-"
    guard normalized.hasPrefix(expectedPrefix), normalized.hasSuffix(".jpg") else { return false }
    let digits = normalized.dropFirst(expectedPrefix.count).dropLast(4)
    return digits.count == 6 && digits.allSatisfy { $0.isASCII && $0.isNumber }
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
    let lines = labelLines(cell, actualMilliseconds: actualMilliseconds)
    for (index, line) in lines.enumerated() {
      drawText(
        line, at: CGPoint(x: frame.minX + 6, y: frame.maxY - 20 - CGFloat(index * 22)),
        size: 12, color: CGColor(gray: 1, alpha: 1), context: context)
    }
  }

  private static func labelLines(
    _ cell: MatchTimerAuditContactSheetDefinition.Cell, actualMilliseconds: Int64
  ) -> [String] {
    let confidence =
      cell.confidence.map {
        String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0)
      } ?? "null"
    let selected = cell.output.isEmpty ? "<no text>" : cell.output
    return [
      "requested \(format(milliseconds: cell.recordingTimelineMilliseconds))  actual \(format(milliseconds: actualMilliseconds))",
      "OCR \(selected)",
      "confidence \(confidence)",
      "\(cell.disposition): \(cell.reason)",
    ].flatMap(wrapLabelLine)
  }

  private static func wrapLabelLine(_ line: String) -> [String] {
    let font = CTFontCreateWithName("Menlo" as CFString, 12, nil)
    let attributed = NSAttributedString(
      string: line, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
    guard attributed.length > 0 else { return [""] }
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let string = line as NSString
    var lines: [String] = []
    var offset = 0
    repeat {
      let count = max(
        1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(cellWidth - 12)))
      lines.append(string.substring(with: NSRange(location: offset, length: count)))
      offset += count
    } while offset < attributed.length
    return lines
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
