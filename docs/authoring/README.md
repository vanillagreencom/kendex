# Authoring a marketplace

A kendex marketplace is a git repository of skills, agents, hooks, commands, MCP servers and Pi extensions. There is no registration step: any repository that holds skills already works, and `kendex marketplace subscribe owner/repo` finds them where they are (`skills/`, `.claude/skills`, a single root `SKILL.md`, or a Claude plugin registry). Everything below is the optional structure that makes a repository easier to browse, check and publish.

## Start

```sh
kendex marketplace new my-marketplace
```

That creates a folder holding a `kendex.toml`, a README, the check workflow and a licence, initialised as a git repository. Templates for each file are in [templates/](templates/); `kendex init --kind agent|skill|hook <name>` scaffolds one item.

## Layout

```
my-marketplace/
  kendex.toml                                  what this marketplace says about itself
  agents/<name>.md                             one agent per file
  skills/<name>/SKILL.md                       one folder per skill; the folder name is its name
  skills/<name>/kendex.settings.toml.example   the settings that skill declares
  hooks/<name>.sh   commands/<name>.md   mcp/<name>.toml   pi-extensions/<name>/
  README.md                                    how to subscribe
  LICENSE
  .github/workflows/kendex-check.yml           the check, on every push
```

- A skill's identity is its directory name; a `SKILL.md` whose `name:` disagrees with its folder is a check finding.
- Executable kinds are never guessed: hooks, commands and MCP servers install only from a repository that declares kendex's layout (any parseable `kendex.toml` does) or from a plugin registry. A `hooks/` folder in an undeclared repository is repository tooling, not installable content.

## kendex.toml

```toml
[marketplace]
name = "my-marketplace"
description = "Skills for the whole team"
author = "Jane Doe"
license = "MIT"            # an SPDX id; omit while undecided
homepage = "https://example.com"
tags = ["rust", "review"]

# Optional: where agents and skills live.
[catalog]
skills = ["skills", "extra-skills"]
agents = ["agents"]

# Optional: curated sets installed under one name. Members are bare names,
# one list per kind: agents, skills, commands, hooks, mcp-servers.
[bundles.starter]
description = "Everything a new project needs"
skills = ["review"]
agents = ["scout"]
```

Everything is optional. Without a `[marketplace]` table the directory listing falls back to what GitHub knows. A `kendex.toml` that exists but does not parse makes the whole catalog a finding, never a silently different catalog.

## What each kind needs

- Skill: `skills/<name>/SKILL.md` with frontmatter `name` (matching the folder) and `description`; extra files in the folder ship with it.
- Agent: `agents/<name>.md` with frontmatter `name` and `description`; optional `model`, `color`, and tool allow and deny lists.
- Hook: `hooks/<name>.sh` with a comment header naming `event`, an optional `matcher`, and a `description`.
- Command: `commands/<name>.md` with frontmatter `description`.
- MCP server: `mcp/<name>.toml` describing the invocation.
- A skill, command or MCP server may add `summary`, the line a marketplace row shows and search reads; `description` is what an agent reads to decide whether to load the item, and stands in when there is no summary.

A description is never guessed: an empty one stays empty and is a check finding. Tags come from `tags = [...]` in `[marketplace]` or per item in frontmatter, never inferred from names. A marketplace page renders the package's own body, the `SKILL.md` for a skill and the one file for every other kind; a `README.md` beside a skill ships with it and is listed, not rendered.

## Settings

Only a skill seeds settings into a project, through its `kendex.settings.toml.example`: [settings.md](settings.md).

For project-defined shell command restrictions, configure the [command-safety hook](command-safety.md).

## The check

```sh
kendex marketplace check
```

Validates every package the way installing validates it: names a harness's loader would refuse, skill trees that disagree with themselves, and settings templates outside the grammar fail it. The safety rules an install runs print their findings and the package's score and fail nothing; the score is advisory wherever it is shown. The scaffolded workflow runs the check on every push and pull request.

## Publishing

Push the repository to GitHub, make it public, and submit it from the app (Mine, then Submit to community), with `kendex marketplace submit`, or at [kendex.ai/submit](https://kendex.ai/submit). kendex.ai verifies your push authority over the repository, indexes it and lists it. The listing follows the repository id, so a renamed repository keeps its listing.
