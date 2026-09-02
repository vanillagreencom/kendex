---
name: preflight
description: "Load to run, tune, or debug preflight."
summary: "Diff-scoped deterministic pre-review checks: shell parse and shellcheck errors, fail-open bash, unwired test suites, untrapped scratch dirs, hardcoded temp paths, dead path citations, edited applied migrations, and malformed JSON or TOML."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [review, testing]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Preflight

Every lane is diff-scoped and fail-only, with no warnings tier: a finding
lands only on a line this change ADDED, and a lane that cannot decide reports
nothing. What a lane may read: [references/lanes.md](references/lanes.md).

```bash
.agents/skills/preflight/scripts/preflight              # vs the default branch's merge base
.agents/skills/preflight/scripts/preflight --staged     # staged changes (pre-commit)
.agents/skills/preflight/scripts/preflight --all        # every tracked file, every line
```

`--base REF` sets the comparison point; `--repo PATH` runs against another
checkout. The default base is `origin/HEAD`, then `origin/main`, then
`main`; if none resolve, the run fails closed.

## Lanes

| Lane | Fails on | Tool |
|---|---|---|
| `shell-syntax` | A changed shell file bash cannot parse. | `bash -n` |
| `shellcheck-errors` | Any error-severity finding, anywhere in a changed shell file. | shellcheck |
| `masked-returns` | SC2155/SC2311 on an added line, a declaration whose exit status hides the command's. | shellcheck |
| `fail-open` | An `=$(mktemp …)` assignment added to a file without errexit; a new script that never sets `-e`, `-u` and `pipefail`, unless git records it non-executable under a `scripts/lib/` tree, where nothing can run it and the preamble would set the sourcing caller's mode instead; an added `grep`/`find`/`git`/`jq`/`diff`/`cmp`, at a command position, whose status is discarded by `\|\| true` (or `\|\| :`). The same text quoted inside a message is not a finding. | built in |
| `unwired-suite` | A new suite file that no tracked runner invokes: `tests/*.test.sh`, `tests/test-*.sh`, `*.test.ts`, `*.test.js`, `*.test.mjs`, fixtures excluded. Runner set and wiring grammar: [references/lanes.md](references/lanes.md). | built in |
| `mktemp-trap` | A new shell file with an added `mktemp` invocation and no `trap … EXIT` anywhere in it. The invocation is the word at a command position, not named in a comment or a string. | built in |
| `hardcoded-temp-path` | An added directory-creating call taking a literal absolute temp path (`/tmp/…`, `/var/tmp/…`) as (part of) its first argument: `mkdtemp`/`mkdir` and their `Sync` variants (JS/TS), `mkdtemp`/`makedirs`/`mkdir` (Python), `create_dir_all` (Rust), and a shell `mkdir -p` at a command position. Not the shape: the literal as a value (config field, fixture string, path nothing creates), a `$TMPDIR`-derived path, or a commented-out call. | built in |
| `docs-cited-paths` | An added backticked path in a `.md` file, inside a directory the repo really has and the doc's own subtree, that names nothing tracked or on disk. Also the reverse: an added source line citing a `.md` path that names nothing tracked or on disk. URL spans and double-quoted strings are stripped first; data files (JSON/TOML/YAML/lock), test-named files, and installed-artifact subtrees (`.agents/` and the harness dirs' skills/agents/hooks/rules/instructions/packages/kendex trees) are out of scope; the same directory guards apply. | built in |
| `applied-migration-edited` | A path the MERGE BASE carries, changed, deleted or renamed, matching a configured migrations glob; the correction is a new migration, never an edit here. `PREFLIGHT_MIGRATION_GLOBS` replaces the default set (refinery and Flyway shapes only). Glob semantics and what is not the shape: [references/lanes.md](references/lanes.md). | built in |
| `data-syntax` | A changed `.json` or `.toml` file no parser accepts. | jq, taplo or python3 |

Shell files are `*.sh`, `*.bash`, or anything with a `sh`/`bash` shebang.
Deleted files, and files under `tests/` or `fixtures/`, are out of scope
for the lanes that judge whole files; `unwired-suite` is the exception.

Installed-artifact subtrees (`.agents/` and the harness dirs'
skills/agents/hooks/rules/instructions/packages/kendex trees) are out of
scope for `masked-returns`, `fail-open`, `unwired-suite`, `mktemp-trap`,
`docs-cited-paths`. `shell-syntax`, `shellcheck-errors`,
`hardcoded-temp-path`, `applied-migration-edited`, `data-syntax` stay on
there. A `prompts/` or `commands/` tree under a harness dir keeps every
lane. A lane whose tool is missing skips silently. It neither fails nor
passes the run.

Exit codes: `0` clean, `1` findings, `2` usage/environment error (bad flag,
not a git repository, unresolvable base). Findings print as
`path:line: [lane] message`, line `0` for a whole-file finding.

## Wiring

Dev agents run `preflight` in the validate step, **before** the project's own
validation command. The growth-guards pre-commit chain runs
`preflight --staged` itself, and CI runs `preflight --base origin/<default>`
on a COMMITTED install. Hook and CI wiring: [README.md](README.md) § Wiring it.
