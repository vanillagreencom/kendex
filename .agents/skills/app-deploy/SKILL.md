---
name: app-deploy
description: "Load when asked to cut, ship, or release a kendex version."
summary: "Releases a kendex version: bumps versions, finalizes the changelog, tags per docs/RELEASING.md."
---

# Release kendex

1. Bump the workspace `version` in `Cargo.toml` and the version in
   `crates/app/tauri.conf.json` — both must equal the tag minus the `v`,
   or the update feed no-ops or loops.
2. Run `tools/changelog-collate` to fold the `changelog.d` fragments into
   `CHANGELOG.md`'s `Unreleased`. A nonzero exit halts the release: read its
   message, fix the fragment or `CHANGELOG.md`, run it again. Then move those
   entries under a new `## [<version>] - <date>` heading, leaving an empty
   `## [Unreleased]` above it; confirm every breaking change carries its
   **Breaking** call-out and migration note.
3. Commit, tag `v<version>`, push the tag. CI builds each target and
   publishes a draft GitHub Release with CLI binaries, app bundles, and
   `feed.json` (details: `docs/RELEASING.md`).
4. Review the draft, then publish it — publishing is what makes the
   version "latest" for self-update.

Distro packaging (Arch, Fedora, Ubuntu…) would hook in after the draft
exists; no such pipelines are built yet.
