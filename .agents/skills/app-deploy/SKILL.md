---
name: app-deploy
description: Release a new kendex version — bump versions, finalize the changelog, tag per docs/RELEASING.md. Use when asked to cut, ship, or release a version.
---

# Release kendex

1. Bump the workspace `version` in `Cargo.toml` and the version in
   `crates/app/tauri.conf.json` — both must equal the tag minus the `v`,
   or the update feed no-ops or loops.
2. In `CHANGELOG.md`, move the `Unreleased` entries under a new
   `## [<version>] - <date>` heading; confirm every breaking change
   carries its **Breaking** call-out and migration note.
3. Commit, tag `v<version>`, push the tag. CI builds each target and
   publishes a draft GitHub Release with CLI binaries, app bundles, and
   `feed.json` (details: `docs/RELEASING.md`).
4. Review the draft, then publish it — publishing is what makes the
   version "latest" for self-update.

Distro packaging (Arch, Fedora, Ubuntu…) would hook in after the draft
exists; no such pipelines are built yet.
