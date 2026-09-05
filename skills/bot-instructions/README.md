# bot-instructions

Review instructions for GitHub review bots. Repository owners use one configuration file to set the rules each bot reads.

## Install

```bash
kendex add vanillagreencom/kendex --skill bot-instructions
```

Requires Python 3.11 or newer. Follow [references/checklist.md](references/checklist.md) § Adding a repo to enable the bots and adopt their files.

## Features

- Generate the instruction files for the configured review bots.
- Check generated files for local changes or missing output.
- Adopt existing bot files into the managed configuration.
- Apply shared rules and rules for selected paths.

## How it works

You enable the review bots in `bot-instructions.toml`. The renderer reads that file and the shared review rules. It prepares and validates each bot's instruction file before writing it. The check command compares those files with the configured output.

## Settings

- `bot-instructions.toml`: every key and the glob dialect, [schemas/repo-toml.md](schemas/repo-toml.md).
- Which block lands in which file, and why each omission is deliberate: [schemas/renders.md](schemas/renders.md).
- Per-repo settings no file can configure: [references/checklist.md](references/checklist.md) § The settings.
