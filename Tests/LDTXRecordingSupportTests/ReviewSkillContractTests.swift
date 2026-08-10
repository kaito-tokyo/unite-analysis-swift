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

@Test func matchReviewRequiresIntegratedCausalNarrative() throws {
  let skill = try reviewSkillText("SKILL.md")

  #expect(skill.contains("因果物語を検討して訂正するための内部視点"))
  #expect(skill.contains("必須カテゴリへ分割せず"))
  #expect(skill.contains("一読できる統合した因果物語"))
  #expect(skill.contains("初期候補を数多く保持する"))
  #expect(skill.contains("実現しなかった危険を幅広く覆う"))
  #expect(skill.contains("1本の因果連鎖へまとめる"))
  #expect(skill.contains("分析者は、映像からイベント"))
  #expect(skill.contains("プレイヤーは、自分の貢献の意味"))
  #expect(skill.contains("押し出し、行動不能、瞬間火力、進入阻止"))
  #expect(skill.contains("### この対話契約の非目標"))
}
