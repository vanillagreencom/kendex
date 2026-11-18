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

Use `adopt --dry-run` to preview takeover without writes. Keep the existing [bot-instructions manifest](../bot-instructions/schemas/repo-toml.md). The library reports hand edits and refuses symlinked preview targets. `render` writes the selected outputs. `check` compares them without writes. `check --staged` reads tracked settings and review files from the index. Process and private-file settings keep their working values and normal precedence. A nested settings file keeps its working values only when it is absent from HEAD and the index. A staged deletion stays absent even if its working file remains. Exit codes: 0 clean, 1 findings, 2 could not complete. Options and the check report contract: `scripts/github-repository-settings --help`.

Preview grants no write ownership. To adopt the effect, choose the settings below, then use Set up on this package's desktop page, or the CLI's disclosed install with `--allow-repo-effects`, using kendex 1.21.0 or later. Core retires the armed predecessor, runs `setup-install`, and transfers arming records. The same installer also serves ordinary core rendering and one-run consumer refresh. Every call uses the shared renderer's marker gate and refuses unmanaged content; takeover requires explicit armed `adopt`. A missing location choice refuses installation; core reports recovery and leaves the previous owner armed when recovery succeeds.

Direct `render`, `adopt` and `retire` require this package's arming record in this worktree. Armed `adopt` takes unmanaged content over and reports divergence; follow it with `render`. `retire` removes the shared library's marked review files and the owned region body, preserving its heading and surroundings. Core runs the distinct declared `setup-retire` operation for package removal and failed-install cleanup. While bot-instructions remains armed in this worktree, cleanup preserves all shared-marker outputs for core's old-owner recovery render. Otherwise it removes only the shared library's marked outputs and region, including partial writes before arming exists. Recovery regenerates the old owner's full output from current inputs; it does not preserve prior edits to marked content. Direct retirement alone does not change the record. The read-only `region-bounds --input PATH` protocol delegates to the shared library without settings or arming checks, so core can read, commit and restore the owned region.

Before adoption, choose `hosted` or `local` for `GITHUB_STANDARD_CHECK_LOCATION` in the settings `[env]` table. It has no default. When both adoption keys are empty or absent, `check` reports not adopted and exits 0 without judging review files. This package reports the value during `check`; it installs no hosted CI. `GITHUB_STANDARD_BOT_REVIEW` defaults to `off`. Off selects the library's local output. On selects its full output and the bots enabled in the manifest. Local output requires the manifest's `codex` flag and an installed bot-instructions package inside the checkout. The [settings example](kendex.settings.toml.example) declares the settings.

`bot-instructions` is the temporary renderer, schema and validator dependency. KEN-2362 removes that dependency after the ownership transition. `review-gate` provides the existing settings reader. Install these required packages beside this package. The catalog must pass its dependency and render checks with the latest released kendex engine. Release any required engine support before adopting catalog content that needs it.

The declaration retains the shared renderer's written paths and markers. bot-instructions keeps its declaration for predecessor discovery and recovery; core selects one owner and never falls back from an unarmed new owner, except one installed only as another package's dependency: until its setup runs here or in the main checkout, an installed bot-instructions stays the owner. The package reads the existing core arming inventory without writing it; its record semantics are those of kendex 1.21.0 `repo_effects/armed.rs`. For staged review-file checker selection, follow `commit-guards/SKILL.md` § Git hooks.
