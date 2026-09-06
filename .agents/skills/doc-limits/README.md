# doc-limits

A byte-size check for repository documents. It limits the Markdown that agents read and reports documents that exceed their path class.

## Install

```bash
kendex add vanillagreencom/kendex --skill doc-limits
```

Requires Git, Bash and standard POSIX tools. Bash 3.2 is supported. The commit-guards pre-commit hook runs the installed check.

## Features

- Check document sizes against byte limits.
- Apply project limits by path pattern.
- Permit excluded documents only through a reasoned exclusion row.
- Check staged documents with staged policy.

## How it works

The checker selects tracked Markdown documents. It selects each document's first matching size class. It compares the byte count with that limit and reports every oversized document. The check leaves the files and index unchanged.

## Settings

Set project values in `kendex.settings.toml` under `[env]`. Local overrides use `.kendex/settings.toml` or `.env.local`. Process values have priority. `doc-limits --help` lists the settings and flags.

## Path classes

Set `DOC_LIMITS_CLASSES` to override document limits. Each entry uses `pattern=Nk`, with semicolons between entries. The `k` suffix means 1024 bytes. [references/policy.md](references/policy.md) defines class selection and reasoned exclusions.
