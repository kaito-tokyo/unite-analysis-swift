// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import ArgumentParser
import CoreGraphics
import CxxStdlib
import Foundation
import IconMatcherNative

package struct IconMatch: Codable, Sendable, Equatable {
  package var name: String
  package var score: Float

  package init(name: String, score: Float) {
    self.name = name
    self.score = score
  }
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

  package init(_ image: CGImage) throws {
    let width = image.width
    let height = image.height
    let bytesPerRow = width * 4
    var rgba = [UInt8](repeating: 0, count: bytesPerRow * height)
    let rendered = rgba.withUnsafeMutableBytes { bytes in
      guard
        let context = CGContext(
          data: bytes.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: bytesPerRow,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
      else {
        return false
      }
      context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else {
      throw LoadoutRecognitionError.invalidImage
    }

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

package struct PreparedAKAZEInput: Sendable {
  package var image: BGRImage
  package var mask: BGRImage?
}

extension unite_analysis.IconMatcher {
  package func matchHeldItem(in image: BGRImage) throws -> [IconMatch] {
    let results = image.bytes.withUnsafeBufferPointer { buffer in
      matchHeldBGR(
        buffer.baseAddress,
        buffer.count,
        UInt32(image.width),
        UInt32(image.height),
        image.bytesPerRow,
        0.40,
        3,
        0.90
      )
    }
    return try iconMatches(results)
  }

  func matchBattleItem(in image: BGRImage) throws -> [IconMatch] {
    let results = image.bytes.withUnsafeBufferPointer { buffer in
      matchBattleBGR(
        buffer.baseAddress,
        buffer.count,
        UInt32(image.width),
        UInt32(image.height),
        image.bytesPerRow,
        3,
        0.80
      )
    }
    return try iconMatches(results)
  }

  package func preparedHeldImage(_ image: BGRImage) throws -> PreparedAKAZEInput {
    let prepared = image.bytes.withUnsafeBufferPointer { buffer in
      prepareHeldBGR(
        buffer.baseAddress, buffer.count, UInt32(image.width), UInt32(image.height),
        image.bytesPerRow, 0.40)
    }
    return try preparedImage(prepared)
  }

  package func preparedBattleImage(_ image: BGRImage) throws -> PreparedAKAZEInput {
    let prepared = image.bytes.withUnsafeBufferPointer { buffer in
      prepareBattleBGR(
        buffer.baseAddress, buffer.count, UInt32(image.width), UInt32(image.height),
        image.bytesPerRow)
    }
    return try preparedImage(prepared)
  }

  private func preparedImage(_ image: unite_analysis.PreparedIconImage) throws
    -> PreparedAKAZEInput
  {
    guard image.isValid() else {
      throw ValidationError("Could not prepare AKAZE diagnostic image")
    }
    let width = Int(image.width())
    let height = Int(image.height())
    let prepared = try BGRImage(
      width: width, height: height, bytesPerRow: width * 3,
      bytes: (0..<image.byteCount()).map { image.byte($0) })
    let mask: BGRImage? =
      if image.hasMask() {
        try BGRImage(
          width: width, height: height, bytesPerRow: width * 3,
          bytes: (0..<image.maskByteCount()).flatMap { index in
            let value = image.maskByte(index)
            return [value, value, value]
          })
      } else {
        nil
      }
    return PreparedAKAZEInput(image: prepared, mask: mask)
  }

  private func iconMatches(_ results: unite_analysis.IconMatchResults) throws -> [IconMatch] {
    let message = swiftString(from: errorMessage())
    guard message.isEmpty else {
      throw ValidationError(message)
    }
    return (0..<results.count()).map { index in
      let name = results.name(index)
      return IconMatch(
        name: swiftString(from: name),
        score: results.score(index)
      )
    }
  }
}

package struct RecognizedItem: Codable, Sendable, Equatable {
  package var name: String?
  package var score: Float?
  package var candidates: [IconMatch]

  package init(_ matches: [IconMatch]) {
    let top = matches.first
    let runnerUpScore = matches.dropFirst().first?.score ?? 0
    name =
      if let top,
        top.score >= LoadoutRecognizer.minimumAcceptedVoteSum,
        top.score >= LoadoutRecognizer.minimumTopToRunnerUpRatio * runnerUpScore
      {
        top.name
      } else {
        nil
      }
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

package struct RecognizedAllyLoadout: Codable, Sendable, Equatable {
  package var slot: Int
  package var heldItems: [RecognizedItem]
  package var battleItem: RecognizedItem
  package var declaredRoute: DeclaredRoute
}

package struct RecognizedEnemyLoadout: Codable, Sendable, Equatable {
  package var slot: Int
  package var battleItem: RecognizedItem
}

package struct LoadoutRecognition: Codable, Sendable, Equatable {
  package var format: String
  package var matchFormat: String
  package var allies: [RecognizedAllyLoadout]
  package var enemies: [RecognizedEnemyLoadout]
}

package enum LoadoutRecognizer {
  /// One full-strength Lowe-ratio vote, or equivalent accumulated partial evidence.
  package static let minimumAcceptedVoteSum: Float = 1
  /// Requires the winner to own at least two thirds of the top-two accumulated evidence.
  package static let minimumTopToRunnerUpRatio: Float = 2
  /// Half the smallest circular separation between the three declared-route reference hues.
  package static let maximumRouteHueDistance: Float = 24.5
  /// Tolerates JPEG chroma subsampling while still requiring a substantial colored glyph.
  package static let minimumRouteChromaticFraction: Float = 0.12

  package static func recognizeDraft(
    finalPreparation: CGImage,
    versus: CGImage,
    matcher: unite_analysis.IconMatcher,
    akazeInputObserver: ((String, PreparedAKAZEInput) throws -> Void)? = nil
  ) throws -> LoadoutRecognition {
    let preparation = try requireFullHD(finalPreparation)
    let versus = try requireFullHD(versus)
    // These landmarks were measured on the Switch's 1632x918 game viewport. Frames are
    // normalized to 1920x1080 before recognition, so keep the ROI coordinates in that
    // canonical space as well (both dimensions scale by exactly 20/17).
    let heldX = [180, 521, 862, 1204, 1545]
    let heldDX = [0, 53, 106]
    let battleX = [338, 679, 1021, 1361, 1701]
    let versusX = [412, 735, 1053, 1371, 1688]

    let allies = try heldX.indices.map { player in
      let heldItems = try heldDX.enumerated().map { item, offset in
        let crop = try preparation.crop(
          centerX: heldX[player] + offset, centerY: 605, side: 47)
        if let akazeInputObserver {
          try akazeInputObserver(
            "ally-\(player + 1)-held-\(item + 1)", try matcher.preparedHeldImage(crop))
        }
        return RecognizedItem(
          try matcher.matchHeldItem(in: crop))
      }
      let battle = try preparation.crop(centerX: battleX[player], centerY: 607, side: 56)
      if let akazeInputObserver {
        try akazeInputObserver(
          "ally-\(player + 1)-battle", try matcher.preparedBattleImage(battle))
      }
      let route = try preparation.crop(
        centerX: heldX[player] - 52, centerY: 702, width: 42, height: 33)
      return RecognizedAllyLoadout(
        slot: player + 1,
        heldItems: abstainingOnDuplicateHeldItems(heldItems),
        battleItem: RecognizedItem(try matcher.matchBattleItem(in: battle)),
        declaredRoute: classifyRoute(route)
      )
    }
    let enemies = try versusX.indices.map { player in
      let battle = try versus.crop(centerX: versusX[player], centerY: 858, side: 56)
      if let akazeInputObserver {
        try akazeInputObserver(
          "enemy-\(player + 1)-battle", try matcher.preparedBattleImage(battle))
      }
      return RecognizedEnemyLoadout(
        slot: player + 1,
        battleItem: RecognizedItem(try matcher.matchBattleItem(in: battle)))
    }
    return LoadoutRecognition(
      format: "pokemon-unite-draft-loadout-2",
      matchFormat: "draft",
      allies: allies,
      enemies: enemies)
  }

  package static func recognizeBlind(
    preparation: CGImage,
    matcher: unite_analysis.IconMatcher,
    akazeInputObserver: ((String, PreparedAKAZEInput) throws -> Void)? = nil
  ) throws -> LoadoutRecognition {
    let image = try requireFullHD(preparation)
    let heldX = [308, 576, 844, 1114, 1384]
    let heldDX = [0, 38, 76]
    let battleX = [354, 622, 890, 1160, 1428]
    let routeX = [452, 720, 988, 1256, 1524]

    let allies = try heldX.indices.map { player in
      let heldItems = try heldDX.enumerated().map { item, offset in
        let crop = try image.crop(
          centerX: heldX[player] + offset, centerY: 756, side: 40)
        if let akazeInputObserver {
          try akazeInputObserver(
            "ally-\(player + 1)-held-\(item + 1)", try matcher.preparedHeldImage(crop))
        }
        return RecognizedItem(
          try matcher.matchHeldItem(in: crop))
      }
      let battle = try image.crop(centerX: battleX[player], centerY: 818, side: 48)
      if let akazeInputObserver {
        try akazeInputObserver(
          "ally-\(player + 1)-battle", try matcher.preparedBattleImage(battle))
      }
      let route = try image.crop(centerX: routeX[player], centerY: 722, width: 36, height: 28)
      return RecognizedAllyLoadout(
        slot: player + 1,
        heldItems: abstainingOnDuplicateHeldItems(heldItems),
        battleItem: RecognizedItem(try matcher.matchBattleItem(in: battle)),
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
    guard fraction >= minimumRouteChromaticFraction else {
      return DeclaredRoute(name: nil, medianHue: nil, chromaticFraction: fraction)
    }
    let sorted = hues.sorted()
    let median = sorted[sorted.count / 2]
    let references: [(String, Float)] = [("top", 20), ("central", 100), ("bottom", 151)]
    let nearest = references.min { hueDistance(median, $0.1) < hueDistance(median, $1.1) }!
    let name =
      hueDistance(median, nearest.1) <= maximumRouteHueDistance ? nearest.0 : nil
    return DeclaredRoute(name: name, medianHue: median, chromaticFraction: fraction)
  }

  /// A player cannot equip the same held item twice. Preserve the evidence but do not
  /// publish any contradictory duplicate as a recognized value.
  package static func abstainingOnDuplicateHeldItems(_ items: [RecognizedItem])
    -> [RecognizedItem]
  {
    let accepted = items.compactMap(\.name)
    let duplicates = Set(accepted.filter { name in accepted.count(where: { $0 == name }) > 1 })
    guard !duplicates.isEmpty else { return items }
    return items.map { item in
      guard let name = item.name, duplicates.contains(name) else { return item }
      var result = item
      result.name = nil
      return result
    }
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
