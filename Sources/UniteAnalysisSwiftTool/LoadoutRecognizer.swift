// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import CxxStdlib
import Foundation
import IconMatcherNative

package struct IconMatch: Codable, Sendable, Equatable {
  package var name: String
  package var score: Float
}

package func swiftString(from value: std.string) -> String {
  String(decoding: value.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

package enum LoadoutRecognitionError: Error, Equatable {
  case invalidImage
  case invalidCanvas(width: Int, height: Int)
}

package struct BGRImage: Sendable {
  package var width: Int
  package var height: Int
  package var bytesPerRow: Int
  package var bytes: [UInt8]

  package init(width: Int, height: Int, bytesPerRow: Int, bytes: [UInt8]) throws {
    guard width > 0, height > 0, bytesPerRow >= width * 3,
      bytes.count >= bytesPerRow * height
    else {
      throw LoadoutRecognitionError.invalidImage
    }
    self.width = width
    self.height = height
    self.bytesPerRow = bytesPerRow
    self.bytes = bytes
  }

  init(_ image: CGImage) throws {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
    guard
      let context = CGContext(
        data: &rgba,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
      )
    else {
      throw LoadoutRecognitionError.invalidImage
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    var bgr = [UInt8]()
    bgr.reserveCapacity(width * height * 3)
    for offset in stride(from: 0, to: rgba.count, by: 4) {
      bgr.append(rgba[offset + 2])
      bgr.append(rgba[offset + 1])
      bgr.append(rgba[offset])
    }
    try self.init(width: width, height: height, bytesPerRow: width * 3, bytes: bgr)
  }
}

extension unite_analysis.IconMatcher {
  package func matchHeldItem(in image: BGRImage) -> [IconMatch] {
    image.bytes.withUnsafeBufferPointer { buffer in
      iconMatches(
        matchHeldBGR(
          buffer.baseAddress,
          buffer.count,
          UInt32(image.width),
          UInt32(image.height),
          image.bytesPerRow,
          0.40,
          3,
          0.90
        ))
    }
  }

  func matchBattleItem(in image: BGRImage) -> [IconMatch] {
    image.bytes.withUnsafeBufferPointer { buffer in
      iconMatches(
        matchBattleBGR(
          buffer.baseAddress,
          buffer.count,
          UInt32(image.width),
          UInt32(image.height),
          image.bytesPerRow,
          3,
          0.80
        ))
    }
  }

  private func iconMatches(_ results: unite_analysis.IconMatchResults) -> [IconMatch] {
    (0..<results.count()).map { index in
      let name = results.name(index)
      return IconMatch(
        name: swiftString(from: name),
        score: results.score(index)
      )
    }
  }
}

struct RecognizedItem: Codable, Sendable, Equatable {
  var name: String?
  var score: Float?
  var candidates: [IconMatch]

  init(_ matches: [IconMatch]) {
    name = matches.first?.name
    score = matches.first?.score
    candidates = matches
  }
}

package struct DeclaredRoute: Codable, Sendable, Equatable {
  package var name: String?
  package var method = "hsv"
  package var medianHue: Float?
  package var chromaticFraction: Float
}

struct RecognizedAllyLoadout: Codable, Sendable, Equatable {
  var slot: Int
  var heldItems: [RecognizedItem]
  var battleItem: RecognizedItem
  var declaredRoute: DeclaredRoute
}

struct RecognizedEnemyLoadout: Codable, Sendable, Equatable {
  var slot: Int
  var battleItem: RecognizedItem
}

struct LoadoutRecognition: Codable, Sendable, Equatable {
  var format: String
  var matchFormat: String
  var allies: [RecognizedAllyLoadout]
  var enemies: [RecognizedEnemyLoadout]
}

package enum LoadoutRecognizer {
  static func recognizeDraft(
    finalPreparation: CGImage,
    versus: CGImage,
    matcher: unite_analysis.IconMatcher
  ) throws -> LoadoutRecognition {
    let preparation = try requireFullHD(finalPreparation)
    let versus = try requireFullHD(versus)
    let heldX = [153, 443, 733, 1023, 1313]
    let heldDX = [0, 45, 90]
    let battleX = [287, 577, 868, 1157, 1446]
    let versusX = [350, 625, 895, 1165, 1435]

    let allies = try heldX.indices.map { player in
      let heldItems = try heldDX.map { offset in
        RecognizedItem(
          matcher.matchHeldItem(
            in: try preparation.crop(centerX: heldX[player] + offset, centerY: 514, side: 40)))
      }
      let battle = try preparation.crop(centerX: battleX[player], centerY: 516, side: 48)
      let route = try preparation.crop(
        centerX: heldX[player] - 44, centerY: 597, width: 36, height: 28)
      return RecognizedAllyLoadout(
        slot: player + 1,
        heldItems: heldItems,
        battleItem: RecognizedItem(matcher.matchBattleItem(in: battle)),
        declaredRoute: classifyRoute(route)
      )
    }
    let enemies = try versusX.indices.map { player in
      let battle = try versus.crop(centerX: versusX[player], centerY: 729, side: 48)
      return RecognizedEnemyLoadout(
        slot: player + 1,
        battleItem: RecognizedItem(matcher.matchBattleItem(in: battle)))
    }
    return LoadoutRecognition(
      format: "pokemon-unite-draft-loadout-2",
      matchFormat: "draft",
      allies: allies,
      enemies: enemies)
  }

  static func recognizeBlind(
    preparation: CGImage,
    matcher: unite_analysis.IconMatcher
  ) throws -> LoadoutRecognition {
    let image = try requireFullHD(preparation)
    let heldX = [308, 576, 844, 1114, 1384]
    let heldDX = [0, 38, 76]
    let battleX = [354, 622, 890, 1160, 1428]
    let routeX = [452, 720, 988, 1256, 1524]

    let allies = try heldX.indices.map { player in
      let heldItems = try heldDX.map { offset in
        RecognizedItem(
          matcher.matchHeldItem(
            in: try image.crop(centerX: heldX[player] + offset, centerY: 756, side: 40)))
      }
      let battle = try image.crop(centerX: battleX[player], centerY: 818, side: 48)
      let route = try image.crop(centerX: routeX[player], centerY: 722, width: 36, height: 28)
      return RecognizedAllyLoadout(
        slot: player + 1,
        heldItems: heldItems,
        battleItem: RecognizedItem(matcher.matchBattleItem(in: battle)),
        declaredRoute: classifyRoute(route)
      )
    }
    return LoadoutRecognition(
      format: "pokemon-unite-blind-loadout-1",
      matchFormat: "blind",
      allies: allies,
      enemies: [])
  }

  package static func classifyRoute(_ image: BGRImage) -> DeclaredRoute {
    let hues = image.chromaticHues(minimumSaturation: 120, minimumValue: 80)
    let fraction = Float(hues.count) / Float(image.width * image.height)
    guard fraction >= 0.15 else {
      return DeclaredRoute(name: nil, medianHue: nil, chromaticFraction: fraction)
    }
    let sorted = hues.sorted()
    let median = sorted[sorted.count / 2]
    let references: [(String, Float)] = [("top", 20), ("central", 100), ("bottom", 151)]
    let name = references.min { hueDistance(median, $0.1) < hueDistance(median, $1.1) }!.0
    return DeclaredRoute(name: name, medianHue: median, chromaticFraction: fraction)
  }

  private static func requireFullHD(_ image: CGImage) throws -> BGRImage {
    guard image.width == 1920, image.height == 1080 else {
      throw LoadoutRecognitionError.invalidCanvas(width: image.width, height: image.height)
    }
    return try BGRImage(image)
  }

  private static func hueDistance(_ left: Float, _ right: Float) -> Float {
    let difference = abs(left - right)
    return min(difference, 180 - difference)
  }
}

extension BGRImage {
  fileprivate func crop(centerX: Int, centerY: Int, side: Int) throws -> BGRImage {
    try crop(centerX: centerX, centerY: centerY, width: side, height: side)
  }

  fileprivate func crop(centerX: Int, centerY: Int, width: Int, height: Int) throws -> BGRImage {
    let originX = centerX - width / 2
    let originY = centerY - height / 2
    guard originX >= 0, originY >= 0, originX + width <= self.width,
      originY + height <= self.height
    else { throw LoadoutRecognitionError.invalidImage }
    var result = [UInt8]()
    result.reserveCapacity(width * height * 3)
    for row in originY..<(originY + height) {
      let start = row * bytesPerRow + originX * 3
      result.append(contentsOf: bytes[start..<(start + width * 3)])
    }
    return try BGRImage(width: width, height: height, bytesPerRow: width * 3, bytes: result)
  }

  fileprivate func chromaticHues(minimumSaturation: UInt8, minimumValue: UInt8) -> [Float] {
    var result: [Float] = []
    for y in 0..<height {
      for x in 0..<width {
        let offset = y * bytesPerRow + x * 3
        let blue = Float(bytes[offset]) / 255
        let green = Float(bytes[offset + 1]) / 255
        let red = Float(bytes[offset + 2]) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let saturation = maximum == 0 ? 0 : delta / maximum
        guard saturation * 255 >= Float(minimumSaturation),
          maximum * 255 >= Float(minimumValue), delta > 0
        else { continue }
        let degrees: Float
        if maximum == red {
          degrees = 60 * ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
          degrees = 60 * ((blue - red) / delta + 2)
        } else {
          degrees = 60 * ((red - green) / delta + 4)
        }
        result.append((degrees < 0 ? degrees + 360 : degrees) / 2)
      }
    }
    return result
  }
}
