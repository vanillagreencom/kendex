# growth-guards checks

What each check bans and how it is scoped. The package overview, the
invocation forms and the git hooks are in [README.md](README.md); every
configuration key is in [SKILL.md](SKILL.md).

## todo-ban

Flat ban on work markers in first-party tracked files — the words TODO,
FIXME, HACK, XXX in comment-marker shapes, no baseline. Prose that quotes or
names a marker does not fire; matching is case-sensitive. Do the work now or
track it and delete the marker; vendored trees go in excludes with a reason.

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
`reason = "..."` does not count. Legacy counts freeze in a tighten-only
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

A changelog entry longer than `GROWTH_GUARDS_CHANGELOG_CAP` characters
(default 200) fails, naming the file, the entry's line, its length and its
first line. One number is the whole rule — no line counting and no
continuation grammar — so an entry that states its outcome passes however it
is wrapped.

An entry opens on a list marker (`-`, `*`, `+`) at column 0 followed by a
space or tab, so a horizontal rule or a front-matter fence opens none. It runs
to the next such marker, an ATX heading (up to three leading spaces, one to
six hashes, then a space, a tab, or end of line — so a continuation naming an
issue number opens none, and neither does a line indented four spaces), or a
blank line followed by a line that is neither indented nor a marker. A blank line alone does not end it: an indented
second paragraph is part of the entry, the shape a Markdown list item and the
fragment tooling both accept, and an indented bullet belongs to the entry it
sits under rather than being one. Its text is those lines with CR stripped and
whitespace runs collapsed to one space. The count is in characters: a UTF-8
sequence counts once, so an em dash costs one.

A configured path that is not readable changelog text is named as unmeasured
and counted apart from the clean total: a path git tracks as a symlink or a
submodule gitlink, and a blob git would call binary, which the sibling checks'
`--cached` scans skip the same way.

Text that is not valid UTF-8 is a collection error naming the line, not a
skip. git calls such a blob text whenever it holds no NUL, and there is no
character count to take over it — a run of stray continuation bytes would
otherwise measure as almost nothing.

`GROWTH_GUARDS_CHANGELOG_PATHS` (default `CHANGELOG.md`) is a
space-separated list of shell globs matched against the full repo-relative
path, `*` crossing `/` as in the excludes lists. Paths matching no tracked
file are a clean pass — a repository with no changelog has nothing to judge —
and a repository keeping one entry per file names that tree instead
(`changelog.d/*/*.md`, whose two segments keep a `changelog.d/README.md` out).
An empty list is a config error; the way to switch the check off is to drop
it from `GROWTH_GUARDS_CHECKS`.

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
nor a hex letter, which is what keeps a longer token and a CSS colour out:
`#12345`, `#1234ab` and `#0088cc` all pass.

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

A configured path that is not readable markdown is named as unmeasured and
counted apart from the clean total, the way `changelog-entries` names one: a
path git tracks as a symlink or a submodule gitlink, and a blob git would
call binary. Each of the three is a path `git grep --cached` would drop with
no status and no stderr — a symlink's blob is its target path, not the file
a harness loads through it — so the walk classifies every matched blob
before the scan. A blob it cannot read is a collection error, never a skip.

## commit-msg

Conventional-commit gate over one message, shaped for the git `commit-msg`
hook (`commit-msg FILE`, or stdin when FILE is absent/`-`). The header — the
first non-blank, non-comment line — must match `type(scope)!: subject`, the
scope and `!` optional. Types come from `GROWTH_GUARDS_COMMIT_TYPES`; the
scope class `[#A-Za-z0-9 _.,/-]+` passes uppercase issue keys
(`fix(ABC-123): ...`) and issue numbers (`fix(#123): ...`).
