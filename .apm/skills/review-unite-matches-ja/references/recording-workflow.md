# 録画とSwift CLIのワークフロー

録画を調べる前、または分析コマンドを実行する前に、この文書を最後まで読む。

## 実行契約

このスキルの標準分析手段は、プラグイン同梱の`run_unite_analysis` MCPツールだけとする。ツールの`arguments`へCLI引数を文字列配列として渡し、録画ルートは`currentDirectory`へ渡す。JSONLを`-`から読む場合は`standardInput`へ内容を渡す。

```text
run_unite_analysis(arguments: ["--help"])
```

実行前に、MCPツールで次に相当する引数を実行して機能を確認する。

```text
arguments: ["--help"]
```

以下のコード例にある`unite-analysis-swift`は、MCPツールへ渡す`arguments`を読みやすく示すCLI表記であり、シェルから実行しない。MCPツールがない、実行できない、または必要なサブコマンドがない場合は、その検査を未実行として報告する。スキルからCLIをビルド、インストール、更新、上書きしない。

プラグインにはスキルと署名済みappバンドルが同じバージョンで含まれる。Swiftソースのチェックアウト、`.build`内の成果物、プラグイン外の実行ファイルへ依存しない。

このワークフローでは外部の認識・映像・音声ツールでSwift CLIの欠落機能を暗黙に補完せず、未取得として扱う。ただし、`sample-frames` helpに示される同形のFFmpeg抽出は、ユーザーまたは既存ワークフローが明示的に選んだ場合に限り利用できる。

AVFoundationで動画または音声を読む`batch-frame`、`sample-frames`、`precise-frame`、`contact-sheet`、`frame-burst`、`audio-peaks-v1`、`asr-v1`、`extract-clip`、`recognize-draft-loadout-v1`、`recognize-blind-loadout-v1`、`eval-draw-text-script`と、Apple Visionを使う`detect-matches-v1`、`ocr-v1`、`scan-result-v1`はサンドボックス外で実行する。`asr-v1`が必要とするApple管理のSpeech assetもサンドボックス外で取得する。サンドボックス外での実行が許可されない場合は、環境制約により未実行として記録する。

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
unite-analysis-swift help <subcommand>
unite-analysis-swift schema <schema-basename>
```

| サブコマンド | 用途 |
|---|---|
| `batch-frame` | 各ジョブの`source`、`outputPrefix`、数値`matchTimestamps`で指定した複数時刻・複数矩形のソース動画画像を出力する |
| `precise-frame` | AVAssetReaderで1枚の明示的なソース矩形画像を出力する |
| `contact-sheet` | ソース動画フレームから任意配置のコンタクトシートを作る |
| `frame-burst` | 指定時刻以降の連続ソースフレームを連写として1枚へ並べ、1秒未満の動作を検証する |
| `ocr-v1` | 静止画ジョブごとに矩形、領域名、認識タイプを明示してOCRする |
| `sample-frames` | FFmpeg相似のcrop、fps、scale指定で1領域のJPEG連番を出力する |
| `detect-chroma-events-v1` | JPEG連番をファイル名辞書順に処理して視覚イベント候補を提案する |
| `audio-peaks-v1` | recording format v2の主映像音声のパワー上昇から映像確認候補時刻を提案する |
| `asr-v1` | ローカル音声・動画内の発話をAppleのオンデバイス音声認識で時刻付きテキスト索引にする |
| `extract-clip` | 試合相対の指定区間を再エンコードせずMP4へ切り出す |
| `scan-result-v1` | 結果画面またはバトルデータ画面をJSONへ読み取る |
| `recognize-draft-loadout-v1` | draftの最終準備画面とVS画面から、味方の持ち物・バトルアイテム・宣言ルート、敵のバトルアイテムをJSONへ読み取る |
| `recognize-blind-loadout-v1` | blind選択画面から、味方の持ち物・バトルアイテム・宣言ルートをJSONへ読み取る |
| `eval-draw-text-script` | コンタクトシートの`drawText`用JSC式を単独評価する |
| `schema` | `$schema` URLのbasenameを指定して内蔵JSON Schemaを表示する |
| `config` | 明示的な保存・公開時にユーザー設定を管理する |

専用サブコマンドがある処理を、手作業の抽出や独自スクリプトへ置き換えない。失敗した場合は、実行したサブコマンド、入力、失敗理由、未取得項目を記録する。

## 発話の任意索引

録画に含まれるユーザー発話、チーム音声、またはゲーム内アナウンスが場面探索に役立つ場合だけ`asr-v1`を使う。全試合で必須にせず、音声トラックがない場合、発話が分析に寄与しない場合、または音声認識を実行できない場合は省略理由を記録する。

対象試合またはシーンを`extract-clip`でMP4へ切り出し、そのMP4を`--input`へ渡す。設定は`asr-v1.input.schema.json`に従うJSONとして同じ試合の分析領域へ保存し、`language`には録音された発話の言語を指定する。`contextualStrings`には映像、ロードアウト、リザルト、またはユーザーの説明から確認済みの公式名称だけを最大100件まで渡し、一般知識から参加者、技名、意図を先回りして補完しない。

```json
{
  "$schema": "https://kaito-tokyo.github.io/unite-analysis-swift/asr-v1.input.schema.json",
  "language": "ja-JP",
  "contextualStrings": ["エースバーン", "ユナイト技"]
}
```

```sh
unite-analysis-swift asr-v1 \
  --input _PokemonUniteAnalysis/matches/match-01/clips/commentary.mp4 \
  --config _PokemonUniteAnalysis/matches/match-01/asr-config.json
```

返された完全な`asr-v1.output.schema.json`準拠JSONを、対応する入力MP4と設定JSONを識別できる分析成果物として保存する。`results`の`startTime`と`duration`は入力MP4基準であり、元録画や試合の絶対時刻とみなさない。パススルー切り出しでは近接する同期サンプルから始まる場合もあるため、認識時刻は該当区間を探す索引に限って使う。

認識テキストだけで、発話者、ゲーム内の出来事、技の使用、命中、意図、因果関係を確定しない。`isFinal`が`true`でも認識内容の正しさを保証しない。採用する内容と対応時刻は入力MP4の音声を聴き、出来事はソース動画画像または連続映像で再確認する。音声トラックなし、対応localeなし、asset取得不能、デコード不能、または認識失敗は、実行コマンドと理由を添えて`失敗`または`未実行`として記録する。

## JSONジョブ

`batch-frame`、`contact-sheet`、`frame-burst`、`ocr-v1`には、1行1ジョブの`jobs.jsonl`を渡す。各ジョブに空でない一意な`jobId`を明示し、各出力行の`jobId`で結果を対応付ける。jobs行に`$schema`は書かない。`-`を指定する場合はstdinをEOF前から1行ずつ処理し、stdoutのJSONL応答を1行ずつ読む。1ジョブの失敗では後続処理やプロセス終了コードが失敗しないため、全応答行の`ok`を検査する。`sample-frames`と`detect-chroma-events-v1`はJSONLジョブを使わず、1回につき1領域をオプションで処理する。

- `batch-frame`の各ジョブには`outputPrefix`を、`contact-sheet`と`frame-burst`の各ジョブには`output`を明示する。`ocr-v1`の結果はstdout、またはコマンドの`--output`が指定するJSONLへ書き出す。
- 録画を読むコマンドは`.ldtxrecord`ルートをカレントディレクトリにし、試合ごとの`record-spec.json`を`--record-spec`で必ず指定する。試合区間を検出する前の`detect-matches-v1`だけは例外で、録画を`--input`、固定UIレイアウトJSONを`--layout`で指定する。`ocr-v1`は静止画入力のみを読み、`record-spec.json`を使わない。
- すべての相対パスは、ジョブファイルの位置に関係なく現在の作業ディレクトリ基準とする。
- 既存成果物を意図せず上書きしない。`--force`は再生成対象を確認した場合だけ使う。
- `ocr-v1`の各ジョブは`region`で`ocr-options.json`の同名エントリを選び、`source`と`type`を明示する。`ocr-options.json`には`$schema`、選択領域ごとの空でない`recognitionLanguages`、必要なら`customWords`を記録する。fallbackはない。
- `sample-frames`と`detect-chroma-events-v1`には同じ正の有限値`fps`を明示する。
- `batch-frame`と`contact-sheet`の`matchTimestamps`は試合開始を0とする有限数値の配列とし、厳密な昇順にする。負数は試合開始前、試合時間より大きい値は試合終了後を表す。
- ソース矩形を主映像の左上原点ピクセル座標で明示し、既定のゲーム領域を仮定しない。

## 試合区間の動画切り出し

ハイライトの共有、局所シーンの連続再生、またはレポート用の映像を必要とするときは、`extract-clip`でrecording format v2の`main.fragmented.mp4`から必要区間をMP4へ切り出す。外部の動画ツールで再エンコードせず、まずこの専用サブコマンドを使う。

初回のハイライト対話では、選んだ候補ごとに1本のクリップを必ず先に生成し、動画を主成果物として提示する。境界は固定時間窓ではなくシーンモデルから決め、局所的な試みの短い前置き、敵と味方の反応、出力の確定までを含める。コンタクトシート、`frame-burst`、原寸フレームは候補探索、サブ秒検証、特定瞬間の補助証拠として維持する。

`.ldtxrecord`ルートから、`--start`と`--end`を試合開始からの秒数で指定する。`--start`の既定値は`0`、`--end`を省略すると試合終了までとなる。出力は`_PokemonUniteAnalysis/matches/match-<NN>/`以下の`.mp4`へ書く。

```sh
unite-analysis-swift extract-clip \
  --record-spec _PokemonUniteMatches/match-01/record-spec.json \
  --start 420 \
  --end 510 \
  --output _PokemonUniteAnalysis/matches/match-01/final-stretch.mp4
```

- 指定区間は`0 <= start < end <= record-spec duration`を満たす有限値とする。ソース動画の範囲外はエラーになる。
- `AVAssetExportPresetPassthrough`により、互換性のある圧縮済み映像・音声サンプルをデコード・再エンコードせずコピーする。
- 指定した開始時刻に新しいキーフレームは作られない。プレイヤーは近接する同期サンプルからデコードし始める場合がある。フレーム単位で正確かつ独立デコード可能な開始が必須なら、このコマンドではなく再エンコードが必要と報告する。
- MCPが返す`video/mp4`のresource linkをチャットへ提示し、再生できたことを確認する。resource linkが返らない、再生できない、または抽出に失敗した場合は、その候補の不足理由を明示し、ソース動画画像だけをfallbackとして提示する。
- 既存出力はエラーになる。再生成対象を確認した場合だけ`--force`を使う。出力は一時的な同階層ファイルへ書き出した後、成功時だけ目的パスへ置く。
- 出力MP4の映像・音声、指定区間、開始付近のデコード可否は、対応する決定的なリポジトリツールまたはテストが利用できる場合だけ、その結果を検証結果として記録する。利用できない項目は未実行と報告する。実際の再生は補助的な確認として行えるが、目視・聴取だけを検証済みの根拠にしない。

## ソース動画証拠

Vision/OCR出力はシーク用索引であり、画像証拠ではない。分析画像は必ず`batch-frame`、`precise-frame`、`contact-sheet`、または`frame-burst`でソース動画から生成する。

概要コンタクトシートは候補探索に使う。重要な主張は、密な時系列の`batch-frame`または`precise-frame`画像で再確認する。要求時刻と実際の取得時刻、ゲーム内時計の違いが見えるようにし、ラベルで関連UIを覆わない。

ゲーム領域は16:9でも録画内の位置とピクセル寸法が異なり得る。固定矩形を既定値にせず、各ジョブに対象録画の実測矩形を指定する。

## 標準コンタクトシート構成

具体的な配置JSONと使い方は[contact-sheet-layouts.md](contact-sheet-layouts.md)を正本とする。標準として固定するのは、10列×10行、6秒間隔の`overview` 5種類だけである。標準条件では[overview-contact-sheet-jobs.jsonl](overview-contact-sheet-jobs.jsonl)を変更せず使う。

overview以外のコンタクトシートに固定のPhase、Detail、列数、時間間隔、セル寸法を設けない。検証する主張を先に決め、overviewに定義されたROIの`source`を再利用または組み合わせて、必要な時刻範囲と密度の分析用コンタクトシートを自律的に設計・生成し、生成結果を読んで分析へ使う。注目する画面領域と時間範囲へ絞り、最終シート全体はセルを歪めず正方形または16:9に近い表示しやすい比率を推奨する。必要なら目的または時間帯で複数枚へ分割する。

複数overviewのROIを1セルへ組み合わせる場合は、元の`placements`配列を連結しない。各ROIに新しいセル内の重ならない`destination`を割り当て、動的ラベルは1つへ統合し、全配置を同じ`matchTimestamp`へ対応させる。ラベルで試合時計、ミニマップ、通知、味方状態、ターゲットホイールを覆わない。標準HUDと異なる場合だけソース矩形を再実測し、変更値と理由を分析メモへ記録する。

### 分析順序と確定証拠

選出形式、ロードアウト、リザルトから作成した前提コンテキストを先に読み、標準の読み順は次とする。

1. 5種類のoverviewを試合全体のサンプル索引として走査する。特定の接敵相手を探すときは`target-wheel-overview`を優先するが、6秒未満の接触は欠落し得るため網羅的な接敵検出には使わない。
2. 検証する主張と必要なROIを選ぶ。
3. overviewの`placements`を使って、候補場面の分析用コンタクトシートを必要な密度で作る。
4. 重要な主張はすべて、密な時系列の`batch-frame`または`precise-frame`原寸画像で再確認する。数字、個体識別、技の命中、同時死亡など縮小セルで確定できない事実には、追加の原寸確認を行う。

振り向きなど連続動作の成立時間を検証するときは、[frame-burst.md](frame-burst.md)に従い、候補区間を`frame-burst`で60連続フレームの連写として並べる。これはコンタクトシートではない。時間指定を細分した通常の`contact-sheet`で代用しない。

コンタクトシートだけで細部を断定しない。一方、単一フレームへ直ちに分解して時系列の関係を失わず、まず分析用コンタクトシートで試み、反応、出力を連続して読む。

## 事前イベント点候補生成

事前イベント点候補は重要イベントの確定結果ではなく、未分類のシーク索引である。候補の意味は必ずソース動画へ戻って判断する。候補生成の後に行うシーン境界、局所目標、敵反応、味方への伝播、因果関係の分析はこの契約に含めない。

対話前の分析では、次の候補生成を原則実行する。

1. `audio-peaks-v1`を試合全体へ実行し、完全なraw JSONを`_PokemonUniteAnalysis/matches/<match-id>/candidates/audio-peaks.json`へ`--output`で保存する。全`intervals`をそのまま候補にしない。
2. 対象録画で確定したUI領域ごとに`sample-frames`を2 fps、JPEG quality 0.95で実行し、同じ2 fpsで`detect-chroma-events-v1`を実行する。ファイル名は`frame-000001.jpg`のようにゼロ埋めし、辞書順と時系列を一致させる。
3. `event-detect-v1.input.schema.json`に従い、音声出力と領域名付き色差出力、空の`ocrCandidates`と`scheduledCandidates`を指定する。`event-detect-v1`を一度実行し、機械選択された`chroma:<region>`構成点をOCR対象索引にする。分位点、音声クラスタ、二次候補判定、統合をモデルが再計算しない。
4. 選択された各raw色差点の時刻を`t`とし、`t - 0.5`、`t`、`t + 0.5`秒を`precise-frame`で同じ領域の実寸JPEGとして元動画から再抽出する。試合範囲外の時刻は除き、各画像を`ocr-v1`へ渡す。3時刻の結果とconfidenceをすべて保持し、表示途中と判断できる文字列を無理に統合しない。`batch-frame`は近似シークにより複数の要求時刻が同じ実フレームへ吸着し得るため、この短時間OCR列には使わない。色差計算用の縮小JPEGをOCR入力にせず、OCR内部で候補を生成・選別させない。OCR失敗または空結果でも色差候補を除去しない。
5. OCR観測と確認済みの定刻イベントをmanifestへ追加し、`event-detect-v1`を再実行して`_PokemonUniteAnalysis/matches/<match-id>/candidates/events.json`へ保存する。この出力だけを後続の自由分析へ渡す。
6. `event-detect-v1`出力の全構成点と由来を保持する。由来は`audio`、`chroma:<region>`、`ocr:<region>`、`scheduled`であり、色差は領域内score、音声はscore、OCRは認識値とconfidenceを保持する。異なる領域のraw scoreを直接比較しない。

2 fpsでは、10分試合の各領域が約1200枚になる。領域を縮小したJPEG連番は色差測定用の一時索引であり、証拠画像ではない。色差出力の`requestedInmatch`が`t`なら、変化後の画像は通常`round(t * fps) + 1`番のJPEGに対応するが、OCRと最終確認には番号から画像を流用せず、`requestedInmatch`を使って元動画から再抽出する。

`event-detect-v1`はnearest-rank分位点、領域ごとの一次・二次色差選択、最初の点を起点とする5秒未満の音声固定幅クラスタ、2秒の二次候補被覆判定、隣接差2秒以下の推移的統合を決定論的に実行する。入力契約は`event-detect-v1.input.schema.json`、出力契約は`event-detect-v1.output.schema.json`で確認する。

16:9ゲーム領域での初期領域は次とする。値はゲーム領域の幅と高さに対する割合であり、実際のピクセル矩形へ比例変換してゲーム領域の左上オフセットを加える。UI配置が異なるモードではソース動画で領域を再確認する。

| 領域名 | 正規化矩形 `(x,y,width,height)` | 色差用scale |
|---|---:|---:|
| `event-banner` | `(26.35%,11.44%,49.02%,12.53%)` | `100x14` |
| `top-center-event` | `(31.86%,0%,36.76%,23.97%)` | `75x27` |
| `center-announcement` | `(30.64%,19.61%,42.89%,28.32%)` | `87x32` |

定刻候補は、対象モードと試合時間から確定できるものだけを追加する。10分の標準試合では試合相対480秒のラストスパートを`scheduled`として追加する。マップやモードで時刻が変わり得る野生ポケモン出現を一般知識から補完しない。

入力メディア不存在、必要なCLI機能不存在、デコード不能、Vision利用不能など、技術的に実行できない場合だけ該当種別を省略できる。その場合は、未取得種別、実行コマンド、失敗理由を分析成果物へ記録する。

上記の分位点、音声クラスタ幅、統合幅は`event-detect-v1`の固定契約である。録画条件の違いで候補が明らかに過多または過少でも、モデルが値を変更せずIssueとして記録する。OCR時刻列を変更した場合は変更値と理由を分析メモへ記録する。

OCR結果に疑問がある場合は、`ocr-v1`出力の入力絶対パスと`source`を使って同じJPEG領域を確認する。OCR文字列だけで出来事を確定せず、ソース動画画像を再確認する。`audio-peaks-v1`と`detect-chroma-events-v1`もイベントを分類しない。

`audio-peaks-v1`は`--record-spec`と必要なら正の`--gain`を受け、試合全体を解析する。`--output`を指定しても完全なJSONをstdoutへ出力する既存契約は変わらない。`inmatch-start`や`duration`は指定しない。format v2の`main.fragmented.mp4`内の音声トラックを使い、音声トラックなし、format v1、デコード不能はエラーとして記録する。出力契約は`audio-peaks-v1.output.schema.json`で確認する。

分析メモには`audio-peaks-v1`を`成功（peaksあり）`、`成功（0件）`、`失敗`、`未実行`のいずれかで記録し、成功時はraw JSONの保存先も記録する。raw JSONを保存しただけでは後段へ引き渡し済みとせず、候補選択・統合へ渡したかを別に記録する。失敗または未実行では、実行予定または実行したコマンドと理由を残す。

`detect-chroma-events-v1`はJPEGディレクトリ、同じ`--fps`、JSON出力先をオプションで受ける。出力は全隣接ペアの無選別測定であり、契約は`chroma-events-v1.output.schema.json`で確認する。

試合全体の概要コンタクトシートは目視探索索引であり、上記の機械生成候補に含めない。`scan-result-v1`も事前基礎情報と最終結果の復元であり、候補生成に含めない。

## リザルト

`scan-result-v1`には、Swift CLIで生成し、ゲーム画面全体が正しく含まれると確認した静止画を渡す。

- 総合結果には`--type summary`を使う。
- バトルデータには`--type battle-data`を使う。
- レイアウトや切り出しが不正な画像の認識値を採用しない。
- Apple Visionを実行できない場合は未実行として報告する。
- 出力JSONと元のソース動画画像を対応づけて保存する。
- 出力契約は`scan-result-v1.output.schema.json`で確認する。
- `--output`は既存ファイルを`--force`なしで原子的に置換するため、新規パスを使うか、置換対象を確認してから実行する。

## 選出形式とロードアウト

選出形式は、Swift CLIで生成した選出開始前からVS画面までの画像列で判断する。

- ban、交互ピック、明示的な選択ターンが見える場合は`draft`とする。
- 味方が同時に選択し、banや交互ターンが見えない場合は`blind`とする。
- 区別に必要な映像がない場合は`unknown`とする。
- 最終準備、ルート、VS画面のレイアウトだけで選出形式を決めない。

持ち物、バトルアイテム、宣言ルートは専用コマンドで読み取る。draftかblindかは認識器に推測させず、上の映像証拠で形式を確定してから対応するコマンドを選ぶ。`--record-spec`と試合相対の安定フレーム時刻を指定し、標準出力先は`<recording>/_PokemonUniteAnalysis/matches/match-<NN>/`とする。認識候補が空なら値は`—`または`?`とし、一般的なビルドから補完しない。

## 前提コンテキスト

候補生成とハイライト探索の前に、選出形式、ロードアウト、リザルトの取得結果を1つの前提コンテキストとして整理する。操作ポケモン、味方と相手の構成、宣言ルート、持ち物、バトルアイテム、勝敗、チームスコア、KO、アシスト、ダメージなど、取得できた値と対応するソース成果物を記録する。

取得できなかった項目も省略せず、選出形式だけは`unknown`、取得不能な値は`—`、不確実な値は`?`として、未実行または失敗した認識種別、実行予定または実行したコマンド、失敗理由を記録する。一般的な構成や最終結果から欠損値を補完しない。この前提コンテキストを候補生成、overview走査、局所シーン分析、ハイライト作成の各段階へ明示的に引き渡す。

最終結果から得た後知恵と、各シーン時点で盤面から利用可能だった情報を区別する。前提コンテキストは解釈の再作業を避けるための入力であり、当時のプレイヤーが結果や後続イベントを知っていた証拠として使わない。

## 録画調査の順序

1. ユーザーが指定した録画と対象試合を確認する。
2. `.finalized`、`Info.plist`、`record-spec.json`を確認し、録画形式、試合境界、ゲーム画面矩形を確定する。specがなければ根拠を集めて候補を復元・記録する。
3. `run_unite_analysis`へ`["--help"]`を渡してCLIを確認する。
4. 既存の`_PokemonUniteAnalysis`成果物を調べ、現行入力と一致するものを再利用する。
5. 選出開始前からVS画面までの映像で`draft`、`blind`、`unknown`を判定する。認識器に形式を推測させない。
6. `draft`なら`recognize-draft-loadout-v1`、`blind`なら`recognize-blind-loadout-v1`を実行する。`unknown`または技術的失敗なら、未取得の認識種別、コマンド、理由を記録する。
7. 結果画面とバトルデータ画面の安定フレームを抽出し、`scan-result-v1`を実行する。取得不能または失敗した種類、コマンド、理由も記録する。
8. 取得値と未取得理由を前提コンテキストへ整理し、以降の全分析入力として保存する。
9. 事前イベント点候補生成の実行契約を実行し、候補または未取得理由を前提コンテキストとともに保存する。
10. `batch-frame`または`contact-sheet`で、候補生成とは別に試合全体の概要を作る。
11. 前提コンテキストと候補から局所目標と出力を自由に分析し、密なソース動画画像で検証する。
12. KO、デス、得点、オブジェクト、離脱、中断、交換、強制反応、進入路、味方の合流を確認する。
13. 選んだ各ハイライト候補について、シーンの試みから出力までを境界にした`extract-clip`を生成する。失敗または提示不能なら候補ごとに理由を記録する。
14. クリップを提示できる候補では動画を主成果物、ソース動画画像を補助証拠として初回対話へ提示する。失敗または提示不能な候補では不足理由を明示し、ソース動画画像をその候補のfallback主成果物として提示する。目視事実、時系列推論、分析仮説、ユーザー説明を区別して対話へ入る。

マップ状態を読む場合は、同じソースフレームのミニマップ、味方状態、ゲーム内時計を併せて確認する。味方の分布と生存・復帰状態を補間せず記録する。
