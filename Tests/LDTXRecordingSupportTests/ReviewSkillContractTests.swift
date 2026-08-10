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

@Test func allyReactionWindowsRequireFeasibilityAndRevision() throws {
  let skill = try reviewSkillText("SKILL.md")
  let model = try reviewSkillText("references/reaction-windows.md")

  #expect(skill.contains("任意の[味方の反応窓]"))
  #expect(model.contains("使わなかった"))
  #expect(model.contains("使えなかった"))
  #expect(model.contains("視覚的に明瞭な形で使った"))
  #expect(model.contains("視覚的に不明瞭な形で使った"))
  #expect(model.contains("決定的な制約が確認できる"))
  #expect(model.contains("対応行動を取らなかったことを継続して観察できる"))
  #expect(model.contains("行動の可視性が不足"))
  #expect(model.contains("責任、消極性、判断ミスを味方へ帰属させない"))
  #expect(model.contains("最初の視覚分類と因果説明を更新する"))
  #expect(model.contains("通常の試合振り返りに必須とせず"))
}
