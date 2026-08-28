# changelog.d

One CHANGELOG entry per file. Two branches never write the same
`CHANGELOG.md` line, so neither is ejected from the merge queue by the other.

- **Path**: `changelog.d/<section>/<name>.md`, a real file and not a symlink.
  The section is one of `added`, `changed`, `deprecated`, `removed`, `fixed`,
  `security`. Name the file after the issue: `changelog.d/fixed/<issue>.md`.
- **Content**: exactly one Markdown list item — the first non-blank line opens
  with `- ` and says something, every later line indents under it, and the
  whole entry runs at most 200 characters, whitespace runs collapsed, however
  it is wrapped and however many indented paragraphs it holds. Everything
  `AGENTS.md` says about a CHANGELOG entry holds: it is for consumers, it
  states an outcome, and a **Breaking:** change carries its migration note
  inline.
- **Release**: `tools/changelog-collate` folds every fragment git carries into
  `## [Unreleased]` in `CHANGELOG.md` under its section heading, in Keep a
  Changelog order and filename order within a section, then deletes the
  fragments. Two headings for one section collapse into a single heading,
  emitted in Keep a Changelog order and carrying their blocks in file order.

`tools/changelog-collate --check` judges the fragments and writes nothing;
`tools/guard` runs it, so the format has one judge. Exit codes follow the
guard family: 0 clean, 1 a fragment the format refuses, 2 could not run. The
length has one judge too, the growth-guards `changelog-entries` lane, pointed
at this directory by `GROWTH_GUARDS_CHANGELOG_PATHS`.

`tools/guard` refuses any line under `## [Unreleased]` that HEAD does not
already carry. `CHANGELOG_COLLATE=1` declares a deliberate write there,
needed only when the guard or the commit runs while collated entries are
still under that heading.
