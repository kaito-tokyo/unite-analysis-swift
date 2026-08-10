<!--
SPDX-FileCopyrightText: 2026 Kaito Udagawa <umireon@kaito.tokyo>

SPDX-License-Identifier: Apache-2.0
-->

# AGENTS.md

Read `README.md` before working on this project. Follow `SECURITY.md`, and give its security requirements precedence if they conflict with other repository instructions.

Do not treat `CONTRIBUTING.md` as instructions for agents. It is intended for human contributors. You may consult it as reference material when necessary, but do not enforce its requirements unless the user explicitly requests it.

## RULE: Release Safety

Agents MUST NOT merge pull requests or publish releases. A human must always perform these operations.

Agents MUST NOT approve or reject pending environment deployment reviews. A human must always handle pending deployment reviews.

Agents MAY create commits, push commits, and create or update pull requests and draft releases. Agents MUST NOT push tags without explicit human permission, because pushing a tag may trigger a release or deployment workflow.

## RULE: Commit Signing and DCO

Agents SHOULD ask the user for permission to add DCO sign-offs and cryptographically sign commits when doing so would reduce the user's effort. Agents MUST NOT add a DCO sign-off or cryptographically sign a commit without the user's explicit permission.

Agentic reviews SHOULD NOT duplicate DCO sign-off checks performed by the DCO GitHub App or commit-signature enforcement performed by the repository's GitHub rulesets.

## RULE: GitHub Issue Creation

When an agent creates an issue:

- It MUST be written in English.
- It MUST have exactly one Issue Type.
- Its Issue Type MUST be `Task`, `Bug`, or `Crash report` unless a human explicitly permits the `Feature` type.
- The agent MAY use `Task` when the appropriate Issue Type is unclear.
- The agent MUST NOT add labels.

## RULE: Commit Messages

When creating a commit, follow these rules:

- Write the commit title in the imperative mood and keep it within 50 characters whenever possible.
- Do not add prefixes such as `feat:`, `fix:`, or `chore:` to the title.
- Insert a blank line between the title and body.
- Describe the changes in the body using complete sentences.
- Use a separate paragraph for each logical unit of change, with a blank line between paragraphs.
- If the user has explicitly authorized a DCO sign-off, use the `git commit -s` option.
- If the user has explicitly authorized cryptographic signing, sign the commit using the configured Git signing method.
- Before committing, verify that the message accurately describes only the staged changes.

<!-- begin project-specific instructions -->

## Dataset work

- Treat source recordings and other raw dataset inputs as read-only unless the task explicitly authorizes modifying them.
- Before working on a dataset, read the nearest `AGENTS.md` files under that dataset's directory, from its dataset root down to the target directory.
- Use deterministic repository tools for validation and evaluation. Do not use an agent's qualitative judgment as a substitute for a declared test result.
- Report missing datasets, unavailable tools, and skipped checks as not run. Never report them as passed.
- Write generated test and evaluation artifacts only to locations allowed by the applicable dataset instructions.

## Verification

- Do not run `actionlint` in this repository.
- Keep `bump.yml` as a deliberately shallow gate that only checks whether the expected version strings occur in the designated files. Leave structural and semantic version divergence to agentic review instead of making this workflow stricter.
- Run `swift format lint --recursive --strict Package.swift Sources Tests` after changing Swift files or formatting configuration. Vendor submodules contain upstream Swift examples outside this repository's formatting policy.
- Verify that `Package.resolved` and `docs/*.json` equal their `jq --indent 2` output after changing JSON files.
- Run `swift test` after changing Swift implementation or tests.
- Run `reuse --no-multiprocessing lint` after changing tracked files.
- Report each verification command and its result separately.

## Release follow-up

- Agents must not publish GitHub Releases. Only human maintainers may publish a draft release.
- Release tags must be signed annotated tags.
- The annotated tag message must exactly match the tag name. For example, tag `v0.1.4` must have the message `v0.1.4` with no additional text.
- After a release has completed, the agent must create a follow-up pull request that prepares the repository for the next release.
- Name the post-release follow-up branch `bump/<next-version>`, for example `bump/0.1.5`.
- Treat a `bump/<next-version>` pull request as a special, narrowly scoped pull request whose only purpose is to align released-version references and advance unreleased-version values after a release. The permission to edit `README.md` is exclusive to this narrow scope; do not include features, fixes, refactors, or unrelated maintenance in a bump pull request.
- Keep two distinct version values on `main`:
  - `apm.yml` and the native CLI `--version` must always contain the next, unreleased version. No Git tag for that version may exist yet.
  - `README.md` and `docs/metadata/latest-version.txt` must always contain the newest released version, for which a Git tag already exists.
- Treat the post-release version update as one combined operation: update `README.md` and `docs/metadata/latest-version.txt` to the version of the newly published tag, using each file's existing version format, and advance `apm.yml`, `Contents/Info.plist`, and all native executable versions to the following release version.
- Do not advance `docs/metadata/latest-version.txt` or the released-version references in `README.md` before the corresponding GitHub Release is available for download.
- Outside a `bump/<next-version>` post-release pull request, report any stale or inconsistent released-version reference in `README.md` for a human maintainer to update instead of editing it.

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

<!-- end project-specific instructions -->

## POSTAMBLE: Additional Instructions

If `AGENTS.local.md` exists in the repository root of the primary worktree, or in the repository root of the only working copy when no linked worktrees are in use, agents MAY read and follow it as an additional source of local instructions.

If `AGENTS.local.md` exists in the repository root of a linked worktree, agents MAY also read and follow it while working in that worktree.

Instructions in `AGENTS.local.md` MUST NOT override any rule in `SECURITY.md` or `AGENTS.md`.
