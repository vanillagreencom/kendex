# Changelog fragments

## Release standard

This standard applies to kendex, its apps, Pi packages, GitHub releases, and the AUR and Homebrew recipes that pin those releases.

- Write each kendex consumer change as one list item in `changelog.d/<section>/<name>.md`. Use `added`, `changed`, `deprecated`, `removed`, `fixed`, or `security`. State the outcome.
- Start a breaking-change item with `- **Breaking:**`. Name the break and include its migration note in that item.
- Collate accepted fragments into `CHANGELOG.md` at release. Move the pending entries under the new version heading.
- Pi packages keep their channel record in their own `CHANGELOG.md` under `### Unreleased`. A package major needs a `- **Breaking:**` entry there. Rename the heading to the new version at release, keeping the entry.
- Choose the bump from the changes: patch for a fix, minor for an additive change, major only with a Breaking call-out that names the break. A major bump of kendex or an app also needs owner approval.
- Before 1.0, add no migration shims. From 1.0, a changed schema or setting format keeps reading the old form with a warning for at least one minor release.
- Package-manager recipes pin the published kendex version. They do not choose a separate bump or write separate release notes.

## Checks

- Fragment sections, content shape, and length limits are defined in [the changelog check](../skills/commit-guards/CHECKS.md#changelog-entries).
- Follow [the release procedure](../.agents/skills/app-deploy/SKILL.md) to combine accepted fragments into the pending release section of `CHANGELOG.md`. The collator validates the destination before writing and deletes the fragments after replacement.
- Ordinary checks permit wording and heading edits in the combined release notes.
- The [major-bump check](../skills/commit-guards/CHECKS.md#major-bumps) compares the prior version with the staged version after the release edits. It accepts the retained call-out after collation or a package heading rename. The app JSON version represents the kendex release; `crates/cli/tests/compat.rs` checks that it equals the Cargo workspace version.
- The `commit-msg` lane requires a fragment for changes under the configured consumer paths. `[no-changelog]` waives it when the change has no consumer effect. A record change counts under the release declaration.
