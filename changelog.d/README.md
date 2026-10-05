# Changelog fragments

## Release standard

This standard applies to kendex, its apps, Pi packages, GitHub releases, and the AUR and Homebrew recipes that pin those releases.

- Write each kendex program change, under `crates/`, `ui/`, `packaging/` or the CLI, as one list item in `changelog.d/<section>/<name>.md`. Use `added`, `changed`, `deprecated`, `removed`, `fixed`, or `security`. State the outcome.
- Write each catalog package change, a skill, hook or agent, as one list item in `changelog.d/<package>/<section>/<name>.md`, `<package>` being its directory or file name. One entry names one package.
- The kendex version counts program changes only. A package entry never moves the kendex version or causes a kendex release, whatever its section or Breaking mark.
- Packages version independently. A change to a skill raises its own `metadata.version` in that commit, by the release-version rule. Hooks and agents carry no version.
- Start a breaking-change item with `- **Breaking:**`. Name the break and include its migration note in that item.
- Collate accepted fragments into `CHANGELOG.md` at release. Program entries fold under their sections; package entries fold under `### Packages`, one `#### <package> <version>` heading per package with the version it states at release. Move the pending entries under the new version heading.
- Pi packages keep their channel record in their own `CHANGELOG.md` under `### Unreleased`. A package major needs a `- **Breaking:**` entry there. Rename the heading to the new version at release, keeping the entry.
- Choose the version and the fragment section by [the release-version rule](../skills/commit-guards/CHECKS.md#release-versions).
- From 1.0, a change that would break a consumer of the kendex program keeps the old form working, with one warning that names the new form, for at least one minor release. Its removal waits for a major release. A package marks its own break with its own major.
- The consumer refresh route's old forms, the step 6 rows of the consumer refresh design's deletion list (the design is attached to KEN-2601), are removed one minor release after every consumer runs the shared refresh workflow, not at a major release. Before Build B merges, each consumer's default branch holds the adopter that reads the new form (that design's migration order, step 3), so no reader of the old form remains.
- Package-manager recipes pin the published kendex version. They do not choose a separate bump or write separate release notes.

## Checks

- Fragment sections and content shape are defined in [the changelog check](../skills/commit-guards/CHECKS.md#changelog-entries).
- Follow [the release procedure](../.agents/skills/app-deploy/SKILL.md) to combine accepted fragments into the pending release section of `CHANGELOG.md`. The collator validates the destination before writing and deletes the fragments after replacement.
- Ordinary checks permit wording and heading edits in the combined release notes.
- The [version-bump check](../skills/commit-guards/CHECKS.md#version-bumps) compares the prior version with the staged version after the release edits. That section states which bumps it refuses and which entries it reads. The app JSON version represents the kendex release; `crates/cli/tests/compat.rs` checks that it equals the Cargo workspace version.
- The `commit-msg` lane requires a fragment for changes under the configured consumer paths. `[no-changelog]` waives it when the change has no consumer effect. A record change counts under the release declaration.
