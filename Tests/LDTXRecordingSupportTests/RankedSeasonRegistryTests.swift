// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

private struct RankedSeasonRegistry: Decodable {
  let schemaVersion: Int
  let updatedAt: String
  let timezone: String
  let seasons: [RankedSeason]
}

private struct RankedSeason: Decodable {
  let season: Int
  let startsAt: String
  let endsAt: String
  let mapFormat: String
  let folderName: String
}

private func skillReferenceURL(_ name: String) -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("skills/review-unite-matches-ja/references")
    .appendingPathComponent(name)
}

@Test func rankedSeasonRegistryHasValidNonoverlappingPeriodsAndFolders() throws {
  let data = try Data(contentsOf: skillReferenceURL("ranked-seasons.json"))
  let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  #expect(
    Set(root.keys) == Set(["$schema", "schemaVersion", "updatedAt", "timezone", "seasons"]))
  #expect(root["$schema"] as? String == "ranked-seasons.schema.json")

  let registry = try JSONDecoder().decode(RankedSeasonRegistry.self, from: data)
  #expect(registry.schemaVersion == 1)
  #expect(registry.timezone == "Asia/Tokyo")
  #expect(Calendar(identifier: .iso8601).date(from: dateComponents(registry.updatedAt)) != nil)

  let formatter = ISO8601DateFormatter()
  var seasonNumbers = Set<Int>()
  var periods: [(start: Date, end: Date, season: Int)] = []

  for season in registry.seasons {
    #expect(season.season > 0)
    #expect(seasonNumbers.insert(season.season).inserted)
    let start = try #require(formatter.date(from: season.startsAt))
    let end = try #require(formatter.date(from: season.endsAt))
    #expect(start < end)
    periods.append((start, end, season.season))

    let expectedPrefix = "Season-\(season.season)-"
    #expect(season.folderName.hasPrefix(expectedPrefix))
    switch season.mapFormat {
    case "groudon":
      #expect(season.folderName == expectedPrefix + "Groudon")
    case "kyogre":
      #expect(season.folderName == expectedPrefix + "Kyogre")
    case "other":
      #expect(season.folderName.count > expectedPrefix.count)
    default:
      Issue.record("Unsupported mapFormat: \(season.mapFormat)")
    }
  }

  let orderedPeriods = periods.sorted { $0.start < $1.start }
  for (previous, current) in zip(orderedPeriods, orderedPeriods.dropFirst()) {
    #expect(previous.end <= current.start)
  }
}

private func dateComponents(_ value: String) -> DateComponents {
  let parts = value.split(separator: "-")
  guard parts.count == 3 else { return DateComponents() }
  return DateComponents(
    year: Int(parts[0]), month: Int(parts[1]), day: Int(parts[2]))
}
