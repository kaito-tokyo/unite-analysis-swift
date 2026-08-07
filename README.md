<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# unite-analysis-swift

A macOS command-line tool for extracting and analyzing evidence from
ポケモンユナイト recordings created by LDTX.

## Requirements

- macOS 26 or later on Apple Silicon

## Codex plugin installation

Install **Kaito-Tokyo Unite Analysis** from the Codex Plugins Directory. The
plugin contains the review skill, native MCP server, analysis runtime, and
descriptor database as one versioned and signed app bundle.

## Standalone CLI installation

```sh
install -d "$HOME/.local/bin"
curl -fsSL https://raw.githubusercontent.com/kaito-tokyo/unite-analysis-swift/main/bin/unite-analysis \
  -o "$HOME/.local/bin/unite-analysis"
chmod +x "$HOME/.local/bin/unite-analysis"
"$HOME/.local/bin/unite-analysis" download
```

The download command verifies the signed, notarized, and stapled release disk
image and its Developer ID-signed executables before installing them in the
current user's Application Support directory.

Swift 6 or later is required only when building from source.

## Usage

Ask your agent to analyze a ポケモンユナイト match recording.

Run `unite-analysis swift --help` to list the available commands. For each
command's options, behavior, and examples, run
`unite-analysis swift <command> --help`.

## License

Licensed under the Apache License 2.0. See `LICENSE`, `LICENSES/`, and `NOTICE`.
