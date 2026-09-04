# kendex

One place to manage AI coding-tool customizations, personally and per project.

<p><img src="docs/img/harness-claude.png" alt="Claude Code" height="20"> <img src="docs/img/harness-codex.png" alt="Codex" height="20"> <img src="docs/img/harness-opencode.png" alt="OpenCode" height="20"> <img src="docs/img/harness-cursor.png" alt="Cursor" height="20"> <img src="docs/img/harness-pi.png" alt="Pi" height="20"> <img src="docs/img/harness-gemini.png" alt="Gemini CLI" height="20"> <img src="docs/img/harness-copilot.png" alt="GitHub Copilot" height="20"></p>

kendex installs agents, skills, hooks, commands, MCP servers, plugins and Pi extensions from git repositories of packages into the folders each coding tool reads. A desktop app and the `kendex` command share one engine. The community marketplace is at [kendex.ai](https://kendex.ai), and this repository's own `agents/`, `skills/`, `hooks/` and `pi-extensions/` are the [default catalog](https://kendex.ai/m/vanillagreencom/kendex) every install starts with.

![kendex](docs/img/tour.gif)

## Install

```sh
curl -fsSL https://kendex.ai/install.sh | sh
```

On Linux that installs the app and the command. On macOS it installs the command; the app is `brew install vanillagreencom/kendex/kendex`. Arch: `yay -S kendex-bin`. Windows: the installer at [kendex.ai/download](https://kendex.ai/download), which also lists the CLI-only packages.

Installing a package from a git repository needs git 2.41 or newer; kendex refuses on an older one, naming the version it found. A package on a local path needs no git. On Windows, `kendex guard` runs the commit guards through `sh`, so it needs the one Git for Windows ships.

## What it does

- Install a skill, agent or hook once and it lands where every tool reads it.
- Write an agent or skill as one file; kendex renders each tool's own format from it.
- See every change before it happens, and undo it after.
- Keep a personal setup and a separate setup per project.
- Bring the skills, agents, hooks and extensions you already have under management.
- Subscribe to any git repository of packages and install from it; browse and publish on the marketplace; install a shared collection from one link.
- See what is out of date across every tool and update in one step, the app and the command included.
- Set skills per agent, add your own instructions to a package, and override an agent's per-tool settings.

## What's supported

| | Claude Code | Codex | OpenCode | Cursor | Pi | Gemini CLI | GitHub Copilot |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Agents | ● | ● | ● | ●¹ | ● | ● | ● |
| Skills | ● | ● | ● | ●¹ | ● | ● | ● |
| Hooks | ● | ● | ●² | ●¹ ² | ●³ | ● | ● |
| Commands | ● | ●⁴ | ○ | ○ | ○ | ● | — |
| MCP servers | ● | ○ | ○ | ○ | — | ●⁵ | ● |
| Plugins | ◐ | ○ | ○ | ○ | — | ○ | ◐ |
| Pi extensions | — | — | — | — | ● | — | — |

● managed · ◐ enable and disable · ○ shown read-only · — no such surface.

1. Cursor is managed in projects only.
2. OpenCode has no hook runtime and Cursor takes a rule rather than a registration, so a hook on either is instructions the model may ignore; a `PreToolUse` hook on `Bash` also sets OpenCode's `permission.bash` to ask.
3. Pi runs hooks through the `pi-hooks` extension; without it registered they are only instructions.
4. Codex stores a command as a skill.
5. Gemini records whether an MCP server is on in one machine-wide file, so a project can declare a server but not switch it off there.

The full per-tool facts are in [docs/adapters](docs/adapters/README.md).

## How it works

Four verbs, always in this order: **scan** what every tool has, read-only; **declare** what you want in one `kendex.toml` per place; **diff** wanted against actual, which is the Home page's audit, `kendex apply --plan` and `kendex verify`; **apply** with a preview, transactionally. A package is fetched into a local cache, rendered with your own instructions and overrides baked in, written once into the project or your home, and linked into every tool that reads it. A lock file records what was installed, from where, and a content fingerprint.

What you can count on:

- Delete anything kendex generated and the next apply builds it back; what you asked for lives in `kendex.toml` and nowhere else.
- A value you set is never overwritten and one you deleted is never put back, in `kendex.toml` and in the keys kendex does not own in a tool's own config.
- A file kendex did not create is reported, never deleted. A link standing where an installed item belongs is a conflict for you to settle.
- Every installed item remembers where it came from; a second source claiming the same name is refused, naming the source that holds it.
- Switching an item off keeps it whole and every unrelated setting in that file stays as you left it.
- A tool's config file symlinked in from your dotfiles is edited through the link, and the link stays.
- Two applies to the same place never interleave.

## Customise

- `kendex.toml`, one per project root and one for your home: every declaration and every tweak. `[skill-instructions]` appends your instructions to a skill, `[agent-additional-instructions]` to an agent; `[agent-frontmatter.<tool>.<agent>]` overrides an agent's per-tool frontmatter; `[agent-skills]` sets skills per agent; `[[custom-hooks]]` declares your own hook commands; `[install] method = "copy"` writes a tree per tool instead of one shared tree, which is the way out on Windows without Developer Mode.
- `kendex.settings.toml`: the `[env]` keys the packages you install read, edited on the app's Settings page. Secrets go in `.env.local`, never there.
- Make a marketplace: [docs/authoring](docs/authoring/README.md). Work on kendex itself: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
