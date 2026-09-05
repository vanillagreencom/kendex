# size-ratchet

A file-size check for repository maintainers. It measures markdown in bytes and code in lines, with a baseline for existing oversized files.

## Install

```bash
kendex add vanillagreencom/kendex --skill size-ratchet
.agents/skills/size-ratchet/scripts/size-ratchet --seed
```

Requires Git, awk and standard POSIX tools. Bash 3.2 is supported. Configure size classes before the first seed. Review and commit the baseline it writes. When growth-guards is installed, its pre-commit hook runs the size check.

## Features

- Check file sizes against the configured path limits.
- Block growth of oversized files recorded in the baseline.
- Tighten baseline entries when files shrink.
- Check baseline changes against the committed baseline.

## How it works

The checker reads tracked files and the configured size limits. It measures each included file in its assigned unit. It compares the result with the limit and any saved baseline entry. The staged check updates smaller baseline entries and reports files that exceed their allowed size.

## Settings

Set project values in `kendex.settings.toml` under `[env]`. Local overrides can use `.kendex/settings.toml` or `.env.local`. Process values have priority.

- `SIZE_RATCHET_THRESHOLD`: the line limit for files outside a class.
- `SIZE_RATCHET_CLASSES`: project limits by path pattern.
- `SIZE_RATCHET_BASELINE`: the saved file-size baseline.
- `SIZE_RATCHET_EXCLUDES`: the file of excluded path patterns and reasons.

Use `size-ratchet --help` for all keys and flags. [references/policy.md](references/policy.md) defines baseline and exclusion formats.

## Path classes

Set `SIZE_RATCHET_CLASSES` in `kendex.settings.toml` under `[env]` to override a file class. Each entry has the form `pattern=threshold`, with semicolons between entries. [references/policy.md](references/policy.md) defines class selection, baseline changes and exclusions.
