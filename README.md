<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# unite-analysis-swift

A macOS command-line tool for extracting and analyzing evidence from
Pokémon UNITE recordings created by LDTX.

## Requirements

- macOS 26 or later on Apple Silicon
- Swift 6 or later

## Installation

```sh
install -d "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/kaito-tokyo/unite-analysis-swift/main/bin/unite-analysis \
  -o "$HOME/.local/bin/unite-analysis"
chmod +x "$HOME/.local/bin/unite-analysis"
unite-analysis download

brew install apm
apm install -g --target codex kaito-tokyo/unite-analysis-swift --skill review-unite-matches-ja
```

## Usage

Ask your agent to analyze a Pokémon UNITE match recording.

Run `unite-analysis swift --help` to list the available commands. For each
command's options, behavior, and examples, run
`unite-analysis swift <command> --help`.

## License

Licensed under the Apache License 2.0. See `LICENSE`, `LICENSES/`, and `NOTICE`.
