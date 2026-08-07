# 保存と公開

正本レポートの作成・移行、Obsidian同期、Google Drive公開、公開分類体系の変更を行う場合にだけ、この文書を最後まで読む。

## 試合単位の保存

すべての録画に複数試合が含まれる可能性を考慮する。録画内の順番で`match-01`、`match-02`のように番号を付ける。1レポートにつき1試合とし、フォルダ、メタデータ、参照画像、索引、Obsidian参照、Google Docsタイトルで同じ試合キーを使う。

- 正本レポート: `<recording>/_PokemonUniteAnalysis/matches/match-<NN>/review.md`
- 録画索引: `<recording>/_PokemonUniteAnalysis/recording-index.md`
- 機械生成下書き: `<recording>/_PokemonUniteAnalysis/matches/match-<NN>/analysis-draft.md`
- 公開状態: `<recording>/_PokemonUniteAnalysis/matches/match-<NN>/publication.json`

録画固有の成果物は、アンダースコアで始まる分析領域だけへ保存する。それ以外のLDTX管理領域を変更しない。

`recording-index.md`には、検出した各候補、録画時刻上の境界、状態値（`unreviewed`、`completed`、`incomplete`、`result-only`）、レポートへのリンクを記録する。後から試合を追加するときも`match-01`を移動しない。

旧形式の`_PokemonUniteAnalysis/review.md`は移行元として扱う。本文と直接参照している画像を`matches/match-01/`へ移し、リンクを更新し、不要になった正本の重複を取り除く。

## 保存レイヤー

各レイヤーは目的が異なり、内容が完全一致しない場合がある。

| レイヤー | 目的 |
|---|---|
| 録画内の`_PokemonUniteAnalysis/` | 録画に直接基づく正本証拠と試合単位の正本レポート |
| Obsidian MatchReports | 完成した試合単位レポートと直接参照画像のミラー |
| Obsidian StrategyBooks | ユーザー固有の作戦、判断基準、考え方 |
| Google Drive | 検索と迅速な参照のためのコピー |

事実誤認は、その事実を保持するすべてのレイヤーで訂正する。レイヤーを同一化するためだけに、派生した解釈を録画内の正本へ逆流させない。

## Obsidianの保存先

MatchReportsとStrategyBooksのルートディレクトリを別々に保持する。片方の設定をもう片方の代用にしない。

Obsidianへの操作を求められた場合にだけ、必要な保存先を解決する。今回の依頼でパスが明示されていなければ、対応する`config get`を実行する。値が設定されていればそれを使い、未設定ならユーザーへ値を尋ねてから`config set`する。Obsidian操作と無関係な依頼で設定を要求しない。

MatchReportsのルートディレクトリは次の優先順位で決める。

1. ユーザーが今回の依頼で明示したMatchReportsパス
2. `unite-analysis-swift config get obsidian-match-reports-root`の出力

StrategyBooksのルートディレクトリは次の優先順位で決める。

1. ユーザーが今回の依頼で明示したStrategyBooksパス
2. `unite-analysis-swift config get obsidian-strategy-books-root`の出力

必要な保存先がいずれも指定されていない場合は、書き込みを始める前にユーザーへ確認する。過去の会話や推測したVault位置を暗黙に使わない。

未設定時には次を既定の候補として提案する。

- MatchReports: `~/Obsidian/PokemonUnite/MatchReports`
- StrategyBooks: `~/Obsidian/PokemonUnite/StrategyBooks`

候補を無断で採用しない。候補が存在しない場合は、パスと作成されるディレクトリを示し、「作成して恒久設定へ保存する」ことへの同意を得る。ユーザーが同意した場合だけディレクトリを作成し、対応する`config set`を実行する。ユーザーが別の値を指定した場合は、その値を使う。

恒久設定はSwift CLIで行う。

```sh
unite-analysis-swift config set obsidian-match-reports-root "/path/to/Obsidian/PokemonUnite/MatchReports"
unite-analysis-swift config set obsidian-strategy-books-root "/path/to/Obsidian/PokemonUnite/StrategyBooks"
```

設定の確認と解除には、それぞれのキーで`config get`と`config unset`を使う。設定ファイルの場所の確認には`unite-analysis-swift config path`を使う。CLIが返した設定エラーを未設定として扱わず、ユーザーへ知らせる。設定ファイルを直接編集しない。

`config get`が対象キーの未登録を返した場合だけ、設定値を尋ねる手順へ進む。不正な設定ファイル、読み取り失敗、CLIの欠落、その他のエラーは未登録と同一視せず、内容をユーザーへ知らせる。`config set`が成功した後に`config get`で読み直し、選択したパスが保存されたことを確認する。

`~`をホームディレクトリとして展開し、シンボリックリンクを解決する。解決した各ルートが既存のディレクトリであることを確認し、保存先を連結した結果が該当ルート配下に収まることを確認してから書き込む。設定されたルートが存在しない場合は自動作成せず、ユーザーへ確認する。明示された保存処理では、その配下に必要なディレクトリを作成してよい。

## Obsidian MatchReports

明示的に求められた場合だけ同期する。各正本レポートをMatchReportsルート配下の`<taxonomy-path>/<recording-id>-match-<NN>/<recording-id>-match-<NN>.md`としてミラーする。フォルダ、試合ディレクトリ、Markdown、`_assets`はこの規則から変更せず、日本語名や任意名へ置き換えない。

確認済みのバトルモード、シーズン、マップ形式、特殊形式から、ObsidianとGoogle Driveで共有する`taxonomyPath`を毎回算出する。`publication.json`に保存された公開先から分類を逆算しない。安定した分類パスは次のとおりとする。

- `Ranked/Season-<number>-<map-format>`
- `Casual/Standard-<map-format>`
- `Casual/Special-<special-format>`
- `Quick`
- `Solo-Challenge`
- `Custom/<format>`
- `Excluded/<publication-status>`

直接参照している画像だけを隣接する`_assets/`へコピーし、リンクを書き換える。代表的な概要コンタクトシート、解釈を実質的に支える追加シート、ハイライト画像、結果証拠が対象となる。動画、生の分析出力、大量の探索用コンタクトシートはコピーしない。無関係なユーザー作成ノートを維持する。

コピー元とミラーの対象数が一致すること、すべての相対リンクが解決すること、旧配置が残っていないこと、保存先が重複していないことを確認する。

`publication.json`は`https://kaito-tokyo.github.io/unite-analysis-swift/publication.schema.json`を正本Schemaとし、`$schema`へこのURL、`schemaVersion`へ`1`を記録する。正確なschemaは`unite-analysis-swift schema publication.schema.json`で単一バイナリから取得する。リポジトリ内の原本は`docs/publication.schema.json`とする。MatchReportsとGoogle Driveについて、最後に同期した相対パス、同期時刻、同期元レポートの`Report-Updated-At`を記録する。Google Driveでは文書IDと検証時刻も記録する。

記録済みの相対パスは分類の正本には使わない。再同期時には現在確認できる試合メタデータから`taxonomyPath`を算出し直す。算出した保存先が`lastRelativePath`と異なる場合は、同期成功後に旧保存先を取り除き、重複がないことを確認してから新しい相対パスを記録する。

`lastRelativePath`は対応する設定ルートからの相対パスとし、絶対パス、`~`、`.`、`..`を含めない。同期または公開と検証が成功した後にだけ、`publication.json`を原子的に更新する。失敗した試行で、最後に成功した状態を上書きしない。StrategyBooksは独立した保存先であり、`publication.json`へ記録しない。

## Obsidian StrategyBooks

明示的に求められた場合だけ作成または更新する。ユーザー固有の作戦、状況ごとの判断基準、本人が説明した意図や考え方をStrategyBooksルートへ保存する。MatchReportsとは完全に独立した保存先として扱い、相互リンク、同期、参照関係を作らない。

StrategyBooks配下の構成や既存ファイルの扱いに固定規則を設けない。エージェントが新しいファイルを作成する場合だけ、内容を後から検索、識別、参照しやすい具体的で安定した名前を選ぶ。日本語名を使ってよい。`メモ`、`新規`、日付だけの名前など、内容を識別できない名前は避ける。

## Google Docs公開

明示的に求められた場合だけ公開する。ローカルMarkdownを正本とし、Google Driveコネクタを使う。タイトル、節の順番、表、画像、正確な`Report-Created-At`、ハイライト索引、コンタクトシートのキャプション、元の画像成果物を維持する。

手動改ページを入れず、ページ分けなし形式を使う。PDF書き出しは別のページ付きレンダリングとして扱う。

バトルモードと形式で整理する。Obsidianと同じ規則で算出した`taxonomyPath`の末尾に`document`を加え、Google Driveの公開先を`<taxonomyPath>/document`とする。ランク公開には確認済みのシーズンとマップ形式が必要である。例は`Ranked/Season-38-Groudon/document`とする。推測した分類や一時フォルダへ公開しない。

カジュアルの標準形式と特殊形式には、それぞれ別の安定フォルダを使う。クイックとソロチャレンジは大まかな配置でもよいが、分析品質は変えない。

代表的なコンタクトシートは、説明本文で使うハイライト画像とは分け、レポート末尾の分析証拠節へ置く。読者が拡大できるようページ分けなし形式を維持し、プレビュー画面やチャット画面のスクリーンショットで代用しない。

作成・更新後はコネクタの結果を読み直し、文書ID、親パス、Google Docs形式、冒頭と末尾の代表的な内容、表、本文内ハイライト画像、コンタクトシートのキャプション、意図したすべての画像を確認する。アップロード開始だけで成功と報告しない。

Asia/Tokyoの各日で最初に大きく更新した公開レポートでは、詳しいワークフロー健全性確認を行う。PDFを書き出し、代表ページと境界、見出し、表、画像、内容を確認し、`Daily-PDF-Validation-At`を記録する。公開処理を変更した場合や異常があった場合も繰り返す。

既存のDriveコピーを再公開する前に、ユーザーへ確認する。

## ランクシーズン台帳

ランクレポートを分類・公開する前に`ranked-season-registry.md`と`ranked-seasons.json`を読む。バトルモードとマップ形式を分離する。試合日時が台帳の期間に一致しない場合や、シーズンまたは形式を確定できない場合はユーザーへ確認する。
