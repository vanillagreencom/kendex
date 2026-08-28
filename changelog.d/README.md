# changelog.d

One CHANGELOG entry per file. Two branches never write the same
`CHANGELOG.md` line, so neither is ejected from the merge queue by the other.

- **Path**: `changelog.d/<section>/<name>.md`, a real file and not a symlink.
  The section is one of `added`, `changed`, `deprecated`, `removed`, `fixed`,
  `security`. Name the file after the issue: `changelog.d/fixed/ken-624.md`.
- **Content**: exactly one Markdown list item — the first non-blank line opens
  with `- `, every later line indents under it, and the whole entry runs at
  most three lines. Everything `AGENTS.md` says about a CHANGELOG entry holds:
  it is for consumers, it states an outcome, a **Breaking:** change carries
  its migration note inline.
- **Release**: `tools/changelog-collate` folds every fragment git carries into
  `## [Unreleased]` in `CHANGELOG.md` under its section heading, in Keep a
  Changelog order and filename order within a section, then deletes the
  fragments. Repeated headings for one section merge into the first.

`tools/changelog-collate --check` judges the fragments and writes nothing;
`tools/guard` runs it, so the format has one judge. Exit codes follow the
guard family: 0 clean, 1 a fragment the format refuses, 2 could not run.

`tools/guard` also refuses a hand-written line under `## [Unreleased]`.
`CHANGELOG_COLLATE=1` releases that rule for the release commit that carries
the collator's write.
