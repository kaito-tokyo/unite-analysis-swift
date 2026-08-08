<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# unite-analysis-swift

A macOS command-line tool for extracting and analyzing evidence from
ポケモンユナイト recordings created by LDTX.

## Requirements

- macOS 26 or later on Apple Silicon

## Installation

Download the signed and notarized macOS installer package from
[GitHub Releases](https://github.com/kaito-tokyo/unite-analysis-swift/releases/latest).
Apple Installer can place `Kaito-Tokyo Unite Analysis.app` in either the current
user's `~/Applications` directory or the system `/Applications` directory.

Install the review skill and MCP configuration with
[Agent Package Manager](https://microsoft.github.io/apm/):

```sh
brew install apm
apm install -g --target codex kaito-tokyo/unite-analysis-swift
```

The APM MCP configuration checks `~/Applications` first and `/Applications`
second.
The app uses one native executable for both interfaces: ordinary commands run
as `unite-analysis-swift <command>`, and the stdio server runs as
`unite-analysis-swift mcp`.

Swift 6 or later is required only when building from source.

## Usage

Ask your agent to analyze a ポケモンユナイト match recording.

For direct CLI use, run the executable inside the installed app bundle. For
example, use
`"$HOME/Applications/Kaito-Tokyo Unite Analysis.app/Contents/MacOS/unite-analysis-swift" --help`
for a per-user installation, or the corresponding path under `/Applications`
for a system installation.

## License

Licensed under the Apache License 2.0. See `LICENSE`, `LICENSES/`, and `NOTICE`.
