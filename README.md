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

```bash
cargo install --git https://github.com/vanillagreencom/vstack.git vstack
vstack add vanillagreencom/vstack
```

That opens an interactive installer where you pick which agents, skills, hooks, and Pi extensions to bring in, and which tools to install them into.

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

`vstack add` writes a `vstack.toml` at your project root. Edit it to customize per-agent behavior; run `vstack refresh` to apply.

```toml
# Skills assigned to each agent.
[agent-skills]
rust = ["rust-arch", "rust-cargo", "github", "worktree"]

# Specialist skills loaded on demand.
[agent-skills-optional]
rust = [{ skill = "rust-async", when = "Async, tokio, channels" }]

# Instructions near the top of the generated agent file.
[agent-launch-instructions]
rust = "Read docs/architecture.md before coding."

# Extra instructions appended to the generated agent file.
[agent-additional-instructions]
rust = "Always run clippy before committing."

# Project instructions prepended to a skill's SKILL.md.
[skill-instructions]
trading-design = "Dark theme, green/red accents."

# Generated frontmatter. vstack populates active defaults; edit and refresh.
# Harness-specific values only affect that harness.
[agent-frontmatter.claude]
rust = { color = "orange", model = "opus[1m]", effort = "xhigh", deny-tools = ["Agent", "AskUserQuestion"], background = false }

[agent-frontmatter.opencode]
rust = { color = "#f97316", model = "openai/gpt-5.5", model-reasoning-effort = "xhigh", deny-tools = ["task", "question"], mode = "subagent" }

[agent-frontmatter.codex]
rust = { model = "gpt-5.5", model-reasoning-effort = "xhigh", sandbox-mode = "danger-full-access" }

[agent-frontmatter.pi]
rust = { color = "orange", model = "openai-codex/gpt-5.5:xhigh", deny-tools = ["subagent", "get_subagent_result", "steer_subagent", "stop_subagent", "question"], pane = true }
```

Prefer `deny-tools` for maintenance: Claude Code writes it as native `disallowedTools`, OpenCode writes it as `permission: <tool>: deny`, and Pi agents use it through the `pi-agents-tmux` extension while inheriting active tools by default. Claude Code also supports `effort`, `background`, `isolation`, and `memory` in generated subagent frontmatter; vstack seeds Claude `background` from Pi `pane` on first install (`pane = true` → `background = false`, `pane = false` → `background = true`) and omits `isolation` and `memory` unless configured. Subsequent edits to `background` in `[agent-frontmatter.claude]` are preserved on refresh. Each canonical agent declares its own `effort:` and harnesses write it verbatim — no cross-harness translation. OpenCode defaults every generated agent to `mode: subagent`; set `[agent-frontmatter.opencode].<agent>.mode = "primary"` only when you want an OpenCode primary agent. OpenCode writes `color` as hex and maps reasoning effort to `options.reasoningEffort` plus `reasoningSummary: auto` and `textVerbosity: medium`. Cursor/Codex do not have the same per-agent tool-deny frontmatter. For Pi agents installed through vstack, frontmatter edits belong in harness-specific `[agent-frontmatter.<harness>]` tables in `vstack.toml`, not in `.pi/agents/<name>.md`; generated agent files are overwritten by `vstack refresh`. The Pi `/agents` popup writes model/deny-tools/color changes to the Pi-specific table.

Migration notes for v3: legacy shared `[agent-frontmatter]` entries are no longer read or regenerated. Move them into the harness-specific table you want, such as `[agent-frontmatter.claude]` or `[agent-frontmatter.pi]`. Legacy `tools` allowlists are also ignored by generated agents; use `deny-tools` instead so each harness can inherit its normal tools and block only the risky ones.

Custom safety hooks (`[[custom-hooks]]`) follow the same pattern. Direct edits to generated agent or skill files are also picked up automatically where possible, but `vstack.toml` is the stable home for generated frontmatter overrides and reusable project guidance.

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
| `reviewer-doc` | reviewer | Reviews documentation accuracy and stale docs. |
| `reviewer-error` | reviewer | Reviews error handling, silent failures, and propagation. |
| `reviewer-perf` | reviewer | Reviews latency, benchmarks, and performance regressions. |
| `reviewer-safety` | reviewer | Reviews unsafe Rust, memory safety, and concurrency correctness. |
| `reviewer-security` | reviewer | Reviews auth, input handling, and security risks. |
| `reviewer-structure` | reviewer | Reviews modularity, file size, and code organization. |
| `reviewer-test` | reviewer | Reviews test coverage, missing cases, and test quality. |

### Skills

`*` = needs project-local setup; see that skill's README.

#### Rust

| Skill | Brief |
|---|---|
| [`rust-arch`](skills/rust-arch/) | Rust architecture rules, anti-patterns, and review heuristics. |
| [`rust-async`](skills/rust-async/) | Async internals, runtime patterns, cancellation, and concurrency composition. |
| [`rust-cargo`](skills/rust-cargo/) | Cargo workflows, workspaces, feature flags, and build/release config. |
| [`rust-conventions`](skills/rust-conventions/) | Style, layout, tests, and definition-of-done conventions. |
| [`rust-cross`](skills/rust-cross/) | Cross-compilation, target setup, and multi-platform builds. |
| [`rust-debugging`](skills/rust-debugging/) | GDB/LLDB, tracing, panic triage, and async runtime debugging. |
| [`rust-ffi`](skills/rust-ffi/) | Safe C interop and FFI wrapper patterns. |
| [`rust-no-std`](skills/rust-no-std/) | `no_std` design, alloc boundaries, and embedded-friendly structure. |
| [`rust-safety`](skills/rust-safety/) | Unsafe code review, SAFETY comments, and safety audit patterns. |

#### Performance

| Skill | Brief |
|---|---|
| [`perf-cache`](skills/perf-cache/) | Cache locality, false sharing, and data layout optimization. |
| [`perf-ebpf`](skills/perf-ebpf/) | Aya/eBPF instrumentation and kernel-level observability. |
| [`perf-latency`](skills/perf-latency/) | Benchmarking and percentile-focused latency measurement. |
| [`perf-lock-free`](skills/perf-lock-free/) | Atomics, loom verification, and lock-free correctness. |
| [`perf-profiling`](skills/perf-profiling/) | Flamegraphs, hotspot analysis, NUMA, and jitter investigation. |
| [`perf-simd`](skills/perf-simd/) | SIMD, auto-vectorization, intrinsics, and runtime dispatch. |
| [`perf-threading`](skills/perf-threading/) | Pinning, topology-aware concurrency, and jitter reduction. |
| [`perf-zero-alloc`](skills/perf-zero-alloc/) | Eliminating allocations in hot paths. |

#### UI / Domain

| Skill | Brief |
|---|---|
| [`iced-rs`](skills/iced-rs/) | Iced 0.14 patterns, reactive UI rules, and Elm-style structure. |
| [`iced-shadcn`](skills/iced-shadcn/) | shadcn Base UI component planning, family decomposition, and parity audits for Iced. |
| [`price-handling`](skills/price-handling/) | Price rounding, epsilon comparison, and market-price handling. |
| [`trading-design`](skills/trading-design/) | Dense, professional trading-style interface design guidance. |

#### Workflow / Platform

| Skill | Brief |
|---|---|
| [`decider`](skills/decider/)* | Architectural decision document management and indexing. |
| [`deep-research`](skills/deep-research/) | Exa-powered deep research and portable findings report generation. |
| [`github`](skills/github/)* | GitHub PR, thread, review, CI, and merge workflows. |
| [`issue-lifecycle`](skills/issue-lifecycle/)* | Delegated implementation, review, and QA issue workflows. |
| [`linear`](skills/linear/)* | Linear issue, cycle, milestone, and project workflows. |
| [`flightdeck`](skills/flightdeck/)* | Master session lifecycle for multi-issue parallel dev work; tmux-only. |
| [`orchestration`](skills/orchestration/)* | Per-issue lifecycle inside a worktree: dev → review → submit → merge. |
| [`project-management`](skills/project-management/)* | TPM-driven planning, audits, roadmaps, and research-backed decomposition. |
| [`second-opinion`](skills/second-opinion/) | Cross-model review via the opposite AI CLI (Claude ↔ Codex). |
| [`worktree`](skills/worktree/)* | Git worktree creation, env/config linkage, and isolated workflows. |

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

Install [`pi-extension-manager`](pi-extensions/pi-extension-manager/README.md) to browse and configure these from inside Pi.

Extensions can ship an `instructions.md` (declared via `pi.appendSystem` in `package.json`); on install, vstack mirrors it into the scope's `APPEND_SYSTEM.md` (`<project>/.pi/APPEND_SYSTEM.md` or `~/.pi/agent/APPEND_SYSTEM.md`) so Pi loads tool-usage guidance into the system prompt. Removed/disabled extensions strip their block automatically.

| Extension | Purpose |
|---|---|
| [`pi-agents-tmux`](pi-extensions/pi-agents-tmux/README.md) | Delegate work to subagents in isolated, persistent tmux panes. |
| [`pi-background-tasks`](pi-extensions/pi-background-tasks/README.md) | Non-blocking shell tasks with a live status dashboard. |
| [`pi-caveman`](pi-extensions/pi-caveman/README.md) | Caveman communication mode. |
| [`pi-claude-bridge`](pi-extensions/pi-claude-bridge/README.md) | Claude Code provider bridge with prompt-context forwarding. |
| [`pi-codex-minimal-tools`](pi-extensions/pi-codex-minimal-tools/README.md) | Codex-style image, patch, and image-generation tools alongside Pi natives. |
| [`pi-extension-manager`](pi-extensions/pi-extension-manager/README.md) | Pi-styled package manager and inline settings editor. |
| [`pi-flightdeck`](pi-extensions/pi-flightdeck/README.md) | ⚠️ **WIP — not production ready.** Mission-control dashboard for the `flightdeck` skill. |
| [`pi-hooks`](pi-extensions/pi-hooks/README.md) | First-class Pi port of the vstack safety hooks: bare-cd blocking, pre-commit fmt+clippy, post-edit clippy, end-of-turn lint. |
| [`pi-output-policy`](pi-extensions/pi-output-policy/README.md) | Large-output policy with truncation and spill-file preservation. |
| [`pi-prompt-stash`](pi-extensions/pi-prompt-stash/README.md) | Per-session prompt stash history with stash/pop editor. |
| [`pi-qol`](pi-extensions/pi-qol/README.md) | Compact statusline, multiline input, image chips, session naming and search. |
| [`pi-questions`](pi-extensions/pi-questions/README.md) | Structured multi-tab popup questions with bridge-driven replies. |
| [`pi-session-bridge`](pi-extensions/pi-session-bridge/README.md) | Side-channel for external control, event streaming, and prompt sending. |
| [`pi-session-manager`](pi-extensions/pi-session-manager/README.md) | Polished session browser for searching, resuming, and managing Pi sessions. |
| [`pi-skills-manager`](pi-extensions/pi-skills-manager/README.md) | Browse, create, edit, and toggle Pi skills from a dedicated shell. |
| [`pi-task-panel`](pi-extensions/pi-task-panel/README.md) | Persistent structured task panel above the status line. |
| [`pi-tool-renderer`](pi-extensions/pi-tool-renderer/README.md) | Compact Claude/opencode-style renderers for built-in tools. |
| [`pi-web-tools`](pi-extensions/pi-web-tools/README.md) | First-party web stack: search, deep research, fetch, video, and more. |

## Testing

The orchestration skill ships a self-contained regression suite. Each
file under `skills/orchestration/tests/*.sh` builds its own sandbox and
exits non-zero on failure; a runner discovers and aggregates them:

```bash
bash skills/orchestration/tests/run-all.sh
# Or filter by name fragment:
bash skills/orchestration/tests/run-all.sh flightdeck_mode
```

Flightdeck has its own layered test surface under
`skills/flightdeck/lib/flightdeck-core/tests/` — see
`skills/flightdeck/tests/README.md` for the parity + live-wake suites.

CLI integration tests live under `cli/`:

```bash
cd cli && cargo test
```

## License

MIT
