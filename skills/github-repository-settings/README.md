# GitHub repository settings

Review-instruction setup for repository maintainers. Select a local review pointer or the enabled GitHub review files.

## Features

- Preview adoption without writing files, and report hand edits.
- Write the selected review files through bot-instructions.
- Check review files against their source, including staged changes.

## Install

```bash
kendex add vanillagreencom/kendex --skill github-repository-settings
```

## How it works

The package uses the existing bot-instructions manifest and renderer. A preview shows the files the selected mode would manage. It grants no write ownership. Follow [SKILL.md](SKILL.md) for adoption, rendering and checking, including the staged-reading contract.

## Setup

Install this package with its required `bot-instructions` and `review-gate` dependencies. Python 3.11 or later is required by bot-instructions. Use the latest released kendex engine accepted by the catalog checks.

Choose `hosted` or `local` for `GITHUB_STANDARD_CHECK_LOCATION` before adoption. Remote review defaults to `off`. Set `GITHUB_STANDARD_BOT_REVIEW` to `on` to render the bots enabled in the existing `[bot-instructions]` manifest table. Put these settings under `[env]` as shown in [the settings example](kendex.settings.toml.example).

Local output writes the `AGENTS.md` review pointer region. It needs the manifest's `codex` flag and an installed bot-instructions package inside the checkout. It leaves remote files outside this operation. This package installs no hosted CI and declares no repository effects.

The required dependencies supply rendering, validation and settings lookup. [SKILL.md](SKILL.md) owns their delivery and compatibility requirements. `scripts/github-repository-settings --help` lists command options.

## Licence

MIT
