# vstack

Cross-harness package manager for AI coding tools.

Author skills, agents, and hooks once. Install them into Claude Code, Cursor, OpenCode, Codex, or Pi from one CLI.

[![Rust](https://img.shields.io/badge/Rust-%20-000000?style=flat-square&logo=rust)](./cli/Cargo.toml)
[![Ratatui](https://img.shields.io/badge/TUI-ratatui-5D3FD3?style=flat-square)](https://ratatui.rs)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-supported-0EA5E9?style=flat-square)](#supported-tools)
[![Cursor](https://img.shields.io/badge/Cursor-supported-0EA5E9?style=flat-square)](#supported-tools)
[![OpenCode](https://img.shields.io/badge/OpenCode-supported-0EA5E9?style=flat-square)](#supported-tools)
[![Codex](https://img.shields.io/badge/Codex-supported-0EA5E9?style=flat-square)](#supported-tools)
[![Pi](https://img.shields.io/badge/Pi-supported-0EA5E9?style=flat-square)](#supported-tools)

![vstack TUI](docs/assets/vstack-tui.png)

---

## What It Is

A package manager for AI coding workflows. Skills, agents, and hooks live in a source repo; vstack translates them for whichever tool you use. Install per project or for the whole machine, customize freely, and updates won't overwrite your edits.

## Highlights

- **One source, many tools.** Claude Code, Cursor, OpenCode, Codex, Pi.
- **Per project or global.** One workspace or every project on the machine.
- **Customizable.** Tweak agents and skills per project — edits survive updates.
- **Skill dependencies.** Skills declare what they need; everything installs together.
- **Swappable catalogs.** Use this catalog or any compatible repo.
- **Fast TUI.** Native Rust interface for browsing, installing, and managing packages.

## Quick Start

Requires Rust. If you don't have it, install [rustup](https://rustup.rs) (Linux/macOS/WSL):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

Then, open new terminal and:

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack
```

Nix users can also run the CLI from the flake:

```bash
nix run github:vanillagreencom/vstack -- add vanillagreencom/vstack
```

That opens an interactive installer where you pick which agents, skills, hooks, and Pi extensions to bring in, and which tools to install them into.

### Flightdeck upgrade note

If Flightdeck reports a run-store permission error after upgrading, such as `mode=644 expected 600`, review and repair legacy permissions with:

```bash
vstack flightdeck migrate-permissions --dry-run
vstack flightdeck migrate-permissions
```

The migration tightens Flightdeck run-store directories to `0700` and files to `0600`. It refuses symlinks, foreign-owned paths, and group/other-writable paths instead of silently masking possible tampering.

## How It Works

A source repo is a package registry. vstack discovers what's there, asks which pieces you want, then writes the right files for each tool.

```text
source repo
├─ agents
├─ skills
├─ hooks
└─ Pi extensions
        ▼
   vstack CLI / TUI
        ▼
Claude Code · Cursor · OpenCode · Codex · Pi
```

### Customizing With `vstack.toml`

`vstack add` writes a `vstack.toml` at your project root. Edit it to customize per-agent behavior, then run `vstack refresh` to apply. Generated agent files are overwritten on refresh — `vstack.toml` is the stable home for overrides.

```toml
# Skills assigned to each agent.
[agent-skills]
rust = ["github", "worktree"]

# Instructions added near the top of the generated agent file.
[agent-launch-instructions]
rust = "Read docs/architecture.md before coding."

# Extra instructions appended to the generated agent file.
[agent-additional-instructions]
rust = "Always run clippy before committing."

# Project instructions prepended to a skill's SKILL.md.
[skill-instructions]
trading-design = "Dark theme, green/red accents."

# Per-harness frontmatter overrides. Each table only affects its own harness.
[agent-frontmatter.claude]
rust = { color = "orange", model = "opus[1m]", effort = "xhigh", deny-tools = ["Agent", "AskUserQuestion"], background = false }

[agent-frontmatter.opencode]
rust = { color = "#f97316", model = "openai/gpt-5.5", model-reasoning-effort = "xhigh", deny-tools = ["task", "question"], mode = "subagent" }

[agent-frontmatter.codex]
rust = { model = "gpt-5.5", model-reasoning-effort = "xhigh", sandbox-mode = "danger-full-access" }

[agent-frontmatter.pi]
rust = { color = "orange", model = "openai-codex/gpt-5.5:xhigh", deny-tools = ["subagent", "question"], allowed-subagents = ["scout"], pane = true }
```

Key rules:

- **Prefer `deny-tools` over allowlists.** Each harness inherits its normal tool set and blocks only what you list. Claude Code writes it as native `disallowedTools`; OpenCode emits `permission: <tool>: deny`; Pi enforces it via `pi-agents-tmux`. Cursor and Codex don't use per-agent deny lists — Codex subagents use `sandbox-mode`/approval instead.
- **Pi `allowed-subagents` enables `delegate_subagent`.** vstack engineer agents default to `allowed-subagents = ["scout"]` so dev agents can dispatch read-only reconnaissance without gaining full orchestration controls. Set `[]` to disable; non-engineer roles default to disabled (and gain `delegate_subagent` in their `deny-tools`). Aliases: `allowedSubagents`, `subagent-agents`, `subagent_agents`.
- **`effort` is written verbatim** by each harness. Valid: `low`, `medium`, `high`, `xhigh` (Claude also accepts `max`). Pi appends it to its model id as `:<effort>`; Pi has no native `max` thinking level, so provider metadata or bridge-specific overrides must map `xhigh` to provider values when needed.
- **OpenCode agents default to `mode: subagent`.** Set `mode = "primary"` only when you want an OpenCode primary agent. OpenCode `color` must be hex.
- **Claude `background` seeds from Pi `pane`** on first install (`pane = true` → `background = false`), then your edits are preserved on refresh.
- **Custom safety hooks (`[[custom-hooks]]`)** follow the same pattern. Direct edits to generated agent or skill files are also picked up where possible.

> **v3 migration:** legacy shared `[agent-frontmatter]` and `tools` allowlists are no longer read. Move overrides into `[agent-frontmatter.<harness>]` and switch allowlists to `deny-tools`.

## Supported Tools

| Tool | Notes |
|---|---|
| Claude Code | Richest native hook support. Works per project or globally. |
| Cursor | Project scope only; safety rules surface as `.cursor/rules`. |
| OpenCode | Config-dir aware. |
| Codex | Native hooks for supported events; events without a Codex equivalent fall back to safety guidance inside agent instructions. |
| Pi | Adds Pi extension installation alongside agents and skills. |

Windows: CLI runs natively; symlink mode falls back to copy.

## Package Catalog In This Repo

### Agents

| Agent | Role | Brief |
|---|---|---|
| `generalist` | engineer | General maintenance, cleanup, docs, stale references, and project hygiene. |
| `iced` | engineer | Iced UI implementation and architecture specialist. |
| `planner` | analyst | Turns requirements and scout findings into ordered implementation plans, plan files, and TPM handoff prompts when roadmap/issue planning is needed. |
| `researcher` | analyst | Exa-powered research specialist for evidence-backed findings reports. |
| `rust` | engineer | Rust engineer for systems work, performance, zero-allocation, and low-level design. |
| `scout` | analyst | Fast reconnaissance for unfamiliar code before planning or implementation; may write requested report artifacts. |
| `tpm` | manager | Technical program management and roadmap analysis agent. |
| `reviewer-arch` | reviewer | Reviews boundaries, abstractions, and architectural drift. |
| `reviewer-correctness` | reviewer | Reviews behavior regressions, compatibility, devex breaks, feature-gate leaks, and state/migration correctness. |
| `reviewer-doc` | reviewer | Reviews documentation accuracy and stale docs. |
| `reviewer-error` | reviewer | Reviews error handling, silent failures, and propagation. |
| `reviewer-perf` | reviewer | Reviews latency, benchmarks, and performance regressions. |
| `reviewer-quality` | reviewer | Reviews maintainability, simplification, abstraction value, type boundaries, and spaghetti-growth risk. |
| `reviewer-safety` | reviewer | Reviews unsafe Rust, memory safety, and concurrency correctness. |
| `reviewer-security` | reviewer | Reviews auth, input handling, and security risks. |
| `reviewer-structure` | reviewer | Reviews modularity, file size, and code organization. |
| `reviewer-test` | reviewer | Reviews test coverage, missing cases, and test quality. |

### Skills

`*` = needs project-local setup; see that skill's README.

#### Rust and Performance Guidance

Rust and performance reference material now lives directly in the `rust`, `reviewer-perf`, and `reviewer-safety` agent bodies as compact resource tables.

#### UI / Domain

| Skill | Brief |
|---|---|
| [`iced-rs`](skills/iced-rs/) | Iced 0.14 GUI expertise with bundled full-API reference and all upstream examples (incl. `iced_wgpu` source). |
| [`iced-shadcn`](skills/iced-shadcn/) | shadcn Base UI component planning, family decomposition, and parity audits for Iced. |
| [`price-handling`](skills/price-handling/) | Price rounding, epsilon comparison, and market-price handling. |
| [`trading-design`](skills/trading-design/) | Dense, professional trading-style interface design guidance. |

#### Workflow / Platform

| Skill | Brief |
|---|---|
| [`decider`](skills/decider/)* | Architectural decision document management and indexing. |
| [`deep-research`](skills/deep-research/) | Exa-powered deep research and portable findings report generation. |
| [`flightdeck`](skills/flightdeck/)* | Primary-agent tmux session supervisor for AI harness panes; runs Linear/GitHub issue and plan-file lanes with structured activity JSONL and Rust dashboard. Sub-agents do NOT load this directly. |
| [`github`](skills/github/)* | Bash CLI over the GitHub API for PR operations: threads, comments, reviews, CI logs, merging, and cross-PR analysis. |
| [`html-artifact`](skills/html-artifact/) | Standalone HTML artifacts for plans, reports, reviews, explainers, prototypes, and custom editors. |
| [`linear-dev`](skills/linear-dev/)* | Delegated implementation and review-fix issue workflows for dev agents. |
| [`linear`](skills/linear/)* | Bash CLI over Linear's GraphQL API with local cache, mutation syncing, and structured output (issues, cycles, milestones, projects). |
| [`linear-orch`](skills/linear-orch/)* | Primary-agent orchestrator for the per-issue Linear lifecycle (dev → review → submit → merge); spawns specialist sub-agents and review pipelines from inside a worktree. Sub-agents do NOT load this directly. |
| [`project-management`](skills/project-management/)* | TPM-driven planning, audits, roadmaps, and research-backed decomposition. |
| [`reviewer`](skills/reviewer/)* | Strict code-review, whole-codebase review, and QA-review ethos, scope boundaries, workflows, and canonical finding/verdict JSON schema. Loaded by any `reviewer-*` agent. |
| [`second-opinion`](skills/second-opinion/) | Cross-model review via the opposite AI CLI (Claude ↔ Codex). |
| [`worktree`](skills/worktree/)* | Git worktree create/list/remove with env/config symlinks and per-worktree bot identity. |

### Hooks

| Hook | Event | Brief |
|---|---|---|
| `block-bare-cd` | `PreToolUse` | Blocks unsafe bare `cd` usage and nudges toward subshell-safe patterns. |
| `pre-commit-check` | `PreToolUse` | Validates formatting and lint before commits. |
| `post-edit-lint` | `PostToolUse` | Runs lint checks after source edits. |
| `task-completed-check` | `TaskCompleted` | Runs final lint checks before marking work complete. Claude-Code-only — codex has no clean equivalent event. |

Hook installation per harness:

- **Claude Code** — script copied under `<scope>/.claude/hooks/`, registered in `settings.json` plus the owning agent's frontmatter.
- **Codex** — native install when codex supports the event (`PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`, `PermissionRequest`, `SessionStart`, `UserPromptSubmit`, `Stop`): script copied to `<scope>/.codex/hooks/`, entry merged into `<scope>/.codex/hooks.json`, and `[features] codex_hooks = true` ensured in `config.toml`. Events without a codex equivalent fall back to a safety advisory appended to each agent's `developer_instructions`.
- **Cursor** — safety advisory `.mdc` written under `<scope>/.cursor/rules/`.
- **OpenCode** — permission rule + instruction file referenced from `opencode.json`.
- **Pi** — same hook behaviors ship as a first-class Pi extension, `@vanillagreen/pi-hooks`. It listens on Pi's `tool_call`/`tool_result`/`turn_end` events and uses `{block: true, reason}` to short-circuit unsafe tool calls. Each hook is independently toggleable from the pi-extension-manager settings panel.

Use `harnesses:` in a hook's frontmatter to scope it explicitly (e.g. `harnesses: [claude-code]`).

**Parity:** changes to a hook script must land in the same commit as the matching change in `pi-extensions/pi-hooks/extensions/hooks.ts` — see [AGENTS.md](AGENTS.md) for the rule.

### Pi Extensions

Install [`pi-extension-manager`](pi-extensions/pi-extension-manager/README.md) to browse and configure these from inside Pi. Current packages target Pi 0.75+ and follow Pi 0.75's Node.js baseline by declaring `engines.node >=22.19.0`; Pi 0.73/0.74 installs should stay on older package releases if they must remain on Node 20.

Extensions can ship an `instructions.md` (declared via `pi.appendSystem` in `package.json`); on install, vstack mirrors it into the scope's `APPEND_SYSTEM.md` (`<project>/.pi/APPEND_SYSTEM.md` or `~/.pi/agent/APPEND_SYSTEM.md`) so Pi loads tool-usage guidance into the system prompt. Removed/disabled extensions strip their block automatically.

If a Pi extension declares production dependencies (`dependencies` or `optionalDependencies`), vstack installs them inside the deployed package directory with `npm install --omit=dev --package-lock=false --legacy-peer-deps --no-audit --no-fund` before registering the package with Pi. The installed `node_modules/` stays local to the Pi scope and is ignored by vstack source hashing/verify drift checks.

| Extension | Purpose |
|---|---|
| [`pi-agents-tmux`](pi-extensions/pi-agents-tmux/README.md) | Delegate work to subagents in isolated, persistent tmux panes. |
| [`pi-background-tasks`](pi-extensions/pi-background-tasks/README.md) | Non-blocking shell tasks with a live status dashboard. |
| [`pi-caveman`](pi-extensions/pi-caveman/README.md) | Caveman communication mode. |
| [`pi-claude-bridge`](pi-extensions/pi-claude-bridge/README.md) | Claude Code provider bridge with prompt-context forwarding. |
| [`pi-codex-minimal-tools`](pi-extensions/pi-codex-minimal-tools/README.md) | Codex-style image, patch, and image-generation tools alongside Pi natives. |
| [`pi-extension-manager`](pi-extensions/pi-extension-manager/README.md) | Pi-styled package manager and inline settings editor. |
| [`pi-flightdeck`](pi-extensions/pi-flightdeck/README.md) | Optional Pi UI support for Flightdeck: inline mini-dashboard, pause banner, notifications, and `/flightdeck` focus/open integration for the Rust app. |
| [`pi-hooks`](pi-extensions/pi-hooks/README.md) | First-class Pi port of the vstack safety hooks: bare-cd blocking, pre-commit fmt+clippy, post-edit clippy, end-of-turn lint. |
| [`pi-output-policy`](pi-extensions/pi-output-policy/README.md) | Large-output policy with transcript-budget-aware truncation, spill-file preservation, and balanced/compact/compat modes. |
| [`pi-prompt-stash`](pi-extensions/pi-prompt-stash/README.md) | Per-session prompt stash history with stash/pop editor. |
| [`pi-qol`](pi-extensions/pi-qol/README.md) | Compact statusline, multiline input, image chips, session naming and search. |
| [`pi-questions`](pi-extensions/pi-questions/README.md) | Structured multi-tab popup questions with bridge-driven replies. |
| [`pi-session-bridge`](pi-extensions/pi-session-bridge/README.md) | Side-channel for external control, event streaming, prompt sending, and the Pi activity broker stream. |
| [`pi-session-manager`](pi-extensions/pi-session-manager/README.md) | Polished session browser for searching, resuming, and managing Pi sessions. |
| [`pi-skills-manager`](pi-extensions/pi-skills-manager/README.md) | Browse, create, edit, and toggle Pi skills from a dedicated shell. |
| [`pi-task-panel`](pi-extensions/pi-task-panel/README.md) | Persistent structured task panel above the status line. |
| [`pi-tool-renderer`](pi-extensions/pi-tool-renderer/README.md) | Compact Claude/opencode-style renderers for built-in tools. |
| [`pi-web-tools`](pi-extensions/pi-web-tools/README.md) | First-party web stack: search, deep research, fetch, video, and more. |

## Extras

Extras are optional non-agent packages distributed by vstack, such as theme packs. See [`extras/README.md`](extras/README.md) for the catalog and per-extra documentation.

```bash
vstack apply vanillagreen-themes --theme ghibli-serene-nature --target ghostty,vscodium,tmux,pi
```

`vstack apply` uses global/user scope by default for app themes. Add `--dry-run` to preview planned changes before writing config; add `--no-ghostty-shaders` for palette-only Ghostty applies. The TUI's **Extras** tab also lets you pick a theme interactively — select the pack, hit `Apply`, and you get a native picker with a Ghostty shader checkbox plus **Uninstall & revert** after a successful apply.

## License

MIT
