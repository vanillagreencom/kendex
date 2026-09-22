---
name: app-deploy
description: "Load when asked to cut, ship, or release a kendex version."
summary: "Releases a kendex version: bumps versions, finalizes the changelog, tags per docs/RELEASING.md."
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Release kendex

1. From a clean index and working tree, set `COMMIT_GUARDS_CHANGELOG_COLLATE=1` in the environment and run `.agents/skills/commit-guards/scripts/changelog-entries --collate`. It folds the `changelog.d` fragments into `CHANGELOG.md`'s `Unreleased`. A nonzero exit halts the release: fix the cause before retrying.
2. Bump the workspace `version` in `Cargo.toml` and the version in `crates/app/tauri.conf.json`. Both must equal the tag minus the `v`, or the update feed no-ops or loops. Move the collated entries under a new `## [<version>] - <date>` heading, leaving an empty `## [Unreleased]` above it. Confirm every breaking change carries its **Breaking** call-out and migration note.
3. Commit with `COMMIT_GUARDS_CHANGELOG_COLLATE=1`. That declaration is what makes `CHANGELOG.md` count as the entry this commit owes for the version bump under `crates/`, whose fragments the collator just deleted, and the `commit-msg` lane refuses the commit without it. Then tag `v<version>` and push the tag. CI builds each target and publishes a draft GitHub Release with CLI binaries, app bundles, and `feed.json` (details: `docs/RELEASING.md`).
4. Review the draft, then publish it. Publishing is what makes the version "latest" for self-update.

Distro packaging runs itself once the recipes reach `main`: `.github/workflows/publish-aur.yml` (`tools/publish-aur`) pushes the four Arch packages `kendex`, `kendex-bin`, `kendex-git` and `kendex-cli-git` to the AUR, and `.github/workflows/publish-homebrew.yml` (`tools/publish-homebrew`) pushes the formula and cask to the Homebrew tap. Both run on every push to `main` touching their recipes, tool or workflow. The AUR publisher defers a package whose pinned downloads are not up yet and lands it when the release is published; the Homebrew push does not check, so a Homebrew version bump must not reach `main` before its release is published (`packaging/README.md` § Publishing).
