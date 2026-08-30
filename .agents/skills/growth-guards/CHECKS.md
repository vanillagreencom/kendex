# growth-guards checks

What each check bans and how it is scoped. The package overview, the
invocation forms and the git hooks are in [README.md](README.md); every
configuration key is in [SKILL.md](SKILL.md).

## todo-ban

Flat ban on work markers in first-party tracked files — the words TODO,
FIXME, HACK, XXX in comment-marker shapes, no baseline. Prose that quotes or
names a marker does not fire; matching is case-sensitive. Do the work now or
track it and delete the marker; vendored trees go in excludes with a reason.
A marker IMMEDIATELY preceded by a backtick, a quote, or joined text is out
of scope in every lane — that adjacency is what lets prose and code quote
the words. A space between them exempts nothing.

- `--staged` — only the lines the staged diff ADDS (the commit lane). A
  marker anywhere else in the index belongs to whoever committed it, and
  blocking every commit in the repository on it is how one fixture stops a
  whole team. Renames are held to exact content, as byte-ceiling holds
  them: a pure move adds no line, while a file that moved and changed is
  read whole. `git diff --cached` supplies the base, so a repository with
  no commits yet judges its first commit like any other. Content decides
  what it reads and an attribute never does: an attributes rule cannot hide
  a path from it, while a blob whose first block carries a NUL is named as
  unmeasured, the asset it is.
- (default) — every tracked file, read from the index. This is the CI
  scope, and the only one that sees a marker no commit is touching. Content
  governs here as it does at commit — the shared index scan forces text, so
  an attributes rule cannot put a file outside it, and sniffs each file it
  names for a NUL in its leading bytes, so an asset is not decoded. A named
  path either scope could not decode is carried into the verdict as
  unmeasured, never folded into a clean total.

## byte-ceiling

Tracked files a change puts over the ceiling (default 200 KB, KB = 1024
bytes) fail. Growth-oriented like size-ratchet — default modes gate no
legacy file a change leaves alone, so adoption needs no cleanup first.
Lockfiles are exempt built-in by exact basename; declared asset trees go in
excludes with a reason.

- `--staged` (default) — files added, changed, or type-changed in the staged
  diff (pre-commit). Editing a committed file past the ceiling puts the same
  bytes in history as adding one, so the staged lane judges both; rename
  detection is held to exact content, so a file that moved and grew is
  judged at its new path.
- `--base REF` — files added since the merge-base with REF (CI on a PR).
- `--all` — every tracked file (audits; pair with excludes rows).

## suppression-ban

Two gates, both scanned language-scoped by pathspec, so docs and scripts
that quote a pragma never fire. **Blanket suppressions fail flat** —
module/crate-wide rust `#![allow(...)]` inner attributes, file-level
`# ruff: noqa` / `# flake8: noqa`, the bare `/* eslint-disable */` block
form, `//nolint` bare or `:all`, and — over biome's JS/TS family plus CSS
and JSONC — `biome-ignore-all`, unscoped `biome-ignore-start`, and
rule-less `biome-ignore lint` / group forms. A per-line suppression naming
its lint with a stated reason stays legal (`# noqa: E501`,
`// eslint-disable-next-line rule -- why`, `//nolint:gosec // why`,
`// biome-ignore lint/<group>/<rule>: why`, a per-item rust attribute).

**Bare-allow ratchet (Rust)** — reasonless `#[allow(dead_code)]` /
`#[allow(unused…)]` attributes are counted per file; an attribute carrying
`reason = "..."` does not count. The count runs over the family's shared
index listing, so an attributes row can neither drop a bare allow out of it
nor let an asset into it. Legacy counts freeze in a tighten-only
baseline: new bare allows, growth past a row, and a baseline looser than
reality all fail. `--update` lowers/removes rows and re-checks; it never
adds a row and never raises one, so deliberate growth — and the first
baseline, hand-turned from the reported `new bare allow` lines into
`LC_ALL=C`-sorted `path<TAB>count` rows — is a hand-edit, visible in review.

## conflict-markers

Flat ban on unresolved merge-conflict markers: the open/base/close trio
(seven `<`, seven vertical bars, seven `>`) at column 0, each followed by a
space or end of line. Indented or quoted occurrences never fire; neither
does bare `=======` — a valid Markdown setext underline (a real conflict
always carries the open and close markers).

## changelog-entries

One judge over two scopes: the fragments a branch writes, and the collated
record a release folds them into.

### Fragments

`GROWTH_GUARDS_CHANGELOG_PATHS` (default `changelog.d/*/*.md`) is a
space-separated list of shell globs matched against the full repo-relative
path, `*` crossing `/` as in the excludes lists. Every matched tracked path
must be

- a real text file — a path git tracks as a symlink or a submodule gitlink,
  and a blob git would call binary, are refused, not skipped;
- directly under a Keep a Changelog section directory (`added`, `changed`,
  `deprecated`, `removed`, `fixed`, `security`), because that directory is
  the heading the collator writes it beneath;
- exactly one Markdown list item — the first non-blank line opens with a
  hyphen and a space and says something, every later line indents under it;
- within `GROWTH_GUARDS_CHANGELOG_CAP` characters (default 200).

A long entry is named with its file, its length and its first line. One
number is the whole length rule — no line counting — so an entry that states
its outcome passes however it is wrapped.

Paths matching no tracked file are a clean pass: a repository with no
fragments has nothing to judge. An empty list is a config error; the way to
switch the check off is to drop it from `GROWTH_GUARDS_CHECKS`.

### The record

`GROWTH_GUARDS_CHANGELOG_RECORD` (default `CHANGELOG.md`; empty switches this
scope off) is the collated file. A line the index carries under its
`## [Unreleased]` heading that HEAD does not is refused: two branches that
both write that list insert at the same place and the merge queue ejects the
trailing one, so entries are written as fragments and folded in at release.

The heading is found by structure, never by substring — a fenced block is
opened and closed by three or more backticks or tildes and holds no headings,
a level-1 or level-2 ATX heading switches the section on or off, and
everything else inside it is content. So a fragment or an example quoting
`## [Unreleased]` moves nothing.

The scope is judged only when HEAD already carries the record: a repository
writing its first one is not hand-editing a collated file.
`GROWTH_GUARDS_CHANGELOG_COLLATE=1` in the environment declares the
collator's own write, the way `RATCHET_RAISE=1` declares a baseline. A path
in both scopes is a config error — they judge by opposite rules.

### Measuring one entry

A fragment is one entry, so measuring it is joining it: every line with CR
stripped, whitespace runs collapsed to one space, the result trimmed. There is
no second entry to find a boundary for — the shape rule above is what
guarantees that, and it is what refuses a heading or a second marker inside a
fragment. The count is in characters: a UTF-8 sequence counts once, so an em
dash costs one, and a fragment wrapped over four indented lines measures the
same as the same text on one.

Text that is not valid UTF-8 is a collection error naming the line, not a
skip. git calls such a blob text whenever it holds no NUL, and there is no
character count to take over it — a run of stray continuation bytes would
otherwise measure as almost nothing. The quoted first line has every C0
control and DEL replaced: bytes in a tracked file must not reach the reader's
terminal through a diagnostic.

## prose

Instruction markdown states the rule that holds now. A history reference in
a file an agent loads fails: a calendar date (`20YY-MM-DD`), a three- or
four-digit issue number after `#`, or one of the words `previously`,
`used to`, `no longer`, `reverted`, `an earlier`, `earlier round`,
`incident`, `historically`, `originally`, `at the time`. An agent acts on
the rule, and a rule wrapped in the story of how it got there costs every
reader the same paragraph to discard — so the story goes in the commit that
made the change, where it stays readable and stops being reread.

Matching is case-insensitive (the banned strings are words, and a
sentence-initial capital is the same word) and whole-word, so `incidental`
and `unreverted` never fire. The issue-number shape takes no leading
boundary — a reference glued to a filename (`spec.md#1204`) is the same
reference — and the character after the digit run must be neither a digit
nor a hex letter, which is what keeps a longer token out: `#12345`,
`#1234ab` and `#0088cc` all pass. Three- and four-digit shorthand still
fires: `#900` is also how issue 900 is written, and no boundary can tell the
two apart.

Scope is the whole rule. `GROWTH_GUARDS_PROSE_PATHS` is a space-separated
list of shell globs matched against the full repo-relative path, `*`
crossing `/` as in the excludes lists, and it REPLACES the default rather
than adding to it. The default names what an agent harness loads on its own
— a skill's entry point and its workflows, an agent definition, and the
repo-level instruction files — each name spelled twice because `*` crosses
`/` but never stands in for the separator itself, the second spelling also
reaching a rendered copy under `.claude/` or `.agents/`:

```
SKILL.md */SKILL.md AGENTS.md */AGENTS.md CLAUDE.md */CLAUDE.md workflows/*.md */workflows/*.md agents/*.md */agents/*.md
```

Everything else keeps its history: a README, a reference doc under a skill,
a changelog, a design record. There is no excludes list — narrowing the path
list is the one control, and an empty list is a config error (the way to
switch the check off is to drop it from `GROWTH_GUARDS_CHECKS`). A list
matching no tracked file is a clean pass that scans nothing.

`git grep --cached` drops three shapes at a configured path with no status
and no stderr — a symlink entry, a submodule gitlink, and a blob it calls
binary — so the walk classifies every matched record itself before the scan.

A **symlink**, a **gitlink**, and a blob carrying a **NUL byte** in its
leading bytes are each named as unmeasured and counted apart from the clean
total, the way `changelog-entries` names one. The lane measures the file at
the path it was pointed at and does not read through a link, so the standard
dual-harness shape — a root `CLAUDE.md` tracked as a link to `AGENTS.md`,
a rendered `.claude/CLAUDE.md` linking back to it — is a pass that names
both links and measures the one tracked file there is. A tally line carries
the count, and the clean `no tracked file matches` verdict is printed only
when nothing was skipped: a path that matched and was named would otherwise
send its reader to widen a glob that was already right.

That NUL sample is the whole binary rule here: git's own is taken from the
path's userdiff driver, so `*.md -diff` would make it call a plain text file
binary, and the scan therefore runs with `--text` — the walk has already
removed everything this lane considers unreadable, so nothing is left for
git to drop. A blob the walk cannot read is a collection error, never a
skip.

## commit-msg

Conventional-commit gate over one message, shaped for the git `commit-msg`
hook (`commit-msg FILE`, or stdin when FILE is absent/`-`). Every
commit-message rule lives here, because only this hook sees the subject.

**Shape.** The header — the first non-blank, non-comment line — must match
`type(scope)!: subject`, the scope and `!` optional. Types come from
`GROWTH_GUARDS_COMMIT_TYPES`; the scope class `[#A-Za-z0-9 _.,/-]+` passes
uppercase issue keys (`fix(ABC-123): ...`) and issue numbers
(`fix(#123): ...`).

**Length.** At most `GROWTH_GUARDS_SUBJECT_MAX` characters (default 72). A
longer header is a body sentence on the line every log shows.

**The changelog a commit owes.** When `GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS`
(empty by default) names a glob some staged path matches, the commit must also
add or modify a path under `GROWTH_GUARDS_CHANGELOG_PATHS` or
`GROWTH_GUARDS_CHANGELOG_RECORD` — the same paths changelog-entries judges —
or carry `[no-changelog]` in the header. Deleting a fragment is not writing
one, so only additions and modifications count as evidence.

Git-generated headers are exempt from shape and length alone: nobody chose
their wording or their size. The changelog rule still runs over them — a
merge that carries code carries its entry — and `[no-changelog]` still
escapes it.

Every applicable rule reports before the verdict, so one run names everything
wrong with the message rather than the first thing.
