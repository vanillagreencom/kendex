# Releasing

One workflow, tag-driven:

```
git tag v0.1.0 && git push origin v0.1.0
```

`.github/workflows/release.yml` builds on a native GitHub-standard runner
per target (Linux x86_64 and aarch64, macOS aarch64 and x86_64, Windows
x86_64; all free for a public repository) and publishes a **draft** GitHub
Release with:

- `kendex-<target>[.exe]` — the CLI binary, one per target. These are what
  `kendex update` downloads.
- The desktop app bundles Tauri produces per platform (deb/rpm/AppImage,
  dmg, NSIS installer), and the `.sig` Tauri writes beside each updater
  bundle. `kendex update` fetches `<AppImage>.sig` straight from the
  release, so it is a published asset and not only an input to `latest.json`.
- `latest.json` — the signed manifest the app's Update button installs
  from, one `{signature, url}` per platform. The publish job writes it from
  the `.sig` files the lanes staged, and names any platform whose signature
  never arrived and fails rather than publishing a release without it.
- `feed.json` — the update feed `kendex update` reads from
  `releases/latest/download/feed.json`. Publishing the draft makes the
  version "latest". New feeds carry `schema: 1`, a SemVer `version`, and an
  `assets` map of HTTPS URLs keyed by Rust target triple. During the schema-1
  transition, readers treat a missing `schema` as 1 but reject any explicit
  unknown value. Keep these fields when adding data.

Review the draft, then publish it. That is the release.

## Pre-releases

A tag whose version carries a SemVer pre-release identifier — `v1.0.0-rc1`
— runs the same workflow and takes two different turns at the end. It is
published outright, marked pre-release rather than left as a draft: a
draft's assets are unreachable, and a candidate nobody can download tests
nothing. Being marked pre-release is what keeps it to candidates, since
GitHub resolves `releases/latest` past every one of them.

That same resolution is why a candidate cannot reach the next one through
`releases/latest`. The publish job therefore also overwrites `latest.json`
and `feed.json` on a fixed `prerelease` release, and a build whose own
version is a candidate reads its updates from there
(`update_feed::feed_url_for`, which the app and `kendex update` both call
with their baked version). A shipped `1.0.0` is on the release channel and
is never offered a candidate; nothing on the machine selects this.

The channel keeps whatever the last candidate left on it, so a machine on
a candidate stays on candidates until it is moved to a full release by
hand. Cutting candidates for a release means cutting one more when the
final ships, or reinstalling those machines.

The workflow runs on tag push only, never on pull requests. Every lane
builds the CLI and the desktop app together; there is no build cache.
The Intel macOS lane uses `macos-15-intel`, supported until August 2027 —
revisit Intel support then.

## User-supplied gates

- **Updater signing** (`TAURI_SIGNING_PRIVATE_KEY`,
  `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` repo secrets): required. Every lane
  bundles an updater-enabled target, so an unset key fails bundling with
  "A public key has been found, but no private key" and the tag produces no
  release. The public half lives in two files that rotate together:
  `plugins > updater > pubkey` in `crates/app/tauri.conf.json` and
  `UPDATER_PUBLIC_KEY` in `crates/core/src/update_feed.rs`, held equal by
  `crates/app/tests/tauri_config.rs`. A private key that does not match
  builds a release the app refuses to install and that `kendex update`
  refuses to install the desktop app from; the CLI binary half of
  `kendex update` is unaffected.
- **macOS signing + notarization** (the seven `APPLE_*` repo secrets:
  certificate p12 + password, signing identity, team id, and the App
  Store Connect API issuer/key-id/key): all seven set, the two mac lanes
  Developer-ID-sign and notarize the bundles; none set, they build
  unsigned; a partial set fails the lane before bundling.
  Material and gotchas are recorded in the owner's dotfiles AGENTS.md.
- **Windows code signing**: not configured; add a certificate before
  distributing outside GitHub Releases.

## Local packaging

`cd crates/app && ../../ui/node_modules/.bin/tauri build` produces
deb/rpm anywhere; the AppImage step needs FUSE2 for linuxdeploy and may
fail on non-Debian hosts — the release runner covers it. Bundling signs
updater artifacts, so set `TAURI_SIGNING_PRIVATE_KEY` or pass `--no-sign`.

## Changelog

Entries are written one file at a time, under
`changelog.d/<section>/<name>.md` (`changelog.d/README.md` has the format).
Nothing edits `CHANGELOG.md` by hand: `tools/guard` refuses a line under
`## [Unreleased]` that HEAD does not already carry.

Before tagging, run `tools/changelog-collate`. It folds every fragment git
carries into `## [Unreleased]` under its section heading, in Keep a Changelog
order and filename order within a section, then deletes the fragments; no
fragments is a no-op. Exit codes follow the guard family: 0 clean, 1 a
fragment the format refuses, 2 could not run — and nothing is written until
every fragment passes, so `CHANGELOG.md` is replaced whole or not at all. It
reads each fragment from the working tree, so it also refuses a `changelog.d`
the index and the disk disagree about, rather than publishing an unstaged
edit and deleting it. A nonzero exit halts the release: read the message, fix
the fragment or `CHANGELOG.md`, run it again. Then rename `## [Unreleased]` to
`## [X.Y.Z] - YYYY-MM-DD` and open a fresh empty one, which leaves the guard
nothing gained to refuse.

`CHANGELOG_COLLATE=1` declares a deliberate write under `## [Unreleased]`.
It is needed only when the guard or the commit runs while the collated
entries are still under that heading.

## Version bumps

The workspace version in `Cargo.toml` and `crates/app/tauri.conf.json`
must match the tag (minus the `v`).
