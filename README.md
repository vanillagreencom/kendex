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

> ✨ **Also check out [VGS](https://github.com/vanillagreencom/vgs)** — our newly released Hyprland / Niri quickshell. 🚀

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

By default, vstack scans `agents/`, `skills/`, `hooks/`, `pi-extensions/`, and `extras/`. Source repos with a different layout can declare catalog roots in their source `vstack.toml`:

```toml
[catalog]
agents = ["pkgs/agents"]
skills = ["pkgs/skills/*", "one-offs/specific-skill"]
hooks = ["automation/vstack-hooks"]
pi_extensions = ["pkgs/plugins/pi-*", "pkgs/plugins/a-specific-extension"]
extras = ["theme-packs"]
```

Each path is relative to the source repo. A path may point at a container directory; skills, Pi extensions, and extras may name one specific item directory, while agents and hooks may also name one specific `.md` or `.sh` file. `*` is supported on the final path segment only. Omitted keys keep the default directory for that item kind, and an empty list (`skills = []`) declares that the source ships no items of that kind.

`vstack check` only calls an installed item removed upstream when every configured root for its kind exists and every item under them was readable. A configured root that has gone missing is reported as a source layout problem to investigate, never as a `vstack remove` to run.

### Customizing With `vstack.toml`

`vstack add` writes a `vstack.toml` at your project root. Edit it to customize per-agent behavior, then run `vstack refresh` to apply. Generated agent files are overwritten on refresh — `vstack.toml` is the stable home for overrides.

```toml
# Where this project's OWN skills live (must be a top-level key, above any table).
# Refresh links each subdirectory into .agents/skills/<name>.
project-skills-dir = "project-skills"

# Skills assigned to each agent.
[agent-skills]
rust = ["github", "worktree"]

# Instructions added near the top of the generated agent file.
# The reserved key `all` applies to every agent; when an agent also has its
# own entry, both render — shared first, then the agent's own, separated by
# a blank line. (`"*"` is accepted as an alias for `all`.)
[agent-launch-instructions]
all = "Run `just setup` before anything else."
rust = "Read docs/architecture.md before coding."

# Extra instructions appended to the generated agent file.
# `all` works here the same way.
[agent-additional-instructions]
rust = "Always run clippy before committing."

# Project instructions prepended to a skill's SKILL.md.
# `all` applies to every installed and project-owned skill.
[skill-instructions]
trading-design = "Dark theme, green/red accents."

# Per-harness frontmatter overrides. Each table only affects its own harness.
[agent-frontmatter.claude]
rust = { color = "orange", model = "inherit", effort = "xhigh", deny-tools = ["Agent", "AskUserQuestion"], background = false }

[agent-frontmatter.opencode]
rust = { color = "#f97316", model = "openai/gpt-5.6-sol", model-reasoning-effort = "xhigh", deny-tools = ["task", "question"], mode = "subagent" }

[agent-frontmatter.codex]
rust = { nickname-candidates = ["Rust-Atlas", "Rust-Delta"], model = "gpt-5.6-sol", model-reasoning-effort = "xhigh", sandbox-mode = "danger-full-access" }

[agent-frontmatter.pi]
rust = { color = "orange", model = "inherit", deny-tools = ["subagent", "get_subagent_result", "steer_subagent", "stop_subagent", "question"], allowed-subagents = ["scout"], pane = true }
```

`vstack refresh` applies `[skill-instructions]` to both locked skills and
project-owned skills at `.agents/skills/<name>/SKILL.md`. For project-owned
skills, vstack maintains only its marked `Project Instructions` block and
leaves the rest of the skill untouched. A `.agents` symlink into another
working tree of the same repository is accepted (the layout the `worktree`
skill provisions); if `.agents` resolves outside the repository entirely, run
the command from the checkout that owns it.

Skills vstack did not install belong in `project-skills-dir` (tracked), never
as real directories inside `.agents`. Refresh links each one into
`.agents/skills/<name>`, which keeps `.agents` fully untracked — a hybrid
tracked/untracked `.agents` tree loses installed skills on rebase.

Key rules:

- **Prefer `deny-tools` over allowlists.** Each harness inherits its normal tool set and blocks only what you list. Claude Code writes it as native `disallowedTools`; OpenCode emits `permission: <tool>: deny`; Pi enforces it via `pi-agents-tmux`. Cursor and Codex don't use per-agent deny lists — Codex subagents use `sandbox-mode`/approval instead.
- **Codex `nickname-candidates` are display-only.** Generated Codex agents use name-prefixed candidates such as `Rust-Atlas` and `Rust-Delta` so the Codex app nickname still shows which agent definition was launched. Codex still identifies the subagent by its `name`.
- **Heavy agents inherit the parent model by default.** Claude and Pi `opus` agents use `model = "inherit"` in `vstack.toml` (Pi omits `model:` in the generated agent file). Cheaper agents such as `scout` can still pin an explicit model. Override any agent's model in `[agent-frontmatter.<harness>]`.
- **Pi `allowed-subagents` enables `delegate_subagent`.** vstack engineer agents default to `allowed-subagents = ["scout"]` so dev agents can dispatch read-only reconnaissance without gaining full orchestration controls. Set `[]` to disable; non-engineer roles default to disabled (and gain `delegate_subagent` in their `deny-tools`). Aliases: `allowedSubagents`, `subagent-agents`, `subagent_agents`.
- **`effort` is written verbatim** by each harness after per-harness frontmatter overrides are applied. Valid: `low`, `medium`, `high`, `xhigh` (Claude also accepts `max`). When Pi emits an explicit model, it appends effort as `:<effort>`; Pi has no native `max` thinking level, so provider metadata or bridge-specific overrides must map `xhigh` to provider values when needed.
- **OpenCode agents default to `mode: subagent`.** Set `mode = "primary"` only when you want an OpenCode primary agent. OpenCode `color` must be hex.
- **Claude `background` seeds from Pi `pane`** on first install (`pane = true` → `background = false`), then your edits are preserved on refresh.
- **Custom safety hooks (`[[custom-hooks]]`)** follow the same pattern. Direct edits to generated agent or skill files are also picked up where possible.

> **v3 migration:** legacy shared `[agent-frontmatter]` and `tools` allowlists are no longer read. Move overrides into `[agent-frontmatter.<harness>]` and switch allowlists to `deny-tools`.

### Checking For Drift

`vstack check` compares every installed scope against its source and reports outdated items, items removed upstream, skills on disk but missing from the lock, lock entries whose install is incomplete — the files are missing, or the harness never registered them and so would never run or load them (agents, skills, hooks and Pi packages; extras record no single install path) — agents referencing uninstalled skills, and sources it cannot resolve, inventory, or fully read. An install whose evidence is itself unreadable (a Pi `settings.json` that will not parse, say) gets its own section naming the file to repair, never a reinstall for a package that may be fine. A source's malformed asset is reported only for the kinds that scope installs from it — the same limit the suggestions below already apply — so a broken Pi package in a source a project draws only skills from is not that project's drift. It also lists items a source ships that the scope never installed (only kinds the scope already uses are offered) — a suggestion, not drift. Its exit code is the contract: `0` clean, `1` drift found, `2` the check itself could not run. Suggestions alone exit `0`. Every remediation command it prints is scoped to the section it sits under — a global finding prints `vstack remove -g <name>` and `vstack add -g …`, since `add` and `remove` default to project scope — so a printed command always acts on the install it was printed for. `vstack refresh` is the exception and stays unflagged: it reinstalls at every scope an item is locked at.

```bash
vstack check                 # human report; also looks up the latest CLI version
vstack check --quiet         # prints nothing when clean — what the session-drift-check hook runs
vstack check --json          # machine-readable report on stdout
vstack check --offline       # no network at all
vstack check --no-available  # skip the available-but-not-installed suggestions
```

`check` never touches the project's git state and never blocks on the network: the verdict comes from the lock, the source trees, and each cache's recorded refresh outcome. The human report additionally looks up the latest CLI version, which `--quiet` and `--offline` skip — so the session-start path (`--quiet`) is fully local and works offline. Remote source caches under `~/.vstack/cache/` are vstack's own clones: one older than six hours is refreshed in the background (never with `--offline`), so cache news lands at the next session rather than costing this one. A single failed refresh is a footnote — working offline stays quiet — but a cache that has been failing for more than two refresh windows, or one vstack cannot write to at all, counts as drift so a permanently broken remote cannot read as clean forever; the report names the cause and points at `vstack refresh`. Background and startup fetches never prompt for credentials, so a private source needs a configured git credential helper or ssh key; interactive `vstack add` and `vstack refresh` keep git's normal prompting. `vstack refresh` applies updates; `check` itself never installs or removes anything. `--quiet` is bounded by construction: each section lists at most ten items and closes with `… and M more (run `vstack check` for the full report)`, while the section headers keep the true counts — the full listing is always one `vstack check` away.

### Runtime Settings

Portable skill scripts load runtime settings in this order:

1. `.env`
2. `vstack.settings.toml` or `.vstack/settings.toml`
3. `.env.local`

Use `vstack.settings.toml` for non-sensitive project defaults that should be committed, such as worktree paths, issue regexes, bot usernames, default Linear team names, and second-opinion command defaults. Keep `.env.local` for secrets, tokens, API keys, private URLs, signing keys, and personal overrides. See [`vstack.settings.toml.example`](vstack.settings.toml.example) and [`.env.local.example`](.env.local.example).

When a project install includes a skill that ships `vstack.settings.toml.example`, `vstack add` seeds `vstack.settings.toml` with that skill's non-sensitive defaults. Existing files are merged by adding missing `[env]` keys only; user values are not overwritten. `vstack refresh` also performs this merge for installed skills.

Secret values may also be injected by the parent process at launch time. GitHub and Linear helpers preserve already-resolved `GH_TOKEN`, `GITHUB_TOKEN`, `GH_BOT_TOKEN`, and `LINEAR_API_KEY` values before reading local files or resolving `op://` references.

## Supported Tools

| Tool | Notes |
|---|---|
| Claude Code | Richest native hook support. Works per project or globally. |
| Cursor | Project scope only; safety rules surface as `.cursor/rules`. |
| OpenCode | Config-dir aware. |
| Codex | Project agents live in `.codex/agents/*.toml`; their Required Skills section points project installs at `.agents/skills/<name>/SKILL.md`. Native hooks are used for supported events; events without a Codex equivalent fall back to safety guidance inside agent instructions. |
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
| `reviewer-test` | reviewer | Reviews test coverage, missing cases, and test quality. |

### Skills

`*` = needs project-local setup; see that skill's README.

#### UI / Domain

| Skill | Brief |
|---|---|
| [`iced-rs`](skills/iced-rs/) | Iced 0.14 GUI expertise with bundled full-API reference and all upstream examples (incl. `iced_wgpu` source). |
| [`price-handling`](skills/price-handling/) | Price rounding, epsilon comparison, and market-price handling. |
| [`trading-design`](skills/trading-design/) | Dense, professional trading-style interface design guidance. |

#### Workflow / Platform

| Skill | Brief |
|---|---|
| [`decider`](skills/decider/)* | Architectural decision document management and indexing. |
| [`deep-research`](skills/deep-research/)* | Exa-powered deep research and portable findings report generation. |
| [`dep-radar`](skills/dep-radar/) | Sweeps pinned versions (SDKs, runtime binaries, npm/cargo deps, vendored forks, model weights), researches upstream, and applies upgrades with their fallout fixed in the same PR. |
| [`github`](skills/github/)* | Bash CLI over the GitHub API for PR operations: threads, comments, reviews, CI logs, merging, and cross-PR analysis. |
| [`dev`](skills/dev/)* | Delegated implementation and review-fix issue workflows for dev agents. |
| [`linear`](skills/linear/)* | Bash CLI over Linear's GraphQL API with local cache, mutation syncing, and structured output (issues, cycles, milestones, projects). |
| [`orch`](skills/orch/)* | Primary-agent orchestration for Linear/GitHub issues: prepare, delegate, review, submit, merge, launch handoff, and oversee session fleets. Sub-agents do NOT load this directly. |
| [`code-quality`](skills/code-quality/) | Generic code-authoring standards for dev agents: no fail-open branches, prove-your-guards, comment rules, over-engineering and cleanup discipline. |
| [`preflight`](skills/preflight/) | Diff-scoped deterministic pre-review checks: shell syntax/fail-open lint, dead doc citations, unlinked TODOs, JSON/TOML syntax. |
| [`project-management`](skills/project-management/)* | TPM-driven planning, audits, roadmaps, and research-backed decomposition. |
| [`review-gate`](skills/review-gate/)* | Org-wide PR merge gate driven by a single review-evidence predicate (approvals, trusted checks, comment-form passes, outage attestation), with convergence scripts and an offline decision-table selftest. |
| [`reviewer`](skills/reviewer/) | Strict code-review, whole-codebase review, and QA-review ethos, scope boundaries, workflows, and canonical finding/verdict JSON schema. Loaded by any `reviewer-*` agent. |
| [`second-opinion`](skills/second-opinion/) | Cross-model review via the opposite AI CLI (Claude ↔ Codex). |
| [`growth-guards`](skills/growth-guards/)* | Four repo growth checks beside `size-ratchet`: flat work-marker ban, byte ceiling on newly added files, blanket lint-suppression ban with a tighten-only bare-allow baseline, and a conventional commit-message gate. Each check independently invocable. |
| [`size-ratchet`](skills/size-ratchet/)* | Tighten-only file-size gate over tracked files: new offenders, growth past a baseline row, and baselines looser than reality all fail; `--update` only lowers or removes rows, never adds or raises. |
| [`worktree`](skills/worktree/)* | Git worktree create/list/remove with env/config symlinks and per-worktree bot identity. |

### Hooks

| Hook | Event | Brief |
|---|---|---|
| `block-bare-cd` | `PreToolUse` | Blocks unsafe bare `cd` usage and nudges toward subshell-safe patterns. |
| `block-unsafe-rm` | `PreToolUse` | Refuses a recursive `rm` whose path starts with a variable that may expand empty (`rm -rf $DIR/$NAME`, `"$P/x"`, `${X:-}`) — the shape the harness halts the whole session on with a "Dangerous rm operation on possibly-empty variable path" prompt, even with permissions bypassed. Names the accepted rewrite: `rm -rf -- "${NAME:?}/sub"` or a literal absolute path. |
| `block-repo-copy` | `PreToolUse` | Refuses a recursive copy (`cp -r`/`-R`/`-a`, recursive or archive `rsync`, local `git clone`, `tar` create-to-extract pipe) when the source carries repository history or a build tree AND the destination resolves under a temp/scratch root. Temp roots are commonly RAM-backed tmpfs, where such a copy fills the filesystem and every process writing there fails with ENOSPC. |
| `pre-commit-check` | `PreToolUse` | Validates formatting and lint before commits. Rust Clippy lane is scoped to staged packages and configurable via `VSTACK_PRE_COMMIT_RUST_CLIPPY` (custom command or `off`). |
| `post-edit-lint` | `PostToolUse` | Runs lint checks after source edits. |
| `task-completed-check` | `TaskCompleted` | Runs final lint checks before marking work complete. Claude-Code-only — codex has no clean equivalent event. |
| `session-drift-check` | `SessionStart` | On a fresh session start (not resume or compact) runs `vstack check --quiet` and hands the agent the drift report — outdated items (`vstack refresh`), items removed upstream (`vstack remove <name>`, `-g` in a global section), unreachable sources — plus, alongside drift, items available but not installed (`vstack add --<kind> <name>`, pending your approval). Prints nothing when the install is current; one line when `vstack` is not on `PATH`, the project directory is unreadable, or the check fails unexpectedly. Never waits on the network: a stale source cache is refreshed in the background and reported at the next session. Never installs or removes anything and never touches the project's git; vstack's own source caches under `~/.vstack/cache` may be fetched at most once per TTL. `VSTACK_DRIFT_HOOK=off` disables it, `VSTACK_DRIFT_HOOK_AVAILABLE=off` hides the available-item suggestions. Claude Code and Codex only (native `SessionStart`); Pi gets the same report from `pi-hooks`. |

Hook installation per harness:

- **Claude Code** — script copied under `<scope>/.claude/hooks/`, registered in `settings.json` plus the owning agent's frontmatter. Both artifacts are what `check`/`verify` require — a script whose `settings.json` entry was deleted, or one whose entry points at a different script, is drift, because Claude Code would never run it. A registration you keep in `settings.local.json` instead counts: Claude Code merges it, so it runs.
- **Codex** — native install when codex supports the event (`PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`, `PermissionRequest`, `SessionStart`, `UserPromptSubmit`, `Stop`): script copied to `<scope>/.codex/hooks/`, entry merged into `<scope>/.codex/hooks.json`, and `[features] hooks = true` ensured in `config.toml`. Events without a codex equivalent fall back to a safety advisory appended to each agent's `developer_instructions`. All three artifacts are what `check`/`verify` require of a native codex hook — a script whose registration was deleted, or a scope with the `hooks` feature switched off, is drift, because codex would never run it.
- **Cursor** — safety advisory `.mdc` written under `<scope>/.cursor/rules/`.
- **OpenCode** — permission rule + instruction file referenced from `opencode.json`.
- **Pi** — same hook behaviors ship as a first-class Pi extension, `@vanillagreen/pi-hooks`. It listens on Pi's `session_start`/`tool_call`/`tool_result`/`turn_end` events and uses `{block: true, reason}` to short-circuit unsafe tool calls. Each hook is independently toggleable from the pi-extension-manager settings panel.

Use `harnesses:` in a hook's frontmatter to scope it explicitly (e.g. `harnesses: [claude-code]`).

### Pi Extensions

Install [`pi-extension-manager`](pi-extensions/pi-extension-manager/README.md) to browse and configure these from inside Pi. Current packages target Pi 0.75+ and follow Pi 0.75's Node.js baseline by declaring `engines.node >=22.19.0`; Pi 0.73/0.74 installs should stay on older package releases if they must remain on Node 20.

Extensions can ship an `instructions.md` (declared via `pi.appendSystem` in `package.json`); on install, vstack mirrors it into the scope's `APPEND_SYSTEM.md` (`<project>/.pi/APPEND_SYSTEM.md` or `~/.pi/agent/APPEND_SYSTEM.md`) so Pi loads tool-usage guidance into the system prompt. Removed/disabled extensions strip their block automatically.

If a Pi extension declares production dependencies (`dependencies` or `optionalDependencies`), vstack installs them inside the deployed package directory with `npm install --omit=dev --package-lock=false --legacy-peer-deps --no-audit --no-fund` before registering the package with Pi. The installed `node_modules/` stays local to the Pi scope and is ignored by vstack source hashing/verify drift checks.

Installing a package writes two artifacts: the copy under `<scope>/packages/<name>` and its entry in the scope's Pi `settings.json` `packages` array. Both are what `check`/`verify` require — a copied package whose entry was deleted, or whose entry points at another package's directory, is drift, because Pi would never load it. Any spelling of the path that still resolves to the same directory counts, so a hand-edited entry keeps working.

| Extension | Purpose |
|---|---|
| [`pi-agents-tmux`](pi-extensions/pi-agents-tmux/README.md) | Delegate work to subagents in isolated, persistent tmux panes. |
| [`pi-background-tasks`](pi-extensions/pi-background-tasks/README.md) | Non-blocking shell tasks with a live status dashboard. |
| [`pi-caveman`](pi-extensions/pi-caveman/README.md) | Caveman communication mode. |
| [`pi-claude-bridge`](pi-extensions/pi-claude-bridge/README.md) | Claude Code provider bridge with prompt-context forwarding. |
| [`pi-codex-minimal-tools`](pi-extensions/pi-codex-minimal-tools/README.md) | Codex-style image, patch, and image-generation tools alongside Pi natives. |
| [`pi-extension-manager`](pi-extensions/pi-extension-manager/README.md) | Pi-styled package manager and inline settings editor. |
| [`pi-hooks`](pi-extensions/pi-hooks/README.md) | First-class Pi port of the vstack safety hooks: bare-cd blocking, pre-commit fmt+clippy, post-edit clippy, end-of-turn lint. |
| [`pi-output-policy`](pi-extensions/pi-output-policy/README.md) | Large-output policy with runaway model-response interruption, transcript-budget-aware tool truncation, spill-file preservation, and balanced/compact/compat modes. |
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

Extras are optional non-agent packages — theme packs and similar — that a source
repo can ship under `extras/`. This repo ships none; point vstack at a catalog
that does.

```bash
vstack apply <pack> --theme <name> --target ghostty,vscodium,tmux,pi
```

`vstack apply` uses global/user scope by default. Add `--dry-run` to preview
changes before writing config, `--no-ghostty-shaders` for palette-only Ghostty
applies, and `--revert` to undo a previous apply. The TUI's **Extras** tab
offers the same flow interactively.

## License

MIT
