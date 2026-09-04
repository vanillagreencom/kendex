# Releasing

The procedure is the `app-deploy` skill (`.agents/skills/app-deploy/SKILL.md`): bump the versions, collate the changelog, commit under the collate declaration, tag, review the draft, publish. `.github/workflows/release.yml` runs on the tag push: one native runner per target, the tag checked against the version the built CLI reports, a full release published as a draft and a pre-release outright. This page holds what neither states.

## What a release carries

- `kendex-<target>[.exe]` and its `.sig`: the command, which `kendex update` installs only as a pair; a lane that signed nothing fails the tag.
- The app bundles per platform (deb, rpm, AppImage, dmg, NSIS installer) and the `.sig` beside each updater bundle; `kendex update` fetches the AppImage's signature straight from the release.
- `latest.json`: the manifest the app's Update button installs from, one `{signature, url}` per platform; a platform whose signature never reached the publish job fails it by name.
- `digests-<target>.json` and its `.sig`: the version, the target and the SHA-256 of that lane's downloads, signed under the release key (`tools/release-digests`). A signature proves bytes, not which release they are, so both shells read this document from the channel they read their manifest from and install nothing whose hash it does not name.
- `feed.json`: what `kendex update` reads at `releases/latest/download/feed.json`; `schema: 1`, a SemVer `version`, `assets` keyed by target triple. A reader treats a missing `schema` as 1 and refuses an unknown one; keep those fields when adding data.

`install.sh` rests on TLS to kendex.ai and github.com alone, on every run, because a fresh machine holds neither the release key nor minisign; `kendex update` is the path held to the key.

## Pre-releases

A tag carrying a SemVer pre-release identifier (`v1.0.0-rc1`) is published outright and marked pre-release, and the workflow's `channel` job repoints the fixed `prerelease` release's `latest.json`, `feed.json` and digests at it. A build whose own version is a candidate reads its updates from there (`crates/core/src/update_channel.rs`); a full release is never offered a candidate.

- The channel moves forward only (`tools/release-channel-point`): re-running an older tag leaves it alone, and a channel carrying assets it cannot read a version off stops the job for a person.
- The channel job's concurrency group drops repoints, never releases; push the newest tag again to move the channel to it.
- A machine on a candidate stays on candidates until moved by hand: cut one more candidate when the final ships, or reinstall it.

## Secrets

- `TAURI_SIGNING_PRIVATE_KEY` and `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`: required. Every lane bundles an updater-enabled target and signs its downloads, so an unset key fails the tag. The public half lives in two places that rotate together, `plugins > updater > pubkey` in `crates/app/tauri.conf.json` and `UPDATER_PUBLIC_KEY` in `crates/core/src/update_feed.rs`, held equal by `crates/app/tests/tauri_config.rs`; a private key that does not match signs the whole release under a key nothing trusts, and the app and `kendex update` refuse it.
- The seven `APPLE_*` secrets (certificate and its password, signing identity, team id, App Store Connect issuer, key id and key): all set, the mac lanes sign and notarize; none set, they build unsigned; a partial set fails the lane.
- Windows code signing is not configured.

## After publishing

Every package recipe carries per-release checksums; `packaging/README.md` § Per release lists what to bump and where to push.

## Local packaging

`cd crates/app && ../../ui/node_modules/.bin/tauri build` bundles deb and rpm anywhere; the AppImage step needs FUSE2 for linuxdeploy. Bundling signs updater artifacts, so set `TAURI_SIGNING_PRIVATE_KEY` or pass `--no-sign`.
