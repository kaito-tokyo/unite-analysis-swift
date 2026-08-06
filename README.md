<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# unite-analysis-swift

A macOS command-line tool for extracting and analyzing evidence from
Pokémon UNITE recordings created by LDTX.

## Requirements

- macOS 26 or later
- Swift 6 or later

## Native item-recognition dependencies

The native recognition component builds OpenCV 5.0.0 and nanopb 0.4.9.1
directly with SwiftPM. Its public API is a small C++ facade imported through
Swift 6 C++ interoperability; Swift does not expose OpenCV or nanopb types.
Initialize the pinned source dependencies after cloning:

```sh
git submodule update --init
swift test
```

Descriptor databases use the schema in
`Protos/descriptor_database.proto`. They are loaded and validated by C++
before their byte matrices are viewed as `CV_8U` OpenCV matrices.

The loadout commands use `IconMatcherNative.IconMatcher` directly with explicit
BGR byte buffers. Held-item inference removes the shared circular UI
frame and adds a white border before AKAZE extraction; battle-item inference
masks the icon to its diamond interior. Both paths use BF-Hamming KNN matching,
a Lowe ratio filter, and distance-ratio-weighted voting against the combined
reference descriptor matrix.

Draft and blind selection screens intentionally use separate commands. Choose
the mode by visually reviewing the recording or its contact sheet; the program
does not add a fragile draft-versus-blind classifier. Times are relative to the
match start in `record-spec.json`, and negative preparation times are written
with `=` so ArgumentParser does not interpret them as options:

The current `record-spec.json` contract is version 2 and uses `matchId`.
Version 1 uses `globalId` and remains readable. This record-spec schema version
is independent of the enclosing ldtxrecord format version; the numbers happen
to coincide today. Missing and unsupported versions are rejected before media
is opened.

```sh
unite-analysis-swift recognize-blind-loadout \
  --record-spec _PokemonUniteMatches/match-01/record-spec.json \
  --prep-time=-49

unite-analysis-swift recognize-draft-loadout \
  --record-spec _PokemonUniteMatches/match-01/record-spec.json \
  --final-prep-time=-49 --vs-time=-34

# v1 recording: times use the output-video.mp4 recording timeline
unite-analysis-swift recognize-draft-loadout \
  --input /path/to/recording.ldtxrecord \
  --final-prep-time=70 --vs-time=90
```

The default descriptor path is
`~/Library/Application Support/tokyo.kaito.unite-analysis-swift/descriptors.pb`.
Pass `--descriptors` to test a replacement database. The recognizer preserves
raw generic predictions; Pokémon-specific interpretation such as forcing a
Mega Stone from a verified Mega Evolution identity belongs in the report layer.

## Installation

```sh
brew install apm
make install
apm install -g --target codex kaito-tokyo/unite-analysis-swift --skill review-unite-matches-ja
```

## Usage

Ask your agent to analyze a Pokémon UNITE match recording.

## License

Licensed under the Apache License 2.0. See `LICENSE`, `LICENSES/`, and `NOTICE`.
