# bot-instructions

Review instructions for GitHub review bots. Repository owners use one configuration file to set the rules each bot reads.

When github-repository-settings declares repository effects, core selects that package as the review-file owner, except where it was installed only as another package's dependency and is set up neither in this checkout nor in its main checkout: this package then keeps the files until that setup. This package stays installed as its temporary renderer and retains its declaration for transfer and recovery.

## Features

- Generate the instruction files for the configured review bots.
- Write the shared review rules to one file per repository, which Codex, Copilot and CodeRabbit are pointed at.
- Check generated files for local changes or missing output.
- Adopt existing bot files into the managed configuration.
- Apply shared rules and rules for selected paths.

## Install

```bash
kendex add vanillagreencom/kendex --skill bot-instructions
```

## How it works

- You list the review bots you use in the `[bot-instructions]` table of the project's `kendex.toml`.
- The skill reads that table together with the review rules every bot shares.
- It checks each bot's instruction file is valid, then writes it where that bot looks for it.
- The check command compares the files on disk with what the table says they should hold.

## Setup

Requires Python 3.11 or newer. Follow [references/checklist.md](references/checklist.md) § Adding a repo to enable the bots and adopt their files.

- `[bot-instructions]` in `kendex.toml`, or `kendex-local.toml` for a source catalog: every key and the glob dialect, [schemas/repo-toml.md](schemas/repo-toml.md).
- Which block lands in which file, and why each omission is deliberate: [schemas/renders.md](schemas/renders.md).
- Per-repo settings no file can configure: [references/checklist.md](references/checklist.md) § The settings.

## Licence

MIT, in the repository's LICENSE file.
