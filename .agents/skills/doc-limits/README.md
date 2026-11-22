# doc-limits

A byte-size check for the Markdown documents a coding harness loads at every turn. It reports each document over the limit its path class sets.

## Features

- Apply project limits by path pattern.
- Skip the files kendex generates, and exclude other documents only with a written reason.
- Check staged documents against the staged settings and exclusions.
- Fail the check for a document over its limit.

## Install

```bash
kendex add vanillagreencom/kendex --skill doc-limits
```

## How it works

The checker measures every tracked `AGENTS.md`, `CLAUDE.md`, `GEMINI.md` and `SKILL.md`, each under its first matching class. It compares the byte count with that limit and reports every oversized document. The check leaves the files and index unchanged.

## Path classes

Set `DOC_LIMITS_CLASSES` to override the limit of a measured file. Each entry uses `pattern=Nk`, with semicolons between entries. The `k` suffix means 1024 bytes. [references/policy.md](references/policy.md) says how a file's class is chosen and how to exclude a document with a written reason.

## Setup

Requires Git, Bash, jq, the commit-guards skill and standard POSIX tools. Bash 3.2 is supported. The commit-guards pre-commit hook runs the installed check.

Set project values in `kendex.settings.toml` under `[env]`. Local overrides use `.kendex/settings.toml` or `.env.local`. Process values have priority. `doc-limits --help` lists the settings and flags.

## Licence

MIT, in the repository's LICENSE file.
