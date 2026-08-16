# フレーム連写

フレーム連写はコンタクトシートとは別の証拠形式とする。振り向き、照準修正、技の発生、命中確認など1秒未満の動作は、`frame-burst`で連続するソースフレームを並べる。既存`contact-sheet`へ細かい時刻列を渡す方法は近似シークで同一フレームへ吸着し得るため、この用途には使わない。

1行を1つの連写区間とするJSONLを作る。複数の候補区間は同じファイルへ並べ、一意な`jobId`で応答と対応付ける。

```json
{"jobId":"absol-265","matchTimestamp":265.0,"source":{"x":0,"y":0,"width":1632,"height":918},"cellWidth":320,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/absol-265.jpg"}
{"jobId":"absol-499.2","matchTimestamp":499.2,"source":{"x":0,"y":0,"width":1632,"height":918},"cellWidth":320,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/absol-499.2.jpg"}
```

```sh
unite-analysis-swift frame-burst \
  --record-spec _PokemonUniteMatches/match-01/record-spec.json \
  _PokemonUniteAnalysis/matches/match-01/frame-burst-jobs.jsonl
```

JSONLは`_PokemonUniteAnalysis/matches/match-01/frame-burst-jobs.jsonl`へ保存する。各ジョブは、指定時刻以降の最初のソースフレームから60枚を連続デコードし、全フレームを5列×12行へ固定配置する。間引きは行わず、各セルにはゼロ始まりのソースインデックスと実際の試合相対時刻が必ず表示される。`cellWidth`から`source`の縦横比を保ってセル高が決まる。

最初のセルは指定時刻以降で最初にデコードされたフレームであり、左から右、上から下へ読む。注目対象が小さい場合は全画面ではなくROIを指定する。全stdout応答の`ok`を検査し、成功結果の`decodedFrameCount`、`firstPresentationTimestamp`、`lastPresentationTimestamp`、`coveredDuration`を確認する。録画末尾などで60枚を取得できないジョブは失敗として扱う。

## 候補探索と同期detailの手順

長い場面はoverview contact sheetで候補時刻`T`を絞るか、`extract-clip`で連続再生する。接触候補`I`の直前から、広域contextとdetailを同じ`matchTimestamp`で生成する。

```jsonl
{"jobId":"impact-context","matchTimestamp":I_MINUS_0_25,"source":{"x":0,"y":0,"width":1632,"height":918},"cellWidth":480,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/impact-context.jpg"}
{"jobId":"impact-detail","matchTimestamp":I_MINUS_0_25,"source":{"x":DETAIL_X,"y":DETAIL_Y,"width":DETAIL_WIDTH,"height":DETAIL_HEIGHT},"cellWidth":480,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/impact-detail.jpg"}
```

`I_MINUS_0_25`と`DETAIL_*`は観測した候補へ置換する。contextとdetailは同一の`matchTimestamp`から固定60フレームをデコードするため、ラベルのソースインデックスと実時刻でセルを同期できる。1セルを分割して両方を縮小するより、独立した2枚に同じラベルを付ける方が広域の関係とHUD・対象の細部をそれぞれ判読しやすい。

contextで使用者と対象の順序、detailで命中、回避、中断、移動、妨害、攻撃の重なりなどの機能的効果を確認する。見えない技名を推測で確定せず、必要なら開始時刻とcropを狭めた別の連写を作る。候補発見はcontact sheet、サブ秒の証拠確認は`frame-burst`、プレイヤーとの場面共有はシーン境界に沿った`extract-clip`を使い、連写画像を動画の代用にしない。
