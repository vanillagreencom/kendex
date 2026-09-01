# preflight

A diff-scoped, fail-only checker for the escape classes worth catching
mechanically: fail-open bash, new suites no runner invokes, scratch
directories no EXIT trap removes, directories created at hardcoded absolute
temp paths, docs citing repo paths that do not exist, source files citing
docs that do not exist, edits to a migration a database has already run, and
data files no parser accepts.

Findings land only on lines a change ADDED, and there is no warnings tier: a
lane that cannot decide stays quiet, so every finding is worth a hard failure.

```bash
.agents/skills/preflight/scripts/preflight              # vs the default branch's merge base
.agents/skills/preflight/scripts/preflight --staged     # the staged index
.agents/skills/preflight/scripts/preflight --all        # every tracked file, every line
```

```
docs/guide.md:41: [docs-cited-paths] cites a path that does not exist: docs/setup.md
preflight: 1 finding(s) across 3 changed file(s)
```

`--base REF` sets the comparison point, `--repo PATH` runs against another
checkout. Exit codes: `0` clean, `1` findings, `2` usage or environment error.

## Wiring it

**Validation.** Run it ahead of the project's own build, lint and test
command, so a finding lands before a long run does.

**Commit time.** Where `growth-guards` is also installed, its pre-commit
chain runs `preflight --staged` itself — nothing to wire. Any other hook
calls the script with `--staged`.

**CI.** `preflight --base origin/<default-branch>` on the PR head. The
installed skill must be committed: a CI checkout sees tracked files only,
never a machine-local `.agents` symlink.

## Requirements

`git`, `awk`, and the usual POSIX userland; Bash 3.2 compatible.
`shellcheck` is optional and enables the two shellcheck lanes. `data-syntax`
reads JSON through `jq` and TOML through `taplo`, or, where `taplo` is
absent, a `python3` new enough to carry `tomllib` (3.11 and later). A lane
whose tool is missing skips silently.

Lane table, scope rules, and the subtrees each lane skips:
[SKILL.md](SKILL.md).
