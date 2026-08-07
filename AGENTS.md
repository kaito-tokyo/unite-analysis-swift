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

- Run `swift format lint --recursive --strict Package.swift Sources Tests` after changing Swift files or formatting configuration. Vendor submodules contain upstream Swift examples outside this repository's formatting policy.
- Verify that `Package.resolved` and `docs/*.json` equal their `jq --indent 2` output after changing JSON files.
- Run `swift test` after changing Swift implementation or tests.
- Run `reuse --no-multiprocessing lint` after changing tracked files.
- Report each verification command and its result separately.

## Release artifact zero trust

- Apply this policy only to products that can become GitHub Release assets. It does not apply to source code, runner environments, caches, test artifacts, or other outputs that cannot enter the release path.
- Attest every release-bound product in the job that produces it, before transferring it to another job or workflow.
- After receiving a release-bound product from another job or workflow, verify its attestation before reading, transforming, signing, packaging, notarizing, or publishing it.
- Attest transformed release products separately. An attestation for an input does not implicitly attest a signed, packaged, notarized, or otherwise transformed output.
- Preserve enough provenance in attestations to trace a release product to its producing workflow, source commit, and relevant input product.
- Rely on the provenance implications recorded by `actions/attest` for source and runner authenticity. Do not add separate source or environment verification solely for this policy.
