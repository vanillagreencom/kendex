---
name: github-repository-settings
description: "Load to manage repository review instruction files or report live GitHub review and merge settings."
summary: "Review instruction files and opt-in GitHub ruleset reporting."
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
repo-effects:
  configured-by: bot-instructions
  summary: "Renders the enabled review-bot instruction files, the pointed code-review file and the owned Code Review Rules region in this repository."
  writes:
    - ".github/copilot-instructions.md"
    - ".github/instructions/"
    - ".coderabbit.yaml"
    - ".pr_agent.toml"
    - "best_practices.md"
    - "REVIEW.md"
    - ".macroscope/"
    - "AGENTS.md"
  installer: "scripts/github-repository-settings setup-install"
  uninstaller: "scripts/github-repository-settings setup-retire"
  checker: "scripts/github-repository-settings check"
  staged-checker: "scripts/github-repository-settings check --staged"
  removal: "Core runs the declared setup-retire operation before removing the package and revokes its arming record."
  notes:
    - "Only surfaces enabled in the effective [bot-instructions] manifest are written."
    - "The review doctrine is written to [bot-instructions.repo] code_review_path, which defaults to .github/instructions/code-review.md and is refused outside that directory, so every path this package writes is one of those listed above."
---

# GitHub repository settings

```bash
.agents/skills/github-repository-settings/scripts/github-repository-settings adopt --dry-run
.agents/skills/github-repository-settings/scripts/github-repository-settings render
.agents/skills/github-repository-settings/scripts/github-repository-settings check
.agents/skills/github-repository-settings/scripts/github-repository-settings check --staged
```

- `adopt --dry-run` previews a takeover without writes.
- Keep the existing [bot-instructions manifest](../bot-instructions/schemas/repo-toml.md).
- `render` writes the selected outputs.
- `check` compares them without writes.
- `check --staged` reads tracked settings and review files from the index.
  - Process and private-file settings keep their working values and normal precedence.
  - A nested settings file keeps its working values only when it is absent from HEAD and the index.
  - A staged deletion stays absent, even if its working file remains.
  - For staged review-file checker selection, follow `commit-guards/SKILL.md` § Git hooks.
- `scripts/github-repository-settings --help` gives the options and the check report contract.

## Setup

1. Choose `GITHUB_STANDARD_BOT_REVIEW` in the `[env]` table of `kendex.settings.toml` at the repository root: `off`, the default, selects the library's local output, and `on` selects its full output and the bots the manifest enables.
2. Use Set up on this package's desktop page, or run the `kendex add` or `kendex apply` that installs this package with `--allow-repo-effects`, with kendex 1.23.0 or later.

- Local output requires the manifest's `codex` flag and an installed bot-instructions package inside the checkout.
- The [settings example](kendex.settings.toml.example) declares the setting.
- When `GITHUB_STANDARD_BOT_REVIEW` is empty or absent, `check` reports not adopted and exits 0 without judging review files.
- This package installs no hosted CI.
- Core selects one owner and never falls back from an unarmed new owner, with one exception. If this package is installed only as another package's dependency, an installed bot-instructions stays the owner until this package's setup runs here or in the main checkout.

## Takeover and removal

- Armed `adopt` takes unmanaged content over and reports divergence. Run `render` after it.
- `retire` removes the shared library's marked review files and the owned region body. It keeps the region's heading and surroundings.
- Core runs the separate declared `setup-retire` operation for package removal and for failed-install cleanup.
  - While bot-instructions remains armed in this worktree, that cleanup keeps every shared-marker output for core's recovery render of the old owner.
  - Otherwise it removes only the shared library's marked outputs and region, partial writes made before arming included.
  - The recovery render regenerates the old owner's full output from current inputs. It does not keep earlier edits to marked content.
- A direct `retire` does not change the arming record.

## Read when

- Before running the read-only GitHub report, migrating its settings from review-gate, or finding which package renders the review files: [references/platform-checks.md](references/platform-checks.md).
