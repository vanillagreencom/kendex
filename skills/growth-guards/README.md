# growth-guards

Four checks that stop quiet repo decay, one family beside `size-ratchet`:
work markers, oversized additions, blanket lint suppression, and
non-conventional commit messages. They share one idiom and one exit
contract: `0` clean, `1` violations, `2` usage/config/collection error. All
scans read INDEX content; binary files are skipped by the text scans.
`SKILL.md` is the agent-facing reference; `DEVELOPMENT.md` covers internals.

## Invocation

```bash
scripts/growth-guards [all]         # batch: every enabled repo check
scripts/growth-guards CHECK [ARGS]  # one check, flags passed through
scripts/CHECK [ARGS]                # each check is a standalone executable
```

The batch runs `GROWTH_GUARDS_CHECKS` (default
`todo-ban byte-ceiling suppression-ban`) and fails closed: exit 2 if any
check could not complete, else 1 if any found violations. `commit-msg` reads
a message, so it never runs in the batch. In an installed project the
scripts live under `.agents/skills/growth-guards/scripts/`; wire CI at
whichever grain fits — `byte-ceiling --base origin/main` gates a PR's
additions, and local commits are covered by the git hooks below.

## Git hooks

```bash
.agents/skills/growth-guards/scripts/install-git-hooks [--repo PATH]
.agents/skills/growth-guards/scripts/install-git-hooks --uninstall
```

The installer writes a helper into the repository's `.git/hooks` plus one
marked delegating line in `pre-commit` and `commit-msg` — never
`core.hooksPath`, and an existing hook keeps its content and its own exit
status. Repeat runs are no-ops, and repairs; `--uninstall` drops the helper
and our line and leaves the rest of a consumer's own hook untouched. `vstack
add` and `vstack refresh` run the installer for a project that has the skill
installed (a non-git project is skipped with a note), and `vstack remove
growth-guards` runs `--uninstall` first.

`pre-commit` judges ONE commit snapshot: `size-ratchet --staged` and
`preflight --staged` when those skills are installed beside this one, the
`growth-guards` batch over the staged content, then the repo-root-relative
executable named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL` (empty means none).
`commit-msg` runs this family's message gate on git's message file. Both
shims BLOCK and fail closed on the family's exit contract — `1` carries the
check's own remediation text, `2` names a guard that could not run; `git
commit --no-verify` is the deliberate bypass.

## todo-ban

Flat ban on work markers in first-party tracked files — the words TODO,
FIXME, HACK, XXX in comment-marker shapes, no baseline. Prose that quotes or
names a marker does not fire, and matching is case-sensitive. Remediation:
do the work now, or move it to the tracker and delete the marker.
Vendored/generated trees go in the excludes list with a reason.

## byte-ceiling

Newly added tracked files over the ceiling (default 200 KB, KB = 1024
bytes) fail. Growth-oriented like size-ratchet: legacy files already in
history are not gated by the default modes, so adoption needs no cleanup
first. Lockfiles are exempt built-in, by exact basename; declared asset
trees go in the excludes list with a reason.

- `--staged` (default) — files added in the staged diff (pre-commit).
- `--base REF` — files added since the merge-base with REF (CI on a PR).
- `--all` — every tracked file (audits; pair with excludes rows for known
  legacy assets).

## suppression-ban

Two gates, both scanned language-scoped by pathspec, so docs and scripts
that quote a pragma never fire. **Blanket suppressions fail flat** —
module/crate-wide rust `#![allow(...)]` inner attributes, file-level
`# ruff: noqa` / `# flake8: noqa`, the bare `/* eslint-disable */` block form
with no rules named, and `//nolint` with nothing after it or `//nolint:all`.
A per-line suppression that names its lint and states its reason stays legal
(`// eslint-disable-next-line rule -- why`, `# noqa: E501`,
`//nolint:gosec // why`, a per-item rust attribute).

**Bare-allow ratchet (Rust)** — reasonless `#[allow(dead_code)]` /
`#[allow(unused…)]` attributes are counted per file; an attribute carrying
`reason = "..."` does not count. Repos with legacy counts freeze them in a
tighten-only baseline: new bare allows, growth past a row, and a baseline
looser than reality all fail. `--update` lowers/removes rows to current
reality and re-checks; it never adds a row and never raises a number, so
deliberate growth — and the first baseline, turned from each reported `new
bare allow` line (path and count) into an `LC_ALL=C`-sorted `path<TAB>count`
row — is a hand-edit, visible in review.

## commit-msg

Conventional-commit gate over one message, shaped for the git `commit-msg`
hook (`commit-msg FILE`, or stdin when FILE is absent/`-`). The header — the
first non-blank, non-comment line — must match `type(scope)!: subject`, the
scope and `!` optional. Types come from `GROWTH_GUARDS_COMMIT_TYPES`; the
scope class `[#A-Za-z0-9 _.,/-]+` passes uppercase issue keys
(`fix(ABC-123): ...`) and issue numbers (`fix(#123): ...`).

## Configuration

Every key, its default and its meaning: [SKILL.md](SKILL.md). Each resolves
environment > `.env.local` > `.vstack/settings.toml` > committed
`vstack.settings.toml` (flat `KEY = "value"` under `[env]`) > `.env` >
default. Per-check flags (`--excludes`, `--baseline`) override every source
for the paths. All relative paths are repo-root-relative.

```toml
[env]
GROWTH_GUARDS_BYTE_CEILING_KB = "500"
GROWTH_GUARDS_CHECKS = "todo-ban suppression-ban"
```

## Requirements

`git`, `awk`, and the usual POSIX userland. Bash 3.2 compatible (macOS
system bash).
