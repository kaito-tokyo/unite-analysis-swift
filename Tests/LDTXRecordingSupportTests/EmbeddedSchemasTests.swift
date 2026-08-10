// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import UniteAnalysisSwiftCommands

let repositoryRoot = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent()
  .deletingLastPathComponent()
  .deletingLastPathComponent()

private func objectSchemasAreClosed(_ value: Any) -> Bool {
  if let dictionary = value as? [String: Any] {
    if dictionary["type"] as? String == "object",
      dictionary["properties"] != nil || dictionary["patternProperties"] != nil,
      dictionary["additionalProperties"] as? Bool != false
    {
      return false
    }
    return dictionary.values.allSatisfy(objectSchemasAreClosed)
  }
  if let array = value as? [Any] {
    return array.allSatisfy(objectSchemasAreClosed)
  }
  return true
}

private func fieldDescriptions(named fieldName: String, in value: Any) -> [String?] {
  if let dictionary = value as? [String: Any] {
    var descriptions: [String?] = []
    if let properties = dictionary["properties"] as? [String: Any],
      let field = properties[fieldName] as? [String: Any]
    {
      descriptions.append(field["description"] as? String)
    }
    for nested in dictionary.values {
      descriptions.append(contentsOf: fieldDescriptions(named: fieldName, in: nested))
    }
    return descriptions
  }
  if let array = value as? [Any] {
    return array.flatMap { fieldDescriptions(named: fieldName, in: $0) }
  }
  return []
}

@Test func embeddedSchemasMatchDocumentsAndNamingContract() throws {
  let docsURL = repositoryRoot.appendingPathComponent("docs", isDirectory: true)
  let documentBasenames = try Set(
    FileManager.default.contentsOfDirectory(
      at: docsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "json" }.map(\.lastPathComponent))

  #expect(Set(EmbeddedSchemas.basenames) == documentBasenames)
  #expect(Set(EmbeddedSchemas.storedBasenames) == documentBasenames)

  for basename in documentBasenames.sorted() {
    let embeddedData = try #require(EmbeddedSchemas.data(basename: basename))
    let documentData = try Data(contentsOf: docsURL.appendingPathComponent(basename))
    let embeddedObject = try JSONSerialization.jsonObject(with: embeddedData)
    let documentObject = try JSONSerialization.jsonObject(with: documentData)

    #expect((embeddedObject as AnyObject).isEqual(documentObject))
    let root = try #require(embeddedObject as? [String: Any])
    let identifier = try #require(root["$id"] as? String)
    #expect(URL(string: identifier)?.lastPathComponent == basename)
  }
}

@Test func inputSchemasRejectUnknownObjectProperties() throws {
  let inputSchemas = [
    "batch-frame.schema.json",
    "contact-sheet.schema.json",
    "event-detect.input.schema.json",
    "frame-burst.schema.json",
    "ocr-options.schema.json",
    "ocr.schema.json",
    "publication.schema.json",
  ]
  for basename in inputSchemas {
    let data = try Data(contentsOf: repositoryRoot.appendingPathComponent("docs/\(basename)"))
    #expect(objectSchemasAreClosed(try JSONSerialization.jsonObject(with: data)))
  }
}

@Test func schemasDescribeSemanticallyAmbiguousFields() throws {
  let fieldNames = [
    "actualInmatch", "confidence", "detectionScore", "matchTimestamps", "requestedInmatch",
    "score",
  ]
  let docsURL = repositoryRoot.appendingPathComponent("docs", isDirectory: true)
  let schemaURLs = try FileManager.default.contentsOfDirectory(
    at: docsURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
  ).filter { $0.pathExtension == "json" }
  let schemaObjects = try schemaURLs.map {
    try JSONSerialization.jsonObject(with: Data(contentsOf: $0))
  }

  for fieldName in fieldNames {
    let descriptions = schemaObjects.flatMap {
      fieldDescriptions(named: fieldName, in: $0)
    }
    #expect(!descriptions.isEmpty)
    #expect(descriptions.allSatisfy { $0?.isEmpty == false })
  }
}
