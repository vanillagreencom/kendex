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

`.github/workflows/release.yml` starts a version release through a dispatch on `main`. Its secret-free preparation job requires the selected commit to belong to the workflow run commit's main history. It verifies that the release pull request merged to `main` at that selected commit. The preparation job retains its fixed `changelog.d` tree check at the proven collation head. A failed tree read or a path other than `changelog.d/README.md` stops preparation. The changelog owner checks pending program fragments in the selected merge tree. The publishing check reads tracked policy from the selected merge before discovering pending program fragments. It checks those fragments against the selected version level. A nonzero patch component means patch; otherwise a nonzero minor component means minor; otherwise major. Unchanged-version re-collation and independent package release history do not add a publishing comparison. It refuses later entries that need a higher release level and names their path and required level. Admitted entries wait for the next release. Each native runner builds the selected merge commit. The publish job checks the requested tag against the built CLI version, creates the tag if absent, and verifies its target before publication. It publishes a full release as a draft and a pre-release outright. Tag pushes start no release build. The major tag `v<major>` names the release consumers' shared refresh workflow and moves per [§ Major tag](#major-tag). The version is the one the release-version rule above gives; the `changelog-entries` commit lane refuses any other.

A release carries:

- `kendex-<target>[.exe]` and its `.sig`: the command, which `kendex update` installs only as a pair; a lane that signed nothing fails the release.
- The app bundles per platform (deb, rpm, AppImage, dmg, NSIS setup) and the `.sig` beside each updater bundle. The deb, rpm and NSIS setup install the `kendex` command on the PATH too; the macOS app carries it inside the bundle as the sidecar `Contents/MacOS/kendex` and offers once on first launch to link it at `/usr/local/bin/kendex`; the AppImage carries none; no `.msi` is built. The lane proves each installer with `tools/release-installer-check` and `tools/release-installer-check.ps1`.
- `latest.json`: the manifest the app's Update button installs from, one `{signature, url}` per platform; a platform whose signature never reached the publish job fails it by name.
- `digests-<target>.json` and its `.sig`: the version, target and SHA-256 of that lane's downloads, signed under the release key (`tools/release-digests`); the principle is `docs/architecture/updates.md`.
- `feed.json`: what `kendex update` reads at `releases/latest/download/feed.json`; `schema: 1`, a SemVer `version`, `assets` keyed by target triple. A reader treats a missing `schema` as 1 and refuses an unknown one; keep those fields when adding data.

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
