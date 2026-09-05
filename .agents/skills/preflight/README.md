# preflight

A checker for changed files in a repository. It detects script errors, broken document paths and invalid data before the project build and tests.

## Install

```bash
kendex add vanillagreencom/kendex --skill preflight
```

Requires Git, awk and standard POSIX tools. Bash 3.2 is supported. Install shellcheck for its shell checks, jq for JSON checks, and taplo or Python with tomllib for TOML checks. A check with a missing tool is skipped.

## Features

- Check shell syntax and selected shell error patterns.
- Find unwired test suites and unmanaged temporary directories.
- Check cited paths and JSON or TOML syntax.
- Detect edits to configured applied migrations.

## How it works

The checker selects changed files from Git. Each check reads the file types it supports. Findings identify the file, location and check. Your validation command or Git hook uses the exit result to stop on a finding.

## Settings

`PREFLIGHT_JSONC_GLOBS` names `.json` files whose producer permits comments. Its default covers tsconfig, jsconfig, `.vscode`, `.devcontainer`, and VS Code `*-color-theme.json` files. The `.jsonc` suffix needs no setting.

`PREFLIGHT_MIGRATION_GLOBS` names migrations whose recorded checksum makes an edit unsafe. Its default covers the versioned refinery and Flyway paths in [references/lanes.md](references/lanes.md).

Set these values in `kendex.settings.toml` under `[env]`, in `.kendex/settings.toml`, in `.env.local`, or in the process environment. Later sources take priority. `--base REF` sets the comparison point. `--repo PATH` runs against another checkout.

## Wiring

- Validation: run it ahead of the project's own build, lint and test command.
- Commit time: where `growth-guards` is installed, its pre-commit chain runs `preflight --staged` itself. Any other hook calls the script with `--staged`; the chain's `GROWTH_GUARDS_PRE_COMMIT_LOCAL` lane runs its executable with no arguments, so wiring preflight there needs a wrapper that adds the flag.
- CI: `preflight --base origin/<default-branch>` on the PR head. The installed skill must be committed: a CI checkout sees tracked files only, never a machine-local `.agents` symlink.
