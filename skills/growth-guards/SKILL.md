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
  summary: "Arms git pre-commit and commit-msg hooks, so every commit in this repository runs the guard chain, for everyone who commits here, not only for kendex."
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
    - "A missing companion is announced and skipped, as is a repo-local size-ratchet that rejects --staged and preflight on a first commit; every other companion or guard failure blocks the commit."
    - "Both hooks block on nonzero results; Git's no-verify flag bypasses both for one commit."
    - "Git does not clone hooks; arm every clone once."
---

# Growth Guards

```bash
.agents/skills/growth-guards/scripts/growth-guards              # batch: every enabled repo check
.agents/skills/growth-guards/scripts/growth-guards all --staged # the same batch at commit scope
.agents/skills/growth-guards/scripts/growth-guards todo-ban     # one check by name, flags pass through
.agents/skills/growth-guards/scripts/install-git-hooks          # arm the git pre-commit/commit-msg shims
.agents/skills/growth-guards/scripts/install-git-hooks --check  # read-only: are the shims still armed?
```

## The checks

| Check | Verdict |
|---|---|
| **todo-ban** | Any work marker (TODO, FIXME, HACK, XXX in comment-marker shapes) in a tracked, non-excluded file fails. No baseline. |
| **byte-ceiling** | A tracked file over the configured ceiling fails; lockfiles are exempt. |
| **suppression-ban** | Blanket lint suppressions fail; reasonless Rust dead or unused allows may only tighten against the baseline. |
| **conflict-markers** | An unresolved merge-conflict marker in a tracked, non-excluded file fails. |
| **changelog-entries** | Each `GROWTH_GUARDS_CHANGELOG_PATHS` fragment is one Markdown list item in a Keep a Changelog section and at most `GROWTH_GUARDS_CHANGELOG_CAP` characters. |
| **prose** | A history reference in Markdown named by `GROWTH_GUARDS_PROSE_PATHS` fails; `GROWTH_GUARDS_CHECKS` controls whether the lane runs. |
| **commit-msg** | The header must be `type(scope)!: subject` within `GROWTH_GUARDS_SUBJECT_MAX`; a commit touching `GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS` also owes a changelog entry or `[no-changelog]`. |

Full check shapes and scopes: [CHECKS.md](CHECKS.md).

Exit codes: `0` clean, `1` violations, `2` usage, configuration, or collection error. An unmerged entry in a scanned path is a collection error.

## Git hooks

Run `scripts/install-git-hooks [--repo PATH]` to arm the shims.

Pre-commit order: `size-ratchet --staged` when installed -> `preflight --staged` when installed -> `growth-guards all --staged` -> `GROWTH_GUARDS_PRE_COMMIT_LOCAL` when configured. `commit-msg` runs the message gate.

Arming and disarming apply to the whole repository. Disarm before removing the skill. Ownership and layering: [README.md § Who gates a commit](README.md#who-gates-a-commit); install mechanics: [DEVELOPMENT.md § Git hook install contract](DEVELOPMENT.md#git-hook-install-contract).

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

Settings follow [README.md § Configuration](README.md#configuration).
`GROWTH_GUARDS_SETTINGS_FILE=/dev/null` skips file sources; `GROWTH_GUARDS_CHANGELOG_COLLATE=1` is environment-only and bypasses only the record comparison.

**Excludes format.** `pattern<TAB>reason` per line (shell glob against the
full repo-relative path; `*` crosses `/`); a pattern without a reason is a
config error. A pattern opening with `!` carves its matches back into the
scanned set, and wins over every exclusion row whatever the order. That is
how hand-written source inside an otherwise excluded render tree
(`.agents/**` plus `!.agents/skills/my-skill/**`) stays governed. To exclude a
path that literally begins with `!`, escape it: `\!foo`.
**Baseline format.** `path<TAB>count`, `LC_ALL=C` sorted,
unique paths, positive counts.
Seeding a first baseline and CI wiring: [README.md](README.md). Hook install and removal details: [DEVELOPMENT.md](DEVELOPMENT.md).
