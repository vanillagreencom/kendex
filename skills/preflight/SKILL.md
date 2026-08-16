---
name: preflight
description: "Diff-scoped deterministic pre-review checks, fail-only and precision-first: unparseable shell, shellcheck errors, masked return values on added lines, fail-open bash (unchecked mktemp without errexit, new scripts without strict mode), docs citing repo paths that do not exist, TODO/FIXME markers with no issue reference, and malformed JSON/TOML. Load when running, tuning, or debugging preflight or wiring it into validation/CI."
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
| `docs-cited-paths` | An added backticked path in a `.md` file, inside a directory the repo really has and the doc's own subtree, that names nothing tracked or on disk. | built in |
| `todo-links` | An added `TODO:`/`FIXME(` marker — the word immediately followed by `:` or `(` — with no `#123`, `ABC-123`, or URL on the line. Prose that merely uses the word is not a marker. | built in |
| `data-syntax` | A changed `.json` or `.toml` file no parser accepts. | jq, taplo or python3 |
| `workflow-run-syntax` | A `run:` block in a changed `.github/workflows/*.yml` that bash cannot parse (`${{ … }}` replaced by a placeholder; steps with a non-shell `shell:` skipped). Reported at the offending file line. | python3 with PyYAML |

Shell files are `*.sh`, `*.bash`, or anything with a `sh`/`bash` shebang.
Deleted files, and files under `tests/` or `fixtures/`, are out of scope
for the lanes that judge whole files. A lane whose tool is missing skips
silently — an absent shellcheck never fails a run and never passes one.

Exit codes: `0` clean, `1` findings, `2` usage/environment error (bad flag,
not a git repository, unresolvable base). Findings print as
`path:line: [lane] message`, line `0` for a whole-file finding.

## Wiring

Dev agents run `preflight` in the validate step, **before** the project's
own validation command. Untracked files are outside every diff scope:
stage new files before expecting them to be checked.

The commit-time surface is vstack's managed `pre-commit-check` harness
hook (PreToolUse on `git commit`), which runs `preflight --staged` when
this skill is installed — it arrives and updates with `vstack refresh`,
and it is not a git-native hook: it intercepts agent commits, not
terminal commits.

CI is an optional backstop: `preflight --base origin/<default>` on the PR
head. Like any CI-consumed skill, that requires the installed skill to be
COMMITTED to the repo — CI checkouts see only tracked files, never a
machine-local `.agents` symlink.
