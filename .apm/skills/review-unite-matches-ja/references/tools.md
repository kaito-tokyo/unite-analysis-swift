# SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

# SPDX-License-Identifier: Apache-2.0

# 証拠不足から選ぶ調査ツール

この文書は、不明な事実から次の調査へ進むための手順である。正確な引数、入出力、制約は実行中の`unite-analysis-swift help <subcommand>`を正本とし、実行方法と共通契約は[recording-workflow.md](recording-workflow.md)に従う。

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
- **使うツール**: `extract-clip`。連続した映像と、ソースに音声トラックがある場合はその音声をMP4で提示する。静止画で関連するプレイシーケンスを伝えられないときは、必ず動画を提示する。
- **再現例**: `unite-analysis-swift extract-clip --record-spec _PokemonUniteMatches/match-01/record-spec.json --start 260 --end 275 --output _PokemonUniteAnalysis/matches/match-01/clips/objective-fight.mp4`。
- **解釈と提示**: 試みの開始、敵と味方の反応、出力までを含む範囲にする。MCPが返した絶対パスを、チャットクライアントがサポートするローカルメディア添付として提示し、表示できたことを確認してから見るべき点を共有する。ソースに音声トラックがない場合は、音声は未取得ではなく存在しないと報告する。
- **限界**: チャットがローカルメディア添付をサポートしない場合は、MP4を提示済みとしない。提示不能と報告し、静止画から同じシーケンスを推測しない。パススルーは指定開始時刻に新しいキーフレームを作らない。フレーム単位の独立デコードが必要な証拠に使わず、詳細な動作順序も動画の印象だけで断定しない。
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
- **使うツール**: 結果画面は`scan-result`、draftの最終準備画面とVS画面は`recognize-draft-loadout`、blind選択画面は`recognize-blind-loadout`を使う。
- **再現例**: 先に対象画面を`_PokemonUniteAnalysis/matches/match-01/frames/result-summary.jpg`へフルサイズで抽出し、OCR設定を`_PokemonUniteAnalysis/matches/match-01/ocr-options.json`へ保存する。`unite-analysis-swift scan-result _PokemonUniteAnalysis/matches/match-01/frames/result-summary.jpg --type summary --ocr-options _PokemonUniteAnalysis/matches/match-01/ocr-options.json --output _PokemonUniteAnalysis/matches/match-01/result-summary.json`を実行する。ロードアウトは必ず各コマンドの`--help`から現在の必須画像と引数を確認する。
- **解釈と提示**: `scan-result`では出力JSONのconfidence、warnings、raw OCRを保持し、低confidenceの名前は入力画像で再確認する。ロードアウト認識では出力JSONの`score`、`candidates`、ルート測定値を保持し、選択候補とデコード済み入力フレームを対応させて再確認する。
- **限界**: 縮小セル、余白を含む画像、異なる画面種別に`scan-result`を使わない。認識結果から録画時刻や操作プレイヤーを推測しない。
- **次の調査**: 欠けた画面を`contact-sheet`で探し、`precise-frame`で抽出し直す。

## 候補発見から検証・提示へ進む例

1. `contact-sheet`のoverviewでユナイトわざの候補時刻を見つける。セルだけで使用者や命中相手を断定しない。
2. 候補の直前から`frame-burst`を生成し、使用者、対象、発生、命中または回避の順を確かめる。
3. 局所のセルと必要な`precise-frame`でHUDや個体識別を再確認する。
4. 前後の配置、味方の追撃、戦闘後の変換を対話するなら`extract-clip`でMP4を作る。静止画では伝わらない連続動作を、ユーザーに静止画から推理させない。
