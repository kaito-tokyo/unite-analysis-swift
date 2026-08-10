# フレーム連写

フレーム連写はコンタクトシートとは別の証拠形式とする。振り向き、照準修正、技の発生、命中確認など1秒未満の動作は、`frame-burst`で連続するソースフレームを並べる。既存`contact-sheet`へ細かい時刻列を渡す方法は近似シークで同一フレームへ吸着し得るため、この用途には使わない。

1行を1つの連写区間とするJSONLを作る。複数の候補区間は同じファイルへ並べ、一意な`jobId`で応答と対応付ける。

```json
{"jobId":"absol-265","matchTimestamp":265.0,"source":{"x":0,"y":0,"width":1632,"height":918},"frameCount":60,"decimate":2,"columns":8,"cellWidth":320,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/absol-265.jpg"}
{"jobId":"absol-499.2","matchTimestamp":499.2,"source":{"x":0,"y":0,"width":1632,"height":918},"frameCount":60,"decimate":2,"columns":8,"cellWidth":320,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/absol-499.2.jpg"}
```

```sh
unite-analysis-swift frame-burst \
  --record-spec _PokemonUniteMatches/match-01/record-spec.json \
  _PokemonUniteAnalysis/matches/match-01/frame-burst-jobs.jsonl
```

JSONLは`_PokemonUniteAnalysis/matches/match-01/frame-burst-jobs.jsonl`へ保存する。`frameCount`は連続デコードするソースフレーム数であり、連写が覆う時間範囲を決める。値は1から600までとする。任意の`decimate: N`はソースインデックス`0, N, 2N, ...`だけを表示し、時間範囲を変えずにセルを間引く。省略時は`1`とする。標準的な1秒前後の分析ジョブでは`frameCount`を60、`decimate`を2、`columns`を8、`cellWidth`を320から始める。`labelFrames: true`を指定すると、各セルへ保持前のソースインデックスと実際の試合相対時刻が表示される。動作順序を検証する成果物では必ず有効にする。

最初のセルは指定時刻以降で最初にデコードされたフレームであり、左から右、上から下へ読む。注目対象が小さい場合は全画面ではなくROIを指定する。全stdout応答の`ok`を検査し、開始・終了PTSをstderrで確認して、録画の実フレームレートから連写が覆う実時間を判断する。

## 可変密度と同期detailの手順

overview contact sheetで候補時刻`T`を見つけたら、まず`T - 1.0`秒から広域を粗く残す。次に粗い連写で見つけた接触候補`I`の約0.25秒前から、全フレームを残すcontextとdetailを同じ条件で生成する。

```jsonl
{"jobId":"candidate-coarse","matchTimestamp":T_MINUS_1_0,"source":{"x":0,"y":0,"width":1632,"height":918},"frameCount":120,"decimate":6,"labelFrames":true,"columns":5,"cellWidth":480,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/candidate-coarse.jpg"}
{"jobId":"impact-context-dense","matchTimestamp":I_MINUS_0_25,"source":{"x":0,"y":0,"width":1632,"height":918},"frameCount":30,"decimate":1,"labelFrames":true,"columns":5,"cellWidth":480,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/impact-context-dense.jpg"}
{"jobId":"impact-detail-dense","matchTimestamp":I_MINUS_0_25,"source":{"x":DETAIL_X,"y":DETAIL_Y,"width":DETAIL_WIDTH,"height":DETAIL_HEIGHT},"frameCount":30,"decimate":1,"labelFrames":true,"columns":5,"cellWidth":480,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/impact-detail-dense.jpg"}
```

`T_MINUS_1_0`、`I_MINUS_0_25`、`DETAIL_*`は観測した候補へ置換する。dense contextとdense detailは同一の`matchTimestamp`、`frameCount`、`decimate`を使うため、ラベルのソースインデックスと実時刻でセルを同期できる。1セルを分割して両方を縮小するより、独立した2枚に同じラベルを付ける方が広域の関係とHUD・対象の細部をそれぞれ判読しやすい。

粗い連写で発生・接触・反応の範囲を探し、dense contextで使用者と対象の順序、dense detailで命中、回避、中断、移動、妨害、攻撃の重なりなどの機能的効果を確認する。見えない技名を推測で確定せず、必要なら開始時刻とcropを狭めた2回目のdense連写を作る。候補発見はcontact sheet、サブ秒の証拠確認は`frame-burst`、プレイヤーとの場面共有はシーン境界に沿った`extract-clip`を使い、連写画像を動画の代用にしない。
