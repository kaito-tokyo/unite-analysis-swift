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

OCR is performed locally with Apple Vision.

## Build and install

Build the `unite-analysis-swift` executable in release configuration:

```sh
make build
```

Install it into `/usr/local/bin`:

```sh
sudo make install
```

The installed command is `/usr/local/bin/unite-analysis-swift`.

Set `PREFIX` or `DESTDIR` to stage the installation elsewhere.

## Agent skill

This repository distributes the Japanese-localized `review-unite-matches-ja` skill through
[Agent Package Manager](https://microsoft.github.io/apm/). Install only that
skill with:

```sh
apm install kaito-tokyo/unite-analysis-swift --skill review-unite-matches-ja
```

The APM source is kept under `.apm/skills/`. Run `apm compile` when updating the
skill to regenerate target-specific output.

Set the Obsidian MatchReports and StrategyBooks destinations used by the skill
with the installed command:

```sh
unite-analysis-swift config set obsidian-match-reports-root "/path/to/Obsidian/PokemonUnite/MatchReports"
unite-analysis-swift config set obsidian-strategy-books-root "/path/to/Obsidian/PokemonUnite/StrategyBooks"
```

Use `config get` and `config unset` with either key, and use `config path` to
locate the underlying user configuration file. A path stated in the current
request takes precedence over its corresponding stored setting.

When either destination is needed but unset, the skill asks before configuring
it and proposes `~/Obsidian/PokemonUnite/MatchReports` or
`~/Obsidian/PokemonUnite/StrategyBooks`. A missing directory is created only
after the user agrees to both its path and creation.

## License

Licensed under the Apache License 2.0. See `LICENSE`, `LICENSES/`, and `NOTICE`.
