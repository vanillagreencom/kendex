# Releasing

The procedure is the `app-deploy` skill (`.agents/skills/app-deploy/SKILL.md`): collate the changelog from a clean tree under the collate declaration, bump the versions, commit under that declaration, merge the release pull request, tag its merge commit, review the draft, publish. `.github/workflows/release.yml` runs on the tag push: one native runner per target, the tag checked against the version the built CLI reports, a full release published as a draft and a pre-release outright. It runs on `v*.*.*` tags only: the major tag `v<major>` names the release consumers' shared refresh workflow runs, moves per step 4 of that skill, and starts no build. This page holds what neither states.

## Choosing the version

The bump follows [the release-version rule](../skills/commit-guards/CHECKS.md#release-versions). The `changelog-entries` commit lane refuses the bumps its [version-bump check](../skills/commit-guards/CHECKS.md#version-bumps) lists.

## What a release carries

- `kendex-<target>[.exe]` and its `.sig`: the command, which `kendex update` installs only as a pair; a lane that signed nothing fails the tag.
- The app bundles per platform (deb, rpm, AppImage, dmg, NSIS setup) and the `.sig` beside each updater bundle; `kendex update` fetches the AppImage's signature straight from the release. The deb, rpm and NSIS setup install the `kendex` command on the PATH too: the deb and rpm at `/usr/bin/kendex`, the setup as `bin\kendex.exe` under its install directory, which its hooks (`crates/app/release/nsis-hooks.nsh`) put on the user PATH and take off on uninstall where they put it there. The macOS app and its `.app.tar.gz` carry it inside the bundle as the sidecar `Contents/MacOS/kendex`, signed and notarized with the app; on first launch the app offers once to link it at `/usr/local/bin/kendex`, and Settings keeps the offer. The AppImage carries none. No `.msi` is built. The lane proves each installer with `tools/release-installer-check` (Linux and macOS) and `tools/release-installer-check.ps1` (Windows, a real silent install and uninstall) before it stages anything.
- `latest.json`: the manifest the app's Update button installs from, one `{signature, url}` per platform; a platform whose signature never reached the publish job fails it by name.
- `digests-<target>.json` and its `.sig`: the version, target and SHA-256 of that lane's downloads, signed under the release key (`tools/release-digests`). A main document also carries its monotonic build number and source commit. Both shells install nothing whose identity or hash this document does not name.
- `feed.json`: what `kendex update` reads at `releases/latest/download/feed.json`; `schema: 1`, a SemVer `version`, `assets` keyed by target triple. A main feed also carries `apps` and `digests` URLs for the same immutable build. A reader treats a missing `schema` as 1 and refuses an unknown one; keep those fields when adding data.

`install.sh` rests on TLS to kendex.ai and github.com alone, on every run, because a fresh machine holds neither the release key nor minisign; `kendex update` is the path held to the key.

## Catalog compatibility

`.github/workflows/catalog-check.yml` installs the latest released kendex with `skills/review-gate/scripts/install-latest.sh`. `tools/catalog-release-check` runs that engine's catalog check, then installs the catalog into an isolated project for all harnesses and runs the consumer's refresh and verify commands. The wrapper defaults to strict authoring checks; the reusable workflow passes `--allow-advisories` when its caller sets `strict: false`. Core judges unsupported declared-hook delivery, which fails under either setting. A nonzero command result stops the wrapper and prints one `catalog-release: version=... feature=...` record with the engine's diagnostic. Release an engine that supports the feature before merging catalog content that uses it. A binary built from the pull request does not satisfy this check. `crates/cli/tests/release_workflow/catalog.rs` installs that release for the acceptance and declared-incompatibility fixtures. The consumer refresh template uses the same release installer.

## Pre-releases

A tag carrying a SemVer pre-release identifier (`v1.0.0-rc1`) is published outright and marked pre-release. The workflow's `channel` job puts its `feed.json` on the fixed `prerelease` release. The feed keeps all download URLs on the immutable tagged release. A build whose own version is a candidate reads its updates from there (`crates/core/src/update_channel.rs`); a full release is never offered a candidate.

- The channel moves forward only (`tools/release-channel-point`): re-running an older tag leaves it alone, and a channel carrying assets it cannot read a version off stops the job for a person.
- The channel job's concurrency group drops repoints, never releases; push the newest tag again to move the channel to it.
- A machine on a candidate stays on candidates until moved by hand: cut one more candidate when the final ships, or reinstall it.

## Main channel

Each completed `main` build publishes all assets under an immutable `main-build-<run>-<attempt>-<commit>` tag. It then replaces the single `feed.json` pointer on the pre-release named `main` at the fixed `rolling-main` tag. The pointer names the command, app, and signed digest documents from that immutable build. `kendex update --git` and `install.sh --git` resolve the pointer once, so one install cannot combine two builds. A binary installed from it stays on this channel when it checks again. One workflow group holds a main run through all targets, publication and the channel update. A newer push replaces only an older wholly pending workflow. It cannot replace pending targets inside the active run. Tag workflows use separate groups for each run. Publication uses a separate group for each run. The serialized channel publisher authenticates the current and candidate build numbers. It refuses a candidate whose run number is not greater. The concurrency checks in `crates/cli/tests/release_workflow/channel.rs` and the pointer checks in `crates/cli/tests/release_workflow/channel_point.rs` hold these rules.

If the `rolling-main` release exists without `feed.json`, delete that empty release in GitHub Releases and rerun the newest main workflow. The publisher treats only a missing release as a fresh channel.

## Secrets

- `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`: required. Every lane bundles an updater-enabled target and signs its downloads, so an unset key fails the tag. The public half lives in two places that rotate together, `plugins > updater > pubkey` in `crates/app/tauri.conf.json` and `UPDATER_PUBLIC_KEY` in `crates/core/src/update_feed.rs`, held equal by `crates/app/tests/tauri_config.rs`; a private key that does not match signs the whole release under a key nothing trusts, and the app and `kendex update` refuse it.
- The seven `APPLE_*` secrets (certificate and its password, signing identity, team id, App Store Connect issuer, key id and key): all set, the mac lanes sign and notarize; none set, they build unsigned; a partial set fails the lane.
- Windows code signing is not configured.

## After publishing

Every package recipe carries per-release checksums; `packaging/README.md` § Per release lists what to bump, and § Publishing the workflows that carry the bump to the AUR and the Homebrew tap once it is on `main`.

## Local packaging

`cd crates/app && ../../ui/node_modules/.bin/tauri build` bundles deb and rpm anywhere; the AppImage step needs FUSE2 for linuxdeploy. Bundling signs updater artifacts, so set `TAURI_SIGNING_PRIVATE_KEY` or pass `--no-sign`.

The command inside each installer comes from an overlay under `crates/app/release/`, one per platform, passed as `--config release/<platform>.json`; each reads the command the lane staged under `target/bundle-cli/` (`tools/release-installer-check`'s header and the `Stage the command for the bundle` step in `release.yml` name the file per platform). The overlays stay out of `tauri.conf.json` because tauri-build copies `externalBin` and `resources` at compile time, and a plain `cargo build -p kendex-app` must need no staged command; `crates/app/tests/tauri_config.rs::release_only_bundle_settings_stay_out_of_the_base_config` holds it. To bundle with the command locally: `cargo build --release -p kendex-cli`, copy `target/release/kendex` to `target/bundle-cli/kendex`, then `../../ui/node_modules/.bin/tauri build --bundles deb,rpm --no-sign --config release/linux.json` from `crates/app`.

## Pi packages on npm

The procedure is the `npm-deploy` skill (`.agents/skills/npm-deploy/SKILL.md`): it lands the version bumps and pushes one release tag `<unscoped-name>-v<version>` per package. `.github/workflows/publish-npm.yml` runs on that tag, and its one job there dispatches the same workflow on `main`. The dispatched run's `publish` job publishes the package with npm trusted publishing: npm gives the job a one-publish credential in exchange for its GitHub identity, so no npm token exists. `tools/publish-npm --help` lists every check and answer.

- Every package needs, on npmjs.com under its Settings, Trusted publishing, a GitHub Actions publisher with organization `vanillagreencom`, repository `kendex`, workflow filename `publish-npm.yml`, environment `kendex`, and the allowed action `npm publish` ticked. An organization admin sets it once per package; a publisher created after 2026-09-03 allows only `npm stage publish` until that action is ticked.
- The environment is what binds publishing to reviewed code. The `kendex` environment deploys from `main` only ([D003](decisions/D003-one-merge-path.md) step 2), and no lane can change that policy. GitHub refuses the `publish` job on any other ref, and npm refuses a token from any job outside the environment, so a branch's edited copy of the workflow or of `tools/publish-npm` gets no credential, and a tag on unreviewed code only reaches main's copy, which refuses a tag whose commit `main` does not hold.
- npm matches the workflow by filename. Renaming the file, or calling it from another workflow, breaks every publish until each package's trusted publisher names the new filename. npm cannot edit a publisher, so an admin adds a new one beside the old (a package holds up to 10) and then deletes the old one.
- Trusted publishing cannot make a package's first publish, because npm sets a publisher only on a package that exists; `tools/publish-npm` refuses such a package with `first-release=<name>`. An npm organization admin publishes the first version by hand from the fetched `main` head, sets its trusted publisher as above, then tags that same commit `<unscoped-name>-v<version>` and pushes the tag; the publish run that push dispatches on `main` reports `served=`, found as in the `npm-deploy` skill's Publish step 3.
- `gh workflow run publish-npm.yml --ref main -f tag=<unscoped-name>-v<version>` runs the publish against an existing tag: a failed run is retried this way, and so is a tag whose commit predates the workflow, which starts no run when pushed. Either publishes only while the package's directory on `main` is the same as at the tag: npm's signed provenance names the `main` commit the run checked out, so `tools/publish-npm` refuses a package changed since its tag with `moved=<tag>`, and that package needs a new version and tag. `-f dry_run=true` runs every check and publishes nothing. Both run on `main` alone.
