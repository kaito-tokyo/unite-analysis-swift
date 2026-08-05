// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import ImageIO
import Vision

struct Arguments {
  var input: String
  var output: String?
}

enum ScannerError: Error, CustomStringConvertible {
  case message(String)

  var description: String {
    switch self {
    case .message(let value): return value
    }
  }
}

public struct NormalizedRect: Codable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double
}

public struct TextObservation: Codable, Sendable {
  public let text: String
  public let confidence: Float
  public let box: NormalizedRect
}

struct OCRCell: Codable {
  let text: String?
  let confidence: Float?
  let alternatives: [String]
}

struct BattleDataRow: Codable {
  let side: String
  let row: Int
  let name: OCRCell
  let damageDealt: OCRCell
  let damageTaken: OCRCell
  let healing: OCRCell
}

struct SummaryRow: Codable {
  let side: String
  let row: Int
  let name: OCRCell
  let scored: OCRCell
  let knockouts: OCRCell
  let assists: OCRCell
  let rating: OCRCell
}

struct ScreenResult: Codable {
  let kind: String
  let detectionScore: Int
  let rawText: [TextObservation]
  let battleData: [BattleDataRow]?
  let summary: [SummaryRow]?
}

struct ScanResult: Codable {
  let input: String
  let generatedAt: String
  let ocrOptions: [String: OCRRecognitionOptions]
  let screens: [ScreenResult]
  let warnings: [String]
}

public enum ResultScreenType: String {
  case summary
  case battleData
}

public struct OCRRecognitionOptions: Codable, Sendable {
  public let recognitionLanguages: [String]
  public let customWords: [String]?

  public init(recognitionLanguages: [String], customWords: [String]? = nil) {
    self.recognitionLanguages = recognitionLanguages
    self.customWords = customWords
  }
}

public struct OCRRecognitionOptionsDocument: Decodable, Sendable {
  public static let schemaURL =
    "https://kaito-tokyo.github.io/unite-analysis-swift/ocr-options.schema.json"

  public let schema: String
  public let regions: [String: OCRRecognitionOptions]

  private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DynamicCodingKey.self)
    let schemaKey = DynamicCodingKey(stringValue: "$schema")!
    schema = try container.decode(String.self, forKey: schemaKey)
    regions = try Dictionary(
      uniqueKeysWithValues: container.allKeys.compactMap { key in
        guard key.stringValue != "$schema" else { return nil }
        return (key.stringValue, try container.decode(OCRRecognitionOptions.self, forKey: key))
      })
  }
}

public enum ScanResultOCRRegion {
  public static let screenText = "result-screen.text"
  public static let playerName = "player-name"
  public static let numeric = "result-screen.numeric"
}

public enum OCRInputType: String, Codable, Sendable {
  case text
  case playerName = "player-name"
  case numeric
}

public struct OCRInputResult: Codable, Sendable {
  public let observations: [TextObservation]
  public let values: [String]
}

public enum OCRInput {
  static func readingOrder(_ observations: [TextObservation]) -> [TextObservation] {
    let verticallyOrdered = observations.sorted {
      if $0.box.y != $1.box.y { return $0.box.y > $1.box.y }
      return $0.box.x < $1.box.x
    }
    var rows: [[TextObservation]] = []
    var rowAnchorY: Double?
    for observation in verticallyOrdered {
      if let rowAnchorY, abs(rowAnchorY - observation.box.y) <= 0.02 {
        rows[rows.count - 1].append(observation)
      } else {
        rows.append([observation])
        rowAnchorY = observation.box.y
      }
    }
    return rows.flatMap { $0.sorted { $0.box.x < $1.box.x } }
  }

  static func interpreted(
    _ observations: [TextObservation], type: OCRInputType
  ) -> OCRInputResult {
    let ordered = readingOrder(observations)
    let values: [String]
    switch type {
    case .text:
      values = ordered.map(\.text)
    case .playerName:
      let joined = ordered.map(\.text).joined(separator: " ")
      values = joined.isEmpty ? [] : [OCR.cleanName(joined)]
    case .numeric:
      values = ordered.flatMap { OCR.numberTokens(in: $0.text) }
    }
    return OCRInputResult(observations: ordered, values: values)
  }

  public static func recognize(
    _ image: CGImage,
    type: OCRInputType,
    options: OCRRecognitionOptions
  ) throws -> OCRInputResult {
    let observations = try OCR.recognize(
      image,
      languages: options.recognitionLanguages,
      customWords: options.customWords ?? [],
      correction: false
    )
    return interpreted(observations, type: type)
  }
}

public enum StillImageInput {
  private static let extensions = Set(["bmp", "gif", "heic", "jpeg", "jpg", "png", "tif", "tiff"])

  public static func supports(_ url: URL) -> Bool {
    extensions.contains(url.pathExtension.lowercased())
  }

  public static func load(_ url: URL) throws -> CGImage {
    guard supports(url) else {
      throw ScannerError.message(
        "Still-image input accepts only BMP, GIF, HEIC, JPEG, PNG, or TIFF: \(url.path)"
      )
    }
    let data = try Data(contentsOf: url)
    guard
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      throw ScannerError.message("Could not decode still image: \(url.path)")
    }
    return image
  }
}

enum GameScreenInput {
  static let width = 1632
  static let height = 918
}

enum OCR {
  static func recognize(
    _ image: CGImage,
    languages: [String],
    customWords: [String] = [],
    correction: Bool = false
  ) throws -> [TextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = languages
    request.customWords = customWords
    request.usesLanguageCorrection = correction
    request.minimumTextHeight = 0.008
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    return (request.results ?? []).compactMap { observation in
      guard let candidate = observation.topCandidates(1).first else { return nil }
      let box = observation.boundingBox
      return TextObservation(
        text: candidate.string,
        confidence: candidate.confidence,
        box: NormalizedRect(x: box.minX, y: box.minY, width: box.width, height: box.height)
      )
    }
  }

  static func cell(
    _ image: CGImage,
    rect: CGRect,
    numeric: Bool,
    languages: [String],
    customWords: [String]
  ) throws -> OCRCell {
    guard let crop = image.cropping(to: rect.integral) else {
      return OCRCell(text: nil, confidence: nil, alternatives: [])
    }
    // Player names are proper nouns and mixed-script handles, so language
    // correction is more likely to change a valid name than repair it.
    let observations = try recognize(
      crop,
      languages: languages,
      customWords: customWords,
      correction: false)
    let joined =
      observations
      .sorted { $0.box.x < $1.box.x }
      .map(\.text)
      .joined(separator: " ")
    let candidates: [String]
    if numeric {
      candidates = numberTokens(in: joined)
    } else {
      candidates = joined.isEmpty ? [] : [joined]
    }
    let selected = candidates.first.map { numeric ? $0 : cleanName($0) }
    let confidence = observations.map(\.confidence).max()
    return OCRCell(
      text: selected, confidence: confidence,
      alternatives: candidates.map { numeric ? $0 : cleanName($0) })
  }

  static func numericCells(
    _ image: CGImage,
    rect: CGRect,
    count: Int,
    languages: [String],
    customWords: [String]
  ) throws -> [OCRCell] {
    guard let crop = image.cropping(to: rect.integral) else {
      return Array(repeating: OCRCell(text: nil, confidence: nil, alternatives: []), count: count)
    }
    let observations = try recognize(
      crop, languages: languages, customWords: customWords
    ).sorted { $0.box.x < $1.box.x }
    var cells: [OCRCell] = []
    for observation in observations {
      for token in numberTokens(in: observation.text) {
        cells.append(
          OCRCell(text: token, confidence: observation.confidence, alternatives: [token]))
      }
    }
    while cells.count < count {
      cells.append(OCRCell(text: nil, confidence: nil, alternatives: []))
    }
    return Array(cells.prefix(count))
  }

  static func numericCell(
    observations: [TextObservation],
    image: CGImage,
    x: CGFloat,
    y: CGFloat
  ) -> OCRCell {
    let matches = observations.compactMap {
      observation -> (distance: CGFloat, token: String, confidence: Float)? in
      guard let token = numberTokens(in: observation.text).first else { return nil }
      let centerX = CGFloat(observation.box.x + observation.box.width / 2) * CGFloat(image.width)
      let centerY =
        (1 - CGFloat(observation.box.y + observation.box.height / 2)) * CGFloat(image.height)
      let dx = abs(centerX - x)
      let dy = abs(centerY - y)
      guard dx <= 55, dy <= 34 else { return nil }
      return (dx + dy * 1.5, token, observation.confidence)
    }
    guard let best = matches.min(by: { $0.distance < $1.distance }) else {
      return OCRCell(text: nil, confidence: nil, alternatives: [])
    }
    return OCRCell(text: best.token, confidence: best.confidence, alternatives: [best.token])
  }

  static func numericRow(
    observations: [TextObservation],
    image: CGImage,
    centers: [CGFloat],
    y: CGFloat
  ) -> [OCRCell] {
    var values = [String?](repeating: nil, count: centers.count)
    var confidences = [Float?](repeating: nil, count: centers.count)
    for observation in observations {
      let tokens = numberTokens(in: observation.text)
      guard tokens.count == 1, let token = tokens.first else { continue }
      let minX = CGFloat(observation.box.x) * CGFloat(image.width)
      let maxX = CGFloat(observation.box.x + observation.box.width) * CGFloat(image.width)
      let centerY =
        (1 - CGFloat(observation.box.y + observation.box.height / 2)) * CGFloat(image.height)
      guard abs(centerY - y) <= 34 else { continue }
      let eligible = centers.indices.filter { centers[$0] >= minX - 22 && centers[$0] <= maxX + 22 }
      guard !eligible.isEmpty else { continue }
      if eligible.count == 1 {
        let index = eligible[0]
        values[index] = token
        confidences[index] = observation.confidence
      } else {
        var pieces = Array(repeating: "", count: centers.count)
        let characters = Array(token)
        for (offset, character) in characters.enumerated() {
          let characterX =
            minX + (CGFloat(offset) + 0.5) * (maxX - minX) / CGFloat(characters.count)
          if let index = eligible.min(by: {
            abs(centers[$0] - characterX) < abs(centers[$1] - characterX)
          }) {
            pieces[index].append(character)
          }
        }
        for index in eligible where !pieces[index].isEmpty {
          values[index] = pieces[index]
          confidences[index] = observation.confidence
        }
      }
    }
    return values.indices.map { index in
      guard let value = values[index] else {
        return OCRCell(text: nil, confidence: nil, alternatives: [])
      }
      return OCRCell(text: value, confidence: confidences[index], alternatives: [value])
    }
  }

  static func cleanName(_ value: String) -> String {
    value.trimmingCharacters(in: CharacterSet(charactersIn: "「『| "))
  }

  static func recognizeResultScreen(
    _ image: CGImage, languages: [String], customWords: [String]
  ) throws -> [TextObservation] {
    var observations = try recognize(
      image, languages: languages, customWords: customWords, correction: true)
    let sx = CGFloat(image.width) / CGFloat(GameScreenInput.width)
    let sy = CGFloat(image.height) / CGFloat(GameScreenInput.height)
    let regions = [
      CGRect(x: 600 * sx, y: 0, width: 1032 * sx, height: 200 * sy),
      CGRect(x: 0, y: 80 * sy, width: 1632 * sx, height: 690 * sy),
    ]
    for region in regions {
      if let crop = image.cropping(to: region.integral) {
        observations.append(
          contentsOf: try recognize(
            crop, languages: languages, customWords: customWords, correction: true))
      }
    }
    return observations
  }

  static func numberTokens(in value: String) -> [String] {
    let normalized =
      value
      .replacingOccurrences(of: "O", with: "0")
      .replacingOccurrences(of: "o", with: "0")
      .replacingOccurrences(of: "I", with: "1")
      .replacingOccurrences(of: "l", with: "1")
      .replacingOccurrences(of: ",", with: "")
    let regex = try! NSRegularExpression(pattern: #"\d+(?:\.\d+)?%?"#)
    let range = NSRange(normalized.startIndex..., in: normalized)
    return regex.matches(in: normalized, range: range).compactMap {
      Range($0.range, in: normalized).map { String(normalized[$0]) }
    }
  }
}

struct Layout {
  // Coordinates are calibrated directly for the cropped 1632x918 game canvas.
  static let gameWidth: CGFloat = 1632
  static let gameHeight: CGFloat = 918
  static let battleRowTops: [CGFloat] = [200, 304, 408, 510, 610]
  static let summaryRowTops: [CGFloat] = [205, 307, 409, 510, 612]

  struct Columns {
    let name: CGRect
    let first: CGRect
    let second: CGRect
    let third: CGRect
    let fourth: CGRect?
  }

  static let battleLeft = Columns(
    name: CGRect(x: 195, y: 5, width: 230, height: 78),
    first: CGRect(x: 430, y: 2, width: 110, height: 42),
    second: CGRect(x: 545, y: 2, width: 110, height: 42),
    third: CGRect(x: 665, y: 2, width: 115, height: 42),
    fourth: nil
  )
  static let battleRight = Columns(
    name: CGRect(x: 935, y: 5, width: 230, height: 78),
    first: CGRect(x: 1170, y: 2, width: 110, height: 42),
    second: CGRect(x: 1288, y: 2, width: 110, height: 42),
    third: CGRect(x: 1410, y: 2, width: 115, height: 42),
    fourth: nil
  )
  static let summaryLeft = Columns(
    name: CGRect(x: 190, y: 2, width: 240, height: 70),
    first: CGRect(x: 430, y: 2, width: 64, height: 70),
    second: CGRect(x: 535, y: 2, width: 62, height: 70),
    third: CGRect(x: 615, y: 2, width: 65, height: 70),
    fourth: CGRect(x: 696, y: 2, width: 95, height: 70)
  )
  static let summaryRight = Columns(
    name: CGRect(x: 935, y: 2, width: 220, height: 70),
    first: CGRect(x: 1141, y: 2, width: 64, height: 70),
    second: CGRect(x: 1259, y: 2, width: 62, height: 70),
    third: CGRect(x: 1341, y: 2, width: 65, height: 70),
    fourth: CGRect(x: 1413, y: 2, width: 96, height: 70)
  )

  static func rect(_ base: CGRect, row: Int, rowTops: [CGFloat], image: CGImage) -> CGRect {
    let sx = CGFloat(image.width) / CGFloat(GameScreenInput.width)
    let sy = CGFloat(image.height) / CGFloat(GameScreenInput.height)
    return CGRect(
      x: base.minX * sx,
      y: (rowTops[row] + base.minY) * sy,
      width: base.width * sx,
      height: base.height * sy
    )
  }
}

func detectionScores(_ observations: [TextObservation]) -> (battle: Int, summary: Int) {
  let joined = observations.map(\.text).joined(separator: " ").lowercased()
  var battle = 0
  var summary = 0
  for keyword in ["与えた", "受けた", "ダメージ", "回復", "バトルデータ"] where joined.contains(keyword.lowercased())
  {
    battle += 4
  }
  for keyword in ["win", "lose", "スコアの詳細", "次へ"] where joined.contains(keyword.lowercased()) {
    summary += 3
  }
  let numbers = OCR.numberTokens(in: joined).count
  if numbers >= 12 {
    battle += 1
    summary += 1
  }
  return (battle, summary)
}

func battleRows(
  from image: CGImage,
  nameOptions: OCRRecognitionOptions,
  numericOptions: OCRRecognitionOptions
) throws -> [BattleDataRow] {
  var rows: [BattleDataRow] = []
  for (side, columns) in [("ally", Layout.battleLeft), ("enemy", Layout.battleRight)] {
    for row in 0..<5 {
      rows.append(
        BattleDataRow(
          side: side,
          row: row,
          name: try OCR.cell(
            image,
            rect: Layout.rect(columns.name, row: row, rowTops: Layout.battleRowTops, image: image),
            numeric: false,
            languages: nameOptions.recognitionLanguages,
            customWords: nameOptions.customWords ?? []),
          damageDealt: try OCR.cell(
            image,
            rect: Layout.rect(columns.first, row: row, rowTops: Layout.battleRowTops, image: image),
            numeric: true,
            languages: numericOptions.recognitionLanguages,
            customWords: numericOptions.customWords ?? []),
          damageTaken: try OCR.cell(
            image,
            rect: Layout.rect(
              columns.second, row: row, rowTops: Layout.battleRowTops, image: image), numeric: true,
            languages: numericOptions.recognitionLanguages,
            customWords: numericOptions.customWords ?? []),
          healing: try OCR.cell(
            image,
            rect: Layout.rect(columns.third, row: row, rowTops: Layout.battleRowTops, image: image),
            numeric: true,
            languages: numericOptions.recognitionLanguages,
            customWords: numericOptions.customWords ?? [])
        ))
    }
  }
  return rows
}

func summaryRows(
  from image: CGImage,
  nameOptions: OCRRecognitionOptions,
  numericOptions: OCRRecognitionOptions
) throws -> [SummaryRow] {
  var rows: [SummaryRow] = []
  let fullObservations = try OCR.recognize(
    image,
    languages: numericOptions.recognitionLanguages,
    customWords: numericOptions.customWords ?? [])
  for (side, columns) in [("ally", Layout.summaryLeft), ("enemy", Layout.summaryRight)] {
    for row in 0..<5 {
      let scaleX = CGFloat(image.width) / CGFloat(GameScreenInput.width)
      let scaleY = CGFloat(image.height) / CGFloat(GameScreenInput.height)
      let textY = (Layout.summaryRowTops[row] + 43) * scaleY
      let centers = [columns.first, columns.second, columns.third, columns.fourth!]
        .map { $0.midX * scaleX }
      var numbers = OCR.numericRow(
        observations: fullObservations,
        image: image,
        centers: centers,
        y: textY
      )
      let numericBase = CGRect(
        x: columns.first.minX,
        y: 0,
        width: columns.fourth!.maxX - columns.first.minX,
        height: 76
      )
      let rowWide = try OCR.numericCells(
        image,
        rect: Layout.rect(numericBase, row: row, rowTops: Layout.summaryRowTops, image: image),
        count: 4,
        languages: numericOptions.recognitionLanguages,
        customWords: numericOptions.customWords ?? []
      )
      if rowWide.allSatisfy({ $0.text != nil }) {
        for index in numbers.indices where numbers[index].text == nil {
          numbers[index] = rowWide[index]
        }
      }
      // Vision occasionally suppresses an isolated score glyph of 0.
      // Infer it only when every other statistic in that row was read.
      if numbers[0].text == nil && numbers[1...3].allSatisfy({ $0.text != nil }) {
        numbers[0] = OCRCell(text: "0", confidence: nil, alternatives: ["0"])
      }
      rows.append(
        SummaryRow(
          side: side,
          row: row,
          name: try OCR.cell(
            image,
            rect: Layout.rect(columns.name, row: row, rowTops: Layout.summaryRowTops, image: image),
            numeric: false,
            languages: nameOptions.recognitionLanguages,
            customWords: nameOptions.customWords ?? []),
          scored: numbers[0],
          knockouts: numbers[1],
          assists: numbers[2],
          rating: numbers[3]
        ))
    }
  }
  return rows
}

public enum ResultScannerRunner {
  public static func run(
    input: String,
    type: ResultScreenType,
    ocrOptions: [String: OCRRecognitionOptions],
    output: String? = nil
  ) throws {
    guard let screenTextOptions = ocrOptions[ScanResultOCRRegion.screenText],
      let playerNameOptions = ocrOptions[ScanResultOCRRegion.playerName],
      let numericOptions = ocrOptions[ScanResultOCRRegion.numeric]
    else {
      throw ScannerError.message(
        "scan-result requires OCR options for \(ScanResultOCRRegion.screenText), \(ScanResultOCRRegion.playerName), and \(ScanResultOCRRegion.numeric)"
      )
    }
    let arguments = Arguments(input: input, output: output)
    let inputURL = URL(fileURLWithPath: arguments.input).standardizedFileURL
    let image = try StillImageInput.load(inputURL)
    let raw = try OCR.recognizeResultScreen(
      image,
      languages: screenTextOptions.recognitionLanguages,
      customWords: screenTextOptions.customWords ?? [])
    let scores = detectionScores(raw)

    let screen: ScreenResult
    var warnings: [String] = []
    switch type {
    case .battleData:
      screen = ScreenResult(
        kind: "battleData",
        detectionScore: scores.battle,
        rawText: raw,
        battleData: try battleRows(
          from: image,
          nameOptions: playerNameOptions,
          numericOptions: numericOptions),
        summary: nil
      )
      if scores.battle < 4 {
        warnings.append("The input image has a low battle-data detection score.")
      }
    case .summary:
      screen = ScreenResult(
        kind: "summary",
        detectionScore: scores.summary,
        rawText: raw,
        battleData: nil,
        summary: try summaryRows(
          from: image,
          nameOptions: playerNameOptions,
          numericOptions: numericOptions)
      )
      if scores.summary < 3 {
        warnings.append("The input image has a low summary-screen detection score.")
      }
    }
    warnings.append(
      "The scanner returns all rows and never treats the highlighted cursor row as the local player."
    )

    let formatter = ISO8601DateFormatter()
    let result = ScanResult(
      input: inputURL.path,
      generatedAt: formatter.string(from: Date()),
      ocrOptions: [
        ScanResultOCRRegion.screenText: screenTextOptions,
        ScanResultOCRRegion.playerName: playerNameOptions,
        ScanResultOCRRegion.numeric: numericOptions,
      ],
      screens: [screen],
      warnings: warnings
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(result)
    if let output = arguments.output {
      try data.write(to: URL(fileURLWithPath: output), options: .atomic)
    } else {
      FileHandle.standardOutput.write(data)
      FileHandle.standardOutput.write(Data("\n".utf8))
    }
  }
}
