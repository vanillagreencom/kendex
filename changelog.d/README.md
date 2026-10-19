# Changelog fragments

## Release standard

This standard applies to kendex, its apps, Pi packages, GitHub releases, and the AUR and Homebrew recipes that pin those releases.

- Write each kendex program change, under `crates/`, `ui/`, `packaging/` or the CLI, as one list item in `changelog.d/<section>/<name>.md`. Use `added`, `changed`, `deprecated`, `removed`, `fixed`, or `security`. State the outcome.
- Compatible catalog content writes no kendex fragment and causes no kendex release. Consumers receive it from main through [the existing refresh route](../docs/architecture/merge-rail.md).
- The kendex version counts program changes only. Changes to [the shared refresh workflow and code it executes from its release checkout](../docs/architecture/merge-rail.md) remain program changes and need a program fragment and release. Release a merged fix to that code on the same day, in that day's batch release.
- Catalog content that needs new engine behavior follows [the catalog compatibility procedure](../.agents/skills/app-deploy/SKILL.md#catalog-compatibility). The catalog job's package-suites leg runs the suites a Linux CI shard gives a kendex, in changed shell packages whose scripts call kendex, with the latest released engine on merge groups. Release engine support first, then raise `min_kendex` before merging that content.
- Skills, hooks and agents carry no version, and a skill's `SKILL.md` states no `metadata.version`.
- Start a breaking-change item with `- **Breaking:**` and name the break. Its migration note is the `You do:` line the next bullet sets out.
- A program entry in `changed/`, `removed/` or `deprecated/`, and every `- **Breaking:**` item, that changes a consumer's file format, a setting, or what a command does with the consumer's files ends with one `You do:` line. Use `You do: nothing`, adding `(migrated on apply)` when a kendex run rewrites the consumer's files itself, or `You do: <the exact step>`, one sentence a consumer can follow without opening anything else. Any other entry whose reader must act uses the exact-step form. An entry that needs no action and changes none of those things carries no line. Put the line in its own paragraph, after a blank line and indented under the item, so the changelog and releases page show it on its own line. A single-newline continuation joins the sentence above it. Apply this rule to fragments written after it merges.
- Collate accepted program fragments into `CHANGELOG.md` at release under their sections. Move the pending entries under the new version heading.
- Pi packages keep their channel record in their own `CHANGELOG.md` under `### Unreleased`. A package major needs a `- **Breaking:**` entry there. Rename the heading to the new version at release, keeping the entry.
- Choose the version and the fragment section by [the release-version rule](../skills/commit-guards/CHECKS.md#release-versions).
- From 1.0, a change that would break a consumer of the kendex program keeps the old form working, with one warning that names the new form, for at least one minor release. Its removal waits for a major release. A Pi package marks its own break in its independent record and uses its own major version.
- The consumer refresh route's old forms, the step 6 rows of the consumer refresh design's deletion list (the design is attached to KEN-2601), are removed one minor release after every consumer runs the shared refresh workflow, not at a major release. Before Build B merges, each consumer's default branch holds the adopter that reads the new form (that design's migration order, step 3), so no reader of the old form remains.
- Package-manager recipes pin the published kendex version. They do not choose a separate bump or write separate release notes.

## Checks

- Fragment sections and content shape are defined in [the changelog check](../skills/commit-guards/CHECKS.md#changelog-entries).
- Follow [the release procedure](../.agents/skills/app-deploy/SKILL.md) to combine accepted fragments into the pending release section of `CHANGELOG.md`. The collator validates the destination before writing and deletes the fragments after replacement.
- Ordinary checks permit wording and heading edits in the combined release notes.
- The [version-bump check](../skills/commit-guards/CHECKS.md#version-bumps) compares the prior version with the staged version after the release edits. That section states which bumps it refuses and which entries it reads. The app JSON version represents the kendex release; `crates/cli/tests/compat.rs` checks that it equals the Cargo workspace version.
- The `commit-msg` lane requires a fragment for changes under the configured consumer paths. `[no-changelog]` waives it when the change has no consumer effect. A record change counts under the release declaration.
