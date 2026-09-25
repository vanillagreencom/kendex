# Releasing

The procedure is the `app-deploy` skill (`.agents/skills/app-deploy/SKILL.md`): collate the changelog from a clean tree under the collate declaration, bump the versions, commit under that declaration, tag, review the draft, publish. `.github/workflows/release.yml` runs on the tag push: one native runner per target, the tag checked against the version the built CLI reports, a full release published as a draft and a pre-release outright. This page holds what neither states.

## What a release carries

- `kendex-<target>[.exe]` and its `.sig`: the command, which `kendex update` installs only as a pair; a lane that signed nothing fails the tag.
- The app bundles per platform (deb, rpm, AppImage, dmg, NSIS setup) and the `.sig` beside each updater bundle; `kendex update` fetches the AppImage's signature straight from the release. Every downloadable installer carries the `kendex` command too: the deb and rpm at `/usr/bin/kendex`, the macOS app and its `.app.tar.gz` as the sidecar `Contents/MacOS/kendex`, signed and notarized with the app, and the NSIS setup as `bin\kendex.exe` under its install directory, which its hooks (`crates/app/release/nsis-hooks.nsh`) put on the user PATH and take off on uninstall. No `.msi` is built. The lane proves each installer with `tools/release-installer-check` (Linux and macOS) and `tools/release-installer-check.ps1` (Windows, a real silent install and uninstall) before it stages anything.
- `latest.json`: the manifest the app's Update button installs from, one `{signature, url}` per platform; a platform whose signature never reached the publish job fails it by name.
- `digests-<target>.json` and its `.sig`: the version, target and SHA-256 of that lane's downloads, signed under the release key (`tools/release-digests`). A main document also carries its monotonic build number and source commit. Both shells install nothing whose identity or hash this document does not name.
- `feed.json`: what `kendex update` reads at `releases/latest/download/feed.json`; `schema: 1`, a SemVer `version`, `assets` keyed by target triple. A main feed also carries `apps` and `digests` URLs for the same immutable build. A reader treats a missing `schema` as 1 and refuses an unknown one; keep those fields when adding data.

`install.sh` rests on TLS to kendex.ai and github.com alone, on every run, because a fresh machine holds neither the release key nor minisign; `kendex update` is the path held to the key.

## Pre-releases

A tag carrying a SemVer pre-release identifier (`v1.0.0-rc1`) is published outright and marked pre-release. The workflow's `channel` job puts its `feed.json` on the fixed `prerelease` release. The feed keeps all download URLs on the immutable tagged release. A build whose own version is a candidate reads its updates from there (`crates/core/src/update_channel.rs`); a full release is never offered a candidate.

- The channel moves forward only (`tools/release-channel-point`): re-running an older tag leaves it alone, and a channel carrying assets it cannot read a version off stops the job for a person.
- The channel job's concurrency group drops repoints, never releases; push the newest tag again to move the channel to it.
- A machine on a candidate stays on candidates until moved by hand: cut one more candidate when the final ships, or reinstall it.

## Main channel

Each push to the `main` branch publishes all assets under an immutable `main-build-<run>-<attempt>-<commit>` tag. It then replaces the single `feed.json` pointer on the pre-release named `main` at the fixed `rolling-main` tag. The pointer names the command, app, and signed digest documents from that immutable build. `kendex update --git` and `install.sh --git` resolve the pointer once, so one install cannot combine two builds. A binary installed from it stays on this channel when it checks again. A newer main build can cancel an older build before publication. The serialized channel publisher authenticates the current and candidate build numbers. It refuses a candidate whose run number is not greater.

If the `rolling-main` release exists without `feed.json`, delete that empty release in GitHub Releases and rerun the newest main workflow. The publisher treats only a missing release as a fresh channel.

## Secrets

- `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`: required. Every lane bundles an updater-enabled target and signs its downloads, so an unset key fails the tag. The public half lives in two places that rotate together, `plugins > updater > pubkey` in `crates/app/tauri.conf.json` and `UPDATER_PUBLIC_KEY` in `crates/core/src/update_feed.rs`, held equal by `crates/app/tests/tauri_config.rs`; a private key that does not match signs the whole release under a key nothing trusts, and the app and `kendex update` refuse it.
- The seven `APPLE_*` secrets (certificate and its password, signing identity, team id, App Store Connect issuer, key id and key): all set, the mac lanes sign and notarize; none set, they build unsigned; a partial set fails the lane.
- Windows code signing is not configured.

## After publishing

Every package recipe carries per-release checksums; `packaging/README.md` § Per release lists what to bump, and § Publishing the workflows that carry the bump to the AUR and the Homebrew tap once it is on `main`.

## Local packaging

`cd crates/app && ../../ui/node_modules/.bin/tauri build` bundles deb and rpm anywhere; the AppImage step needs FUSE2 for linuxdeploy. Bundling signs updater artifacts, so set `TAURI_SIGNING_PRIVATE_KEY` or pass `--no-sign`.

The command inside each installer comes from an overlay under `crates/app/release/`, one per platform, passed as `--config release/<platform>.json`; each reads the command the lane staged under `target/bundle-cli/` (`tools/release-installer-check`'s header and the `Stage the command for the bundle` step in `release.yml` name the file per platform). The overlays stay out of `tauri.conf.json` because tauri-build copies `externalBin` and `resources` at compile time, and a plain `cargo build -p kendex-app` must need no staged command; `crates/app/tests/tauri_config.rs::release_only_bundle_settings_stay_out_of_the_base_config` holds it. To bundle with the command locally: `cargo build --release -p kendex-cli`, copy `target/release/kendex` to `target/bundle-cli/kendex`, then `tauri build --bundles deb,rpm --no-sign --config release/linux.json` from `crates/app`.
