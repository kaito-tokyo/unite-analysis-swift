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

このワークフローでは外部の認識・映像・音声ツールでSwift CLIの欠落機能を暗黙に補完せず、未取得として扱う。ただし、`sample-frames` helpに示される同形のFFmpeg抽出は、ユーザーまたは既存ワークフローが明示的に選んだ場合に限り利用できる。

AVFoundationで動画または音声を読む`batch-frame`、`sample-frames`、`precise-frame`、`contact-sheet`、`frame-burst`、`audio-peaks`、`recognize-draft-loadout`、`recognize-blind-loadout`、`eval-draw-text-script`と、Apple Visionを使う`ocr`、`scan-result`はサンドボックス外で実行する。サンドボックス外での実行が許可されない場合は、環境制約により未実行として記録する。

サンドボックス内で`Cannot Decode`になった場合は、同じコマンドと入力をサンドボックス外で再実行してから成否を判定する。サンドボックス内の失敗だけを根拠に録画破損や実装不具合と判定しない。

## 入力と保存領域

ユーザーが指定した完了済み`.ldtxrecord`を読み取り専用の入力として扱う。固定の録画ディレクトリを仮定しない。

- `.finalized`がないアクティブな録画を除外する。
- recording format v2だけを対象とする。主映像ファイル名は`main.fragmented.mp4`であり、`LDTXRecordingMainMediaFile`も通常は同じ名前を記録する。
- 物理試合メタデータは`<recording>/_PokemonUniteMatches/match-<NN>/record-spec.json`とする。
- 分析成果物は`<recording>/_PokemonUniteAnalysis/`以下だけへ書く。
- 正本レポートは`<recording>/_PokemonUniteAnalysis/matches/match-<NN>/review.md`とする。
- LDTXが管理する既存ファイルを変更しない。

`record-spec.json`は録画を読む各コマンドの必須入力である。見つからない場合は、ソース動画、`Info.plist`、既存の分析成果物から根拠を集め、試合境界とゲーム画面矩形を候補として復元する。候補specは`<recording>/_PokemonUniteAnalysis/matches/match-<NN>/record-spec.json`へ保存し、根拠と未確定な値を分析メモへ記録する。LDTXが管理する`_PokemonUniteMatches/`には書き込まない。

## サブコマンドの選択

オプションとJSON契約の正本は、インストール済みコマンドのヘルプとバイナリ内蔵schemaとする。

```sh
~/.local/bin/unite-analysis-swift help <subcommand>
~/.local/bin/unite-analysis-swift schema <schema-basename>
```

| サブコマンド | 用途 |
|---|---|
| `batch-frame` | 各ジョブの`source`、`outputPrefix`、数値`matchTimestamps`で指定した複数時刻・複数矩形のソース動画画像を出力する |
| `precise-frame` | AVAssetReaderで1枚の明示的なソース矩形画像を出力する |
| `contact-sheet` | ソース動画フレームから任意配置のコンタクトシートを作る |
| `frame-burst` | 指定時刻以降の連続ソースフレームを連写として1枚へ並べ、1秒未満の動作を検証する |
| `ocr` | 静止画ジョブごとに矩形、領域名、認識タイプを明示してOCRする |
| `sample-frames` | FFmpeg相似のcrop、fps、scale指定で1領域のJPEG連番を出力する |
| `detect-chroma-events` | JPEG連番をファイル名辞書順に処理して視覚イベント候補を提案する |
| `audio-peaks` | recording format v2の主映像音声のパワー上昇から映像確認候補時刻を提案する |
| `scan-result` | 結果画面またはバトルデータ画面をJSONへ読み取る |
| `recognize-draft-loadout` | draftの最終準備画面とVS画面から、味方の持ち物・バトルアイテム・宣言ルート、敵のバトルアイテムをJSONへ読み取る |
| `recognize-blind-loadout` | blind選択画面から、味方の持ち物・バトルアイテム・宣言ルートをJSONへ読み取る |
| `eval-draw-text-script` | コンタクトシートの`drawText`用JSC式を単独評価する |
| `schema` | `$schema` URLのbasenameを指定して内蔵JSON Schemaを表示する |
| `config` | 明示的な保存・公開時にユーザー設定を管理する |

専用サブコマンドがある処理を、手作業の抽出や独自スクリプトへ置き換えない。失敗した場合は、実行したサブコマンド、入力、失敗理由、未取得項目を記録する。

## JSONジョブ

`batch-frame`、`contact-sheet`、`frame-burst`、`ocr`には、1行1ジョブの`jobs.jsonl`を渡す。各ジョブに空でない一意な`jobId`を明示し、各出力行の`jobId`で結果を対応付ける。jobs行に`$schema`は書かない。`-`を指定する場合はstdinをEOF前から1行ずつ処理し、stdoutのJSONL応答を1行ずつ読む。1ジョブの失敗では後続処理やプロセス終了コードが失敗しないため、全応答行の`ok`を検査する。`sample-frames`と`detect-chroma-events`はJSONLジョブを使わず、1回につき1領域をオプションで処理する。

- `batch-frame`の各ジョブには`outputPrefix`を、`contact-sheet`と`frame-burst`の各ジョブには`output`を明示する。`ocr`の結果はstdout、またはコマンドの`--output`が指定するJSONLへ書き出す。
- 録画を読むコマンドは`.ldtxrecord`ルートをカレントディレクトリにし、試合ごとの`record-spec.json`を`--record-spec`で必ず指定する。`ocr`は静止画入力のみを読み、`record-spec.json`を使わない。
- すべての相対パスは、ジョブファイルの位置に関係なく現在の作業ディレクトリ基準とする。
- 既存成果物を意図せず上書きしない。`--force`は再生成対象を確認した場合だけ使う。
- `ocr`の各ジョブは`region`で`ocr-options.json`の同名エントリを選び、`source`と`type`を明示する。`ocr-options.json`には`$schema`、選択領域ごとの空でない`recognitionLanguages`、必要なら`customWords`を記録する。fallbackはない。
- `sample-frames`と`detect-chroma-events`には同じ正の有限値`fps`を明示する。
- `batch-frame`と`contact-sheet`の`matchTimestamps`は試合開始を0とする有限数値の配列とし、厳密な昇順にする。負数は試合開始前、試合時間より大きい値は試合終了後を表す。
- ソース矩形を主映像の左上原点ピクセル座標で明示し、既定のゲーム領域を仮定しない。

## ソース動画証拠

Vision/OCR出力はシーク用索引であり、画像証拠ではない。分析画像は必ず`batch-frame`、`precise-frame`、`contact-sheet`、または`frame-burst`でソース動画から生成する。

概要コンタクトシートは候補探索に使う。重要な主張は、密な時系列の`batch-frame`または`precise-frame`画像で再確認する。要求時刻と実際の取得時刻、ゲーム内時計の違いが見えるようにし、ラベルで関連UIを覆わない。

ゲーム領域は16:9でも録画内の位置とピクセル寸法が異なり得る。固定矩形を既定値にせず、各ジョブに対象録画の実測矩形を指定する。

## 標準コンタクトシート構成

具体的な配置JSONと使い方は[contact-sheet-layouts.md](contact-sheet-layouts.md)を正本とする。標準として固定するのは、10列×10行、6秒間隔の`overview` 5種類だけである。標準条件では[overview-contact-sheet-jobs.jsonl](overview-contact-sheet-jobs.jsonl)を変更せず使う。

overview以外のコンタクトシートに固定のPhase、Detail、列数、時間間隔、セル寸法を設けない。検証する主張を先に決め、overviewに定義されたROIの`source`を再利用または組み合わせて、必要な時刻範囲と密度の分析用コンタクトシートを自律的に設計・生成し、生成結果を読んで分析へ使う。注目する画面領域と時間範囲へ絞り、最終シート全体はセルを歪めず正方形または16:9に近い表示しやすい比率を推奨する。必要なら目的または時間帯で複数枚へ分割する。

複数overviewのROIを1セルへ組み合わせる場合は、元の`placements`配列を連結しない。各ROIに新しいセル内の重ならない`destination`を割り当て、動的ラベルは1つへ統合し、全配置を同じ`matchTimestamp`へ対応させる。ラベルで試合時計、ミニマップ、通知、味方状態、ターゲットホイールを覆わない。標準HUDと異なる場合だけソース矩形を再実測し、変更値と理由を分析メモへ記録する。

### 分析順序と確定証拠

標準の読み順は次とする。

1. 5種類のoverviewを試合全体のサンプル索引として走査する。特定の接敵相手を探すときは`target-wheel-overview`を優先するが、6秒未満の接触は欠落し得るため網羅的な接敵検出には使わない。
2. 検証する主張と必要なROIを選ぶ。
3. overviewの`placements`を使って、候補場面の分析用コンタクトシートを必要な密度で作る。
4. 重要な主張はすべて、密な時系列の`batch-frame`または`precise-frame`原寸画像で再確認する。数字、個体識別、技の命中、同時死亡など縮小セルで確定できない事実には、追加の原寸確認を行う。

振り向きなど連続動作の成立時間を検証するときは、[frame-burst.md](frame-burst.md)に従い、候補区間を`frame-burst`で60連続フレームの連写として並べる。これはコンタクトシートではない。時間指定を細分した通常の`contact-sheet`で代用しない。

コンタクトシートだけで細部を断定しない。一方、単一フレームへ直ちに分解して時系列の関係を失わず、まず分析用コンタクトシートで試み、反応、出力を連続して読む。

## 事前イベント点候補生成

事前イベント点候補は重要イベントの確定結果ではなく、未分類のシーク索引である。候補の意味は必ずソース動画へ戻って判断する。候補生成の後に行うシーン境界、局所目標、敵反応、味方への伝播、因果関係の分析はこの契約に含めない。

対話前の分析では、次の候補生成を原則実行する。

1. `audio-peaks`を試合全体へ実行する。`peaks`のscoreの95パーセンタイル以上を時刻順に並べ、最初の点を起点とする5秒未満の固定幅クラスタへまとめる。次の点が現在のクラスタの最初の点から5秒以上離れたら、新しいクラスタを始める。隣接差による推移的統合で5秒を超えるクラスタを作らない。クラスタの代表点はscoreが最大の点、同点なら早い点とし、最小時刻、最大時刻、全構成ピークも保持する。全`intervals`をそのまま候補にしない。
2. 対象録画で確定したUI領域ごとに`sample-frames`を2 fps、JPEG quality 0.95で実行し、同じ2 fpsで`detect-chroma-events`を実行する。ファイル名は`frame-000001.jpg`のようにゼロ埋めし、辞書順と時系列を一致させる。
3. 色差scoreの分位点は領域ごとに独立して計算する。99.5パーセンタイル以上を一次候補、99パーセンタイル以上を二次候補とする。一次候補はすべて後段へ渡す。二次候補は、その時刻が一次色差候補または音声候補のいずれの構成点からも2秒を超えて離れている場合だけ、未被覆時間帯の補完として渡す。この段階では近接するraw色差点を代表点へ畳み込まない。
4. 後段へ渡す一次・二次の各raw色差点の時刻を`t`とし、`t - 0.5`、`t`、`t + 0.5`秒を`precise-frame`で同じ領域の実寸JPEGとして元動画から再抽出する。試合範囲外の時刻は除き、各画像を`ocr`へ渡す。3時刻の結果とconfidenceをすべて保持し、表示途中と判断できる文字列を無理に統合しない。`batch-frame`は近似シークにより複数の要求時刻が同じ実フレームへ吸着し得るため、この短時間OCR列には使わない。色差計算用の縮小JPEGをOCR入力にせず、OCR内部で候補を生成・選別させない。OCR失敗または空結果でも色差候補を除去しない。
5. 音声、色差、OCR、確認済みの定刻イベントを試合相対時刻へ正規化する。近接候補は隣接点の差が2秒以下なら推移的に統合し、構成点の最小時刻と最大時刻を確認範囲として保持する。
6. 統合後も全構成点と由来を失わない。由来は`audio`、`chroma:<region>`、`ocr:<region>`、`scheduled`とし、色差は領域内分位、音声はscore、OCRは認識値とconfidenceを保持する。異なる領域のraw scoreを直接比較しない。
7. 統合候補の入力契約と保存契約が利用可能なら、候補列を後続の自由分析への入力として保存する。契約が未確定な間は独自スキーマを作らず、各ツール出力、選択条件、採用時刻、統合範囲、由来を分析メモへ残す。

2 fpsでは、10分試合の各領域が約1200枚になる。領域を縮小したJPEG連番は色差測定用の一時索引であり、証拠画像ではない。色差出力の`requestedInmatch`が`t`なら、変化後の画像は通常`round(t * fps) + 1`番のJPEGに対応するが、OCRと最終確認には番号から画像を流用せず、`requestedInmatch`を使って元動画から再抽出する。

この文書のパーセンタイルはnearest-rankで求める。scoreを昇順に並べた個数`N`の列について、`p`パーセンタイルのしきい値は1始まりの`ceil(p / 100 * N)`番目とし、その値以上を採用する。値が同じ候補はすべて採用するため、採用件数を固定しない。

16:9ゲーム領域での初期領域は次とする。値はゲーム領域の幅と高さに対する割合であり、実際のピクセル矩形へ比例変換してゲーム領域の左上オフセットを加える。UI配置が異なるモードではソース動画で領域を再確認する。

| 領域名 | 正規化矩形 `(x,y,width,height)` | 色差用scale |
|---|---:|---:|
| `event-banner` | `(26.35%,11.44%,49.02%,12.53%)` | `100x14` |
| `top-center-event` | `(31.86%,0%,36.76%,23.97%)` | `75x27` |
| `center-announcement` | `(30.64%,19.61%,42.89%,28.32%)` | `87x32` |

定刻候補は、対象モードと試合時間から確定できるものだけを追加する。10分の標準試合では試合相対480秒のラストスパートを`scheduled`として追加する。マップやモードで時刻が変わり得る野生ポケモン出現を一般知識から補完しない。

入力メディア不存在、必要なCLI機能不存在、デコード不能、Vision利用不能など、技術的に実行できない場合だけ該当種別を省略できる。その場合は、未取得種別、実行コマンド、失敗理由を分析成果物へ記録する。

上記の分位点、音声クラスタ幅、統合幅、OCR時刻列は再現可能な初期契約である。録画条件の違いで候補が明らかに過多または過少なら変更できるが、変更値と理由を分析メモへ記録する。統合候補ファイルの正式なJSON Schemaと保存場所は`event-detect`設計まで未確定とする。

OCR結果に疑問がある場合は、`ocr`出力の入力絶対パスと`source`を使って同じJPEG領域を確認する。OCR文字列だけで出来事を確定せず、ソース動画画像を再確認する。`audio-peaks`と`detect-chroma-events`もイベントを分類しない。

`audio-peaks`は`--record-spec`と必要なら正の`--gain`だけを受け、試合全体を解析する。`inmatch-start`や`duration`は指定しない。format v2の`main.fragmented.mp4`内の音声トラックを使い、音声トラックなし、format v1、デコード不能はエラーとして記録する。出力契約は`audio-peaks.output.schema.json`で確認する。

`detect-chroma-events`はJPEGディレクトリ、同じ`--fps`、JSON出力先をオプションで受ける。出力は全隣接ペアの無選別測定であり、契約は`chroma-events.output.schema.json`で確認する。

試合全体の概要コンタクトシートは目視探索索引であり、上記の機械生成候補に含めない。`scan-result`も事前基礎情報と最終結果の復元であり、候補生成に含めない。

## リザルト

`scan-result`には、Swift CLIで生成し、ゲーム画面全体が正しく含まれると確認した静止画を渡す。

- 総合結果には`--type summary`を使う。
- バトルデータには`--type battle-data`を使う。
- レイアウトや切り出しが不正な画像の認識値を採用しない。
- Apple Visionを実行できない場合は未実行として報告する。
- 出力JSONと元のソース動画画像を対応づけて保存する。
- 出力契約は`scan-result.output.schema.json`で確認する。
- `--output`は既存ファイルを`--force`なしで原子的に置換するため、新規パスを使うか、置換対象を確認してから実行する。

## 選出形式とロードアウト

選出形式は、Swift CLIで生成した選出開始前からVS画面までの画像列で判断する。

- ban、交互ピック、明示的な選択ターンが見える場合は`draft`とする。
- 味方が同時に選択し、banや交互ターンが見えない場合は`blind`とする。
- 区別に必要な映像がない場合は`unknown`とする。
- 最終準備、ルート、VS画面のレイアウトだけで選出形式を決めない。

持ち物、バトルアイテム、宣言ルートは専用コマンドで読み取る。draftかblindかは認識器に推測させず、上の映像証拠で形式を確定してから対応するコマンドを選ぶ。`--record-spec`と試合相対の安定フレーム時刻を指定し、標準出力先は`<recording>/_PokemonUniteAnalysis/matches/match-<NN>/`とする。認識候補が空なら値は`—`または`?`とし、一般的なビルドから補完しない。

## 録画調査の順序

1. ユーザーが指定した録画と対象試合を確認する。
2. `.finalized`、`Info.plist`、`record-spec.json`を確認し、specがなければ根拠を集めて候補を復元・記録する。
3. `~/.local/bin/unite-analysis-swift --help`でCLIを確認する。
4. 既存の`_PokemonUniteAnalysis`成果物を調べ、現行入力と一致するものを再利用する。
5. 事前イベント点候補生成の実行契約を実行し、候補または未取得理由を保存する。
6. `batch-frame`または`contact-sheet`で、候補生成とは別に試合全体の概要を作る。
7. `scan-result`で、候補生成とは別に取得可能な結果とバトルデータを読み取る。
8. 候補から局所目標と出力を自由に分析し、密なソース動画画像で検証する。
9. KO、デス、得点、オブジェクト、離脱、中断、交換、強制反応、進入路、味方の合流を確認する。
10. 目視事実、時系列推論、分析仮説、ユーザー説明を区別して対話へ入る。

マップ状態を読む場合は、同じソースフレームのミニマップ、味方状態、ゲーム内時計を併せて確認する。味方の分布と生存・復帰状態を補間せず記録する。
