// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import CoreGraphics
import CoreMedia
import CoreText
import Foundation
import JavaScriptCore
import JavaScriptCoreSupport
import LDTXRecordingSupport

public enum ContactSheetGeneratorError: Error, CustomStringConvertible {
  case message(String)

  public var description: String {
    switch self {
    case .message(let value): value
    }
  }
}

public enum RecordVisionInputLogger {
  public static func recordSpec(_ url: URL) {
    write("record spec", url)
  }

  public static func sourceVideo(_ url: URL) {
    write("source video", url)
  }

  public static func sourceAudio(_ url: URL) {
    write("source audio", url)
  }

  public static func unfinishedRecording(_ url: URL) {
    let line =
      "unite-analysis-swift: warning: recording is not finalized (missing .finalized): " + url.path
      + "\n"
    FileHandle.standardError.write(Data(line.utf8))
  }

  private static func write(_ label: String, _ url: URL) {
    let line = "unite-analysis-swift: " + label + ": " + url.path + "\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}

private struct ContactSheetAnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}

private func rejectUnknownContactSheetKeys(
  from decoder: Decoder, allowedKeys: Set<String>, context: String
) throws {
  let container = try decoder.container(keyedBy: ContactSheetAnyCodingKey.self)
  let unknownKeys = Set(container.allKeys.map(\.stringValue)).subtracting(allowedKeys)
  guard unknownKeys.isEmpty else {
    throw DecodingError.dataCorrupted(
      .init(
        codingPath: decoder.codingPath,
        debugDescription: "Unknown \(context) keys: \(unknownKeys.sorted().joined(separator: ", "))"
      ))
  }
}

public struct ContactSheetDefinition: Codable {
  public struct Size: Codable {
    public let width: Int
    public let height: Int

    private enum CodingKeys: String, CodingKey, CaseIterable { case width, height }

    public init(from decoder: Decoder) throws {
      try rejectUnknownContactSheetKeys(
        from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)), context: "size")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      width = try container.decode(Int.self, forKey: .width)
      height = try container.decode(Int.self, forKey: .height)
    }
  }
  public struct Rectangle: Codable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    private enum CodingKeys: String, CodingKey, CaseIterable { case x, y, width, height }

    public init(from decoder: Decoder) throws {
      try rejectUnknownContactSheetKeys(
        from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
        context: "rectangle")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      x = try container.decode(Int.self, forKey: .x)
      y = try container.decode(Int.self, forKey: .y)
      width = try container.decode(Int.self, forKey: .width)
      height = try container.decode(Int.self, forKey: .height)
    }
  }
  public struct Text: Codable {
    public struct Script: Codable {
      public let `return`: String

      private enum CodingKeys: String, CodingKey, CaseIterable { case `return` }

      public init(from decoder: Decoder) throws {
        try rejectUnknownContactSheetKeys(
          from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
          context: "draw-text script")
        let container = try decoder.container(keyedBy: CodingKeys.self)
        `return` = try container.decode(String.self, forKey: .return)
      }
    }
    public let text: String?
    public let script: Script?
    public let x: Int
    public let y: Int
    public let fontSize: Double
    public let color: String?
    public let backgroundColor: String?
    public let borderColor: String?
    public let fontName: String?

    private enum CodingKeys: String, CodingKey, CaseIterable {
      case text, script, x, y, fontSize, color, backgroundColor, borderColor, fontName
    }

    public init(from decoder: Decoder) throws {
      try rejectUnknownContactSheetKeys(
        from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
        context: "draw-text")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      text = try container.decodeIfPresent(String.self, forKey: .text)
      script = try container.decodeIfPresent(Script.self, forKey: .script)
      x = try container.decode(Int.self, forKey: .x)
      y = try container.decode(Int.self, forKey: .y)
      fontSize = try container.decode(Double.self, forKey: .fontSize)
      color = try container.decodeIfPresent(String.self, forKey: .color)
      backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor)
      borderColor = try container.decodeIfPresent(String.self, forKey: .borderColor)
      fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
    }
  }
  public struct Placement: Codable {
    public let source: Rectangle?
    public let destination: Rectangle?
    public let drawText: Text?

    private enum CodingKeys: String, CodingKey, CaseIterable { case source, destination, drawText }

    public init(from decoder: Decoder) throws {
      try rejectUnknownContactSheetKeys(
        from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
        context: "placement")
      let container = try decoder.container(keyedBy: CodingKeys.self)
      source = try container.decodeIfPresent(Rectangle.self, forKey: .source)
      destination = try container.decodeIfPresent(Rectangle.self, forKey: .destination)
      drawText = try container.decodeIfPresent(Text.self, forKey: .drawText)
    }
  }
  public let cell: Size
  public let columns: Int
  public let backgroundColor: String?
  public let placements: [Placement]
  public let matchTimestamps: [Double]
  /// Required and validated by the command-line JSONL jobs interface.
  public let jobId: String?
  /// Required by the command-line jobs interface; ignored by the renderer itself.
  public let output: String?

  private enum CodingKeys: String, CodingKey, CaseIterable {
    case jobId, cell, columns, backgroundColor, placements, matchTimestamps, output, frames
  }

  public init(from decoder: Decoder) throws {
    try rejectUnknownContactSheetKeys(
      from: decoder, allowedKeys: Set(CodingKeys.allCases.map(\.rawValue)),
      context: "contact-sheet")
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.frames) {
      throw DecodingError.dataCorruptedError(
        forKey: .frames,
        in: container,
        debugDescription: "frames is no longer supported; use matchTimestamps")
    }
    cell = try container.decode(Size.self, forKey: .cell)
    columns = try container.decode(Int.self, forKey: .columns)
    backgroundColor = try container.decodeIfPresent(String.self, forKey: .backgroundColor)
    placements = try container.decode([Placement].self, forKey: .placements)
    matchTimestamps = try container.decode([Double].self, forKey: .matchTimestamps)
    jobId = try container.decodeIfPresent(String.self, forKey: .jobId)
    output = try container.decodeIfPresent(String.self, forKey: .output)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(cell, forKey: .cell)
    try container.encode(columns, forKey: .columns)
    try container.encodeIfPresent(backgroundColor, forKey: .backgroundColor)
    try container.encode(placements, forKey: .placements)
    try container.encode(matchTimestamps, forKey: .matchTimestamps)
    try container.encodeIfPresent(jobId, forKey: .jobId)
    try container.encodeIfPresent(output, forKey: .output)
  }
}

public enum DrawTextScriptEngine {
  package static let executionTimeLimit: TimeInterval = 0.1

  private static let terminateTimedOutScript: UASJavaScriptShouldTerminateCallback = {
    _, callbackContext in
    callbackContext?.assumingMemoryBound(to: Bool.self).pointee = true
    return true
  }

  public static func evaluate(
    script: String,
    recordSpecURL: URL,
    index: Int,
    inmatch: Double?,
    beforeStart: Double?,
    afterEnd: Double?,
    actualInmatch: Double? = nil
  ) async throws -> String {
    let values = [inmatch, beforeStart, afterEnd].compactMap { $0 }
    guard values.count == 1, values[0].isFinite else {
      throw ContactSheetGeneratorError.message(
        "Specify exactly one finite inmatch, beforeStart, or afterEnd value")
    }
    let record = try JSONDecoder().decode(
      RecordVisionRecordSpec.self, from: Data(contentsOf: recordSpecURL))
    RecordVisionInputLogger.recordSpec(recordSpecURL)
    let bundleURL = try recordingBundle(above: recordSpecURL)
    if !FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent(".finalized").path)
    {
      RecordVisionInputLogger.unfinishedRecording(bundleURL)
    }
    let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
    RecordVisionInputLogger.sourceVideo(recording.videoURL)
    let asset = AVURLAsset(url: recording.videoURL)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw ContactSheetGeneratorError.message("No video track")
    }
    let size = try await track.load(.naturalSize)
    return try evaluate(
      script: script, index: index, inmatch: inmatch, beforeStart: beforeStart, afterEnd: afterEnd,
      actualInmatch: actualInmatch,
      matchDuration: record.duration, recordMatchId: record.matchId,
      videoWidth: Int(size.width), videoHeight: Int(size.height),
      videoFrameRate: Double(try await track.load(.nominalFrameRate)),
      videoDuration: try await asset.load(.duration).seconds
    )
  }

  package static func evaluate(
    script: String,
    index: Int,
    inmatch: Double?,
    beforeStart: Double?,
    afterEnd: Double?,
    actualInmatch: Double? = nil,
    matchDuration: Double,
    recordMatchId: String,
    videoWidth: Int,
    videoHeight: Int,
    videoFrameRate: Double,
    videoDuration: Double
  ) throws -> String {
    guard let context = JSContext() else {
      throw ContactSheetGeneratorError.message("Could not create JavaScript context")
    }
    context.setObject(
      [
        "index": index,
        "inmatch": inmatch as Any,
        "beforeStart": beforeStart as Any,
        "afterEnd": afterEnd as Any,
        "actualInmatch": actualInmatch as Any,
      ], forKeyedSubscript: "FRAME" as NSString)
    context.setObject(["duration": matchDuration], forKeyedSubscript: "MATCH" as NSString)
    context.setObject(["matchId": recordMatchId], forKeyedSubscript: "RECORD" as NSString)
    context.setObject(
      [
        "width": videoWidth, "height": videoHeight, "frameRate": videoFrameRate,
        "duration": videoDuration,
      ], forKeyedSubscript: "VIDEO" as NSString)
    var timedOut = false
    let result = withUnsafeMutablePointer(to: &timedOut) { timedOutPointer in
      UASSetJavaScriptExecutionTimeLimit(
        context.jsGlobalContextRef, executionTimeLimit, terminateTimedOutScript, timedOutPointer)
      defer { UASClearJavaScriptExecutionTimeLimit(context.jsGlobalContextRef) }
      return context.evaluateScript(script)
    }
    if timedOut {
      throw ContactSheetGeneratorError.message(
        "drawText script timed out after \(executionTimeLimit) seconds")
    }
    if let exception = context.exception {
      throw ContactSheetGeneratorError.message(
        "drawText script failed: \(exception.toString() ?? "unknown error")")
    }
    guard let result, !result.isUndefined, !result.isNull else {
      throw ContactSheetGeneratorError.message("drawText script must return a value")
    }
    return result.toString() ?? ""
  }

  private static func recordingBundle(above recordSpecURL: URL) throws -> URL {
    var candidate = recordSpecURL.deletingLastPathComponent()
    while candidate.path != "/" {
      if candidate.pathExtension == "ldtxrecord" { return candidate }
      candidate.deleteLastPathComponent()
    }
    throw ContactSheetGeneratorError.message(
      "record-spec.json must be inside a .ldtxrecord bundle: \(recordSpecURL.path)")
  }
}

public enum ContactSheetGenerator {
  private static let cellSeparator: Int = 8
  private static let cellSeparatorColor = CGColor(red: 1, green: 0, blue: 1, alpha: 1)

  package struct PreparedInput {
    fileprivate let recordSpecURL: URL
    fileprivate let isFinalized: Bool
    fileprivate let recordSpec: RecordVisionRecordSpec
    fileprivate let asset: AVURLAsset
    fileprivate let videoDuration: CMTime
    fileprivate let video: VideoMetadata
  }

  package static func prepare(recordSpecURL: URL) async throws -> PreparedInput {
    let recordSpec = try JSONDecoder().decode(
      RecordVisionRecordSpec.self, from: Data(contentsOf: recordSpecURL))
    RecordVisionInputLogger.recordSpec(recordSpecURL)
    guard recordSpec.startPTS.timescale > 0 else {
      throw ContactSheetGeneratorError.message("startPTS.timescale must be positive")
    }
    try validate(duration: recordSpec.duration)
    let bundleURL = try recordingBundle(above: recordSpecURL)
    let isFinalized = FileManager.default.fileExists(
      atPath: bundleURL.appendingPathComponent(".finalized").path)
    if !isFinalized {
      RecordVisionInputLogger.unfinishedRecording(bundleURL)
    }
    let recording = try ResolvedRecordingInput.resolve(bundleURL.path, allowUnfinished: true)
    RecordVisionInputLogger.sourceVideo(recording.videoURL)
    let asset = AVURLAsset(url: recording.videoURL)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else {
      throw ContactSheetGeneratorError.message("No video track: \(recording.videoURL.path)")
    }
    let naturalSize = try await track.load(.naturalSize)
    let videoDuration = try await asset.load(.duration)
    return PreparedInput(
      recordSpecURL: recordSpecURL, isFinalized: isFinalized, recordSpec: recordSpec, asset: asset,
      videoDuration: videoDuration,
      video: VideoMetadata(
        width: Int(naturalSize.width), height: Int(naturalSize.height),
        frameRate: Double(try await track.load(.nominalFrameRate)),
        duration: videoDuration.seconds))
  }

  package static func refreshIfUnfinished(_ prepared: PreparedInput) async throws -> PreparedInput {
    if prepared.isFinalized { return prepared }
    return try await prepare(recordSpecURL: prepared.recordSpecURL)
  }

  public static func run(
    definitionURL: URL, recordSpecURL: URL, outputURL: URL, quality: Double, force: Bool
  ) async throws {
    try await run(
      definitionData: Data(contentsOf: definitionURL), recordSpecURL: recordSpecURL,
      outputURL: outputURL, quality: quality, force: force)
  }

  public static func run(
    definitionData: Data, recordSpecURL: URL, outputURL: URL, quality: Double, force: Bool
  ) async throws {
    let prepared = try await prepare(recordSpecURL: recordSpecURL)
    try await run(
      definitionData: definitionData, prepared: prepared, outputURL: outputURL,
      quality: quality, force: force)
  }

  package static func run(
    definitionData: Data, prepared: PreparedInput, outputURL: URL, quality: Double, force: Bool
  ) async throws {
    guard force || !FileManager.default.fileExists(atPath: outputURL.path) else {
      throw ContactSheetGeneratorError.message(
        "Output already exists: \(outputURL.path). Pass --force to overwrite.")
    }
    let definition = try JSONDecoder().decode(ContactSheetDefinition.self, from: definitionData)
    let recordSpec = prepared.recordSpec
    let frameOffsets = try validate(definition: definition)
    let rows = Int(ceil(Double(definition.matchTimestamps.count) / Double(definition.columns)))
    let width =
      definition.columns * definition.cell.width + max(0, definition.columns - 1) * cellSeparator
    let height = rows * definition.cell.height + max(0, rows - 1) * cellSeparator
    guard
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else { throw ContactSheetGeneratorError.message("Could not allocate contact-sheet image") }
    context.setFillColor(try color(definition.backgroundColor ?? "#000000"))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(cellSeparatorColor)
    for column in 1..<definition.columns {
      let x = column * definition.cell.width + (column - 1) * cellSeparator
      context.fill(CGRect(x: x, y: 0, width: cellSeparator, height: height))
    }
    for row in 1..<rows {
      let y = row * definition.cell.height + (row - 1) * cellSeparator
      context.fill(CGRect(x: 0, y: y, width: width, height: cellSeparator))
    }

    let asset = prepared.asset
    let videoDuration = prepared.videoDuration
    let video = prepared.video
    let start = CMTime(value: recordSpec.startPTS.value, timescale: recordSpec.startPTS.timescale)
    let sourceTimes = try validatedSourceTimes(
      start: start, offsets: frameOffsets, videoDuration: videoDuration)
    let generator = AVAssetImageGenerator(asset: asset)
    generator.apertureMode = .encodedPixels
    generator.appliesPreferredTrackTransform = false
    var renderedIndices = Set<Int>()

    for await result in generator.images(for: sourceTimes) {
      let requestedTime: CMTime
      let sourceFrame: CGImage
      let actualTime: CMTime
      switch result {
      case .success(let valueRequestedTime, let image, let valueActualTime):
        requestedTime = valueRequestedTime
        sourceFrame = image
        actualTime = valueActualTime
      case .failure(let valueRequestedTime, let error):
        throw ContactSheetGeneratorError.message(
          VideoFrameSupport.decodingFailureMessage(
            "Source-video image generation failed at \(valueRequestedTime.seconds)s: \(error.localizedDescription)"
          )
        )
      }
      guard let index = sourceTimes.firstIndex(where: { CMTimeCompare($0, requestedTime) == 0 }),
        renderedIndices.insert(index).inserted
      else {
        throw ContactSheetGeneratorError.message(
          "Source-video image generation returned an unknown or duplicate requested time: \(requestedTime.seconds)s"
        )
      }
      let frameDefinition = definition.matchTimestamps[index]
      let actualInmatch = CMTimeSubtract(actualTime, start).seconds
      let column = index % definition.columns
      let row = index / definition.columns
      let cellX = column * (definition.cell.width + cellSeparator)
      let cellY = height - (row + 1) * definition.cell.height - row * cellSeparator
      for placement in definition.placements {
        if let source = placement.source, let destination = placement.destination {
          let crop = try VideoFrameSupport.cropped(sourceFrame, rect: rect(source))
          context.interpolationQuality = .high
          context.draw(
            crop,
            in: destinationRect(destination, cellHeight: definition.cell.height).offsetBy(
              dx: CGFloat(cellX), dy: CGFloat(cellY)))
        } else if let text = placement.drawText {
          let renderedText = try resolveText(
            text, frame: frameDefinition, index: index, actualInmatch: actualInmatch,
            matchDuration: recordSpec.duration, recordMatchId: recordSpec.matchId, video: video
          )
          try draw(
            text, renderedText: renderedText, in: context, cellX: cellX, cellY: cellY,
            cellHeight: definition.cell.height)
        }
      }
    }
    guard renderedIndices.count == sourceTimes.count else {
      throw ContactSheetGeneratorError.message(
        "Source-video image generation returned \(renderedIndices.count) of \(sourceTimes.count) requested frames"
      )
    }
    guard let image = context.makeImage() else {
      throw ContactSheetGeneratorError.message("Could not finalize contact-sheet image")
    }
    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try VideoFrameSupport.writeBaselineJPEG(image, to: outputURL, quality: quality)
  }

  package static func validate(definition: ContactSheetDefinition) throws -> [Double] {
    guard definition.cell.width > 0, definition.cell.height > 0, definition.columns > 0,
      !definition.placements.isEmpty, !definition.matchTimestamps.isEmpty
    else {
      throw ContactSheetGeneratorError.message(
        "cell, columns, placements, and matchTimestamps must not be empty or non-positive")
    }
    for placement in definition.placements {
      if let source = placement.source, let destination = placement.destination,
        placement.drawText == nil
      {
        guard valid(source), valid(destination),
          destination.x + destination.width <= definition.cell.width,
          destination.y + destination.height <= definition.cell.height
        else {
          throw ContactSheetGeneratorError.message(
            "Image placement must be positive and fit inside cell")
        }
      } else if let text = placement.drawText, placement.source == nil, placement.destination == nil
      {
        guard text.x >= 0, text.y >= 0, text.fontSize > 0, text.fontSize.isFinite,
          (text.text == nil ? 0 : 1) + (text.script == nil ? 0 : 1) == 1
        else {
          throw ContactSheetGeneratorError.message(
            "drawText requires valid position, fontSize, and exactly one of text or script")
        }
      } else {
        throw ContactSheetGeneratorError.message(
          "Each placement must be exactly one image placement or drawText placement")
      }
    }
    return try validatedOffsets(matchTimestamps: definition.matchTimestamps)
  }

  package static func validatedOffsets(matchTimestamps: [Double]) throws -> [Double] {
    var offsets: [Double] = []
    offsets.reserveCapacity(matchTimestamps.count)
    for (index, frame) in matchTimestamps.enumerated() {
      guard frame.isFinite else {
        throw ContactSheetGeneratorError.message(
          "matchTimestamps must contain only finite values")
      }
      if let previous = offsets.last, frame <= previous {
        throw ContactSheetGeneratorError.message(
          "matchTimestamps must be strictly increasing: matchTimestamps[\(index)] = \(frame)s is not later than matchTimestamps[\(index - 1)] = \(previous)s"
        )
      }
      offsets.append(frame)
    }
    return offsets
  }

  package static func validate(duration: Double) throws {
    guard duration.isFinite, duration >= 0 else {
      throw ContactSheetGeneratorError.message(
        "record-spec.json duration must be a finite non-negative value")
    }
  }

  package static func validatedSourceTimes(
    start: CMTime, offsets: [Double], videoDuration: CMTime
  ) throws -> [CMTime] {
    guard start.seconds.isFinite, videoDuration.seconds.isFinite,
      CMTimeCompare(videoDuration, .zero) > 0
    else {
      throw ContactSheetGeneratorError.message(
        "Could not determine a positive source-video duration")
    }
    var sourceTimes: [CMTime] = []
    sourceTimes.reserveCapacity(offsets.count)
    for (index, offset) in offsets.enumerated() {
      let sourceTime = CMTimeAdd(
        start, CMTime(seconds: offset, preferredTimescale: start.timescale))
      guard sourceTime.seconds.isFinite, CMTimeCompare(sourceTime, .zero) >= 0,
        CMTimeCompare(sourceTime, videoDuration) < 0
      else {
        let format: (Double) -> String = {
          String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), $0)
        }
        throw ContactSheetGeneratorError.message(
          "Requested contact-sheet source time \(format(sourceTime.seconds))s for matchTimestamps[\(index)] = \(format(offset))s is outside source-video range [0.000, \(format(videoDuration.seconds)))s"
        )
      }
      sourceTimes.append(sourceTime)
    }
    return sourceTimes
  }

  private static func valid(_ rectangle: ContactSheetDefinition.Rectangle) -> Bool {
    rectangle.x >= 0 && rectangle.y >= 0 && rectangle.width > 0 && rectangle.height > 0
  }

  private static func rect(_ rectangle: ContactSheetDefinition.Rectangle) -> CGRect {
    CGRect(x: rectangle.x, y: rectangle.y, width: rectangle.width, height: rectangle.height)
  }

  // JSON uses the same top-left coordinate system for source, destination, and drawText.
  // CGContext's destination coordinates are bottom-left based, so only the output placement
  // needs conversion before compositing.
  private static func destinationRect(
    _ rectangle: ContactSheetDefinition.Rectangle, cellHeight: Int
  ) -> CGRect {
    CGRect(
      x: rectangle.x,
      y: cellHeight - rectangle.y - rectangle.height,
      width: rectangle.width,
      height: rectangle.height
    )
  }

  private static func color(_ value: String) throws -> CGColor {
    let hex = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard hex.count == 6 || hex.count == 8, let number = UInt32(hex, radix: 16) else {
      throw ContactSheetGeneratorError.message("Color must be #RRGGBB or #RRGGBBAA")
    }
    let alpha = hex.count == 8 ? CGFloat(number & 0xFF) / 255 : 1
    let rgb = hex.count == 8 ? number >> 8 : number
    return CGColor(
      red: CGFloat((rgb >> 16) & 0xFF) / 255,
      green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255,
      alpha: alpha
    )
  }

  private static func draw(
    _ text: ContactSheetDefinition.Text, renderedText: String, in context: CGContext, cellX: Int,
    cellY: Int, cellHeight: Int
  ) throws {
    let backgroundPadding: CGFloat = 4
    let borderWidth: CGFloat = 1
    let font: CTFont
    if let fontName = text.fontName {
      font = CTFontCreateWithName(fontName as CFString, text.fontSize, nil)
    } else {
      font =
        CTFontCreateUIFontForLanguage(.system, text.fontSize, nil)
        ?? CTFontCreateWithName("Helvetica" as CFString, text.fontSize, nil)
    }
    let attributes: [NSAttributedString.Key: Any] = [
      kCTFontAttributeName as NSAttributedString.Key: font,
      kCTForegroundColorAttributeName as NSAttributedString.Key: try color(text.color ?? "#FFFFFF"),
    ]
    let line = CTLineCreateWithAttributedString(
      NSAttributedString(string: renderedText, attributes: attributes))
    let baseline = CGPoint(
      x: cellX + text.x, y: cellY + cellHeight - text.y - Int(text.fontSize.rounded()))
    if let backgroundColor = text.backgroundColor {
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      var leading: CGFloat = 0
      let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
      let background = CGRect(
        x: baseline.x - backgroundPadding,
        y: baseline.y - descent - backgroundPadding,
        width: width + backgroundPadding * 2,
        height: ascent + descent + backgroundPadding * 2
      )
      context.setFillColor(try color(backgroundColor))
      context.fill(background)
      if let borderColor = text.borderColor {
        context.setStrokeColor(try color(borderColor))
        context.setLineWidth(borderWidth)
        context.stroke(background.insetBy(dx: borderWidth / 2, dy: borderWidth / 2))
      }
    }
    context.textPosition = baseline
    CTLineDraw(line, context)
  }

  fileprivate struct VideoMetadata {
    let width: Int
    let height: Int
    let frameRate: Double
    let duration: Double
  }

  private static func resolveText(
    _ text: ContactSheetDefinition.Text,
    frame: Double,
    index: Int,
    actualInmatch: Double,
    matchDuration: Double,
    recordMatchId: String,
    video: VideoMetadata
  ) throws -> String {
    if let value = text.text { return value }
    guard let script = text.script else {
      throw ContactSheetGeneratorError.message("drawText has neither text nor script")
    }
    let inmatch = (0...matchDuration).contains(frame) ? frame : nil
    let beforeStart = frame < 0 ? -frame : nil
    let afterEnd = frame > matchDuration ? frame - matchDuration : nil
    return try DrawTextScriptEngine.evaluate(
      script: script.return, index: index, inmatch: inmatch, beforeStart: beforeStart,
      afterEnd: afterEnd,
      actualInmatch: actualInmatch,
      matchDuration: matchDuration, recordMatchId: recordMatchId,
      videoWidth: video.width, videoHeight: video.height, videoFrameRate: video.frameRate,
      videoDuration: video.duration
    )
  }

  private static func recordingBundle(above recordSpecURL: URL) throws -> URL {
    var candidate = recordSpecURL.deletingLastPathComponent()
    while candidate.path != "/" {
      if candidate.pathExtension == "ldtxrecord" { return candidate }
      candidate.deleteLastPathComponent()
    }
    throw ContactSheetGeneratorError.message(
      "record-spec.json must be inside a .ldtxrecord bundle: \(recordSpecURL.path)")
  }
}
