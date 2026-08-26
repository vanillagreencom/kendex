# growth-guards

Five checks that stop quiet repo decay, one family beside `size-ratchet`:
work markers, oversized additions, blanket lint suppression, conflict
markers, and non-conventional commit messages. One idiom, one exit contract
— `0` clean, `1` violations, `2` usage/config/collection error. Scans read
INDEX content and skip binaries. Requirements: `git`, `awk`, the usual
POSIX userland; Bash 3.2 compatible (macOS bash). `SKILL.md` is the
agent-facing reference; `DEVELOPMENT.md` covers internals.

## Invocation

```bash
scripts/growth-guards [all]         # batch: every enabled repo check
scripts/growth-guards CHECK [ARGS]  # one check, flags passed through
scripts/CHECK [ARGS]                # each check is a standalone executable
```

The batch runs `GROWTH_GUARDS_CHECKS` (default
`todo-ban byte-ceiling suppression-ban conflict-markers`) and fails closed:
exit 2 if any check could not complete, else 1 on violations. `commit-msg`
reads a message, so it never runs in the batch. Installed scripts live under
`.agents/skills/growth-guards/scripts/`; wire CI at whichever grain fits
(`byte-ceiling --base origin/main` gates a PR's additions); the git hooks
below cover local commits.

## Git hooks

```bash
.agents/skills/growth-guards/scripts/install-git-hooks [--repo PATH]
.agents/skills/growth-guards/scripts/install-git-hooks --uninstall
.agents/skills/growth-guards/scripts/install-git-hooks --check
```

The installer writes a helper into `.git/hooks` plus one marked delegating
line in `pre-commit` and `commit-msg` — never `core.hooksPath`; an existing
hook keeps its content and exit status; repeat runs are no-ops and repairs.
`--uninstall` drops only the helper and our line. `--check` writes nothing:
`0` armed — in `.git/hooks` or a `core.hooksPath` directory hand-wired to this
skill's hooks — `1` drifted/absent/dormant, `2` could not determine, never a
silent pass. `kendex guard install` runs the installer and `kendex guard
uninstall` runs `--uninstall`.

`pre-commit` judges ONE commit snapshot: `size-ratchet --staged` and
`preflight --staged` when the committing work tree or this install
carries them (work tree first), the `growth-guards` batch, then the
repo-root-relative executable named by `GROWTH_GUARDS_PRE_COMMIT_LOCAL`
(empty means none). `commit-msg` runs this family's message gate. Both
shims BLOCK and fail closed — `1` carries the check's remediation text,
`2` a guard that could not run; `git commit --no-verify` is the bypass.

## Who gates a commit

Two layers, and only one of them is authoritative.

**The git hooks are the gate.** They run for every committer — a person at a
terminal, any AI harness, a script, an editor's commit button — because git
runs them, not because anything asked. They need no kendex binary at commit time: the shim
execs this skill's committed scripts. Git never clones `.git/hooks`, so a
fresh clone carries the scripts but no shims — one `kendex guard install`
arms them, and from then on every commit is gated by committed shell and
git, on a machine that has never installed kendex. That is the whole reason
the checks are shell and travel with the repository.

**kendex only arms and reports.** `kendex guard install` runs the installer
above; `kendex guard uninstall` runs `--uninstall`; `kendex check` reads the hook files
itself — armed, not armed, or could not tell — and runs nothing out of a
checkout, because reading a repository's status must not execute its code.
kendex implements no check of its own; the verdicts a commit is judged by
are all this skill's.

**The `pre-commit-check` harness hook is a stand-in, not a second opinion.**
Where a git pre-commit hook is armed, it steps aside: git will run the gate
itself, and validating twice would only double the wait. It does two things
the git hook cannot. It refuses a command that would sidestep an armed hook
(`--` + `no-verify`, `-n`, or injected git configuration), because git would
skip the message gate too and no fallback can check a message it never sees.
And where nothing is armed, it runs this skill's `scripts/pre-commit` itself,
found the same way the shim finds it, so an unarmed repository is not an
ungated one. It gates its own working directory and no other.

Order, then: git hooks where they exist, the harness hook standing in where
they do not, and a refusal where neither can judge. No layer ever passes a
commit another layer would have blocked.

## todo-ban

Flat ban on work markers in first-party tracked files — the words TODO,
FIXME, HACK, XXX in comment-marker shapes, no baseline. Prose that quotes or
names a marker does not fire; matching is case-sensitive. Do the work now or
track it and delete the marker; vendored trees go in excludes with a reason.

## byte-ceiling

Newly added tracked files over the ceiling (default 200 KB, KB = 1024
bytes) fail. Growth-oriented like size-ratchet — default modes gate no
legacy file, so adoption needs no cleanup first. Lockfiles are exempt
built-in by exact basename; declared asset trees go in excludes with a reason.

- `--staged` (default) — files added in the staged diff (pre-commit).
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

## commit-msg

Conventional-commit gate over one message, shaped for the git `commit-msg`
hook (`commit-msg FILE`, or stdin when FILE is absent/`-`). The header — the
first non-blank, non-comment line — must match `type(scope)!: subject`, the
scope and `!` optional. Types come from `GROWTH_GUARDS_COMMIT_TYPES`; the
scope class `[#A-Za-z0-9 _.,/-]+` passes uppercase issue keys
(`fix(ABC-123): ...`) and issue numbers (`fix(#123): ...`).

## Configuration

Every key, its default and its meaning: [SKILL.md](SKILL.md). Each resolves
environment > `.env.local` > `.kendex/settings.toml` > committed
`kendex.settings.toml` (flat `KEY = "value"` under `[env]`) > `.env` >
default. Per-check flags (`--excludes`, `--baseline`) override every
source; relative paths are repo-root-relative.

```toml
[env]
GROWTH_GUARDS_BYTE_CEILING_KB = "500"
GROWTH_GUARDS_CHECKS = "todo-ban suppression-ban"
```
