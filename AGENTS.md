# vstack

Cross-harness distribution system for AI coding skills, agents, hooks, and Pi extensions. Installs into Claude Code, Cursor, OpenCode, Codex, and Pi via a Rust CLI.

Reviewing a PR as a review bot? Follow `review-bots.md` (repo root) — reviewer context stays there, not here.

## Session handoffs

Session handoff files live ONLY in `docs/handoff/` — exactly one untracked file named `HANDOFF.md`, pruned each update to the minimum context a fresh session needs (no history/prose). The only tracked file there is `docs/handoff/README.md`, which documents the pattern; everything else is git-ignored. Read the handoff only when the user asks or starts a session from a handoff.

## Repo Layout

```
cli/src/
├── main.rs              CLI entry; routes to commands/
├── commands/            add, remove, list, check, update, update_pi, verify, refresh, init
├── pi_extension.rs      Pi extension discovery, install/remove, settings.json merge
├── config.rs            Lock file (JSON), project root detection, staleness/mtime helpers
├── scope.rs             Scope enum (project | global | all); uniform `--scope`/`-g` parsing
├── catalog.rs           Source catalog discovery from default dirs or vstack.toml `[catalog]`
├── mapping.rs           Source vstack.toml — MappingConfig (catalog, agent-skills, role-skills, hook-events)
├── project_config.rs    Project vstack.toml — ProjectConfig, ensure/write/update
├── resolve.rs           Shared helpers — skill-pair resolution, hook source attribution/matching, read_existing_extras, is_vstack_source
├── installer.rs         Symlink/copy logic, install/remove orchestration
├── installer/hooks.rs   Hook install/remove orchestration and shared Claude/Codex/Cursor helpers
├── installer/hooks/     Hook submodules — OpenCode cleanup/install and focused hook tests
├── harness/             (canonical → per-harness translation)
│   ├── claude.rs        → .claude/agents/*.md (disallowedTools, effort/background/isolation/memory, skills, hooks frontmatter)
│   ├── cursor.rs        → .cursor/rules/*.mdc (description + alwaysApply + skills)
│   ├── opencode.rs      → .opencode/agents/*.md (YAML frontmatter + skills)
│   ├── codex.rs         → .codex/agents/*.toml (developer_instructions + Required Skills section)
│   └── pi.rs            → .pi/agents/*.md (name, description, deny-tools, model, pane)
└── tui/                 Install wizard: install_flow, disk_mutations (worker-side install/remove/move/update writes), state, summary, multiselect, render

(agent.rs, skill.rs, hook.rs, frontmatter.rs are simple parsers — names match their job.)

vstack.toml              Source catalog + skill/hook-to-agent mapping (read at install)
agents/                  Default canonical agents dir — `role` field drives per-harness access control
skills/                  Default skill packages dir — each has SKILL.md with optional dependencies
hooks/                   Default safety hooks dir — bash scripts with YAML comment headers
pi-extensions/           Default Pi extension packages dir (npm-shaped). package.json has `pi.extensions`
skill-templates/         Templates for new skills
```

Seam map and sequenced split plan for `project_config.rs` and `installer.rs`: [docs/cli-module-decomposition.md](docs/cli-module-decomposition.md).

## Key Design Decisions

- **Discovered dynamically.** CLI scans source catalog roots at runtime. Default roots are `agents/`, `skills/`, `hooks/`, `pi-extensions/`, and `extras/`; a source `vstack.toml` `[catalog]` table can override each item kind's roots.
- **Canonical source is harness-agnostic.** Translation happens in `cli/src/harness/`.
- **Agent `role` drives access control.** `analyst` → planning/research/recon artifacts. `reviewer` → report-only/subagent (may write reports, not product code). `engineer` → full access/primary. `manager` → analysis/report artifacts.
- **Skill dependencies and ownership use frontmatter.** `dependencies: { required: [...], optional: [...] }` in SKILL.md. Shipped VStack skills also declare `metadata.source`, `metadata.repository`, and `metadata.bugs` so agents can route upstream failures to the owning project.
- **Report ownership is identity-based.** Installed lock entries stamp the source GitHub `owner/repo` as `source_repo` when resolvable. `vstack report` uses skill/agent frontmatter first, then `source_repo` or a live source Git origin; a vstack-shaped local directory alone is never proof of upstream ownership.
- **Upstream reports carry a routing label.** vstack-targeted issues get one flat label — `cli`, `skills`, `harness` (team VST subsystems) or `ci-infra`, `docs`, `chore` (existing workspace labels, reused) — derived from the asset selector or set explicitly with `--area`. The GitHub→Linear sync carries it across, where a Linear triage rule files the synced issue into the matching project. Labels are bare words with no prefix or parent group, matching memsira/hyprtrade; `agent:*` is the workspace's only grouped-and-prefixed set. Project-local reports never get one: a `gh` call naming a label the target repo lacks fails outright. See [docs/issue-label-taxonomy.md](docs/issue-label-taxonomy.md).
- **One hook execution contract.** `cli/src/installer/hooks/contract.rs` holds the event × harness matrix — enforcement mechanism, advisory, or unsupported — and every install path, CLI label, and the published table derive from it. Advisory artifacts open with `advisory — this harness cannot execute hooks`. Registered commands anchor on something that holds from any working directory in git and non-git projects: `$CLAUDE_PROJECT_DIR` for project-scope Claude, the install-time absolute path everywhere else.
- **Pi extensions are npm-shaped.** vstack copies them to `<scope>/packages/<name>`, runs a prod-only, lockfile-free `npm install` there when the package declares dependencies, and registers the path in Pi's `settings.json` `packages` array.
- **Skill/hook attribution is config-driven.** Source `vstack.toml` `[agent-skills]` is authoritative — explicit entries skip prefix matching; `[role-skills]` adds skills to all agents of a role. Project `vstack.toml` gets `[agent-skills]` populated at install; users edit and refresh. Markdown harnesses get `skills:` frontmatter; Codex agents get a "Required Skills" instruction section.
- **Reconciliation is automatic.** After every `vstack add`, all installed agents are regenerated with the current full set of installed skills and hooks.
- **Project root walks up from CWD.** `config::project_root()` finds `.vstack-lock.json` or a harness dir (`.claude/`, `.cursor/`, `.codex/`, `.opencode/`, `.pi/`, `.agents/`) by walking parents. `$HOME` with only user-level harness dirs and no lock file is rejected, so project-scope writes never route into user state.
- **Runtime settings are split from secrets.** Portable skill scripts load `.env`, then `vstack.settings.toml` / `.vstack/settings.toml` `[env]`, then `.env.local`. Committed non-sensitive defaults go in `vstack.settings.toml`; secrets, keys, and personal overrides in `.env.local`.
- **Git hooks come from the skill, not the CLI.** After a project-scope `add`/`refresh` has written its items, an installed growth-guards skill has its `scripts/install-git-hooks` run against the project so `.git/hooks/pre-commit` and `commit-msg` stay armed and repaired; `vstack remove` runs `--uninstall` before the skill's files go and REFUSES the removal when that cleanup fails, because the shims fail closed. `core.hooksPath` is never set; a non-git project is skipped with a note, and an installer failure is a warning, never an install failure.
- **Skill settings templates are opt-in.** A skill can ship `vstack.settings.toml.example`; project-scope `add`/`refresh` merge its `[env]` defaults into `<project>/vstack.settings.toml`, creating the file when missing and never overwriting existing keys. Global installs do not write project settings.

## Formats

### Agent frontmatter (`agents/*.md`)
```yaml
name: rust
description: ...
model: opus          # opus | sonnet | haiku
role: engineer       # engineer | analyst | reviewer | manager
color: orange
```

### Skill frontmatter (`skills/*/SKILL.md`)
```yaml
name: orch
description: ...
license: MIT
user-invocable: true
dependencies:
  required: [linear, github, worktree]
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
```

Use the ownership fields only for VStack-shipped skills; non-VStack skills point at their own upstream.

Optional skill settings template (`skills/*/vstack.settings.toml.example`):
```toml
[env]

MY_SKILL_TIMEOUT = "300"
```

### Hook header (`hooks/*.sh`)
```bash
# ---
# name: block-bare-cd
# event: PreToolUse       # PreToolUse | PostToolUse | PreCompact | PostCompact | PermissionRequest | SessionStart | UserPromptSubmit | Stop | TaskCompleted
# matcher: Bash           # Bash | Edit|Write | (empty for all)
# description: ...
# safety: ...
# timeout: 30             # optional, seconds
# harnesses: [claude-code, codex]   # optional allowlist; default = all
# ---
```

`event:` must name a row of the hook execution contract (`cli/src/installer/hooks/contract.rs`, published in [README.md](README.md#hook-execution-contract)); an event outside it is refused at install. The contract is also what `vstack list`/`check` derive each hook's `enforced`/`advisory`/`unsupported` label from, so changing a cell changes every install path and the published table at once.

`harnesses:` accepts a YAML list or comma-separated string. Use it for hooks whose wire format or event has no parallel in another harness (`TaskCompleted` is Claude-Code-only), or that a harness has no implementation for — a hook the `pi-hooks` package does not port must exclude `pi`, or Pi reports enforcement it does not have.

### Pi extension package (`pi-extensions/<name>/package.json`)
Npm-shaped manifest. vstack discovers any subdir containing `package.json`. Packages publish under `@vanillagreen/`; unscoped names work as `--pi-extension <name>` filters.
```json
{
  "name": "@vanillagreen/pi-qol",
  "keywords": ["pi-package"],
  "pi": { "extensions": ["./extensions/qol.ts"], "appendSystem": "./instructions.md" },
  "bin": { "pi-bridge": "./bin/pi-bridge.js" },
  "peerDependencies": {
    "@earendil-works/pi-coding-agent": "*",
    "@earendil-works/pi-tui": "*"
  }
}
```
On install vstack copies the package into `<scope>/packages/<name>` and adds `./packages/<name>` to Pi's `settings.json` `packages` array, preserving other entries. The catalog of shipped extensions lives in [README.md](README.md#pi-extensions) — don't duplicate it here.

### Mapping config (`vstack.toml`)
```toml
[catalog]
# Each omitted key keeps its default root. Paths are source-root-relative.
# Packaged items use item dirs; agents/hooks may also name one `.md`/`.sh` file.
# A path can use `*` on the final segment only.
agents = ["agents"]
skills = ["skills", "packages/skills/*", "one-offs/specific-skill"]
hooks = ["hooks"]
pi_extensions = ["pi-extensions", "pkgs/plugins/pi-*"]
extras = ["extras"]

[agent-skills]
rust = ["github", "worktree", ...]
iced = ["iced-rs", "trading-design", ...]

[role-skills]
analyst = ["linear", "github"]
engineer = ["dev", "github", "decider", "linear"]
reviewer = ["reviewer"]

[hook-events]
"PreToolUse:Bash" = "all"
"PostToolUse:Edit|Write" = ["engineer"]
"PostCompact:" = "all"
```

### Project customization (`vstack.toml` at project root)

Per-agent customization survives `vstack add` — re-applied on every install/reconciliation. The annotated example of every table (`[agent-skills]`, `[agent-launch-instructions]`, `[agent-additional-instructions]`, `[agent-frontmatter.<harness>]`, `[skill-instructions]`) lives in [README.md](README.md#customizing-with-vstacktoml) — don't duplicate it here.

`vstack refresh` applies `[skill-instructions]` to locked installs and to canonical project-owned `.agents/skills/<name>/SKILL.md` files; only the vstack-marked block is managed — all other skill content and unrelated project files are preserved. Mutating project refresh and hook-removal paths load configuration strictly and validate the `.agents/skills` ownership boundary before changing locks, hooks, settings, or generated agents; global removal stays forgiving.

## Per-Harness Model Mapping

| Canonical | Claude Code | OpenCode | Codex | Pi |
|-----------|-------------|----------|-------|-----|
| `opus` | `inherit` | `openai/gpt-5.6-sol` | `gpt-5.6-sol` | `inherit` |
| `sonnet` | `sonnet` | `openai/gpt-5.6-sol` | `gpt-5.6-sol` | `openai-codex/gpt-5.6-sol` |
| `haiku` | `haiku` | `openai/gpt-5.6-sol` | `gpt-5.6-sol` | `openai-codex/gpt-5.6-sol` |

Each canonical agent declares its own `effort:` (`low` | `medium` | `high` | `xhigh`; Claude also accepts `max`), written verbatim after per-harness frontmatter overrides — no cross-harness translation, no derivation from `model`. Claude and Pi `opus` agents inherit the parent model by default; cheaper agents may pin one. Users override models in project `[agent-frontmatter.<harness>]`.

## Per-Harness Tool Overrides

- Prefer `deny-tools` over allowlists — harness defaults stay available while unsafe tools are blocked. Claude Code writes native `disallowedTools`, seeds `background` from Pi `pane` on first install (preserving later edits), and omits `isolation`/`memory` unless configured. Pi emits `deny-tools` for `pi-agents-tmux`; generated Pi reviewer agents also deny `tasks_write` so review fan-outs don't mutate task panels. OpenCode generates agents as `mode: subagent` with default denies (`task`; `question` except planner), emits `permission: <tool>: deny` entries, maps `color` to hex, and writes reasoning under `options.reasoningEffort`. `mode = "primary"` agents get no generated denies, and refresh clears a generated-shaped deny list (exactly `["task"]` or `["task", "question"]`) on primary agents — keep intentional primary-agent denies non-generated-shaped (any extra entry).
- Cursor and Codex don't take per-agent tool denies; Codex subagents use sandbox/approval configuration.
- Pi `allowed-subagents` is the `delegate_subagent` allowlist. Engineer agents default to `["scout"]` so dev agents can dispatch read-only recon; other roles default to empty and get `delegate_subagent` denied. Set `allowed-subagents = []` to disable the engineer default. Aliases: `allowedSubagents`, `subagent-agents`, `subagent_agents`. Pane targets are rejected at runtime.

## Rules

- **Engineer over patch.** When an issue or finding prompts a change, fix the mechanism, not the prose: determinism and tooling first — a deletion, a short-circuit, or a tool; added prose is the last resort. Skills are instructions, not explanations. Never add defensive caveat blocks or issue-number citations to skill/agent md files — provenance belongs in git history and code comments. If a skill needs a paragraph of explanation to be used safely, that is a tool gap: make it just work instead.
- **SKILL.md is progressive disclosure.** Always-loaded content is only what every agent needs on every load; depth goes in `references/` and `workflows/` files read on demand. No history, no editorializing, nothing irrelevant.
- **No project-specific references.** Zero mentions of specific apps, crate names, paths, or tools in `agents/`, `skills/`, `hooks/`.
- **Validate ctx7 IDs.** Every library ID in SKILL.md ctx7 tables must resolve via `npx ctx7@latest docs <id> "test"`.
- **Green CI is not proof it works.** For anything driving a real subprocess (pi-extensions, the bridge, hooks), a suite that stubs the transport only proves the stubs agree. Run the real path before calling it done, and say which you ran.
- **Test after CLI changes.** `cd cli && cargo test`; integration via `cli/scripts/integration-check.sh` (throwaway temp project). `cargo run -- add` from inside the checkout installs into the checkout itself — not a validation path.
- **Hooks must be portable.** No hardcoded paths.
- **Skill scripts and tests are Bash 3.2 (macOS default).** No `mapfile`/`readarray`, `declare -A`/`local -A`, `${var,,}`, or `exec {fd}>`; guard empty-array expansion with `"${arr[@]+"${arr[@]}"}"`. Per-skill lint tests enforce this.
- **`--` before variable path arguments** applies to values sourced from configuration, argv, or the environment — not to a path the script built itself (`mktemp -d`, its own fixture directory).
- **New `tests/*.sh` and `scripts/*` files need the executable bit** (`chmod +x` before committing). CI fails non-executable files; `scripts/lib/` sourced libraries are the exception.
- **Worktrees live OUTSIDE the repo root** at `~/dev/.worktrees/vstack/<id>`, never in-repo `trees/`. Use the path `worktree create` prints.
- **Child workflows return JSON to parent.** Subagent workflows output JSON in `<output_format>` tags; the calling primary agent writes files.
- **Workflow shell examples must be harness-safe.** Simple commands with explicit arguments. No inline `$(...)`, shell loops, heredocs, or redirected writes in required workflow steps — Codex may classify those shapes as approval-required. Use helper scripts (`git-context`, `workflow-state`) for derived values, harness file tools for tmp files, and separate reads instead of shell loops.
- **Keep CLI version and GitHub release tag in sync.** Don't bump or release without explicit ask.
- **`vstack add` scope is destructive — read the printed summary.** Every non-interactive run prints `Scope: PROJECT (...)` vs `GLOBAL (...)`, method, and every item written. Confirm both before claiming success.
- **Never `--global` without an item filter.** CLI refuses `--global -y` unless `--all` or an item filter is set. Item filters are exclusive, except `--agent` auto-includes dependent skills from `[agent-skills]` + `[role-skills]` (opt out with `--no-auto-skills`); auto-included skills appear in the scope summary.
- **Scope flag is uniform.** `list`, `check`, `refresh`, `remove` accept `--scope project|global|all`; `-g` = `--scope global`. Default: `all` for read-only, `project` for `remove`. Bare `vstack refresh` reinstalls items at every scope they're locked at.
- **Verify after refresh.** `vstack refresh -v` prints per-item `old→new` hash; `vstack verify [-g] [name…]` confirms source matches lock and byte-matches Pi package installs. Use both before claiming a change is live.
- **Docs and instruction payloads ship with the code change.** Any change to a hook, skill, agent, or Pi extension updates — in the same commit — affected READMEs, AGENTS.md, `vstack.toml`, settings examples, `package.json`, and agent instruction payloads. A behavior change without its docs update is incomplete.
- **Every Pi extension keeps a `CHANGELOG.md` in its package folder** (`pi-extensions/<name>/CHANGELOG.md`), led by a `## Consumer-impacting changes` section. This is the authoritative channel for critical developer information to consumers and repos that vendor an extension: record behavior deltas, new/renamed/removed exports, settings and config changes, and protocol/audit-shape changes under the version that ships them, in the same commit as the change (with the `package.json` bump). Internal-only changes may be omitted; a consumer-impacting change without its changelog entry is incomplete. `package-policy.test.mjs` enforces the file's presence and shape.
- **Edit skills directly.** Edit `skills/<name>/SKILL.md` in place. No separate `rules/` directories or per-skill `AGENTS.md` files.
- **Never touch harness mirror dirs.** `.agents/`, `.claude/`, `.opencode/`, `.pi/`, and `.codex/` are installed outputs, not canonical packages. Edit only `agents/`, `skills/`, `hooks/`, and `pi-extensions/`; mirrors regenerate on `add`/`refresh`.
- **New tmux windows, never split the active pane.** Prefer `skills/orch/scripts/open-terminal` for issue handoff.
- **Create vstack worktrees via the worktree skill** (`skills/worktree/scripts/worktree create <id>`), never raw `git worktree add`. Bare `create` is a new-work claim and exits 75 when a worktree, branch, or PR already owns the ID — inspect that work instead of duplicating it. Rebase or republish only through `create --reuse`/`--restack` and `worktree restack continue|skip|abort`, never a manual rebase or force-push.
- **Worktree scratch goes in `<worktree>/tmp/`**, not the worktree root or `/tmp/`. Worktree root is for tracked content only.
- **READMEs are user-facing only.** What it is, how to use it, features, settings/options, install. Technical/development detail goes in `DEVELOPMENT.md`; agent instructions live in `SKILL.md`.
- **Pi hook parity.** Any change to a hook script lands in the same commit as the matching change in `pi-extensions/pi-hooks/extensions/hooks.ts` so all five harnesses stay behaviorally aligned.
- **Pi upstream lifecycle fix.** When touching pi-agents-tmux completion or print/json lifecycle workarounds, recheck `earendil-works/pi#2023` for upstream fixes.
- **Cross-repo conventions live in [`docs/cross-repo.md`](./docs/cross-repo.md).** Fact-provenance tagging and the shared review-gate shape.

## Updating Pi Extensions

`vstack update-pi [--check] [--scope global|project]` reinstalls only stale Pi packages. Source of truth: `<scope>/.vstack-source.json` plus `npm:` entries in Pi `settings.json`. Installed versions compare against `pi-extensions/<name>/package.json` (vstack repos) or `npm view` (npm); packages group by `(scope, sourceRepo)` and reinstall independently. Stale index entries are dropped. pi-extension-manager reads the same index for its update badge.

## Pi APPEND_SYSTEM.md load order

Pi core loads exactly one `APPEND_SYSTEM.md`: `<cwd>/.pi/APPEND_SYSTEM.md`, falling back to `~/.pi/agent/APPEND_SYSTEM.md` — never concatenated. The Claude bridge can forward both with `includeAppendSystemPromptMd`.

## Pi Extension UI Rules

- Inspect multiple `pi-extensions/*` packages first; match existing patterns.
- Popups: title in top border (`\x1b[32m`); tabs then blank line; search = full-width `toolPendingBg` row, `> [cursor]`, no hint; footer owns key hints (`\x1b[33m`); active rows `selectedBg`+text; matches `\x1b[31m`; no decorative cursors.
- Tool rendering: compact one-line calls; bold label, accent target, muted metadata; tree children; success/error/warning status colors; raw output/diffs only when useful or expanded.
- Persistent banners below status: framed, compact counts in header, tree rows, active first, muted hints, collapse/clear when empty.

## Pi Extension Development Workflow

For any `pi-extensions/**` or Pi package behavior change:
1. **Validate before finishing.** Confirm new code is reachable from where it's invoked. Cross-extension calls: `pi.getCommands()` is metadata only; bridge via `globalThis[Symbol.for("vstack.pi.<topic>")]` (see modal-lock, thinking-timer, question-service). If you can't live-test in Pi, say so.
2. **Commit intended Pi package changes** unless told not to. Stage only intended files; mention unrelated dirty files. If signing fails, retry with `--no-gpg-sign`.
3. **After commit, run `vstack refresh -g`** so the global Pi install picks up committed source. Refresh after commit, not before. Report commit hash and refresh result.
4. **Don't claim done/fixed/committed/ready until commit + refresh are complete.** If skipped, say so and why.

Worktree/feature-branch dev: test via that checkout's local Pi settings; don't point vstack repo sources at temp/worktree paths.

### Pi slash-command expansion

`sendUserMessage` skips slash/skill expansion; `pi-bridge send` compensates with hybrid dispatch (client-side `/skill:` and prompt-template expansion, own-pane keystrokes for extension/TUI commands, raw send for plain text). Prefer `pi-bridge send` over `ctx.ui.pasteToEditor` when controlling another session — a pasted newline is bracketed-paste content, not a guaranteed submit. Mechanics and the repeated-send skill cache live in `pi-extensions/pi-session-bridge/`.

## Build & Test

```bash
cd cli && cargo build                    # build
cd cli && cargo test                     # unit + integration tests
cli/scripts/integration-check.sh         # integration check in a throwaway temp project
```

## Merge flow (review-gate self-adoption, VST-10)

- This repo runs its own review-gate engine through ONE writer:
  `.github/workflows/review-gate-writer.yml` evaluates
  `skills/review-gate/scripts/review-predicate.sh` and posts the "Review
  gate" commit status. PR-attached legs (PR events, review events, status
  events) run a group-less relay job that dispatches a converge pass and
  exits; the engine itself runs on `workflow_dispatch` and the 15-minute
  cron floor, so an eviction from the single-writer group can never leave a
  cancelled check pinning a PR at `UNSTABLE` (VST-210). The merge-group leg
  posts an unconditional success on queue shas — queue entries are post-approval by
  construction, so no predicate runs there. The writer always runs the
  DEFAULT-branch engine, so a PR cannot influence its own gate — a PR that
  repairs the engine itself merges via the ruleset's bypass actor, stated
  in the merge commit. Trust values live in `vstack.settings.toml`.
- The gate answers review-only; CI is branch protection's job. The heavy
  suite jobs run only in the merge queue (fast/full split — see
  `.github/workflows/skill-tests.yml`); the queue runs the full suite once,
  on the merged result, and refuses the merge if it fails. Locally,
  `tools/validate-changed` validates the changed surface — it derives the
  suite lanes from the diff, mirroring the workflow's shards, and prints
  them before running (`--all` for the full sweep) — so a one-skill diff
  never re-runs the whole suite that the queue will run once. The refusal is
  enforced by the queue ruleset's required contexts: `Review gate`,
  `CLI (cargo test + integration check)`, and
  `Skill suites (shell + node)`.
- Merge via `github.sh pr-merge` as always. With the merge queue enabled,
  a successful merge returns exit 75 (`QUEUED IN MERGE QUEUE`) and completes
  asynchronously — confirm with `await-mergeable` / `state == MERGED`
  before propagation, and never force past a queue refusal.
- A fresh head normally gets its pending gate status within moments — the
  writer runs event-fast on every push (`pull_request_target`). The cron
  tick is the FLOOR for transitions with no event (thread resolution, fork
  review evidence). A head still missing its gate status after several
  minutes means a failed or skipped writer run — investigate the runs, do
  not wait out the cron.
  Ruleset/branch-protection changes (required checks, queue enablement,
  Copilot auto-review toggle) are owner actions.

## Publishing & Releases

The agent does not auto-publish or auto-release. When the user asks:
- npm publishing of Pi extension packages → `.pi/prompts/npm-deploy.md`
- vstack CLI version bump + GitHub release → `.pi/prompts/gh-release.md`
