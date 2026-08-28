# changelog.d

One CHANGELOG entry per file. Two branches never write the same
`CHANGELOG.md` line, so neither is ejected from the merge queue by the other.

- **Path**: `changelog.d/<section>/<name>.md`. The section is one of `added`,
  `changed`, `deprecated`, `removed`, `fixed`, `security`. Name the file after
  the issue: `changelog.d/fixed/ken-624.md`.
- **Content**: the Markdown list item the entry becomes — a leading `- `,
  continuation lines indented, at most three lines. Everything `AGENTS.md`
  says about a CHANGELOG entry holds: it is for consumers, it states an
  outcome, a **Breaking:** change carries its migration note inline.
- **Release**: `tools/changelog-collate` folds every fragment into
  `## [Unreleased]` in `CHANGELOG.md` under its section heading, in Keep a
  Changelog order and filename order within a section, then deletes the
  fragments. Repeated headings for one section merge into the first.

`tools/guard` refuses a hand-written line under `## [Unreleased]`.
`CHANGELOG_COLLATE=1` releases that rule for the release commit that carries
the collator's write.
