# preflight

A diff-scoped, fail-only checker for the escape classes worth catching
mechanically: fail-open bash, docs citing repo paths that do not exist,
source files citing docs that do not exist, TODO markers with no issue
behind them, and data files no parser accepts.
It reports only on lines the change added, and every lane is tuned so a
finding is worth a hard failure — a false positive costs more than a miss,
so a lane that cannot decide stays quiet.

```bash
.agents/skills/preflight/scripts/preflight --staged
docs/guide.md:41: [docs-cited-paths] cites a path that does not exist: docs/setup.md
preflight: 1 finding(s) across 3 changed file(s)
```

Exit codes: `0` clean, `1` findings, `2` usage or environment error.
Requirements: `git`, `awk`, and the usual POSIX userland; `shellcheck`,
`jq`, `taplo` and `python3` (with PyYAML for the workflow lane) are each
optional and each enable one lane.
Bash 3.2 compatible. Lane table, scope rules, and wiring into validation,
hooks and CI: [SKILL.md](SKILL.md).
