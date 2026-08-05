<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# 録画とSwift CLIのワークフロー

録画を調べる前、または分析コマンドを実行する前に、この文書を最後まで読む。

## 実行契約

このスキルの標準分析CLIは、配置済みの次のコマンドだけとする。

```text
~/.local/bin/unite-analysis-swift
```

実行前に次を確認する。

```sh
test -x ~/.local/bin/unite-analysis-swift
~/.local/bin/unite-analysis-swift --help
```

PATH上の同名コマンドではなく、この絶対パスを使う。コマンドがない、実行できない、または必要なサブコマンドがない場合は、その検査を未実行として報告する。スキルからCLIをビルド、インストール、更新、上書きしない。

APMはスキルを配布するものであり、Swiftバイナリをインストールするものではない。`apm_modules`、APMキャッシュ、Swiftソースのチェックアウト、`.build`内の成果物へ依存しない。

このワークフローでは外部の認識・映像・音声ツールを使わない。Swift CLIにない機能を別ツールで暗黙に補完せず、未取得として扱う。

`batch-frame`、`precise-frame`、`contact-sheet`など、VideoToolboxでソース動画をデコードする映像抽出サブコマンドはサンドボックス外で実行する。サンドボックス内で`Cannot Decode`になった場合は、同じコマンドと入力をサンドボックス外で再実行してから成否を判定する。サンドボックス内の`Cannot Decode`だけを根拠に、録画破損、spec不整合、CLIのデコード実装不具合と判定しない。サンドボックス外での再実行が許可されない場合は、環境制約により未検証と報告する。

## 入力と保存領域

ユーザーが指定した完了済み`.ldtxrecord`を読み取り専用の入力として扱う。固定の録画ディレクトリを仮定しない。

- `.finalized`がないアクティブな録画を除外する。
- 主映像は`Info.plist`と`record-spec.json`から解決し、固定ファイル名を仮定しない。
- 物理試合メタデータは`<recording>/_PokemonUniteMatches/match-<NN>/record-spec.json`とする。
- 分析成果物は`<recording>/_PokemonUniteAnalysis/`以下だけへ書く。
- 正本レポートは`<recording>/_PokemonUniteAnalysis/matches/match-<NN>/review.md`とする。
- LDTXが管理する既存ファイルを変更しない。

`record-spec.json`はCLIの必須入力である。見つからない場合は、利用可能な根拠から候補specを復元し、上記の物理試合メタデータ位置へ新規作成してよい。既存の`record-spec.json`を推定値で上書きしない。

復元には、ユーザーが示した事前知識、Codexメモリ、同じ録画環境または過去録画のspec、録画内Vision/OCR索引、既存分析成果物、`Info.plist`、主映像の寸法と継続時間を利用してよい。映像配置の自由度が高いため固定レイアウトを仮定せず、次を守る。

1. 試合時計などの時刻証拠から録画上の試合開始PTSと試合時間を計算する。
2. ゲーム領域は対象録画の証拠を優先し、過去specの矩形を使う場合は同一配置と判断した根拠を残す。
3. 候補値が主映像の範囲内にあり、試合区間が動画の継続時間と整合することを確認する。
4. 可能なら候補specを使ってソース動画画像を抽出し、試合時計とゲーム領域を目視検証する。
5. 根拠、計算、採用した値、推定項目、検証済み項目、未検証項目、検証コマンドの失敗を`<recording>/_PokemonUniteAnalysis/matches/match-<NN>/record-spec-recovery.md`へ記録する。

ソース動画抽出が失敗しても、他の根拠が十分なら候補specの作成自体を禁止しない。VideoToolboxを使う抽出は先にサンドボックス外で再実行する。検証状態を未検証または一部検証済みとして明示し、失敗したサブコマンド、実行環境、エラーを記録する。根拠が不足して候補値を合理的に作れない項目だけを未取得とし、Swift CLIによる依存分析を未実行として報告する。

## サブコマンドの選択

オプションとJSON契約の正本は、インストール済みコマンドのヘルプとする。

```sh
~/.local/bin/unite-analysis-swift help <subcommand>
```

| サブコマンド | 用途 |
|---|---|
| `batch-frame` | JSON配列で指定した複数時刻・複数矩形のソース動画画像を出力する |
| `precise-frame` | AVAssetReaderで1枚の明示的なソース矩形画像を出力する |
| `contact-sheet` | ソース動画フレームから任意配置のコンタクトシートを作る |
| `continuous-ocr` | 指定矩形を試合全体または選択イベント時刻でOCRする |
| `ocr-input-frame` | OCR前処理済み入力セルを検査用PNGとして出力する |
| `detect-chroma-events` | 指定矩形の時間方向の色差から視覚イベント候補を提案する |
| `audio-peaks` | main-mix音声のパワー上昇から映像確認候補時刻を提案する |
| `result-scan` | 結果画面またはバトルデータ画面をJSONへ読み取る |
| `eval-draw-text-script` | コンタクトシートの`drawText`用JSC式を単独評価する |

専用サブコマンドがある処理を、手作業の抽出や独自スクリプトへ置き換えない。失敗した場合は、実行したサブコマンド、入力、失敗理由、未取得項目を記録する。

## JSONジョブ

`batch-frame`、`contact-sheet`、`continuous-ocr`、`detect-chroma-events`には、1つのJSON配列としてジョブを渡す。

- 各ジョブの必須`output`へ出力先を記録する。
- `--record-spec`を明示する。
- 相対パスの基準がジョブファイルのディレクトリであることを確認する。標準入力を使う場合は現在の作業ディレクトリ基準になる。
- 既存成果物を意図せず上書きしない。`--force`は再生成対象を確認した場合だけ使う。
- `continuous-ocr`の各ジョブには、空でない`recognitionLanguages`を明示する。
- ソース矩形を主映像の左上原点ピクセル座標で明示し、既定のゲーム領域を仮定しない。

## ソース動画証拠

Vision/OCR出力はシーク用索引であり、画像証拠ではない。分析画像は必ず`batch-frame`、`precise-frame`、または`contact-sheet`でソース動画から生成する。

概要コンタクトシートは候補探索に使う。重要な主張は、密な時系列の`batch-frame`または`precise-frame`画像で再確認する。要求時刻と実際の取得時刻、ゲーム内時計の違いが見えるようにし、ラベルで関連UIを覆わない。

標準的な1920x1080録画でゲーム領域が`(0,0,1632,918)`である場合があっても、既定値として使わない。各ジョブに対象録画の実測矩形を指定する。

## 候補検出とOCR

短時間のUI変化には`detect-chroma-events`を使う。出力スコアは時間差分の候補であり、イベント分類ではない。目的に合う`minimumScore`を選んで`continuous-ocr`へ渡し、固定の万能しきい値を定めない。

OCR結果に疑問がある場合は`ocr-input-frame`で前処理入力を確認する。OCR文字列だけで出来事を確定せず、ソース動画画像を再確認する。

`audio-peaks`はmain-mixの効果音パワー上昇から候補時刻を出すだけであり、KO、得点、オブジェクト、感情、発話を分類しない。

## リザルト

`result-scan`には、Swift CLIで生成し、ゲーム画面全体が正しく含まれると確認した静止画を渡す。

- 総合結果には`--type summary`を使う。
- バトルデータには`--type battle-data`を使う。
- レイアウトや切り出しが不正な画像の認識値を採用しない。
- Apple Visionを実行できない場合は未実行として報告する。
- 出力JSONと元のソース動画画像を対応づけて保存する。

## 選出形式とロードアウト

選出形式は、Swift CLIで生成した選出開始前からVS画面までの画像列で判断する。

- ban、交互ピック、明示的な選択ターンが見える場合は`draft`とする。
- 味方が同時に選択し、banや交互ターンが見えない場合は`blind`とする。
- 区別に必要な映像がない場合は`unknown`とする。
- 最終準備、ルート、VS画面のレイアウトだけで選出形式を決めない。

現行Swift CLIは持ち物、バトルアイテム、宣言ルートの専用自動認識を提供しない。画面から確実に読めない値は`—`または`?`とし、一般的なビルドから補完しない。

## 録画調査の順序

1. ユーザーが指定した録画と対象試合を確認する。
2. `.finalized`、`Info.plist`、`record-spec.json`を確認し、specがなければ根拠を集めて候補を復元・記録する。
3. `~/.local/bin/unite-analysis-swift --help`でCLIを確認する。
4. 既存の`_PokemonUniteAnalysis`成果物を調べ、現行入力と一致するものを再利用する。
5. `batch-frame`または`contact-sheet`で試合全体の概要を作る。
6. 必要に応じて`audio-peaks`、`detect-chroma-events`、`continuous-ocr`で候補時刻を探す。
7. `result-scan`で取得可能な結果とバトルデータを読み取る。
8. 局所目標と出力の候補を選び、密なソース動画画像で検証する。
9. KO、デス、得点、オブジェクト、離脱、中断、交換、強制反応、進入路、味方の合流を確認する。
10. 目視事実、時系列推論、分析仮説、ユーザー説明を区別して対話へ入る。

マップ状態を読む場合は、同じソースフレームのミニマップ、味方状態、ゲーム内時計を併せて確認する。味方の分布と生存・復帰状態を補間せず記録する。
