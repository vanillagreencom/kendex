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
  dmg, NSIS installer).
- `feed.json` — the update feed `kendex update` reads from
  `releases/latest/download/feed.json`. Publishing the draft is what makes
  a version "latest"; until then existing installs see nothing.

Review the draft, then publish it. That is the release.

The workflow runs on tag push only, never on pull requests. Every lane
builds the CLI and the desktop app together, so no lane is spent on the
CLI alone; there is no build cache, because the only release-profile cache main
saves (catalog-check's x86_64 CLI build) is keyed to that job and built
without `--target`, so no release lane could restore it.
The Intel macOS lane uses `macos-15-intel`, the last Intel image GitHub
offers, supported until August 2027 — revisit Intel support then.

## User-supplied gates

- **Updater signing** (`TAURI_SIGNING_PRIVATE_KEY`,
  `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` repo secrets): without them the
  desktop bundles build unsigned and no Tauri updater artifacts are
  produced. CLI self-update is unaffected.
- **macOS notarization / Windows code signing**: not configured; add
  certificates before distributing outside GitHub Releases.

## Local packaging

`cd crates/app && ../../ui/node_modules/.bin/tauri build` produces
deb/rpm anywhere; the AppImage step needs FUSE2 for linuxdeploy and may
fail on non-Debian hosts — the release runner covers it.

## Version bumps

The workspace version in `Cargo.toml` and `crates/app/tauri.conf.json`
must match the tag (minus the `v`) — `kendex update` compares its build
version against the feed, so a mismatched tag ships a feed that either
no-ops or loops.
