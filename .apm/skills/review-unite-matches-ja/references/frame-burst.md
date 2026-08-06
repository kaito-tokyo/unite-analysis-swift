<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# フレーム連写

フレーム連写はコンタクトシートとは別の証拠形式とする。振り向き、照準修正、技の発生、命中確認など1秒未満の動作は、`frame-burst`で連続するソースフレームを並べる。既存`contact-sheet`へ細かい時刻列を渡す方法は近似シークで同一フレームへ吸着し得るため、この用途には使わない。

1行を1つの連写区間とするJSONLを作る。複数の候補区間は同じファイルへ並べ、一意な`jobId`で応答と対応付ける。

```json
{"jobId":"absol-265","matchTimestamp":265.0,"source":{"x":0,"y":0,"width":1632,"height":918},"frameCount":60,"decimate":2,"columns":8,"cellWidth":320,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/absol-265.jpg"}
{"jobId":"absol-499.2","matchTimestamp":499.2,"source":{"x":0,"y":0,"width":1632,"height":918},"frameCount":60,"decimate":2,"columns":8,"cellWidth":320,"output":"_PokemonUniteAnalysis/matches/match-01/frame-bursts/absol-499.2.jpg"}
```

```sh
~/.local/bin/unite-analysis swift frame-burst \
  --record-spec _PokemonUniteMatches/match-01/record-spec.json \
  _PokemonUniteAnalysis/matches/match-01/frame-burst-jobs.jsonl
```

JSONLは`_PokemonUniteAnalysis/matches/match-01/frame-burst-jobs.jsonl`へ保存する。`frameCount`は連続デコードするソースフレーム数であり、連写が覆う時間範囲を決める。値は1から600までとする。任意の`decimate: N`はソースインデックス`0, N, 2N, ...`だけを表示し、時間範囲を変えずにセルを間引く。省略時は`1`とする。標準的な1秒前後の分析ジョブでは`frameCount`を60、`decimate`を2、`columns`を8、`cellWidth`を320から始める。

最初のセルは指定時刻以降で最初にデコードされたフレームであり、左から右、上から下へ読む。注目対象が小さい場合は全画面ではなくROIを指定する。全stdout応答の`ok`を検査し、開始・終了PTSをstderrで確認して、録画の実フレームレートから連写が覆う実時間を判断する。
