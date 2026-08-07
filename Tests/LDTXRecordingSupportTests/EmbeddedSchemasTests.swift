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

private func containsAdditionalProperties(_ value: Any) -> Bool {
  if let dictionary = value as? [String: Any] {
    return dictionary.keys.contains("additionalProperties")
      || dictionary.values.contains(where: containsAdditionalProperties)
  }
  if let array = value as? [Any] {
    return array.contains(where: containsAdditionalProperties)
  }
  return false
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
    #expect(!containsAdditionalProperties(embeddedObject))
  }
}
