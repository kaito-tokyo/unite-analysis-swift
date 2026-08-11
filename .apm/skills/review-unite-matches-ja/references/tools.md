# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

# SPDX-License-Identifier: Apache-2.0

# 証拠不足から選ぶ調査ツール

この文書は、不明な事実から次の調査へ進むための手順である。正確な引数、入出力、制約は実行中の`unite-analysis-swift help <subcommand>`を正本とし、実行方法と共通契約は[recording-workflow.md](recording-workflow.md)に従う。

## 録画内の試合区間を検出する

- **使うツール**: `detect-matches-v1`。LDTX Visionメタデータには依存せず、recording format v2の主映像を直接順次デコードして試合タイマーをOCRする。
- **レイアウト**: `--layout`には同梱の[ja.20260811.match.timer.json](ja.20260811.match.timer.json)を指定する。レイアウトIDとコマンドのバージョンは別の契約であり、エンジン選択をJSON内で行わない。
- **再現例**: `.ldtxrecord`ルートから`unite-analysis-swift detect-matches-v1 --input . --layout .apm/skills/review-unite-matches-ja/references/ja.20260811.match.timer.json`を実行する。このコマンドは試合別`record-spec.json`を作る前に使うため、`--record-spec`を指定しない。
- **限界**: 標準10分試合だけを候補化する。降参および特殊モードの終了は推測しない。

## 長い録画から候補時刻を探す

- **症状**: 関連場面の時刻が不明で、試合全体を通して候補を探す必要がある。
- **使うツール**: `contact-sheet`。広い時間範囲を一覧し、詳細調査の候補を絞る。
- **再現例**: [contact-sheet-layouts.md](contact-sheet-layouts.md)の完成済みoverview JSONLを`_PokemonUniteAnalysis/matches/match-01/overview-jobs.jsonl`に用意し、`unite-analysis-swift contact-sheet --record-spec _PokemonUniteMatches/match-01/record-spec.json _PokemonUniteAnalysis/matches/match-01/overview-jobs.jsonl`を実行する。出力画像は各ジョブの`output`先に保存する。
- **解釈と提示**: セルは事実の確定ではなくシーク用索引として読み、候補時刻と注目したサインを記録する。
- **限界**: 命中、個体識別、数値、1秒未満の順序を縮小セルで断定しない。時間が既知の局所場面に全試合overviewを作らない。
- **次の調査**: 動作順序は`frame-burst`、場面の前後は`extract-clip`、細部は`precise-frame`で確かめる。

## 命中、回避、中断、動作順序を確かめる

- **症状**: 誰が技を使い誰に当たったか、攻撃が回避・中断されたか、重なる動作のどれが先かを通常の静止画では確定できない。
- **使うツール**: `frame-burst`。指定時刻以降のソースフレームを連続デコードし、近似シークによる順序の欠落を避ける。
- **再現例**: [frame-burst.md](frame-burst.md)に従って`frame-burst-jobs.jsonl`を作り、`unite-analysis-swift frame-burst --record-spec _PokemonUniteMatches/match-01/record-spec.json _PokemonUniteAnalysis/matches/match-01/frame-burst-jobs.jsonl`を実行する。出力は`_PokemonUniteAnalysis/matches/match-01/frame-bursts/`以下に保存する。
- **解釈と提示**: 左から右、上から下へ読み、使用者、発生、接触、リアクションの順を追う。セルの細部を再確認するときは、同じ`matchTimestamp`、`frameCount`、`decimate`を保ったまま、対象を含む狭い`source`と大きな`cellWidth`で別の`frame-burst`を生成する。同じデコード済みフレーム列の対応するセルを拡大して確かめる。
- **限界**: MCP結果と連写画像はセルごとのPTSを示さない。選択セルの時刻を推定して`precise-frame`で抽出し直さない。候補時刻の発見や、数秒以上の配置・追撃・変換の説明に使わず、表示の間引きがデコード範囲を広げると解釈しない。
- **次の調査**: 対話でシーケンス全体を共有する必要があれば`extract-clip`、HUDの細部は`precise-frame`を使う。

## 場面の前後やオブジェクト戦全体を共有する

- **症状**: 接敵前の配置、離脱機会、味方の追撃、戦闘後の変換が欠けている。または静止画列ではユーザーに動きを伝えられない。
- **使うツール**: `extract-clip`。連続した映像と、ソースに音声トラックがある場合はその音声をMP4で提示する。初回のハイライト対話では、選んだ候補ごとに必ず動画を主成果物として提示する。
- **再現例**: `unite-analysis-swift extract-clip --record-spec _PokemonUniteMatches/match-01/record-spec.json --start 260 --end 275 --output _PokemonUniteAnalysis/matches/match-01/clips/objective-fight.mp4`。
- **解釈と提示**: 試みの開始、敵と味方の反応、出力までを含む範囲にする。MCPが返す`video/mp4`のresource linkをチャットへ提示し、再生できたことを確認してから見るべき点を共有する。ソースに音声トラックがない場合は、音声は未取得ではなく存在しないと報告する。
- **限界**: チャットがローカルメディア添付をサポートしない場合は、MP4を提示済みとしない。候補ごとに提示不能と報告し、その候補ではソース動画画像をfallbackとして使う。パススルーは指定開始時刻に新しいキーフレームを作らず、近接する同期サンプルからデコードが始まる場合がある。フレーム単位の独立デコードが必要な証拠に使わず、詳細な動作順序も動画の印象だけで断定しない。
- **次の調査**: 短時間の順序は`frame-burst`、数値や個体識別は`precise-frame`で補強する。

## 縮小されたUIや個体を原寸で確かめる

- **症状**: コンタクトシートでHUD、タイマー、クールダウン、プレイヤー名、命中表示を読めない。
- **使うツール**: `precise-frame`。指定時刻以降の最初のデコード済みフレームを、明示したソース矩形の原寸で得る。
- **再現例**: 対象録画の`record-spec.json`にある`game-screen`コンポーネントから`x`、`y`、`width`、`height`を読み、`unite-analysis-swift precise-frame --record-spec _PokemonUniteMatches/match-01/record-spec.json --match-timestamp 265.4 --x <game-screen-x> --y <game-screen-y> --width <game-screen-width> --height <game-screen-height> --output _PokemonUniteAnalysis/matches/match-01/frames/265.4.jpg`を実行する。山括弧内は必ず実測値で置き換える。
- **解釈と提示**: MCPが返す出力パスのフルサイズ画像を確認し、主張に必要な画像をチャットやレポートで提示する。実行経路が要求PTSと実デコードPTSを返す場合だけ、その差も確認する。
- **限界**: MCPの`precise-frame`結果は通常、PTS診断を含まず出力パスだけを返す。その場合は要求時刻とデコード時刻が一致したと報告しない。1枚で動作順序や因果関係を確定せず、時刻が未知のまま総当たりに使わない。
- **次の調査**: 前後の順序は`frame-burst`、シーン全体は`extract-clip`で確かめる。

## リザルトまたはロードアウトを復元する

- **症状**: 結果行、バトルデータ、参加者、持ち物、バトルアイテム、宣言ルートが欠けている。
- **使うツール**: 結果画面は`scan-result-v1`、draftの最終準備画面とVS画面は`recognize-draft-loadout-v1`、blind選択画面は`recognize-blind-loadout-v1`を使う。
- **再現例**: 先に対象画面を`_PokemonUniteAnalysis/matches/match-01/frames/result-summary.jpg`へフルサイズで抽出し、OCR設定を`_PokemonUniteAnalysis/matches/match-01/ocr-options.json`へ保存する。`unite-analysis-swift scan-result-v1 _PokemonUniteAnalysis/matches/match-01/frames/result-summary.jpg --type summary --ocr-options _PokemonUniteAnalysis/matches/match-01/ocr-options.json --output _PokemonUniteAnalysis/matches/match-01/result-summary.json`を実行する。ロードアウトは必ず各コマンドの`--help`から現在の必須画像と引数を確認する。
- **解釈と提示**: `scan-result-v1`では出力JSONのconfidence、warnings、raw OCRを保持し、低confidenceの名前は入力画像で再確認する。ロードアウト認識では出力JSONの`score`、`candidates`、ルート測定値を保持し、選択候補とデコード済み入力フレームを対応させて再確認する。
- **限界**: 縮小セル、余白を含む画像、異なる画面種別に`scan-result-v1`を使わない。認識結果から録画時刻や操作プレイヤーを推測しない。
- **次の調査**: 欠けた画面を`contact-sheet`で探し、`precise-frame`で抽出し直す。

## 候補発見から検証・提示へ進む例

1. `contact-sheet`のoverviewでユナイトわざの候補時刻を見つける。セルだけで使用者や命中相手を断定しない。
2. 候補の直前から`frame-burst`を生成し、使用者、対象、発生、命中または回避の順を確かめる。
3. 局所のセルと必要な`precise-frame`でHUDや個体識別を再確認する。
4. 選んだ各候補について、試みの開始から反応と出力の確定までをシーン境界として`extract-clip`でMP4を作る。初回対話ではMP4を主成果物として提示し、静止画は特定瞬間の補助証拠にする。
