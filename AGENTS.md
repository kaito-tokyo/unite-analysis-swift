<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# Repository instructions

## Protected files

- Agents must not edit `README.md`. Changes to `README.md` are reserved for human maintainers.

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

## Release follow-up

- Release tags must be signed annotated tags.
- The annotated tag message must exactly match the tag name. For example, tag `v0.1.4` must have the message `v0.1.4` with no additional text.
- After a release has completed, the agent must create a follow-up pull request that prepares the repository for the next release.
- Keep two distinct version values on `main`:
  - `apm.yml` and the native CLI `--version` must always contain the next, unreleased version. No Git tag for that version may exist yet.
  - `README.md` and `docs/metadata/latest-version.txt` must always contain the newest released version, for which a Git tag already exists.
- Treat the post-release version update as one combined operation: update `docs/metadata/latest-version.txt` to the version of the newly published tag, without the leading `v`, and advance `apm.yml`, `Contents/Info.plist`, and all native executable versions to the following release version.
- Do not advance `docs/metadata/latest-version.txt` or the released-version references in `README.md` before the corresponding GitHub Release is available for download.
- Because agents must not edit `README.md`, report any stale or inconsistent released-version reference there for a human maintainer to update.

## Shell scripts

- Use `/bin/dash` for POSIX shell entry points intended for the supported macOS environment.
- Do not replace the Dash shebang with `/bin/sh`; on macOS `/bin/sh` starts Bash, which introduces unwanted compatibility-mode behavior and additional startup overhead.
- Keep these scripts compatible with Dash and validate them with `dash -n` and ShellCheck's Dash dialect.

## Release artifact zero trust

- The `release-macos` environment must provide both `MACOS_SIGNING_APPLICATION_IDENTITY` and `MACOS_SIGNING_INSTALLER_IDENTITY`. The signing PKCS#12 secret imported by the release workflow must contain the corresponding Developer ID Application and Developer ID Installer identities.
- Always run code-signing verification outside the sandbox. Do not treat
  `codesign`, `spctl`, or equivalent results produced inside a sandbox as valid
  evidence that a release artifact's signature is valid or invalid.
- Apply this policy only to release-bound products: files or containers that are independently transferred between jobs or workflows for release, or published as GitHub Release assets. It does not apply to source code, runner environments, caches, test artifacts, or other outputs that cannot enter the release path.
- Treat files contained in a release-bound archive or disk image as components of that container, not as separate release-bound products, unless those files are independently transferred or published. Signing or otherwise transforming a component within the job that creates the final container does not by itself require a separate attestation for that component.
- Attest every release-bound product in the job that produces it, before transferring it to another job or workflow.
- After receiving a release-bound product from another job or workflow, verify its attestation before reading, transforming, signing, packaging, notarizing, or publishing it.
- Attest each transformed release-bound product separately before transferring or publishing that product. An attestation for an input container does not implicitly attest a signed, packaged, notarized, or otherwise transformed output container.
- Preserve enough provenance in attestations to trace a release product to its producing workflow, source commit, and relevant input product.
- Rely on the provenance implications recorded by `actions/attest` for source and runner authenticity. Do not add separate source or environment verification solely for this policy.
