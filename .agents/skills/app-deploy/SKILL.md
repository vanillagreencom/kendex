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

Choose the version by the [release-version rule](../../../skills/commit-guards/CHECKS.md#release-versions), from the program entries alone. A package entry chooses no part of the kendex version. Under the [release standard](../../../changelog.d/README.md#release-standard), a release whose entries are all package entries is a patch. Follow that standard for breaking changes and compatibility.

Before collation, run `tools/release-previous-tag`. It prints the newest published stable `vX.Y.Z` release tag and fetches it from `origin`. Use that tag for the file comparison with `HEAD`. Stop if the lookup, fetch or comparison fails.

1. From a clean index and working tree, set `COMMIT_GUARDS_CHANGELOG_COLLATE=1` in the environment and run `.agents/skills/commit-guards/scripts/changelog-entries --collate`. It folds the `changelog.d` fragments into `CHANGELOG.md`'s `Unreleased`: program entries under their sections, package entries under `### Packages`, one heading per package stating its version where it has one and its bare name otherwise. A nonzero exit halts the release: fix the cause before retrying.
2. Bump the workspace `version` in `Cargo.toml` and the version in `crates/app/tauri.conf.json`. Both must equal the tag minus the `v`, or the update feed no-ops or loops. Move the collated entries under a new `## [<version>] - <date>` heading, leaving an empty `## [Unreleased]` above it. The collator writes no link footer: point `[Unreleased]:` at `compare/v<version>..HEAD` and add `[<version>]: https://github.com/vanillagreencom/kendex/releases/tag/v<version>` above the previous version's line.
3. Commit with `COMMIT_GUARDS_CHANGELOG_COLLATE=1`. That declaration makes `CHANGELOG.md` count as the entry for the version bump under `crates/`; the `commit-msg` lane refuses the commit without it. Before merging, integrate intervening changes from `main` into the release branch. Collate their fragments under `## [<version>]` and recheck the version against the combined entries. A collated entry that changes the version the [release-version rule](../../../skills/commit-guards/CHECKS.md#release-versions) gives returns the release to step 2. Merge with the github skill's `pr-merge`. Read `gh pr view <PR> --json state,mergeCommit`. Require `state` to be `MERGED` and record `mergeCommit.oid` as the release commit. This is the merged commit, including the new commit from a squash merge. Fetch `origin main`. Require `git merge-base --is-ancestor <mergeCommit.oid> origin/main` to pass. Require `git ls-tree -r --name-only <mergeCommit.oid> -- changelog.d` to list only `changelog.d/README.md`. Stop on a failed read or ancestry check. If the merged commit still has fragments, integrate the current `main` in a follow-up release change. Collate those fragments under the requested release and recheck its version against the combined entries, returning to step 2 if it changes. Merge that follow-up change, then repeat the merged-commit checks with its `mergeCommit.oid`. Select that commit before creating the version tag. Record the requested tag and merged commit, then start the release workflow on `main`:

   ```sh
   gh workflow run release.yml --repo vanillagreencom/kendex --ref main -f tag="v<version>" -f release_commit="<mergeCommit.oid>"
   ```

   Keep the returned run URL. If the CLI returns no URL, find the `workflow_dispatch` run on `main` with that tag and source commit in its title. Watch it with `gh run watch <RUN_ID> --repo vanillagreencom/kendex --exit-status` through the orch job runner. The workflow builds the selected merged commit, which excludes later main changes, and creates its version tag. Fetch it with `git fetch origin tag v<version>`. Require `git rev-parse v<version>^{commit}` to equal the recorded commit. A failed fetch, failed read or different commit halts the release. Retry failed jobs in the same run. Before a fresh dispatch, inspect `gh release view v<version>` if publication may have completed; do not make a published stable release a draft again. A fresh retry uses the same tag and commit. The workflow never moves an existing version tag.

4. Review the draft, then publish it. Publishing is what makes the version "latest" for self-update. A stable release then needs its major tag `v<major>` moved to the commit `v<version>` tags, or created there for a new major, because consumers' shared refresh workflow runs the release that tag names. The operator moves it: the Jarvis session, under the organization-owner bypass of the major-tag ruleset, when it receives `published v<version> at <SHA>`, `<SHA>` being that commit (`git rev-parse v<version>^{commit}`); the owner only when no Jarvis session runs. A lane moves no major tag: after publishing, it sends that notice to its overseer with `lane-mail notice`, and the overseer relays it with `lane-mail notice --item overseer --to owner`, which the Jarvis session reads while it holds that overseer's mailbox ([The Jarvis session hold](../../../skills/slack/README.md#the-jarvis-session-hold)) and which reaches the owner when no Jarvis session runs. Until the tag moves, every shared-workflow refresh run on that major prints `refresh-warning=behind-release`; a new major's first release warns nowhere, because each run compares only its caller's major.
5. Once the release is published, bump the per-release pins `packaging/README.md` § Per release lists: `version` and the checksums in the Homebrew formula and cask, and `pkgver` and `sha256sums` in the Arch recipes where they are not already current. The pin bump writes no changelog fragment: the [release standard](../../../changelog.d/README.md#release-standard) keeps recipe pins out of the release notes. Landing that bump on `main` is the push that runs the two publishers below.


Distro packaging runs itself once the recipes reach `main`: `.github/workflows/publish-aur.yml` (`tools/publish-aur`) pushes the four Arch packages `kendex`, `kendex-bin`, `kendex-git` and `kendex-cli-git` to the AUR, and `.github/workflows/publish-homebrew.yml` (`tools/publish-homebrew`) pushes the formula and cask to the Homebrew tap. Both run on every push to `main` touching their recipes, their tools or their workflow. The AUR publisher defers a package whose pinned downloads are not up yet and lands it when the release is published; the Homebrew push does not check, so a Homebrew version bump must not reach `main` before its release is published (`packaging/README.md` § Publishing).

## What the workflow does

`.github/workflows/release.yml` starts a version release through a dispatch on `main`. Its secret-free preparation job requires the selected commit to belong to the workflow run commit's main history and to have no pending changelog fragments. Each native runner builds that commit. The publish job checks the requested tag against the built CLI version, creates the tag if absent, and verifies its target before publication. It publishes a full release as a draft and a pre-release outright. Tag pushes start no release build. The major tag `v<major>` names the release consumers' shared refresh workflow and moves per step 4. The version is the one the release-version rule above gives; the `changelog-entries` commit lane refuses any other.

A release carries:

- `kendex-<target>[.exe]` and its `.sig`: the command, which `kendex update` installs only as a pair; a lane that signed nothing fails the release.
- The app bundles per platform (deb, rpm, AppImage, dmg, NSIS setup) and the `.sig` beside each updater bundle. The deb, rpm and NSIS setup install the `kendex` command on the PATH too; the macOS app carries it inside the bundle as the sidecar `Contents/MacOS/kendex` and offers once on first launch to link it at `/usr/local/bin/kendex`; the AppImage carries none; no `.msi` is built. The lane proves each installer with `tools/release-installer-check` and `tools/release-installer-check.ps1`.
- `latest.json`: the manifest the app's Update button installs from, one `{signature, url}` per platform; a platform whose signature never reached the publish job fails it by name.
- `digests-<target>.json` and its `.sig`: the version, target and SHA-256 of that lane's downloads, signed under the release key (`tools/release-digests`); the principle is `docs/architecture/updates.md`.
- `feed.json`: what `kendex update` reads at `releases/latest/download/feed.json`; `schema: 1`, a SemVer `version`, `assets` keyed by target triple. A reader treats a missing `schema` as 1 and refuses an unknown one; keep those fields when adding data.

`install.sh` rests on TLS to kendex.ai and github.com alone, because a fresh machine holds neither the release key nor minisign; `kendex update` is the path held to the key.

## Catalog compatibility

`.github/workflows/catalog-check.yml` installs the latest released kendex and `tools/catalog-release-check` runs that engine's catalog check, then installs the catalog into an isolated project for all harnesses and runs the consumer's refresh and verify commands. Release an engine that supports a feature before merging catalog content that uses it; a binary built from the pull request does not satisfy this check.

A catalog change must also settle in an existing install, not only a fresh one. The same check installs the catalog as the caller's base commit held it, every package declared, then refreshes that project to the change through the same source and verifies it. A dropped or renamed package that the released engine cannot retire fails it: keep the package, a stub is enough, or release the engine that retires it first. Only hooks have an engine retire route today, `RETIRED_HOOKS` in `crates/core/src/engine/desired.rs`; catalog-declared retirement for every kind is KEN-2998. A base commit whose catalog the released engine's catalog check refuses skips this part with `upgrade=skip cause=prior-uninstallable`.

## Pre-releases

A dispatch whose requested version has a SemVer pre-release identifier (`v1.0.0-rc1`) publishes outright and marks the release as pre-release. The workflow explicitly dispatches the AUR publisher on `main`, because a release created with `GITHUB_TOKEN` does not start release-event workflows. The workflow's `channel` job puts its `feed.json` on the fixed `prerelease` release, keeping every download URL on the immutable tagged release. A build whose own version is a candidate reads its updates from there; a full release is never offered a candidate. The channel moves forward only (`tools/release-channel-point`). An older candidate leaves the pointer alone. Rerun the newest release's channel job to move it forward after a missed update. A machine on a candidate stays on candidates until moved by hand.

## Main channel

Each completed `main` build publishes all assets under an immutable `main-build-<run>-<attempt>-<commit>` tag, then replaces the single `feed.json` pointer on the pre-release named `main` at the fixed `rolling-main` tag. `kendex update --git` and `install.sh --git` resolve the pointer once, so one install cannot combine two builds, and a binary installed from it stays on this channel. One workflow group holds a main run through all targets, publication and the channel update; a newer push replaces only an older wholly pending workflow. If the `rolling-main` release exists without `feed.json`, delete that empty release and rerun the newest main workflow; the publisher treats only a missing release as a fresh channel.

## Secrets

The release build, publish and channel jobs use the `kendex` environment. It admits only `main`. Store release signing secrets there. A release dispatch runs the reviewed main workflow even when it builds an earlier merged commit. Confirm the job token can create the requested version tag before release use. If GitHub refuses creation, stop and report that permission failure to the owner. Keep the environment main-only.

The `TAURI_SIGNING_*` pair and the `APPLE_*` secrets are held in this repository's main-only `kendex` environment. Only `release.yml` reads them. GitHub-hosted release runners receive them. Developer workstations need no signing secrets for a release.

For a signed local bundle, follow [DEVELOPMENT.md § Packaging](../../../DEVELOPMENT.md#packaging): the project's private env file holds `op://` references, and `op run` resolves them for that command only. The login environment (`~/.config/environment.d`, a shell profile, or `systemctl --user set-environment`) is not a supported source for a signing secret: any process that prints its environment prints the secret. A literal signing key in the private env file is not supported: skill scripts that load that file also receive the key.

- `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`: required; an unset key fails the release. The public half lives in `crates/app/tauri.conf.json` and `crates/core/src/update_feed.rs`, held equal by `crates/app/tests/tauri_config.rs`; a mismatched private key signs the whole release under a key nothing trusts.
- The seven `APPLE_*` secrets: all set, the mac lanes sign and notarize; none set, they build unsigned; a partial set fails the lane.
- Windows code signing is not configured.

Pi packages on npm are the [npm-deploy](../npm-deploy/SKILL.md) skill.
