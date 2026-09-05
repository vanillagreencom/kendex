# preflight

A diff-scoped, fail-only checker for the escape classes worth catching mechanically: fail-open bash, new suites no runner invokes, scratch directories no EXIT trap removes, hardcoded absolute temp paths, docs citing repo paths that do not exist, edits to a migration a database has already run, and data files no parser accepts. For a repository that wants those caught before a long validation run, not in review.

## Install

```bash
kendex add vanillagreencom/kendex --skill preflight
```

Needs `git`, `awk` and the usual POSIX userland; Bash 3.2 is enough. `shellcheck` is optional and enables the two shellcheck lanes; `data-syntax` reads strict JSON through `jq` and TOML through `taplo` or a Python 3.11+ `tomllib`. A lane whose tool is missing skips silently.

## What it does

- Judges only the lines a change added, against the merge base, the index, or every tracked line.
- Has no warnings tier: a lane that cannot decide stays quiet, so every finding is worth a hard failure.
- Prints one line per finding and one summary line; exit `0` clean, `1` findings, `2` usage or environment error.

## How it works

```bash
.agents/skills/preflight/scripts/preflight              # vs the default branch's merge base
.agents/skills/preflight/scripts/preflight --staged     # the staged index
.agents/skills/preflight/scripts/preflight --all        # every tracked file, every line
```

```
docs/guide.md:41: [docs-cited-paths] cites a path that does not exist: docs/setup.md
preflight: 1 finding(s) across 3 changed file(s)
```

Flags: `preflight --help`. The lane table, scope rules and the subtrees each lane skips: [SKILL.md](SKILL.md). Diff scope, the `unwired-suite` wiring grammar and the `applied-migration-edited` glob set: [references/lanes.md](references/lanes.md).

## Wiring it

- Validation: run it ahead of the project's own build, lint and test command.
- Commit time: where `growth-guards` is installed, its pre-commit chain runs `preflight --staged` itself. Any other hook calls the script with `--staged`; the chain's `GROWTH_GUARDS_PRE_COMMIT_LOCAL` lane runs its executable with no arguments, so wiring preflight there needs a wrapper that adds the flag.
- CI: `preflight --base origin/<default-branch>` on the PR head. The installed skill must be committed: a CI checkout sees tracked files only, never a machine-local `.agents` symlink.

## Customise

`PREFLIGHT_JSONC_GLOBS` names `.json` files whose producer permits comments. Its default covers tsconfig, jsconfig, `.vscode`, `.devcontainer`, and VS Code `*-color-theme.json` files. The `.jsonc` suffix needs no setting.

`PREFLIGHT_MIGRATION_GLOBS` names migrations whose recorded checksum makes an edit unsafe. Its default covers the versioned refinery and Flyway paths in [references/lanes.md](references/lanes.md).

Set these values in `kendex.settings.toml` under `[env]`, in `.kendex/settings.toml`, in `.env.local`, or in the process environment. Later sources take priority. `--base REF` sets the comparison point. `--repo PATH` runs against another checkout.
