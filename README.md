# kendex

One place to manage AI coding-tool customizations across Claude Code,
Codex, OpenCode, Cursor, Pi, Gemini CLI, and GitHub Copilot, personally
and per-project.

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
| Hooks | ● | ● | ● | ● | — | ● | ● |
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
  [kendex.ai/download](https://kendex.ai/download).

For the CLI on its own: `brew install vanillagreencom/kendex/kendex-cli`,
`yay -S kendex`, or the curl
command on macOS. Every install option is on
[kendex.ai/download](https://kendex.ai/download).

Build from source (Rust and Node required):

```sh
cargo build --release -p kendex-cli               # the `kendex` CLI
npm ci --prefix ui
cd crates/app && ../../ui/node_modules/.bin/tauri dev   # the desktop app
```

A debug build keeps its own home under the platform data directory
(`kendex-dev`) instead of yours, so a branch cannot leave records your
installed kendex will not read. Your global skills and agents are not
visible to it, and nothing it writes reaches them.

The boundary is the home, not the whole machine. Three things stay outside
it: a repository you point a debug build at is the real one, so
`--scope project` reads and writes it as usual; a harness folder you set to
an explicit absolute path is used as written; and programs kendex runs for
you, `npm` among them, still see your real home. To dogfood a build against
your real setup, say so:

```sh
KENDEX_REAL_HOME=1 cargo run -p kendex-cli --bin kendex -- list
```

Only `1` opts out — the hatch permits writes to a real machine, so a value
nobody could read as consent leaves the sandbox on.

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

Coming from v1: `kendex import` migrates manifests and locks in place
(originals go to the trash first), then `kendex refresh` regenerates
everything.

## Engine rules

1. Generated artifacts are always overwritable; intent lives only in `kendex.toml`.
2. Nothing you set is clobbered, and nothing you removed is silently re-added.
3. Unmanaged files are reported, not touched. Foreign symlinks are conflicts, not targets.
4. An item's recorded source is durable; a name collision across sources is a hard error naming the original.
5. Enable/disable is a lossless rename or a structured config edit that preserves every unrelated key.
6. One writer per scope; concurrent applies get a "busy" error, never an interleaved write.

## CLI surface

| Verb | Does |
|---|---|
| `add` (or bare `kendex <source>`) | declare and install agents/skills from a source |
| `remove`, `adopt`, `apply` | undeclare, take ownership, reconcile |
| `refresh` | re-resolve sources, regenerate every installation |
| `verify` | drift check; exit 1 on any failing row |
| `list` (`ls`), `check` | observe everything; sanity report |
| `source add/remove/enable/disable/refresh` | manage catalogs per scope |
| `project add/remove/list/discover` | the app's project registry |
| `report` | file an issue, routed to the asset's owner |
| `update`, `update-pi`, `import`, `init` | self-update, Pi packages, v1 migration, catalog scaffolding |

Scopes: `--scope project|global|all` (v1 aliases `p/local`, `g/user`,
`both/*`), `-g` as a shortcut for global.

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
