---
name: github-repository-settings
description: "Load to preview, render or check a repository's selected review instruction files and local review pointer."
summary: "Reads GitHub standard settings and calls the existing bot-instructions library."
license: MIT
user-invocable: true
dependencies:
  required: [bot-instructions, review-gate]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [review, configuration]
---

# GitHub repository settings

```bash
.agents/skills/github-repository-settings/scripts/github-repository-settings adopt --dry-run
.agents/skills/github-repository-settings/scripts/github-repository-settings render
.agents/skills/github-repository-settings/scripts/github-repository-settings check
.agents/skills/github-repository-settings/scripts/github-repository-settings check --staged
```

Use `adopt --dry-run` to preview takeover without writes. Keep the existing [bot-instructions manifest](../bot-instructions/schemas/repo-toml.md). The library reports hand edits and refuses symlinked preview targets. `render` writes the selected outputs. `check` compares them without writes. `check --staged` reads settings and review files from the index. Process and private-file settings keep their precedence. Exit codes: 0 clean, 1 findings, 2 could not complete. Options and the check report contract: `scripts/github-repository-settings --help`.

Preview grants no write ownership. Use the existing [bot-instructions adoption operation](../bot-instructions/SKILL.md) to take unmanaged content over before rendering it.

Before adoption, choose `hosted` or `local` for `GITHUB_STANDARD_CHECK_LOCATION` in the settings `[env]` table. It has no default. This package reports the value during `check`; it installs no hosted CI. `GITHUB_STANDARD_BOT_REVIEW` defaults to `off`. Off selects the library's local output. On selects its full output and the bots enabled in the manifest. Local output requires the manifest's `codex` flag and an installed bot-instructions package inside the checkout. The [settings example](kendex.settings.toml.example) declares the settings.

`bot-instructions` is the temporary renderer, schema and validator dependency. KEN-2362 removes that dependency after the ownership transition. `review-gate` provides the existing settings reader. Install these required packages beside this package. The catalog must pass its dependency and render checks with the latest released kendex engine. Release any required engine support before adopting catalog content that needs it.

This package declares no repository effects. Installation does not transfer the existing bot-instructions effects or change their callers.
