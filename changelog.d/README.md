# Changelog fragments

Write each consumer change in `changelog.d/<section>/<name>.md`. State its outcome. Put migration instructions in a breaking-change entry.

- Fragment sections, content shape, and length limits are defined in [the changelog check](../skills/growth-guards/CHECKS.md#changelog-entries).
- `.agents/skills/growth-guards/scripts/changelog-entries --collate` combines accepted fragments into the pending release section of `CHANGELOG.md`. It validates the destination before writing and deletes the fragments after replacement.
- Ordinary checks permit wording and heading edits in the combined release notes.
- The `commit-msg` lane requires a fragment for changes under the configured consumer paths. `[no-changelog]` waives it when the change has no consumer effect. A record change counts under the release declaration.
