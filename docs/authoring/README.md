# Authoring a marketplace

A kendex marketplace is a git repository of skills, agents, and hooks. There
is no registration step and no format to learn first. Any repository that
holds skills already works: `kendex marketplace subscribe owner/repo` finds
them where they are (`skills/`, `.claude/skills`, a single root `SKILL.md`, or
a Claude plugin registry). Everything below is optional structure that makes a
repository easier to browse, check, and publish.

## Start here

Scaffold a repository:

```sh
kendex marketplace new my-marketplace
```

That creates the folder with a `kendex.toml`, a `README`, the check workflow,
and a licence, and initialises it as a git repository. Add packages, push it to
GitHub, and submit it.

Templates for each file are in [`templates/`](templates/).

## The layout

```
my-marketplace/
  kendex.toml            what this marketplace says about itself
  agents/<name>.md       one agent per file
  skills/<name>/SKILL.md one folder per skill (the folder name is its name)
  skills/<name>/kendex.settings.toml.example  what that skill's settings are
  hooks/<name>.sh        commands/<name>.md   mcp/<name>.toml
  README.md              how to subscribe
  LICENSE
  .github/workflows/kendex-check.yml   the check, on every push
```

Two rules worth knowing:

- A skill's identity is its directory name. A `SKILL.md` whose `name:`
  disagrees with its folder is a check finding.
- Executable kinds are never guessed. Hooks, commands, and MCP servers install
  only from a repository that declares kendex's layout (any parseable
  `kendex.toml` does) or from a plugin registry. A `hooks/` folder in an
  undeclared repository is treated as repository tooling, not installable
  content.

## kendex.toml

```toml
[marketplace]
name = "my-marketplace"
description = "Skills for the whole team"
author = "Jane Doe"
license = "MIT"            # an SPDX id; omit while undecided
homepage = "https://example.com"
tags = ["rust", "review"]

# Optional: override where agents and skills live.
[catalog]
skills = ["skills", "extra-skills"]
agents = ["agents"]

# Optional: curated sets people install with one click. Members are bare
# names, in one list per kind: agents, skills, commands, hooks, mcp-servers.
[bundles.starter]
description = "Everything a new project needs"
skills = ["review"]
agents = ["scout"]
```

Everything is optional. A missing `[marketplace]` table means the directory
listing falls back to what GitHub knows. A `kendex.toml` that exists but does
not parse makes the whole catalog a finding, never a silently different
catalog.

## What each kind needs

- Skill: `skills/<name>/SKILL.md` with frontmatter `name` (matching the folder)
  and `description`. Extra files in the folder ship with it.
- A skill, command, or MCP server may add `summary`: the line a marketplace
  row shows and search reads, where `description` is what an agent reads to
  decide whether to load the item. Without one the row shows the `description`.
- Agent: `agents/<name>.md` with frontmatter `name` and `description`; optional
  `model`, `color`, and tool allow and deny lists.
- Hook: `hooks/<name>.sh` with a comment header naming `event` (for example
  `PreToolUse`), optional `matcher`, and a `description`.
- Command: `commands/<name>.md` with frontmatter `description`.
- MCP server: `mcp/<name>.toml` describing the server invocation.

A description is never guessed. An empty one stays empty and is a check
finding.

## Settings

Only skills seed settings into a project: [settings.md](settings.md).

## Tags

Set `tags = [...]` in `[marketplace]`, or per item in frontmatter. Tags come
from the author, never inferred from names.

## The check

```sh
kendex marketplace check
```

This validates every package the way installing validates it. Names each
harness's loader would refuse and skill trees that disagree with themselves
fail the check. The same safety rules an install runs print their findings
and the package's score, and fail nothing: the score is advisory wherever it
is shown. Breakage surfaces in your CI, not in someone else's install
preview. The scaffolded workflow runs it on each push and pull request.

## Publishing

Push the repository to GitHub, make it public, and submit it, from the app
(Mine, then Submit to community) or at
[kendex.ai/submit](https://kendex.ai/submit). kendex.ai verifies your push
authority over the repository, indexes it, and lists it. The listing follows
the repository id, so renaming the repository later keeps the listing.
