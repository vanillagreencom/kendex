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

## Major tag

Each stable release needs its major tag `v<major>` moved to the commit `v<version>` tags, or created there for a new major, because consumers' shared refresh workflow runs the release that tag names. `<SHA>` is that release's commit (`git rev-parse v<version>^{commit}`).

The Jarvis session moves or creates `v<major>` at `<SHA>` under the organization-admin bypass of the major-tag ruleset for each stable release. The owner does this when no Jarvis session runs. A lane moves no major tag. A major tag never moves backwards to an older version. If it already names a newer stable release, keep that target. After the move, run `git ls-remote --tags origin v<major>` and require the returned SHA to equal `<SHA>`. A failed read or a different SHA stops release follow-up. Until the tag moves, every shared-workflow refresh run on that major prints `refresh-warning=behind-release`; a new major's first release warns nowhere, because each run compares only its caller's major.

## What the workflow does

Build only the proven release pull request's merged commit on `main`, as [workflows/release.md](workflows/release.md) requires. Stop on a failed source, ancestry, tree, changelog or tag check. The proven collation head must contain only `changelog.d/README.md` under `changelog.d`; a later program fragment that requires a higher release level stops publication. Admitted fragments wait for the next release.

[release.yml](../../../.github/workflows/release.yml) owns the build and artifact declarations. A missing command signature or platform updater signature fails the release. The version tag must match the built CLI version and the proven commit; never move an existing version tag. Stable releases require draft review before publication; pre-releases publish outright.

`install.sh` rests on TLS to kendex.ai and github.com alone, because a fresh machine holds neither the release key nor minisign; `kendex update` is the path held to the key.

## Catalog compatibility

When a pull request makes the catalog require new engine behavior, raise the source `kendex.toml` root `min_kendex` to that engine's next release version in the same pull request. Package content changes that use existing engine behavior leave the minimum unchanged and cause no engine release or skill version change. The engine refuses an above-minimum catalog before rendering or install writes for its plan. The source architecture contract states which command-wide checks precede all plans. Catalog download caches are excluded from the write guarantee.

`.github/workflows/catalog-check.yml` installs the latest released kendex and `tools/catalog-release-check` runs that engine's catalog check, then installs the catalog into an isolated project for all harnesses and runs the consumer's refresh and verify commands. Release an engine that supports a feature before merging catalog content that uses it; a binary built from the pull request does not satisfy this check.

On a merge group, the catalog job's package-suites leg also runs, in each changed shell package whose scripts or suites call kendex, every suite a Linux CI shard gives a kendex, with that installed release first on PATH, through `tools/guard --released-packages`. Pi packages and unchanged packages do not rerun. The catalog check also asks the released manifest reader about actual `kendex.toml` files the catalog ships. A failure names the package, suite and engine version. Release the engine first, then raise `min_kendex` and merge the package content.

A catalog change must also settle in an existing install, not only a fresh one. The same check installs the catalog as the caller's base commit held it, every package declared, then refreshes that project to the change through the same source and verifies it. A dropped or renamed package that the released engine cannot retire fails it: keep the package, a stub is enough, or release the engine that retires it first. Only hooks have an engine retire route today, `RETIRED_HOOKS` in `crates/core/src/engine/desired.rs`; catalog-declared retirement for every kind is KEN-2998. A base commit whose catalog the released engine's catalog check refuses skips this part with `upgrade=skip cause=prior-uninstallable`.

## Pre-releases

A dispatch whose requested version has a SemVer pre-release identifier (`v1.0.0-rc1`) publishes outright and marks the release as pre-release. The workflow explicitly dispatches the AUR publisher on `main`, because a release created with `GITHUB_TOKEN` does not start release-event workflows. The workflow's `channel` job puts its `feed.json` on the fixed `prerelease` release, keeping every download URL on the immutable tagged release. A build whose own version is a candidate reads its updates from there; a full release is never offered a candidate. The channel moves forward only (`tools/release-channel-point`). An older candidate leaves the pointer alone. Rerun the newest release's channel job to move it forward after a missed update. A machine on a candidate stays on candidates until moved by hand.

## Main channel

Each completed `main` build publishes all assets under an immutable `main-build-<run>-<attempt>-<commit>` tag, then replaces the single `feed.json` pointer on the pre-release named `main` at the fixed `rolling-main` tag. `kendex update --git` and `install.sh --git` resolve the pointer once, so one install cannot combine two builds, and a binary installed from it stays on this channel. One workflow group holds a main run through all targets, publication and the channel update; a newer push replaces only an older wholly pending workflow. If the `rolling-main` release exists without `feed.json`, delete that empty release and rerun the newest main workflow; the publisher treats only a missing release as a fresh channel.

## Secrets

The release build, publish and channel jobs use the `kendex` environment. It admits only `main`. Store release signing secrets there. A release dispatch runs the reviewed main workflow even when it builds an earlier merged commit. Confirm the job token can create the requested version tag before release use. If GitHub refuses creation, stop and report that permission failure to the owner. Keep the environment main-only.

The `TAURI_SIGNING_*` pair and the `APPLE_*` secrets are held in this repository's main-only `kendex` environment. Only `release.yml` reads them. GitHub-hosted release runners receive them. Developer workstations need no signing secrets for a release.

For a signed local bundle, follow [DEVELOPMENT.md § Packaging](../../../DEVELOPMENT.md#packaging): a dedicated signing env file with mode `600` holds only the Tauri signing pair as `op://` references, and `op run` resolves them for that command only. No skill script loads this dedicated file. The login environment (`~/.config/environment.d`, a shell profile, or `systemctl --user set-environment`) is not a supported source for a signing secret: any process that prints its environment prints the secret. A literal signing key in a file that skill scripts load is not supported: those scripts also receive the key.

- `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`: required; an unset key fails the release. The public half lives in `crates/app/tauri.conf.json` and `crates/core/src/update_feed.rs`, held equal by `crates/app/tests/tauri_config.rs`; a mismatched private key signs the whole release under a key nothing trusts.
- The seven `APPLE_*` secrets: all set, the mac lanes sign and notarize; none set, they build unsigned; a partial set fails the lane.
- Windows code signing is not configured.

Pi packages on npm are the [npm-deploy](../npm-deploy/SKILL.md) skill.
