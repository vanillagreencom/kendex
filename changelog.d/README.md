# changelog.d

One CHANGELOG entry per file. Two branches never write the same
`CHANGELOG.md` line, so neither is ejected from the merge queue by the other.

- **Path**: `changelog.d/<section>/<name>.md`, a real file and not a symlink.
  The section is one of `added`, `changed`, `deprecated`, `removed`, `fixed`,
  `security`. Name the file after the issue: `changelog.d/fixed/<issue>.md`.
  Anything else tracked under `changelog.d`, this README excepted, is refused
  — nothing would ever fold it in.
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

The format has one judge: the growth-guards `changelog-entries` lane, pointed
at this directory by `GROWTH_GUARDS_CHANGELOG_PATHS`. It runs at every commit,
and `tools/changelog-collate` asks it which paths are fragments and which
section each is in before folding anything in — the collator decides none of
that itself. Exit codes follow the guard family: 0 clean, 1 a fragment the
judge refuses, 2 could not run.

That same lane refuses any line under `## [Unreleased]` in `CHANGELOG.md`
that HEAD does not already carry. `GROWTH_GUARDS_CHANGELOG_COLLATE=1`
declares a deliberate write there. The release commit carries it for a second
reason too: it is what makes `CHANGELOG.md` count as that commit's own entry,
once the collator has deleted the fragments (`docs/RELEASING.md`).

A commit touching `crates/` or `ui/` without one of these files is refused by
the growth-guards `commit-msg` lane, which reads
`GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS`; `[no-changelog]` in the subject is
the escape.
