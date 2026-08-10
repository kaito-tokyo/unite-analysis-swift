// SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>
//
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

private func reviewSkillText(_ relativePath: String) throws -> String {
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  return try String(
    contentsOf:
      repositoryRoot
      .appendingPathComponent(".apm/skills/review-unite-matches-ja")
      .appendingPathComponent(relativePath),
    encoding: .utf8)
}

@Test func initialHighlightDiscussionRequiresSceneBoundedClips() throws {
  let skill = try reviewSkillText("SKILL.md")
  let workflow = try reviewSkillText("references/recording-workflow.md")

  #expect(skill.contains("選んだ候補ごとに`extract-clip`を1本生成する"))
  #expect(skill.contains("再生可能な動画クリップを各候補の主成果物"))
  #expect(skill.contains("ソース動画画像をfallback"))
  #expect(skill.contains("近接する同期サンプル"))

  #expect(workflow.contains("境界は固定時間窓ではなくシーンモデルから決め"))
  #expect(workflow.contains("動画を主成果物、ソース動画画像を補助証拠"))
}
