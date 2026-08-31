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
- placed by a configured pattern: a pattern is `<root…>/<section>/<name>`,
  so its own last two segments say where the section sits and its own depth
  says which paths it places. The directory a placed path sits in must be a
  Keep a Changelog section (`added`, `changed`, `deprecated`, `removed`,
  `fixed`, `security`), because that directory is the heading the collator
  writes it beneath. `*` crosses `/`, so `changelog.d/*/*.md` MATCHES a path
  a directory deeper as readily as one at its own depth — it places only the
  latter. `changelog.d/fixed/*.md` narrows the same tree to one section and
  places entries in it; a pattern with a glob in the middle places whatever
  reaches its depth. A new pattern shape is answered by the pattern rather
  than by a rule beside it;
- exactly one Markdown list item — the first non-blank line opens with a
  hyphen and a space and says something, and every later NON-BLANK line
  indents under it, so an indented second paragraph is part of the entry;
- within `GROWTH_GUARDS_CHANGELOG_CAP` characters (default 200).

A long entry is named with its file, its length and its first line. One
number is the whole length rule — no line counting — so an entry that states
its outcome passes however it is wrapped.

**Everything else in the fragment tree is refused.** A pattern's *root* is its
leading run of glob-free directories, stopping before the first globbed
segment and before the file name: `changelog.d/*/*.md` roots at
`changelog.d`. A pattern carrying no glob at all names one file, and naming
one file is not naming the directory it sits in, so it roots nowhere and
sweeps nothing — `changelog.d/README.md` as a pattern judges that file and no
other. Every tracked path under a root that no pattern matches is a
violation — a file in the fragment tree that nothing would ever fold in is a
silent drop otherwise, and one nothing judges is a symlink or a heading
published verbatim by whatever does fold it in.

Two paths are exempt, and they are settled BEFORE any pattern is consulted so
that what they mean does not turn on which pattern shape produced the root: a
`README.md` directly under a root, which documents the format, and the
configured record itself, which is the file fragments are folded into rather
than a stray in its own tree. Judged after the glob instead, a README under a
root a narrowing pattern derives would match that glob and be refused as a
malformed fragment — the opposite of an exemption.

Paths matching no tracked file are a clean pass: a repository with no
fragments has nothing to judge. An empty list is a config error; the way to
switch the check off is to drop it from `GROWTH_GUARDS_CHECKS`.

`--collate` judges, and on a clean verdict folds in what it just accepted:
each fragment into the record's `[Unreleased]` section, under the heading its
own section names, in Keep a Changelog order and filename order within a
section, then the fragment files and the section directory each leaves empty
are deleted. A refused run writes nothing. The release commit is its only
caller.

It is one run, not a caller and a judge, because "which paths are fragments,
which section each is in, which paths this judgement covers, and where in the
record the entries go" are answers this check already holds — a collator
deriving any of them a second time is a second grammar, and the one that
folds entries under a fenced example of the heading. The fold reads each
fragment and the record from the WORKING TREE while the judgement measured
what git carries, so it refuses, writing nothing, when the two disagree about
any path this run judged. The record is replaced whole or not at all: the
fold writes a staging file beside it and renames, and an interrupt leaves
nothing behind.

### The record

`GROWTH_GUARDS_CHANGELOG_RECORD` (default `CHANGELOG.md`; empty switches this
scope off) is the collated file. A line the index carries under its
`## [Unreleased]` heading that HEAD does not is refused: two branches that
both write that list insert at the same place and the merge queue ejects the
trailing one, so entries are written as fragments and folded in at release.

The heading is found by structure, never by substring. A fenced block opens
on a run of three or more backticks or tildes and closes only on a run of at
least that length in the same character with nothing but whitespace after it,
so a three-backtick line inside a four-backtick block does not end it. Nothing
inside a fence is a heading; a level-1 or level-2 ATX heading switches the
section on or off, and everything else inside it is content. So a fragment or
an example quoting `## [Unreleased]` moves nothing. The heading text matches
on equality, case-folded, once its leading spaces and hashes come off, so
`## [Unreleased] archive` is a different heading and opens no section. A
record with none is refused rather than collated against the nearest thing.

An unterminated fence is exit 2 naming the file, not a clean pass. It leaves
the parser unable to say where the section starts or stops, and a stray
opening fence above the heading would otherwise make both sides parse to
nothing and every hand-written line read as unchanged.

Every shape rule here judges the STAGED copy. HEAD is history — the committer
cannot change what it holds — so a record HEAD carries that this guard would
not accept is a comparison SKIPPED, naming the reason, never a refusal.
Refusing on HEAD's shape would demand a repair and then block the commit
making it, and a record malformed in HEAD could never be fixed at all. That
covers every way HEAD can fail to be a record — the entry's MODE, its bytes
and its shape, classified together in one answer — because it is the same
acceptance test either copy is put to rather than a list of tolerated states.
A gitlink or a tree has no blob to read as a record and a symlink's blob is a
path rather than a document, so each of those is history to repair as much as
a malformed heading is.

A SECOND `## [Unreleased]` heading is exit 2 for the same reason: which one
is the section is undecided. A duplicate carries no content of its own, so
this comparison would call the record unchanged, while the collator splits
the file at whichever heading it read last and deletes the fragments it
published under it.

Staging the heading AWAY, where HEAD carries one and the index does not, is
a violation. An empty section and a missing one both parse to nothing, so
the comparison alone reports the record unchanged and the malformed state
lands, with a later collation left nowhere to fold into. A release renames
the heading and opens a fresh empty one, which is not this.

A record with no `## [Unreleased]` heading at all is a violation, whether the
commit staged that heading away or the file never carried one. A release
folds every fragment into that heading and deletes the files they came from,
so there is nowhere to put them either way, and the level-3 headings inside
the section must name sections too. Those are the record's SHAPE, judged
here because a release that cannot run should stop at the commit that made it
so rather than at the tag.

A record git tracks in HEAD and not in the index is a DELETION, and it is a
violation too. Absent from the index is otherwise indistinguishable from a
repository that has no record yet, and read as that it would ship the
consumer changelog's removal as a clean run. The collator's declaration does
not excuse it either: a collation renames a replacement over the record and
never removes it. Retire the scope by emptying
`GROWTH_GUARDS_CHANGELOG_RECORD`, not by deleting the file.

The COMPARISON runs only when HEAD already carries the record: a repository
writing its first one is not hand-editing a collated file.
`GROWTH_GUARDS_CHANGELOG_COLLATE=1` in the environment declares the
collator's own write, the way `RATCHET_RAISE=1` declares a baseline — and it
bypasses that comparison and nothing else. It is read at ONE point, the
verdict on the lines the index gained, so every other rule in this scope runs
whether or not it is set and a rule added later cannot opt itself inside it.
The declaration is exported exactly while a collation is running, which is
the moment the record is about to be rewritten: a check it switched off would
be off precisely then. So the type and text rules still judge, an unclosed
fence and a second heading are still exit 2, staging the heading away is
still refused — a release renames it and opens a fresh empty one, so it keeps
a heading to fold into — and deleting the record is still refused, because a
collation renames a replacement over it and never removes it. A path in both
scopes is a config error: they judge by opposite rules. Each of the four ways
the comparison stands down — no record configured, the collator's
declaration, a record git does not track, a record HEAD does not carry yet —
names itself in the verdict, so a gate somebody disarmed never reads as a
repository that has no record.

### Measuring one entry

A fragment is one entry, so measuring it is joining it: every line with CR
stripped, whitespace runs collapsed to one space, the result trimmed. There is
no second entry to find a boundary for — the shape rule above is what
guarantees that, and it is what refuses a heading or a second marker inside a
fragment. The count is in characters: a UTF-8 sequence counts once, so an em
dash costs one, and a fragment wrapped over four indented lines measures the
same as the same text on one.

Both scopes reach a blob by one path. It reads the bytes and proves them text
this check can measure: a blob git would call binary — a NUL in its leading
bytes — is refused, and text that is not valid UTF-8 is a collection error
naming the line, since there is no character count to take over it and a run
of stray continuation bytes would otherwise measure as almost nothing. A
fragment that fails either is a violation; a record that does is a collection
error, because there is no comparison left to make. One path, so a rule added
to it cannot reach the fragments and miss the record.

The quoted first line has every C0 control except tab, and DEL, replaced:
bytes in a tracked file must not reach the reader's terminal through a
diagnostic.

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
add or modify a path under `GROWTH_GUARDS_CHANGELOG_PATHS` — the fragment
scope changelog-entries judges, resolved by the same library — or carry
`[no-changelog]` in the header. Deleting a fragment is not writing one, so
evidence is a path that comes out of the commit carrying content it did not
carry at that path before: a blob where there was none, a blob that changed,
a path whose TYPE became a regular file (a symlink replaced by a file holding
the link target's own bytes is one blob on both sides and a document where
there was none), or the destination of a rename. A mode and a sha together
are what identify a record; either alone lets a transition through. What that path became is changelog-entries'
judgement, running beside this one.

The staged list comes from `--raw`, the spelling `todo-ban` and
`byte-ceiling` already use, with rename detection pinned rather than
inherited. A raw record carries the old and new mode and the old and new blob
for every path, so what the commit did to a file is read off the record
rather than inferred from a status letter. Both sides of a rename TOUCH — the
source loses its content, the destination gains it — and a chmod is a touch
and nothing else, because its blob did not move. A letter that says only
"modified" cannot tell a rewrite from a permission bit, and a changelog
requirement satisfied by one is a requirement satisfied by nothing.

`GROWTH_GUARDS_CHANGELOG_RECORD` counts as that entry only under
`GROWTH_GUARDS_CHANGELOG_COLLATE=1`, the same declaration the record scope
reads: that is the release commit folding the fragments in. Without it any
edit to the record would count — a typo fixed in a section released years ago
— and nothing else would catch it, since changelog-entries judges only the
lines a commit GAINS under `[Unreleased]` and a released section is not that.
The remedy therefore names the fragment globs alone and mentions the record
as the release commit's own write.

Git-generated headers are exempt from shape and length alone: nobody chose
their wording or their size. The changelog rule still runs over them — a
merge that carries code carries its entry — and `[no-changelog]` still
escapes it.

Every applicable rule reports before the verdict, so one run names everything
wrong with the message rather than the first thing.
