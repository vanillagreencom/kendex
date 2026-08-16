---
name: preflight
description: "Diff-scoped deterministic pre-review checks, fail-only and precision-first: unparseable shell, shellcheck errors, masked return values on added lines, fail-open bash (unchecked mktemp without errexit, new scripts without strict mode), docs citing repo paths that do not exist, source files citing docs that do not exist, TODO/FIXME markers with no issue reference, reviewer-bot attributions added to durable prose, malformed JSON/TOML, and workflow run: blocks their shell cannot parse. Load when running, tuning, or debugging preflight or wiring it into validation/CI."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Preflight

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Every lane is diff-scoped and fail-only: findings land on lines this
change ADDED, so a pre-existing violation on an untouched line is never
your problem, and a lane that cannot decide says nothing at all. There is
no warnings tier.

```bash
.agents/skills/preflight/scripts/preflight              # vs the default branch's merge base
.agents/skills/preflight/scripts/preflight --staged     # staged changes (pre-commit)
.agents/skills/preflight/scripts/preflight --all        # every tracked file, every line
```

`--base REF` sets the comparison point; `--repo PATH` runs against another
checkout. The default base is `origin/HEAD`, then `origin/main`, then
`main` — if none resolve, the run fails closed rather than reporting a
clean empty diff.

## Lanes

| Lane | Fails on | Tool |
|---|---|---|
| `shell-syntax` | A changed shell file bash cannot parse. | `bash -n` |
| `shellcheck-errors` | Any error-severity finding, anywhere in a changed shell file. | shellcheck |
| `masked-returns` | SC2155/SC2311 on an added line — a declaration whose exit status hides the command's. | shellcheck |
| `fail-open` | An `=$(mktemp …)` assignment added to a file without errexit; a new script that never sets `-e`, `-u` and `pipefail`. | built in |
| `docs-cited-paths` | An added backticked path in a `.md` file, inside a directory the repo really has and the doc's own subtree, that names nothing tracked or on disk. Also the reverse pointer: an added source line citing a `.md` path that names nothing tracked or on disk — URL spans and double-quoted strings are stripped first, data files (JSON/TOML/YAML/lock) and test-named files are out of scope, and the same directory guards apply. | built in |
| `todo-links` | An added `TODO:`/`FIXME(` marker — the word immediately followed by `:` or `(` — with no `#123`, `ABC-123`, or URL on the line. Prose that merely uses the word is not a marker. | built in |
| `reviewer-attribution` | An added line crediting a transient reviewer-bot pass: a fleet bot name (qodo, copilot, coderabbit, codex, devin; `PREFLIGHT_BOT_NAMES` replaces the set) coupled to a PR/review reference — a parenthetical credit, `per <bot> review`, or `<bot> review of #N`. Naming a bot is not the shape: prose describing reviewer behavior stays clean. `CHANGELOG.md` is exempt — rationale lives there. | built in |
| `data-syntax` | A changed `.json` or `.toml` file no parser accepts. | jq, taplo or python3 |
| `workflow-run-syntax` | A `run:` block in a changed `.github/workflows/*.yml` that its shell cannot parse — `bash -n` for bash, `sh -n` for sh, by name or executable path; `${{ … }}` replaced by a placeholder; other shells skipped, and an undeclared shell counts as bash only on plain `ubuntu-*`/`macos-*` runners. Reported at the offending file line — a folded (`>`) block at its first line; a workflow file that is not valid YAML, at the parser's line; an unterminated `${{`, at its line. | python3 with PyYAML |

Shell files are `*.sh`, `*.bash`, or anything with a `sh`/`bash` shebang.
Deleted files, and files under `tests/` or `fixtures/`, are out of scope
for the lanes that judge whole files. A lane whose tool is missing skips
silently — an absent shellcheck never fails a run and never passes one.

Exit codes: `0` clean, `1` findings, `2` usage/environment error (bad flag,
not a git repository, unresolvable base). Findings print as
`path:line: [lane] message`, line `0` for a whole-file finding.

## Wiring

Dev agents run `preflight` in the validate step, **before** the project's
own validation command. The default and `--base` scopes include every
non-ignored untracked file as a new file; `--staged` sees only the index.

The commit-time surface is vstack's managed `pre-commit-check` harness
hook (PreToolUse on `git commit`), which runs `preflight --staged` when
this skill is installed — it arrives and updates with `vstack refresh`,
and it is not a git-native hook: it intercepts agent commits, not
terminal commits.

CI is an optional backstop: `preflight --base origin/<default>` on the PR
head. Like any CI-consumed skill, that requires the installed skill to be
COMMITTED to the repo — CI checkouts see only tracked files, never a
machine-local `.agents` symlink.
