# kendex

One place to manage AI coding-tool customizations, personally and
per-project.

<img src="docs/img/harness-claude.png" alt="Claude Code" height="20">
<img src="docs/img/harness-codex.png" alt="Codex" height="20">
<img src="docs/img/harness-opencode.png" alt="OpenCode" height="20">
<img src="docs/img/harness-cursor.png" alt="Cursor" height="20">
<img src="docs/img/harness-pi.png" alt="Pi" height="20">
<img src="docs/img/harness-gemini.png" alt="Gemini CLI" height="20">
<img src="docs/img/harness-copilot.png" alt="GitHub Copilot" height="20">

Manages agents, skills, hooks, commands, MCP servers, plugins, and Pi
extensions. Desktop app and CLI over one engine, with a community at
[kendex.ai](https://kendex.ai).

Here for the packages? Browse the
[marketplace of skills, agents, and Pi extensions](https://kendex.ai/m/vanillagreencom/kendex).

![kendex](docs/img/tour.gif)

## Features

- Install a skill, agent, or hook once and it lands in the right place for every tool.
- Write an agent or skill as one file. kendex builds each tool's own format from it.
- See every change before it happens, and undo it after.
- Your edits and removals stay. kendex does not touch files it did not create.
- Keep a personal setup and a separate setup per project.
- Manage your existing skills, agents, hooks, or extensions inside kendex.
- Subscribe to any git repository of skills and install from it.
- Browse the community marketplace, and publish your own.
- Install a shared collection from one link.
- See what is out of date across every tool and fix it in one step.
- Set skills per agent, add instructions, and change per-tool settings.
- Update the app and CLI from inside kendex.

## What's supported

| | Claude Code | Codex | OpenCode | Cursor* | Pi | Gemini CLI | GitHub Copilot† |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Agents | ● | ● | ● | ● | ● | ● | ● |
| Skills | ● | ● | ● | ● | ● | ● | ● |
| Hooks | ● | ● | ● | ● | ●§ | ● | ● |
| Commands | ● | ○ | ○ | ○ | ○ | ● | — |
| MCP servers | ● | ○ | ○ | ○ | — | ●‡ | ● |
| Plugins | ◐ | ○ | ○ | ○ | — | ○ | ◐ |
| Pi extensions | — | — | — | — | ● | — | — |

● managed · ◐ enable/disable · ○ shown read-only · — no such surface.

Notes:

- *Cursor is project-only.
- †Copilot has no file-backed slash commands, so kendex cannot add them.
- †A project can switch a Copilot skill or server off, but cannot switch back on what personal Copilot settings hold down.
- †Copilot reads Claude Code's skills; one file stays one installation, listed under the tool it belongs to.
- ‡Gemini records MCP server state in one machine-wide file, so a project can declare a server but not switch it off there.
- ‡Gemini extensions install globally and switch on through an undocumented file, so they stay read-only.
- §kendex manages Pi hooks at both scopes like any other surface; the `pi-hooks` extension is what makes Pi run them, and without it registered they are only instructions Pi can ignore.

## Install

The app and the CLI. Each command installs both.

```sh
curl -fsSL https://kendex.ai/install.sh | sh
```

On Linux this installs the app and the `kendex` command. On macOS it installs
the command; get the app with the cask below.

- macOS: `brew install vanillagreencom/kendex/kendex`
- Arch: `yay -S kendex-bin`
- Windows: download the installer from
  [kendex.ai/download](https://kendex.ai/download). The commit guards are
  shell scripts that kendex runs through `sh`, so `guard install`, `guard
  run` and `guard check` need the `sh` that Git for Windows ships — the
  same one git uses to run a hook there.

For the CLI on its own: `brew install vanillagreencom/kendex/kendex-cli`,
`yay -S kendex`, or the curl
command on macOS. Every install option is on
[kendex.ai/download](https://kendex.ai/download).

Working on kendex itself: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

## How it works

```
  CATALOGS                YOUR CHOICES               YOUR TOOLS
  git repos of agents,    kendex.toml: what you      each tool's own folders
  skills, hooks, more     want, plus your tweaks     (.claude/ .codex/ .pi/ …)
       │                        │                          ▲
       ▼                        ▼                          │
  ┌──────────┐  render   ┌───────────────┐    apply   ┌────┴─────┐
  │  cached  │ ────────▶ │ finished files│ ─────────▶ │ links,   │
  │  copy    │           │ (your tweaks  │  preview,  │ copies,  │
  └──────────┘           │  baked in)    │  confirm,  │ config   │
                         └───────────────┘  journaled │ entries  │
                                                      └──────────┘
```

Four verbs, always in this order:

1. **scan** what every tool has (read-only).
2. **declare** what you want in one `kendex.toml` per place.
3. **diff** wanted against actual (the Sync page).
4. **apply** with a preview, transactionally.

Installing the `github` skill into a project for Claude Code, Codex, and Pi:

1. The catalog repo is fetched into a local cache.
2. The skill is rendered: catalog content with your project's instructions baked in.
3. The rendered copy lands once in the project (`.agents/skills/github`).
4. Claude Code links to it; Codex and Pi read the same folder. One copy, no drift.
5. A lock file records what was installed, from where, and a content fingerprint.

Agents are generated per tool from one source file. MCP servers and hooks
are edits inside a tool's own config that leave every other key untouched.
Pi extensions are npm packages, copied and registered. Generated files are
safe to regenerate; your intent lives only in `kendex.toml`.

## Quick start

```sh
kendex owner/catalog-repo --agent rust --skill github   # declare + install
kendex list                                             # what exists, everywhere
kendex verify                                           # non-zero exit on drift
kendex refresh                                          # regenerate from sources
kendex adopt skill handmade                             # manage an existing item
kendex apply --plan                                     # preview the full reconcile
```

## What you can count on

- Delete anything kendex generated and the next apply builds it back. What you asked for is written down in `kendex.toml` and nowhere else.
- A value you set is never overwritten, and one you deleted is never put back. That holds for `kendex.toml` and for the keys kendex does not own in a tool's own config.
- A file kendex did not create is reported to you, never deleted. A link standing where an installed item belongs is a conflict for you to settle, not something kendex writes over.
- Keep a tool's config file in your dotfiles and symlink it into place. kendex edits the real file through the link and leaves the link alone.
- Every installed item remembers where it came from. A second source claiming the same name is refused, and the refusal names the source that holds it.
- Switching an item off keeps it whole, so switching it back on gets you what you had. Every unrelated setting in that file stays as you left it.
- Two applies to the same place never interleave. Start one while another is running there and it tells you kendex is busy.

## CLI surface

| Verb | Does |
|---|---|
| `add` (or bare `kendex <source>`) | declare and install agents/skills from a source |
| `remove`, `adopt`, `apply` | undeclare (`--keep-declaration` uninstalls only), take ownership, reconcile |
| `refresh` | re-resolve sources, regenerate every installation |
| `verify` | drift check; exit 1 on any failing row |
| `list` (`ls`), `check` | observe everything; sanity report |
| `source add/remove/enable/disable/refresh` | manage catalogs per scope |
| `project add/remove/list/discover` | the app's project registry |
| `report` | file an issue, routed to the asset's owner |
| `update`, `update-pi`, `init` | self-update, Pi packages, catalog scaffolding |

Scopes: `--scope project|global|all`, `-g` as a shortcut for global.

## Marketplaces and the community

| Verb | Does |
|---|---|
| `marketplace subscribe/unsubscribe/list/browse` | point a scope at a catalog repo; leave keeping or removing its packages |
| `marketplace new/use/mine/import` | build a marketplace: scaffold, register an existing folder, copy packages you have |
| `marketplace check` (or `check --catalog . --strict`) | validate every package the way installing validates it |
| `marketplace submit [--dry-run/--status]` | preflight and submit to the kendex.ai directory |
| `login` / `logout` | sign in to kendex.ai with a code and a browser tab; the credential lives in your system keychain |
| `add https://kendex.ai/c/<id>` | install a shared collection in one preview |

Make your own marketplace: `kendex marketplace new <name>` scaffolds the
repository. The how-to and templates are in
[docs/authoring](docs/authoring/README.md), and on
[kendex.ai/docs/authoring](https://kendex.ai/docs/authoring).

This repository is the default catalog. The `agents/`, `skills/`, `hooks/`
and `pi-extensions/` directories at its root are what a fresh kendex
install offers.
