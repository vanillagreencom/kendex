---
description: Cut a kendex release — version bump, tag, draft review — per the app-deploy skill
argument-hint: "[patch|minor|major]"
---
Load the `app-deploy` skill (`.agents/skills/app-deploy/SKILL.md`) and follow its complete current `workflows/release.md`. Optional bump: `$ARGUMENTS` (`patch`, `minor` or `major`); default to the bump the pending program entries require under `changelog.d/README.md` § Release standard.

## Rules

- Release from `main`, clean, equal to `origin/main`. Dirty or untracked files: stage only what should ship, commit first, ask about anything ambiguous or private-looking. Never `git add -A`, never stash.
- One version in three places, equal to the tag minus `v`: `Cargo.toml` `[workspace.package].version`, `crates/app/tauri.conf.json` `version`, and `Cargo.lock` (run `cargo build -q` after the bump).
- Pi extension npm versions are not touched here (`/npm-deploy`).
- Never move an existing version tag. Follow the skill's Major tag and Secrets authority boundaries.

## Release workflow

Use the skill's workflow for collation, the release pull request, merged-source proof, dispatch, publication and follow-up. Dispatch builds the proven merged commit on `main` and creates its version tag. Do not push a tag to start the release or call `gh release create`.

Keep the prior-tag lookup and file comparison from the workflow's prerequisites. Stop on a failed comparison or no pending file change. Stage exactly `Cargo.toml Cargo.lock crates/app/tauri.conf.json CHANGELOG.md changelog.d` for the release commit, with the workflow's collation declaration.

Check the workflow's declared assets before publication. Follow its retry route on failure; do not delete a version tag to re-tag it. Confirm the stable update feed or pre-release channel through the skill's applicable route.

Report the tag, release commit, workflow run, assets, publication and follow-up outcomes, and anything skipped.
