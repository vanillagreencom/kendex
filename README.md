# kendex

kendex is a desktop app and command-line tool (CLI) for AI coding tools such as Claude Code, Codex and Cursor. It manages agents, skills, hooks and other customizations. You set them up once and use them across your tools and projects.

<p><img src="docs/img/harness-claude.png" alt="Claude Code" height="20"> <img src="docs/img/harness-codex.png" alt="Codex" height="20"> <img src="docs/img/harness-opencode.png" alt="OpenCode" height="20"> <img src="docs/img/harness-cursor.png" alt="Cursor" height="20"> <img src="docs/img/harness-pi.png" alt="Pi" height="20"> <img src="docs/img/harness-gemini.png" alt="Gemini CLI" height="20"> <img src="docs/img/harness-copilot.png" alt="GitHub Copilot" height="20"></p>

![kendex](docs/img/tour.gif)

## Install

```sh
curl -fsSL https://kendex.ai/install.sh | sh
```

| Platform | Install |
|---|---|
| Linux | the script above installs the app and the CLI |
| Arch Linux | `yay -S kendex-bin` |
| macOS | the script above installs the CLI; `brew install vanillagreencom/kendex/kendex` installs the app |
| Windows | the installer at [kendex.ai/download](https://kendex.ai/download), which also lists the CLI-only packages |

Installing a package from a git repository needs git 2.41 or newer; kendex refuses an older one and names the version it found. A package on a local path needs no git. On Windows, `kendex guard` runs the commit guards through the `sh` that Git for Windows ships.

## Features

- Install customizations across your coding tools from one setup.
- Convert agent and skill files into the formats each tool reads.
- Preview package changes before applying them.
- Keep personal settings and a separate setup for each project.
- Manage customizations you already have.
- Browse the [community marketplace](https://kendex.ai) and subscribe to package repositories.
- Find outdated packages and update them.
- Add your own instructions and tool settings to agents and skills.
- Enable, disable or remove installed customizations.
- See where an installed package came from.

## Supported tools

| | Claude Code | Codex | OpenCode | Cursor | Pi | Gemini CLI | GitHub Copilot |
|---|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| Agents | ● | ● | ● | ●¹ | ● | ● | ● |
| Skills | ● | ● | ● | ●¹ | ● | ● | ● |
| Hooks | ● | ● | ●² | ●¹ ² | ●³ | ● | ● |
| Commands | ● | ●⁴ | ○ | ○ | ○ | ● | - |
| MCP servers | ● | ○ | ○ | ○ | - | ●⁵ | ● |
| Plugins | ◐ | ○ | ○ | ○ | - | ○ | ◐ |
| Pi extensions | - | - | - | - | ● | - | - |

● managed · ◐ enable and disable · ○ shown read-only · - not supported.

1. Cursor is managed in projects only.
2. OpenCode has no hook runtime and Cursor takes a rule rather than a registration, so a hook on either is instructions the model may ignore; a `PreToolUse` hook on `Bash` also sets OpenCode's `permission.bash` to ask.
3. Pi runs hooks through the `pi-hooks` extension; without it registered they are only instructions.
4. Codex stores a command as a skill.
5. Gemini records whether an MCP server is on in one machine-wide file, so a project can declare a server but not switch it off there.

The full per-tool facts are in [docs/adapters](docs/adapters/README.md).

## How it works

The desktop app and CLI share the core code that manages your setup. kendex reads the customizations in each coding tool's folders. You declare the setup you want in a `kendex.toml` file for each project. kendex compares that file with the installed setup and shows a preview. After you apply the changes, a lock file records what kendex installed. To undo an installation, remove the package.

## Settings

- Use `kendex.toml` to declare a project setup and add instructions or options for each tool.
- Change package settings in a package's Customize tab or `kendex.settings.toml`.
- Keep private settings and secrets in `.env.local`.

## Documentation

- [Package authoring](docs/authoring/README.md)
- [Development guide](docs/DEVELOPMENT.md)
- [Default catalog](https://kendex.ai/m/vanillagreencom/kendex)
