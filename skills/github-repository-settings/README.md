# GitHub repository settings

Select local review instructions or enabled GitHub review files for a repository.

## Operations

- `adopt --dry-run` previews takeover without writes and reports hand edits.
- `render` writes the selected files through bot-instructions.
- `check [--staged]` compares files without writes and reports the check location. With `--staged`, it reads settings and review files from the index. Process and private-file settings keep their precedence.

## Setup

Install this package with its required `bot-instructions` and `review-gate` dependencies. Python 3.11 or later is required by bot-instructions. Use the latest released kendex engine accepted by the catalog checks.

Choose `hosted` or `local` for `GITHUB_STANDARD_CHECK_LOCATION` before adoption. Remote review defaults to `off`. Set `GITHUB_STANDARD_BOT_REVIEW` to `on` to render the bots enabled in the existing `[bot-instructions]` manifest table. Put these settings under `[env]` as shown in [the settings example](kendex.settings.toml.example).

Local output writes the `AGENTS.md` review pointer region. It needs the manifest's `codex` flag and an installed bot-instructions package inside the checkout. It leaves remote files outside this operation. This package installs no hosted CI and declares no repository effects.

The bot-instructions renderer, schemas and validators remain a temporary dependency. KEN-2362 removes that dependency after the ownership transition. See [the skill](SKILL.md) for commands.

## Licence

MIT
