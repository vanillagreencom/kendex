---
description: Cut a kendex release — version bump, tag, draft review — per docs/RELEASING.md
argument-hint: "[patch|minor|major]"
---
Cut a kendex release. Optional bump: `$ARGUMENTS` (default: patch; minor when
`changelog.d/added/` holds a fragment or CHANGELOG's Unreleased section has an
Added entry; major only when asked).

`docs/RELEASING.md` is the procedure; this prompt only sequences it.

## Rules
- Release from `main`, clean, equal to `origin/main`. Dirty or untracked
  files: stage only what should ship, commit first, ask about anything
  ambiguous or private-looking. Never `git add -A`, never stash.
- One version in three places, equal to the tag minus `v`: `Cargo.toml`
  `[workspace.package].version`, `crates/app/tauri.conf.json` `version`,
  and `Cargo.lock` (run `cargo build -q` after the bump).
- Pi extension npm versions are not touched here (`/npm-deploy`).
- Never move an existing tag.

## Steps
1. `git fetch origin && git status --short` — must be clean and at
   `origin/main`. `gh release list --limit 1` — the last tag.
2. `git log --oneline <last-tag>..HEAD` — confirm there is something to
   ship; finalize `CHANGELOG.md`: run
   `.agents/skills/growth-guards/scripts/changelog-entries --collate` to fold
   the `changelog.d` fragments into `## [Unreleased]`, rename that heading to
   `## [X.Y.Z] - YYYY-MM-DD`, and open a fresh empty `## [Unreleased]`. A
   nonzero exit halts the release: read its message, fix the fragment or
   `CHANGELOG.md`, run it again.
3. Bump the three version sites; `cargo build -q`; `tools/guard`.
4. Commit with exactly `Cargo.toml Cargo.lock crates/app/tauri.conf.json
   CHANGELOG.md changelog.d`, carrying the collation declaration:
   `GROWTH_GUARDS_CHANGELOG_COLLATE=1 git commit -m "chore(release): vX.Y.Z"`.
   That declaration is what makes `CHANGELOG.md` count as this commit's
   changelog entry — the version bump under `crates/` obliges one and the
   fragments were just deleted — so the `commit-msg` lane refuses the commit
   without it. Then push through the normal PR flow if branch protection
   requires it, else push `main`.
5. Tag the MERGED commit, never the local branch: after the bump is on
   `origin/main`, run `git fetch origin`, confirm `git log -1 origin/main`
   is the bump commit, then `git tag vX.Y.Z origin/main && git push
   origin vX.Y.Z`. The tag starts
   `.github/workflows/release.yml`, which builds every target and creates a
   **draft** release. Do not call `gh release create`.
6. `gh run watch` the release workflow. When it finishes, `gh release view
   vX.Y.Z` — the draft must list one `kendex-<target>` per target, the app
   bundles, and `feed.json`. Missing asset → fix the workflow, re-tag only
   after deleting the failed draft and tag.
7. Publish the draft: `gh release edit vX.Y.Z --draft=false`. Confirm
   `releases/latest/download/feed.json` serves the new version. A
   pre-release tag (`v1.0.0-rc1`) skips this — the workflow publishes it
   and repoints the `prerelease` channel itself (docs/RELEASING.md).
8. Report: tag, assets, anything skipped.
