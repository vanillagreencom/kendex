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

Choose the version by the [release-version rule](../../../skills/commit-guards/CHECKS.md#release-versions). Follow the [release standard](../../../changelog.d/README.md#release-standard) for breaking changes and compatibility.

1. From a clean index and working tree, set `COMMIT_GUARDS_CHANGELOG_COLLATE=1` in the environment and run `.agents/skills/commit-guards/scripts/changelog-entries --collate`. It folds the `changelog.d` fragments into `CHANGELOG.md`'s `Unreleased`. A nonzero exit halts the release: fix the cause before retrying.
2. Bump the workspace `version` in `Cargo.toml` and the version in `crates/app/tauri.conf.json`. Both must equal the tag minus the `v`, or the update feed no-ops or loops. Move the collated entries under a new `## [<version>] - <date>` heading, leaving an empty `## [Unreleased]` above it. The collator writes no link footer: point `[Unreleased]:` at `compare/v<version>...HEAD` and add `[<version>]: https://github.com/vanillagreencom/kendex/releases/tag/v<version>` above the previous version's line.
3. Commit with `COMMIT_GUARDS_CHANGELOG_COLLATE=1`. That declaration is what makes `CHANGELOG.md` count as the entry this commit owes for the version bump under `crates/`, whose fragments the collator just deleted, and the `commit-msg` lane refuses the commit without it. Merge the release pull request with the github skill's `pr-merge`, which takes the merge queue or, where the queue is all it would bypass, the admin route. A fragment that merges to `main` before it lands ships in its merge commit uncollated, so `git ls-tree -r --name-only <merge-commit> changelog.d` must list only `changelog.d/README.md`. For any other entry, collate it under `## [<version>]` in a follow-up commit, merge that the same way and check its merge commit; an entry that changes the version the [release-version rule](../../../skills/commit-guards/CHECKS.md#release-versions) gives instead returns the release to step 2; the tag waits until a merge commit passes. Then tag that merge commit on `main` `v<version>`, never the branch commit, and push the tag. CI builds each target and publishes a draft GitHub Release with CLI binaries, app bundles, and `feed.json` (details: `docs/RELEASING.md`).
4. Review the draft, then publish it. Publishing is what makes the version "latest" for self-update. A stable release then needs its major tag `v<major>` moved to the commit `v<version>` tags, or created there for a new major, because consumers' shared refresh workflow runs the release that tag names. The operator moves it: the master session, under the organization-owner bypass of the major-tag ruleset, when it receives `published v<version> at <SHA>`, `<SHA>` being that commit (`git rev-parse v<version>^{commit}`); the owner only when no master runs. A lane moves no major tag: after publishing, it sends that notice to its overseer with `lane-mail notice`, and the overseer relays it with `lane-mail notice --item overseer --to owner`, which the master session reads while it holds that overseer's mailbox ([the master hold](../../../skills/slack/README.md#the-master-hold)) and which reaches the owner when no master runs. Until the tag moves, every shared-workflow refresh run on that major prints `refresh-warning=behind-release`; a new major's first release warns nowhere, because each run compares only its caller's major.
5. Once the release is published, bump the per-release pins `packaging/README.md` § Per release lists: `version` and the checksums in the Homebrew formula and cask, and `pkgver` and `sha256sums` in the Arch recipes where they are not already current. Landing that bump on `main` is the push that runs the two publishers below.


Distro packaging runs itself once the recipes reach `main`: `.github/workflows/publish-aur.yml` (`tools/publish-aur`) pushes the four Arch packages `kendex`, `kendex-bin`, `kendex-git` and `kendex-cli-git` to the AUR, and `.github/workflows/publish-homebrew.yml` (`tools/publish-homebrew`) pushes the formula and cask to the Homebrew tap. Both run on every push to `main` touching their recipes, their tools or their workflow. The AUR publisher defers a package whose pinned downloads are not up yet and lands it when the release is published; the Homebrew push does not check, so a Homebrew version bump must not reach `main` before its release is published (`packaging/README.md` § Publishing).
