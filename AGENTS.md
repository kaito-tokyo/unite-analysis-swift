<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Repository instructions

## Local instructions

- If `AGENTS.local.md` exists in the repository root, read it completely before performing dataset-related work.
- Local instructions may define machine-specific paths and execution details, but they must not weaken or replace the rules in this file.
- Do not commit `AGENTS.local.md`; it is reserved for local configuration.

## Dataset work

- Treat source recordings and other raw dataset inputs as read-only unless the task explicitly authorizes modifying them.
- Before working on a dataset, read the nearest `AGENTS.md` files under that dataset's directory, from its dataset root down to the target directory.
- Use deterministic repository tools for validation and evaluation. Do not use an agent's qualitative judgment as a substitute for a declared test result.
- Report missing datasets, unavailable tools, and skipped checks as not run. Never report them as passed.
- Write generated test and evaluation artifacts only to locations allowed by the applicable dataset instructions.

## Verification

- Run `swift format lint --recursive --strict .` after changing Swift files or formatting configuration.
- Verify that `Package.resolved` and `Schemas/*.json` equal their `jq --indent 2` output after changing JSON files.
- Run `swift test` after changing Swift implementation or tests.
- Run `reuse --no-multiprocessing lint` after changing tracked files.
- Report each verification command and its result separately.
