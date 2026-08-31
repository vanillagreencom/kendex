---
name: growth-guards
description: "Load to add, tune, or debug a repo growth guard, its git hooks, or GROWTH_GUARDS_* settings."
summary: "Seven repo growth guards beside size-ratchet (todo-ban, byte-ceiling, suppression-ban, conflict-markers, changelog-entries, prose, commit-msg) and the git hook shims that run them. changelog-entries judges fragments and the collated record; commit-msg judges header shape, subject length and the changelog a commit owes."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [automation]
repo-effects:
  summary: "Arms git pre-commit and commit-msg hooks, so every commit in this repository runs the guard chain — for everyone who commits here, not only for kendex."
  writes:
    - ".git/hooks/kendex-guards"
    - ".git/hooks/pre-commit"
    - ".git/hooks/commit-msg"
  installer: "scripts/install-git-hooks"
  uninstaller: "scripts/install-git-hooks --uninstall"
  removal: "kendex guard uninstall, or any kendex CLI verb that drops the package (remove, an apply or refresh that takes it away, marketplace unsubscribe --remove-packages) runs the uninstaller before the files go; it drops only the helper and one marked line, leaving any hook you wrote. Deleting the package any other way leaves shims that exec scripts which are gone and fail every commit closed"
  companions:
    - "size-ratchet"
    - "preflight"
  notes:
    - "An existing pre-commit or commit-msg hook keeps its content and its exit status: one marked line goes in after the shebang and falls through to what was already there. core.hooksPath is never set."
    - "The chain runs in order: size-ratchet --staged, preflight --staged, the growth-guards batch at commit scope (todo-ban --staged, byte-ceiling, suppression-ban, conflict-markers, changelog-entries, prose), then the repo-root executable named by GROWTH_GUARDS_PRE_COMMIT_LOCAL. A companion that is not installed is an announced skip, never a silently missing check, and one that is installed but cannot run stops the commit rather than skipping it; the stated skips are preflight on a repository's first commit and a repo-local size-ratchet that rejects --staged."
    - "Both hooks block on any nonzero verdict and fail closed on a guard that could not run. Passing git's no-verify flag bypasses one commit, and skips the message gate with it."
    - "The gate needs no kendex binary once armed: git runs this package's committed scripts, so a machine that never installed kendex still gates commits. Arming does not travel, though — git clones no hooks and this package never sets core.hooksPath — so every clone is armed once, by whoever clones it."
---

# Growth Guards

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Seven checks beside `size-ratchet`, sharing its idiom and exit contract.

```bash
.agents/skills/growth-guards/scripts/growth-guards              # batch: every enabled repo check
.agents/skills/growth-guards/scripts/growth-guards all --staged # the same batch at commit scope
.agents/skills/growth-guards/scripts/growth-guards todo-ban     # one check by name, flags pass through
.agents/skills/growth-guards/scripts/install-git-hooks          # arm the git pre-commit/commit-msg shims
.agents/skills/growth-guards/scripts/install-git-hooks --check  # read-only: are the shims still armed?
```

Each check is also invocable as `scripts/CHECK`.

## The checks

| Check | Verdict |
|---|---|
| **todo-ban** | Any work marker (TODO, FIXME, HACK, XXX in comment-marker shapes) in a tracked, non-excluded file fails. No baseline. Prose naming a marker word does not fire. Two scopes: the default reads the whole index (the CI subject); `--staged` judges only the lines the staged diff ADDS, so a marker the commit does not add is CI's finding rather than this commit's. Content decides what either scope reads and an attributes rule never does; a blob carrying a NUL in its leading bytes is named as unmeasured. |
| **byte-ceiling** | A tracked file over the ceiling (default 200 KB) fails. `--staged` (default) gates every file the commit adds, modifies or changes the type of; `--base REF` only the files added since merge-base; `--all` sweeps every tracked file. Lockfiles are exempt built-in. |
| **suppression-ban** | Blanket lint suppressions fail flat: module-wide rust `allow` inner attributes, file-level ruff/flake8 noqa, the bare `eslint-disable` block form, bare or `all` nolint, biome's `biome-ignore-all` / unscoped `biome-ignore-start` / rule-less `biome-ignore lint` and group forms. Bare rust `allow(dead_code)`/`allow(unused*)` attributes are counted per file against a tighten-only baseline; `--update` lowers/removes rows, never adds or raises one. A per-line suppression naming its lint with a stated reason stays legal. |
| **conflict-markers** | An unresolved merge-conflict marker in a tracked, non-excluded file fails: the open/base/close trio (seven `<`, seven vertical bars, seven `>`) at column 0, each followed by a space or end of line. No baseline. Indented or quoted occurrences and the bare seven-equals separator do not fire. |
| **changelog-entries** | The changelog, over two scopes. Fragments (`GROWTH_GUARDS_CHANGELOG_PATHS`): each matched tracked path must be a real text file — a symlink, a gitlink or a binary blob is refused — be placed by a configured pattern — a pattern is `<root…>/<section>/<name>`, so its own last two segments say where the section sits and its own depth says which paths it places, and `*` crossing `/` matches a deeper path without placing it — with that directory a Keep a Changelog section (`added`, `changed`, `deprecated`, `removed`, `fixed`, `security`), hold exactly one Markdown list item (first non-blank line opens with a hyphen and a space and says something; every later non-blank line indents under it, so an indented second paragraph is part of the entry), and measure within the character cap (default 200). Measuring joins the fragment's lines with CR stripped and whitespace runs collapsed to one space, counted in characters — so wrapping spends no cap. Every OTHER tracked path in the fragment tree is refused too, excepting a `README.md` directly under a root and the configured record itself — both settled before any pattern is consulted, so the exemption does not turn on the pattern shape; `--list` writes NUL-terminated `fragment<TAB>SECTION<TAB>PATH` and `record<TAB>PATH` records on stdout, plus the record's accepted shape as `record-unreleased`, `record-section` and `record-end` line numbers, which is what a collator folds in, what it guards, and where it splits. The record (`GROWTH_GUARDS_CHANGELOG_RECORD`): a line the index carries under its `## [Unreleased]` heading that HEAD does not is refused, so two branches never insert at the same place; the heading is found by ATX structure outside fenced code and matched whole rather than by prefix (a fence closes only on a run of at least its opening length in the same character; an unterminated one, and a second such heading, are exit 2; every shape rule judges the STAGED copy, and a HEAD this guard would not accept is a comparison skipped with its reason rather than a refusal, so the commit repairing history is never the one blocked); a record with no such heading at all is refused, whether the commit staged it away or the file never carried one, and so is a level-3 heading inside the section that names no section; a record HEAD carries that the index stages away is refused rather than read as a repository that never had one, and `GROWTH_GUARDS_CHANGELOG_COLLATE=1` declares the collator's own write, read at one point and bypassing that comparison alone — the type and text rules, the heading rules and the deletion refusal all still judge under it. Text that is not valid UTF-8 is a collection error; paths matching no tracked file are a clean pass. |
| **prose** | A history reference in a configured markdown file fails: a calendar date, a three- or four-digit issue number after `#` (the hex digits are excluded, so a longer token passes; three- and four-digit shorthand cannot be told from an issue number and fails), or a word naming a past state. Scope is the path list — by default what an agent harness loads on its own (`SKILL.md`, `workflows/*.md`, `agents/*.md`, `AGENTS.md`, `CLAUDE.md`), so a reference doc, a changelog and a design record are out of scope by not being named. Matching is case-insensitive and whole-word. A symlink, a gitlink or a blob carrying a NUL at a configured path is named as unmeasured rather than counted clean — the lane measures the file at the path it was pointed at and does not read through a link — and paths matching no tracked file are a clean pass. No baseline; the word list is in CHECKS.md. |
| **commit-msg** | Every commit-message rule: only this hook sees the subject. Header must be `type(scope)!: subject` (scope and `!` optional; uppercase issue keys `fix(ABC-123)` and `#`-number scopes pass) and at most `GROWTH_GUARDS_SUBJECT_MAX` characters. A commit staging a path `GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS` names must also write a changelog entry — a path under `GROWTH_GUARDS_CHANGELOG_PATHS`, or `GROWTH_GUARDS_CHANGELOG_RECORD` under `GROWTH_GUARDS_CHANGELOG_COLLATE=1`, which is the release commit collating the fragments — or carry `[no-changelog]` in the header. Git-generated messages (Merge/Revert/Reapply, fixup!/squash!/amend!) skip shape and length only; the changelog rule still runs over them. Every applicable rule reports before the verdict. Takes the message file or stdin. |

Exit codes everywhere: `0` clean, `1` violations, `2` usage/config/collection
error. Any failure to collect (unreadable file, git/grep execution failure) is
exit 2, never a silent pass. The batch dispatcher exits 2 if any check could
not complete.

Scans read INDEX content (`git grep --cached`, staged blobs). A scan whose
paths include an UNMERGED entry exits 2 naming them: finish or abort the merge,
then re-run.

## Git hooks

`scripts/install-git-hooks [--repo PATH]` writes `.git/hooks` shims.
`pre-commit` runs, in order: `size-ratchet --staged` and `preflight --staged`
when the committing work tree or this install carries those skills (the work
tree's copy wins; a first commit skips preflight with a note; a size-ratchet
that rejects `--staged` in its first-line parser diagnostic is a stated skip —
any other failure blocks); `growth-guards all --staged`, which hands `--staged`
to the checks that take it and leaves the rest at their own default scope; then
the repo-root-relative executable named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`.
`commit-msg` runs the message gate, changelog rule included. Both BLOCK on the exit contract, fail
closed on a guard that could not run; `git commit --no-verify` is the bypass.
The `kendex guard` verbs invoke this installer: `install`, `uninstall`
(`--uninstall`) and `check` (`--check`). Arming and disarming are
repository-level: every work tree and nested project shares one hooks
directory, so an uninstall from any of them disarms the repository. Disarm
before removing this skill: shims whose scripts are gone block every commit. `kendex check` relays
this installer's own `--check` verdict where there is something to report — a clean result folds
into kendex's own all-clear — and asks for it only where
`.git/hooks/kendex-guards` is already there: git clones no hooks, so that
file is a local act, and without it nothing is run out of the checkout at
all. The verdicts are:
(0 armed in `.git/hooks`; 1 drifted, absent, or `core.hooksPath` set and
empty, which switches git hooks off; 2 could not determine — an unreadable
hooks directory, or any `core.hooksPath` naming a directory, which is
outside this verifier's contract: it reads `.git/hooks` only). Repeat runs
are no-ops and repairs; `core.hooksPath` is never set; existing hooks keep
their content and exit status. Full install and refusal behaviour:
[DEVELOPMENT.md](DEVELOPMENT.md).

The git hooks are the authoritative gate: they run for every committer, and
they need no kendex binary — the shim execs this skill's committed scripts.
kendex arms and reports, and implements no check of its own. The
`pre-commit-check` harness hook stands aside where BOTH git hooks are armed,
refuses commands that would sidestep them, and refuses the commit otherwise — it never runs these scripts on a repository's behalf.
Layering and reasoning: [README](README.md).

## Configuration

| Key | Default | Meaning |
|---|---|---|
| `GROWTH_GUARDS_CHECKS` | `todo-ban byte-ceiling suppression-ban conflict-markers changelog-entries prose` | Batch check list (`commit-msg` never batches). |
| `GROWTH_GUARDS_TODO_EXCLUDES` | `tools/todo-ban-excludes` | todo-ban exclusion list. |
| `GROWTH_GUARDS_BYTE_CEILING_KB` | `200` | Byte ceiling in KB. |
| `GROWTH_GUARDS_BYTE_EXCLUDES` | `tools/byte-ceiling-excludes` | byte-ceiling exclusion list (declared asset trees). |
| `GROWTH_GUARDS_SUPPRESSION_EXCLUDES` | `tools/suppression-ban-excludes` | suppression-ban exclusion list. |
| `GROWTH_GUARDS_SUPPRESSION_BASELINE` | `tools/suppression-baseline.tsv` | Bare-allow ratchet baseline. |
| `GROWTH_GUARDS_CONFLICT_EXCLUDES` | `tools/conflict-markers-excludes` | conflict-markers exclusion list. |
| `GROWTH_GUARDS_CHANGELOG_CAP` | `200` | Characters per changelog entry. |
| `GROWTH_GUARDS_CHANGELOG_PATHS` | `changelog.d/*/*.md` | Space-separated globs naming the changelog fragments, matched against the full repo-relative path (`*` crosses `/`). |
| `GROWTH_GUARDS_CHANGELOG_RECORD` | `CHANGELOG.md` | The collated record file; empty switches that scope off. |
| `GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS` | *(empty)* | Globs whose change obliges a changelog entry, judged by `commit-msg`; empty switches the rule off. |
| `GROWTH_GUARDS_PROSE_PATHS` | `SKILL.md */SKILL.md AGENTS.md */AGENTS.md CLAUDE.md */CLAUDE.md workflows/*.md */workflows/*.md agents/*.md */agents/*.md` | Space-separated globs naming the markdown the prose lane scans, matched against the full repo-relative path (`*` crosses `/`). |
| `GROWTH_GUARDS_COMMIT_TYPES` | `build chore ci docs feat fix perf refactor revert style test` | Accepted commit types. |
| `GROWTH_GUARDS_SUBJECT_MAX` | `72` | Characters allowed in a hand-written commit header. |
| `GROWTH_GUARDS_PRE_COMMIT_LOCAL` | *(empty)* | Repo-root-relative executable the pre-commit shim runs last. |

Resolution order for every key: explicit environment > `.env.local` >
`.kendex/settings.toml` > the repo's committed `kendex.settings.toml` (flat
`KEY = "value"` under `[env]`; other tables are ignored) > built-in default;
a `.env` file is never read. Only an ABSENT source is skipped; one that
exists but is unusable is a config error (exit 2).
`GROWTH_GUARDS_SETTINGS_FILE=/dev/null` skips `.env.local` and the settings
files, leaving environment variables and defaults.
`GROWTH_GUARDS_CHANGELOG_COLLATE=1` is read from the environment alone: it
declares the collator's own write under `[Unreleased]` for one run, the way
`RATCHET_RAISE=1` declares a baseline. It bypasses that comparison and
nothing else — what the record IS is judged either way.

**Excludes format** — `pattern<TAB>reason` per line (shell glob against the
full repo-relative path; `*` crosses `/`); a pattern without a reason is a
config error. **Baseline format** — `path<TAB>count`, `LC_ALL=C` sorted,
unique paths, positive counts.

What each check bans and how it is scoped: [CHECKS.md](CHECKS.md). Seeding
a first baseline and CI wiring: [README.md](README.md). Marker shapes, per-language suppression patterns,
and the hook install and removal contract: [DEVELOPMENT.md](DEVELOPMENT.md).
