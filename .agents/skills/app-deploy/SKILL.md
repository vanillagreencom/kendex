---
name: app-deploy
description: "Load when asked to cut, ship, or release a kendex version."
summary: "Releases a kendex version: bumps versions, finalizes the changelog, dispatches the main workflow, and reviews its publication."
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Release kendex

Choose the version by the [release-version rule](../../../skills/commit-guards/CHECKS.md#release-versions), from the program entries alone. Compatible catalog content writes no kendex fragment and causes no kendex release. Follow the [release standard](../../../changelog.d/README.md#release-standard) for released execution code, breaking changes and compatibility.

To cut a release, follow [workflows/release.md](workflows/release.md).

Build every release artifact from the proven release commit. The workflow owns source proof, collation checks and tag verification; a failed check stops publication.

## Major tag

Each stable release needs its major tag `v<major>` moved to the commit `v<version>` tags, or created there for a new major, because consumers' shared refresh workflow runs the release that tag names. `<SHA>` is that release's commit (`git rev-parse v<version>^{commit}`).

The Jarvis session moves or creates `v<major>` at `<SHA>` under the organization-admin bypass of the major-tag ruleset for each stable release. The owner does this when no Jarvis session runs. A lane moves no major tag. A major tag never moves backwards to an older version. If it already names a newer stable release, keep that target. After the move, run `git ls-remote --tags origin v<major>` and require the returned SHA to equal `<SHA>`. A failed read or a different SHA stops release follow-up. Until the tag moves, every shared-workflow refresh run on that major prints `refresh-warning=behind-release`; a new major's first release warns nowhere, because each run compares only its caller's major.

## Catalog compatibility

When a pull request makes the catalog require new engine behavior, raise the source `kendex.toml` root `min_kendex` to that engine's next release version in the same pull request. Package content changes that use existing engine behavior leave the minimum unchanged and cause no engine release or skill version change. The engine refuses an above-minimum catalog before rendering or install writes for its plan. The source architecture contract states which command-wide checks precede all plans. Catalog download caches are excluded from the write guarantee.

Release an engine that supports a feature before merging catalog content that uses it. A binary built from the pull request does not satisfy the released-engine gate in `.github/workflows/catalog-check.yml`. `tools/catalog-release-check` checks fresh installs, shipped manifest schemas and upgrades from the base catalog; `tools/guard --released-packages` checks the changed shell packages against that release.

A dropped or renamed package must remain available, a stub is enough, until a released engine can retire it from an existing install. A base catalog the released engine cannot install leaves upgrade verification skipped, not proved; the check reports `upgrade=skip cause=prior-uninstallable`.

When evaluating publication or recovering a channel, read [Artifacts and channels](references/release-contract.md#artifacts-and-channels).

## Secrets

The release build, publish and channel jobs use the `kendex` environment. It admits only `main`. Store release signing secrets there. A release dispatch runs the reviewed main workflow even when it builds an earlier merged commit. Confirm the job token can create the requested version tag before release use. If GitHub refuses creation, stop and report that permission failure to the owner. Keep the environment main-only.

The `TAURI_SIGNING_*` pair and the `APPLE_*` secrets are held in this repository's main-only `kendex` environment. Only `release.yml` reads them. GitHub-hosted release runners receive them. Developer workstations need no signing secrets for a release.

For a signed local bundle, follow [DEVELOPMENT.md § Packaging](../../../DEVELOPMENT.md#packaging): a dedicated signing env file with mode `600` holds only the Tauri signing pair as `op://` references, and `op run` resolves them for that command only. No skill script loads this dedicated file. The login environment (`~/.config/environment.d`, a shell profile, or `systemctl --user set-environment`) is not a supported source for a signing secret: any process that prints its environment prints the secret. A literal signing key in a file that skill scripts load is not supported: those scripts also receive the key.

- `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`: required; an unset key fails the release. The public half lives in `crates/app/tauri.conf.json` and `crates/core/src/update_feed.rs`, held equal by `crates/app/tests/tauri_config.rs`; a mismatched private key signs the whole release under a key nothing trusts.
- The seven `APPLE_*` secrets: all set, the mac lanes sign and notarize; none set, they build unsigned; a partial set fails the lane.
- Windows code signing is not configured.

Pi packages on npm are the [npm-deploy](../npm-deploy/SKILL.md) skill.
