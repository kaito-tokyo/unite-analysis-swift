# 標準overviewコンタクトシート

標準として固定するコンタクトシートは、10列×10行、6秒間隔で10分試合全体を俯瞰する5種類の`overview`だけとする。標準HUD、原点`(0,0)`のゲーム領域`1632x918`、10分、`match-01`では、[overview-contact-sheet-jobs.jsonl](overview-contact-sheet-jobs.jsonl)を変更せず使う。ジョブファイルはスキルの配置場所にあるため、録画ルートをカレントディレクトリにしてから、`SKILL.md`があるディレクトリを`<skill-root>`として分析成果物領域へコピーする。

```sh
mkdir -p _PokemonUniteAnalysis/matches/match-01
cp <skill-root>/references/overview-contact-sheet-jobs.jsonl \
  _PokemonUniteAnalysis/matches/match-01/overview-contact-sheet-jobs.jsonl
unite-analysis-swift contact-sheet \
  --record-spec _PokemonUniteMatches/match-01/record-spec.json \
  _PokemonUniteAnalysis/matches/match-01/overview-contact-sheet-jobs.jsonl
```

5つの出力は`_PokemonUniteAnalysis/matches/match-01/contact-sheets/`へ作られる。ゲーム領域の原点が`(0,0)`でない場合は、テンプレートをそのまま使わず、すべての`source`矩形へ実測したオフセットを加える。

| overview | 含む領域 | 主な用途 |
|---|---|---|
| `full-frame-overview` | ゲーム領域全体 | 戦闘、移動、ゴール、オブジェクトを含む文脈 |
| `minimap-overview` | ミニマップ | 味方の集散、ゴール状態、反対側の変換 |
| `player-zoom-overview` | プレイヤー周辺 | 向き、間合い、敵の始動、操作反応 |
| `player-ui-overview` | 味方状態、時計と敵KOタイマー、プレイヤーHUD、ターゲットホイール | 生存、接敵相手、ターゲット切替、技と資源 |
| `target-wheel-overview` | ターゲットホイールだけを判読しやすく拡大 | 接敵相手候補の全試合サンプル索引。6秒未満の接触を網羅せず、接触区間の確定には高密度の分析用シートを使う |

## 分析用コンタクトシート

overview以外の列数、時間範囲、時間間隔、セル寸法、組合せを標準化しない。検証する主張に合わせて自由に作る。必要な分析用コンタクトシートの構成を自律的に決め、JSONLを作成し、ソース動画から出力し、生成結果を実際に読んで分析へ使う。overviewを生成しただけで分析用シートの工程を終えない。

1. 5つのoverviewから候補区間と検証する主張を選ぶ。
2. overview JSONから必要な全景またはROIの`source`だけをコピーする。
3. 主張に必要な時刻範囲と密度へ`matchTimestamps`を変更する。
4. 必要なら複数のoverviewのROIを同一セルへ組み合わせる。その際は新しいセル寸法に対して重ならない`destination`を設計し、動的ラベルは1つに統合する。overviewごとの`placements`配列をそのまま連結しない。
5. 同一セル内の全配置は同じ`matchTimestamp`へ対応させる。
6. 重要な主張はすべて密な時系列の原寸画像で再確認する。縮小セルで曖昧な箇所には追加の原寸確認を行う。

### 組み方の推奨

- 最終的なシート全体の縦横比は、正方形または16:9のような一般的で表示しやすい比率に近づける。セル内容を歪めず、列数、行数、セル寸法、対象フレーム数で調整する。
- 試合全体、画面全体、利用可能な全UIを無条件に詰め込まない。注目する画面上の領域と時間範囲を、検証する主張に必要な範囲へ絞る。
- 短時間の操作反応には高い時間密度、ローテーションや味方の集散には広い時間範囲を選ぶ。対象に応じて密度を変える。
- 1枚が過大または極端に細長くなる場合は、判読性を落として1枚へ収めず、時間帯または目的で複数枚へ分割する。
- 配置の美しさだけでなく、試み、反応、出力を左から右、上から下へ連続して読めることを優先する。

標準HUDでない、ゲーム領域が`1632x918`でない、10分試合でない、または`match-01`以外では、JSON全体を再設計せず、該当する入力寸法、時刻列、出力先だけを機械的に変換する。変更値と理由を分析メモへ残す。
