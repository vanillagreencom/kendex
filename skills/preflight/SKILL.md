---
name: preflight
description: "Diff-scoped deterministic pre-review checks: shell parse/shellcheck errors, fail-open bash, unwired test suites, untrapped scratch dirs, directory creation at hardcoded temp paths, dead path citations, TODO markers, bot attributions, malformed JSON/TOML/workflows. Load to run, tune, or debug preflight."
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

# Preflight

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Every lane is diff-scoped and fail-only: findings land only on lines this
change ADDED; a lane that cannot decide reports nothing. There is no
warnings tier.

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
| `masked-returns` | SC2155/SC2311 on an added line — a declaration whose exit status hides the command's. | shellcheck |
| `fail-open` | An `=$(mktemp …)` assignment added to a file without errexit; a new script that never sets `-e`, `-u` and `pipefail`; an added `grep`/`find`/`git`/`jq`/`diff`/`cmp`, at a command position, whose status is discarded by `\|\| true` (or `\|\| :`). The same text quoted inside a message is not a finding. | built in |
| `unwired-suite` | A new suite file — `tests/*.test.sh`, `tests/test-*.sh`, `*.test.ts`, `*.test.js`, `*.test.mjs`; fixtures excluded — that no tracked runner invokes. Runners are `.github/workflows/*.yml`, `tools/validate*`, `scripts/validate*`, `package.json`, `Makefile`, `justfile`, and any `run-all.sh`; wiring is the suite named outright, a path-shaped glob its path satisfies, a directory it lives under, a manifest below the repo root whose subtree holds it, or a runner beside it globbing its own directory. An empty or unreadable runner set: lane stays quiet. | built in |
| `mktemp-trap` | A new shell file with an added `mktemp` invocation — the word at a command position, not named in a comment or a string — and no `trap … EXIT` anywhere in it. | built in |
| `hardcoded-temp-path` | An added directory-creating call taking a literal absolute temp path (`/tmp/…`, `/var/tmp/…`) as (part of) its first argument — `mkdtemp`/`mkdir` and their `Sync` variants (JS/TS), `mkdtemp`/`makedirs`/`mkdir` (Python), `create_dir_all` (Rust), and a shell `mkdir -p` at a command position. Not the shape: the literal as a value (config field, fixture string, path nothing creates), a `$TMPDIR`-derived path, or a commented-out call. | built in |
| `docs-cited-paths` | An added backticked path in a `.md` file, inside a directory the repo really has and the doc's own subtree, that names nothing tracked or on disk. Also the reverse: an added source line citing a `.md` path that names nothing tracked or on disk — URL spans and double-quoted strings are stripped first; data files (JSON/TOML/YAML/lock), test-named files, and installed-artifact subtrees (`.agents/` and the harness dirs' skills/agents/hooks/rules/instructions/packages trees) are out of scope; the same directory guards apply. | built in |
| `todo-links` | An added `TODO:`/`FIXME(` marker — the word immediately followed by `:` or `(` — with no `#N`, `ABC-123`, or URL on the line. Prose that merely uses the word is not a marker. | built in |
| `reviewer-attribution` | An added line crediting a transient reviewer-bot pass: a fleet bot name (qodo, copilot, coderabbit, codex, devin; `PREFLIGHT_BOT_NAMES` replaces the set) coupled to a PR/review reference — a parenthetical credit, `per <bot> review`, or `<bot> review of #N`. Prose that merely names a bot is not the shape. `CHANGELOG.md` is exempt. | built in |
| `data-syntax` | A changed `.json` or `.toml` file no parser accepts. | jq, taplo or python3 |
| `workflow-run-syntax` | A `run:` block in a changed `.github/workflows/*.yml` that its shell cannot parse — `bash -n` for bash, `sh -n` for sh, by name or executable path; `${{ … }}` replaced by a placeholder; other shells skipped, and an undeclared shell counts as bash only on plain `ubuntu-*`/`macos-*` runners. Reported at the offending file line — a folded (`>`) block at its first line; a workflow file that is not valid YAML, at the parser's line; an unterminated `${{`, at its line. | python3 with PyYAML |

Shell files are `*.sh`, `*.bash`, or anything with a `sh`/`bash` shebang.
Deleted files, and files under `tests/` or `fixtures/`, are out of scope
for the lanes that judge whole files; `unwired-suite` is the exception.

Installed-artifact subtrees (`.agents/` and the harness dirs'
skills/agents/hooks/rules/instructions/packages trees) are out of scope
for `masked-returns`, `fail-open`, `unwired-suite`, `mktemp-trap`,
`docs-cited-paths`. `shell-syntax`, `shellcheck-errors`,
`hardcoded-temp-path`, `todo-links`, `reviewer-attribution`,
`data-syntax`, `workflow-run-syntax` stay on there. A `prompts/` or
`commands/` tree under a harness dir keeps every lane. A lane whose tool
is missing skips silently — it neither fails nor passes the run.

Exit codes: `0` clean, `1` findings, `2` usage/environment error (bad flag,
not a git repository, unresolvable base). Findings print as
`path:line: [lane] message`, line `0` for a whole-file finding.

## Wiring

Dev agents run `preflight` in the validate step, **before** the project's
own validation command. The default and `--base` scopes include every
non-ignored untracked file as a new file; `--staged` sees only the index.

Commit-time: kendex's managed `pre-commit-check` harness hook (PreToolUse
on `git commit`) runs `preflight --staged` when this skill is installed.
It installs and updates with `kendex refresh`; it intercepts agent
commits, not terminal commits.

CI (optional): `preflight --base origin/<default>` on the PR head. The
installed skill must be COMMITTED to the repo — CI checkouts see only
tracked files, never a machine-local `.agents` symlink.
