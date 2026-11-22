# GitHub repository settings

github-repository-settings is a kendex package for repository owners who use AI code review. It renders the repository's local review instructions, or the review files of the GitHub review bots the owner enables. To report live rulesets, required checks and merge settings, opt in to [platform checks](references/platform-checks.md).

## Features

- Previews a takeover of existing review files without writes, and reports hand edits.
- Takes unmanaged review content over, once the package is set up.
- Renders the selected review files through bot-instructions.
- Checks the review files without writes, from the working tree or from the index, and reports the check location.
- Removes its marked review files and the owned review region, and keeps unrelated content.

[The skill](SKILL.md) lists the commands.

## Install

```bash
kendex add vanillagreencom/kendex --skill github-repository-settings
```

Needs kendex 1.23.0 or later. bot-instructions, which kendex installs with this package, needs Python 3.11 or later.

## How it works

Set up takes the review files over from bot-instructions. Until Set up runs, the write commands refuse and name Set up. Removing the package removes its marked review files and the review region, unless bot-instructions is still set up. Edits to marked content do not survive removal.

## Setup

1. Choose `hosted` or `local` for `GITHUB_STANDARD_CHECK_LOCATION`. It has no default. `check` reports the value. Adoption and setup refuse while it is empty. `adopt`, `render`, `check` and setup refuse any value other than `hosted`, `local` or empty.
2. `GITHUB_STANDARD_BOT_REVIEW` defaults to `off`, which selects local output. To render the bots the existing `[bot-instructions]` manifest table enables, set it to `on`.
3. Put these settings in the `[env]` table of `kendex.settings.toml` at the repository root, as [the settings example](kendex.settings.toml.example) shows.
4. Use Set up on this package's desktop page, or run the `kendex add` or `kendex apply` that installs this package with `--allow-repo-effects`.

Local output writes the `AGENTS.md` review pointer region. It needs the manifest's `codex` flag and an installed bot-instructions package inside the checkout. It leaves remote review files alone. This package installs no hosted CI.

## Licence

MIT
