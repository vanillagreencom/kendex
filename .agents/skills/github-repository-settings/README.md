# GitHub repository settings

Selects local review instructions or the enabled GitHub review files for a repository. To report live rulesets, required checks and merge settings, opt in to [platform checks](references/platform-checks.md).

## Features

- Previews a takeover of existing review files without writes, and reports hand edits.
- Takes unmanaged review content over, once the package is set up.
- Renders the selected review files through bot-instructions.
- Checks the review files without writes, from the working tree or from the index, and reports the check location.
- Removes its marked review files and the owned review region, and keeps unrelated content.

[The skill](SKILL.md) lists the commands.

## Install

Install this package with its required `bot-instructions` and `review-gate` dependencies. Use kendex 1.23.0 or later. bot-instructions requires Python 3.11 or later.

## How it works

Set up retires the previous owner, runs this package's installer and transfers the arming record. Ordinary write commands refuse until the package is set up, and name Set up.

The installer keeps the renderer's marker gate on setup and on later refreshes, so it refuses unmanaged content. Armed `adopt` is the takeover. Run `render` after it.

Removing the package runs core's declared cleanup, and core revokes the arming record:

- While bot-instructions remains armed, the cleanup keeps the shared marked files, so core can render the old owner after a failure.
- Otherwise it removes the marked review files and region content, in an unarmed clone too.
- Recovery renders the old owner's full output from current inputs, and replaces earlier edits to marked content.

A direct `retire` leaves the arming record for core.

## Setup

1. Choose `hosted` or `local` for `GITHUB_STANDARD_CHECK_LOCATION`.
2. Remote review defaults to `off`. To render the bots the existing `[bot-instructions]` manifest table enables, set `GITHUB_STANDARD_BOT_REVIEW` to `on`.
3. Put these settings under `[env]`, as [the settings example](kendex.settings.toml.example) shows.
4. Use Set up on this package's desktop page, or the CLI's disclosed install with `--allow-repo-effects`.

Local output writes the `AGENTS.md` review pointer region. It needs the manifest's `codex` flag and an installed bot-instructions package inside the checkout. It leaves remote review files alone. This package installs no hosted CI.

## Licence

MIT
