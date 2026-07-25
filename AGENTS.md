# vstack

Cross-harness distribution system for AI coding skills, agents, hooks, and Pi extensions. Installs into Claude Code, Cursor, OpenCode, Codex, and Pi via a Rust CLI.

## Repo Layout

```
cli/src/
├── main.rs              CLI entry; routes to commands/
├── commands/            add, remove, list, check, update, update_pi, verify, refresh, init
├── pi_extension.rs      Pi extension discovery, install/remove, settings.json merge
├── config.rs            Lock file (JSON), project root detection, staleness/mtime helpers
├── scope.rs             Scope enum (project | global | all); uniform `--scope`/`-g` parsing
├── mapping.rs           Source vstack.toml — MappingConfig (agent-skills, role-skills, hook-events)
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

vstack.toml              Skill/hook-to-agent mapping (read at install)
agents/                  Canonical agents — `role` field drives per-harness access control
skills/                  Skill packages — each has SKILL.md with optional dependencies
hooks/                   Safety hooks — bash scripts with YAML comment headers
pi-extensions/           Pi extension packages (npm-shaped). package.json has `pi.extensions`
skill-templates/         Templates for new skills
```

## Key Design Decisions

- **Discovered dynamically.** CLI scans `agents/`, `skills/`, `hooks/`, `pi-extensions/` at runtime. No hardcoded lists.
- **Canonical source is harness-agnostic.** Translation happens in `cli/src/harness/`.
- **Agent `role` drives access control.** `analyst` → planning/research/recon artifacts. `reviewer` → report-only/subagent (may write reports, not product code). `engineer` → full access/primary. `manager` → analysis/report artifacts.
- **Skill dependencies and ownership use frontmatter.** `dependencies: { required: [...], optional: [...] }` in SKILL.md. Shipped VStack skills also declare `metadata.source`, `metadata.repository`, and `metadata.bugs` so agents can route upstream failures only to the owning project.
- **Report ownership is identity-based.** Installed lock entries stamp the source GitHub `owner/repo` as `source_repo` when it can be resolved. `vstack report` uses skill/agent frontmatter first, then `source_repo` or a live source Git origin for agents/hooks; a vstack-shaped local directory alone is never proof of upstream ownership.
- **Hooks diverge by harness.** Claude Code: native shell hooks + settings.json + agent frontmatter. Cursor: safety `.mdc` rules. OpenCode: `.opencode/agents/*.md` + instructions. Codex: native shell hooks under `<scope>/.codex/hooks/` registered in `<scope>/.codex/hooks.json` with `[features] hooks = true` in `config.toml` — events without a codex equivalent (e.g. Claude's `TaskCompleted`) fall back to inline prose in `developer_instructions`. Pi: native TS implementations in the `@vanillagreen/pi-hooks` extension, listening on `tool_call`/`tool_result`/`turn_end`; each hook independently toggleable in pi-extension-manager.
- **Pi extensions are npm-shaped.** vstack copies them to `<scope>/packages/<name>`, runs `npm install --omit=dev --package-lock=false --legacy-peer-deps --no-audit --no-fund` there when `package.json` has `dependencies` or `optionalDependencies`, and registers the path in Pi's `settings.json` `packages` array.
- **Skill/hook attribution is config-driven.** Source `vstack.toml` `[agent-skills]` is authoritative — explicit entries skip prefix matching. `[role-skills]` adds skills to all agents of a role. Project `vstack.toml` also has `[agent-skills]` populated at install; users add/remove and refresh. Markdown-based harnesses get `skills:` frontmatter; Codex agents get a "Required Skills" instruction section.
- **Reconciliation is automatic.** After every `vstack add`, all installed agents are regenerated with the current full set of installed skills and hooks.
- **Project root walks up from CWD.** `config::project_root()` finds `.vstack-lock.json`, `.claude/`, `.cursor/`, `.codex/`, `.opencode/`, `.pi/`, or `.agents/` by walking parents. `$HOME` is rejected as a project root when only user-level harness dirs (`~/.claude`, `~/.pi`, etc.) exist there with no `.vstack-lock.json`, so project-scope writes never accidentally route into user state.
- **Runtime settings are split from secrets.** Portable skill scripts load `.env`, then `vstack.settings.toml` / `.vstack/settings.toml` `[env]`, then `.env.local`. Put committed non-sensitive defaults in `vstack.settings.toml`; reserve `.env.local` for secrets, API keys, private URLs, signing keys, and personal overrides. Existing `.env.local` settings remain supported for compatibility.
- **Skill settings templates are opt-in.** A skill can ship `vstack.settings.toml.example`; project-scope `vstack add` and `vstack refresh` merge its `[env]` defaults into `<project>/vstack.settings.toml`, creating the file when missing and never overwriting existing keys. Global installs do not write project settings.

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

Use the ownership fields only when the skill is shipped by VStack. Non-VStack skills should point at their own upstream instead of `vanillagreencom/vstack`.

Optional skill settings template (`skills/*/vstack.settings.toml.example`):
```toml
[env]

MY_SKILL_TIMEOUT = "300"
```

Project installs merge these defaults into `vstack.settings.toml` so shared non-secret settings are available as soon as the skill is installed.

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

`harnesses:` accepts a YAML list or comma-separated string. Use it for hooks whose wire format or event has no parallel in another harness (e.g. `TaskCompleted` is Claude-Code-only; codex's nearest equivalent is `Stop` with different blocking semantics).

### Pi extension package (`pi-extensions/<name>/package.json`)
Npm-shaped manifest. vstack discovers any subdir containing `package.json`. Packages publish under `@vanillagreen/`; unscoped names work as `--pi-extension <name>` filters via the rename table.
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
On install vstack copies `pi-extensions/<name>/` into `<scope>/packages/<name>` and adds `./packages/<name>` to Pi's `settings.json` `packages` array. Existing entries and other settings keys are preserved; legacy absolute-path entries are replaced with the relative form. The catalog of currently-shipped extensions lives in [README.md](README.md#pi-extensions) — don't duplicate it here.

### Mapping config (`vstack.toml`)
```toml
[agent-skills]
rust = ["github", "worktree", ...]
iced = ["iced-rs", "iced-shadcn", ...]

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

Per-agent customization survives `vstack add` — re-applied on every install/reconciliation.

```toml
# Skills loaded into each agent's context.
[agent-skills]
rust = ["github", "worktree"]

# Launch instructions added near the top of generated agent files.
[agent-launch-instructions]
rust = "Read docs/architecture.md before coding."

# Project guidance appended to generated agent files.
[agent-additional-instructions]
rust = "Always run clippy before committing."

# Generated frontmatter. vstack populates active defaults; edit and refresh.
# Harness-specific values only affect that harness.
[agent-frontmatter.claude]
rust = { color = "orange", model = "inherit", effort = "xhigh", deny-tools = ["Agent", "AskUserQuestion"], background = false }

[agent-frontmatter.opencode]
rust = { color = "#f97316", model = "openai/gpt-5.6-sol", model-reasoning-effort = "xhigh", deny-tools = ["task", "question"], mode = "subagent" }

[agent-frontmatter.codex]
rust = { nickname-candidates = ["Rust-Atlas", "Rust-Delta"], model = "gpt-5.6-sol", model-reasoning-effort = "xhigh", sandbox-mode = "danger-full-access" }

[agent-frontmatter.pi]
rust = { color = "orange", model = "inherit", deny-tools = ["subagent", "get_subagent_result", "steer_subagent", "stop_subagent", "question"], allowed-subagents = ["scout"], pane = true }

# Project instructions prepended to a skill's SKILL.md.
[skill-instructions]
trading-design = "Dark theme, green/red accents."
```

`vstack refresh` applies `[skill-instructions]` to locked installs and to
canonical project-owned `.agents/skills/<name>/SKILL.md` files without lock
entries. For project-owned skills, only the vstack-marked project-instructions
block is managed; repeated refreshes, updates, and removals preserve all other
skill content and unrelated project files.
Mutating project refresh paths load configuration strictly and validate the
canonical `.agents/skills` ownership boundary before lock reconciliation,
hook pruning, or installation. Project hook removal performs the same strict
preflight before changing hook files, settings, locks, or generated agents;
global removal remains forgiving and independent of project configuration.

## Per-Harness Model Mapping

| Canonical | Claude Code | OpenCode | Codex | Pi |
|-----------|-------------|----------|-------|-----|
| `opus` | `inherit` | `openai/gpt-5.6-sol` | `gpt-5.6-sol` | `inherit` |
| `sonnet` | `sonnet` | `openai/gpt-5.6-sol` | `gpt-5.6-sol` | `openai-codex/gpt-5.6-sol` |
| `haiku` | `haiku` | `openai/gpt-5.6-sol` | `gpt-5.6-sol` | `openai-codex/gpt-5.6-sol` |

Each canonical agent declares its own `effort:` in frontmatter. Harnesses write it verbatim after per-harness frontmatter overrides are applied — no cross-harness translation, no derivation from `model`. Valid values: `low`, `medium`, `high`, `xhigh` (and Claude additionally accepts `max`). Claude and Pi `opus` agents inherit the parent model by default; cheaper agents such as `scout` may pin an explicit model. Users can override models in project `[agent-frontmatter.<harness>]` tables.

## Per-Harness Tool Overrides

- Prefer `deny-tools`. Claude Code writes it as native `disallowedTools`, seeds `background` from Pi `pane` on first install (`pane = true` → `background = false`, `pane = false` → `background = true`) and preserves later edits, and omits `isolation`/`memory` unless configured. Pi emits `deny-tools` for `pi-agents-tmux` (default = active parent tools minus denials); generated Pi reviewer agents additionally deny `tasks_write` so isolated review fan-outs do not mutate task panels. OpenCode defaults generated agents to `mode: subagent`, still exposes `mode` for rare primary-agent overrides, emits `permission: <tool>: deny` entries from the same deny list, and applies the subagent default denies (`task`; `question` except planner) only in subagent mode — `mode = "primary"` agents get empty generated `deny-tools`, and refresh clears a stale generated-shaped deny list (exactly `["task"]` or `["task", "question"]`) on primary agents; a user-authored list matching that exact shape is indistinguishable and also cleared, so keep explicit primary-agent denies non-generated-shaped (any extra entry). OpenCode also maps `color` to hex values, and writes reasoning under `options.reasoningEffort` with summary/verbosity defaults.
- Cursor and Codex don't use the same per-agent tool-deny frontmatter; Codex subagents use sandbox/approval configuration instead.
- Per-harness frontmatter overrides live under `[agent-frontmatter.<harness>]`; use `deny-tools` rather than allowlists so harness defaults remain available while unsafe tools are blocked.
- Pi `allowed-subagents` is the restricted delegation allowlist for `delegate_subagent`. Engineer agents default to `["scout"]` so dev agents can dispatch read-only reconnaissance into a fresh bg lane without gaining full `subagent` orchestration. Non-engineer roles default to empty (no delegation) and gain `delegate_subagent` in `deny-tools`. Set `allowed-subagents = []` in `[agent-frontmatter.pi]` to disable the engineer default. Accepted aliases: `allowedSubagents`, `subagent-agents`, `subagent_agents`. Pane targets are rejected at runtime by `delegate_subagent`.

## Rules

- **No project-specific references.** Zero mentions of specific apps, crate names, paths, or tools in `agents/`, `skills/`, `hooks/`.
- **Validate ctx7 IDs.** Every library ID in SKILL.md ctx7 tables must resolve via `npx ctx7@latest docs <id> "test"`.
- **Green CI is not proof it works.** For anything driving a real subprocess (pi-extensions, the bridge, hooks), a suite that stubs the transport only proves the stubs agree. Run the real path before calling it done, and say which you ran.
- **Test after CLI changes.** `cd cli && cargo test`. Integration: `cli/scripts/integration-check.sh` — installs into a throwaway temp project and verifies the scope. Running `cargo run -- add .. --all --copy` from inside the checkout installs into the checkout itself (project scope = nearest project root from CWD), so it is not the validation path.
- **Hooks must be portable.** No hardcoded paths.
- **Skill scripts and tests are Bash 3.2 (macOS default).** No `mapfile`/`readarray`, `declare -A`/`local -A`, `${var,,}`, or `exec {fd}>`; guard empty-array expansion with `"${arr[@]+"${arr[@]}"}"`. Per-skill lint tests enforce this.
- **New `tests/*.sh` and `scripts/*` files need the executable bit** (`chmod +x` before committing; file-write tools create 644). CI fails non-executable files; `scripts/lib/` sourced libraries are the exception.
- **Worktrees live OUTSIDE the repo root** at `~/dev/.worktrees/vstack/<id>` (never in-repo `trees/` — editor-watcher incident, #692). The worktree skill handles this; just use the path `create` prints.
- **Child workflows return JSON to parent.** Subagent workflows output JSON in `<output_format>` tags; the calling primary agent writes files.
- **Workflow shell examples must be harness-safe.** Use simple commands with explicit arguments. Avoid inline `$(...)`, shell loops, heredocs, array-building snippets, and redirected writes in required workflow steps; Codex may classify those helper shapes as approval-required under `never` approval. Use helper scripts (`git-context`, `workflow-state`) for derived values, use harness file-write/edit tools or `apply_patch` for tmp Markdown/JSON files, and read multiple required docs with separate file reads instead of a shell `for` loop.
- **Keep CLI version and GitHub release tag in sync.** `cli/Cargo.toml` version and the GitHub release/tag must always match. Don't bump or release without explicit ask.
- **`vstack add` scope is destructive — read the printed summary.** Every non-interactive run prints `Scope: PROJECT (...)` vs `GLOBAL (...)`, method, and every item written. Confirm both before claiming success.
- **Never `--global` without an item filter.** CLI refuses `--global -y` unless `--all` or one of `--agent`/`--skill`/`--hook`/`--pi-extension` is set. Item filters are exclusive — passing any restricts the install to only those kinds, EXCEPT `--agent` which auto-includes dependent skills referenced via `[agent-skills]` + `[role-skills]` (opt out with `--no-auto-skills`). Auto-included skills are listed in the scope summary.
- **Scope flag is uniform.** `list`, `check`, `refresh`, `remove` accept `--scope project|global|all`. `-g`/`--global` = `--scope global`. Default: `all` for read-only (`list`, `check`, `refresh`), `project` for `remove`. `vstack refresh` with no args reinstalls items at every scope they're locked at.
- **Verify after refresh.** `vstack refresh -v` prints per-item `old→new` hash. `vstack verify [-g] [name…]` confirms source matches lock and byte-matches install dir for Pi packages. Use both before claiming a change is live.
- **Docs and instruction payloads ship with the code change.** Any change to a hook, skill, agent, or Pi extension must update — in the same commit — affected READMEs, AGENTS.md, `vstack.toml`, `vstack.settings.toml.example`, `.env.local.example`, `package.json`, agent instruction payloads (`appendSystem` files / before_agent_start hook prose), and any cross-referencing docs. A behavior change without its docs/instructions update is incomplete.
- **Edit skills directly.** Edit `skills/<name>/SKILL.md` in place. No separate `rules/` directories or per-skill `AGENTS.md` files.
- **Never touch harness mirror dirs.** `.agents/`, `.claude/`, `.opencode/`, `.pi/`, and `.codex/` are installed harness outputs, not canonical packages. Edit only `agents/`, `skills/`, `hooks/`, and `pi-extensions/`; harness mirrors regenerate on `vstack add` / `vstack refresh`.
- **New tmux windows, never split the active pane.** Create a new tmux window in the current session for any spawned handoff work. Prefer `skills/orch/scripts/open-terminal` for issue handoff.
- **Always create vstack worktrees via the worktree skill.** Use `skills/worktree/scripts/worktree create <id>` (not raw `git worktree add`) so `.env.local`, harness mirror dirs, bot identity, and per-worktree config are wired in. Bare `create` is a new-work claim and exits 75 without rebasing when a worktree, branch, or PR already owns the ID; inspect/monitor that work instead of spawning a duplicate, and never batch issue creates in a loop that can hide an earlier nonzero result. A supported `create --reuse` / `create --restack` rewrite carries an exact, worktree-local lease authorization into `worktree push`; use that path instead of a manual force-push. Continue, skip, or abort a paused supported restack through `worktree restack continue|skip|abort`, not top-level `git rebase` control commands, so the tool can validate the state token, recorded worktree, branch, base, remote OID, and lease boundary.
- **Worktree scratch goes in `<worktree>/tmp/`, not at worktree root or `/tmp/`.** Agent task briefs, intermediate result JSONs, review hand-offs, and similar ephemeral artifacts belong in the worktree's gitignored `tmp/` dir (auto-created when listed in `WORKTREE_MKDIRS`). Worktree root is for tracked content only.
- **READMEs are user-facing only.** Describe what the thing is, how to use it, features, settings/options, and install/setup. Technical/development detail goes in `DEVELOPMENT.md`; agent skill instructions live in the matching `SKILL.md`.
- **Pi hook parity.** Pi gets its hooks via the `pi-extensions/pi-hooks` extension (native TS port of `hooks/*.sh` against Pi's `tool_call`/`tool_result`/`turn_end` events). Any change to a hook script must land in the same commit as the matching change in `pi-extensions/pi-hooks/extensions/hooks.ts` so all five harnesses stay behaviorally aligned.
- **Pi upstream lifecycle fix.** When touching pi-agents-tmux completion or print/json lifecycle workarounds, recheck `earendil-works/pi#2023` for upstream true-idle / scheduled-continuation fixes.

## Recording Facts Across Repos

When a session records a fact other sessions will act on, tag how it is known. Vendoring makes the alternative actively dangerous: anything merged here lands in the consuming repos' trees, so their greps of the vendored artifact will keep "confirming" whatever was asserted upstream.

- **`[live]`** — observed directly against a real system. Note the method and its limits.
- **`[corroborated]`** — checked against a source **not derived from the same observation**. Not "additionally verified", which is a phrasing you cannot fail: it certifies whatever you already believe. Naming the second source is the test, because that is when you notice it is your own output.
- **`[inferred]`** — reasoned from docs or code, not observed.

Real instance (2026-07-24): a live connector enumeration went upstream as the exact-id lists in vstack#821, vendored into the consuming repos, and a later grep of that bundle read back as independent agreement with the enumeration it came from — in a note that had itself recorded, two paragraphs earlier, that the entries did not exist before #821.

The corollary that resolves most cases: checking your own code's *behavior* against a fact corroborates it (it tests whether the code copes). Checking a *list you populated* does not (it tests your memory of what you typed).

Two ways the tags fail in practice, both observed:

- **Reading the artifact instead of the source.** Control-flow claims derived from a vendored, minified, post-bundler copy are not `[live]` readings of the code — they are `[inferred]` from a lossy transform. This is structurally likely here for the same reason as the round-trip: consuming repos hold bundles, not sources, so the nearest copy is the wrong one. Cite `src/` with file and line; if only a bundle is at hand, say so and downgrade the claim.
- **Tone upgrading a tag.** `[inferred]` labelled honestly and then described as "the most promising lead" functions as `[live]` for every reader. The tag is not a disclaimer that buys stronger prose — if the surrounding sentence would survive being read as verified, the tag is not doing its job.

Same family as the date-stamping rule below — both let a future reader judge how far to trust a line without re-deriving it.

## Cross-Repo Review Gate

Agreed shape for drovr, memsira, and hyprtrade (settled 2026-07-24). Empirically tested on two repos independently — memsira PR #272 and drovr PR #262, each a live PR with a real unresolved thread — not inferred from docs. Recorded here so it is not re-litigated per repo.

- **The invariant: thread resolution is enforced by a dedicated ruleset with `bypass_actors: []`.** A `pull_request` rule with `required_review_thread_resolution: true` and an empty bypass list. That is the only form proven to hold on every merge path.
- **Classic branch protection is NOT sufficient, and this was the trap.** `required_conversation_resolution: true` with `enforce_admins: false` does **not** stop `gh pr merge --admin` — verified on memsira PR #272 (2026-07-24): with the ruleset disabled and classic protection still on, an admin merge succeeded with a thread left unresolved. The same PR with the zero-bypass ruleset active was blocked: `GraphQL: Repository rule violations found` / `A conversation must be resolved before this pull request can be merged`. Since `--admin` is a documented merge path, any repo relying on classic protection alone has a hole exactly where it assumes coverage.
- **Keep classic `required_conversation_resolution` on anyway — defense in depth, never the mechanism.** It is redundant for the admin path and must never again be relied on there, but it costs nothing and it is the layer that survives someone disabling or misconfiguring the ruleset. The counterfactual half of the memsira test created exactly that window: with the ruleset disabled, classic protection was the only thing standing between a *non-admin* merge and an unresolved thread. Enforcement is the ruleset; this is the backstop.
- **`bypass_actors` is per-ruleset, not per-repo — so split the rules.** Thread resolution goes in its own zero-bypass ruleset; rules that legitimately need an escape hatch stay in a separate ruleset that keeps its bypass (e.g. memsira's `main merge queue` ruleset retains a `RepositoryRole` 5 always-bypass). Classic protection cannot express this because `enforce_admins` is binary and repo-wide.
- **Set `required_approving_review_count` EXPLICITLY to `0`.** The API fills omitted sub-parameters with defaults. Our review bots only ever submit COMMENTED reviews, so any nonzero count deadlocks every PR in every repo. Also set `conditions.ref_name.include` to `~DEFAULT_BRANCH` and verify `bypass_actors` is literally `[]` after creation, not merely as posted.
- **GitHub does not name the ruleset in the error.** An operator sees only `Repository rule violations found` plus `A conversation must be resolved before this pull request can be merged` — no indication which ruleset blocked, so point them at the thread ruleset by name when diagnosing. On a merge-queue repo the violation list also carries `Changes must be made through the merge queue`; both lines appear together and the queue line is not the blocker.
- **Deleting a repo's CI thread term is a per-repo cost decision, NOT part of the invariant.** Only drop it once the zero-bypass ruleset exists. Worth ~23.9 min/run on hyprtrade; worth nothing measurable on memsira, where 20/22 sampled gate failures were the review-at-head term and zero were threads. Classify gate failures by reading `##[error]` lines — grepping the log body echoes the script and yields a confidently wrong answer.
- **Unresolved threads can become unreachable in the UI while still blocking the merge.** After a rebase or force-push the commented commits are gone, the conversation link 404s, and the PR shows zero visible conversations yet refuses to merge (github/community #144455, #10592, #184355). GraphQL still sees them: list with `github.sh pr-threads <N>`, resolve by id with `github.sh resolve-thread <PRRT_...>`. The skill is the escape hatch from a deadlock branch protection creates.
- **Date-stamp measured state, and re-measure before relying on it.** During the conversation that produced this section, two sessions reported hyprtrade branch-protection values that a later read contradicted within the hour. Nobody captured a timestamped before/after, so a genuine mid-flight change and an inaccurate first read are **indistinguishable after the fact** — do not cite either earlier number as evidence of anything. That ambiguity is the actual lesson: with several sessions reading and mutating the same repos concurrently, an unreproducible measurement is worthless, so capture the command output with a timestamp or treat the value as unknown. State as of 2026-07-25 00:42Z, measured directly rather than taken from the sessions' reports — all three converged on **both** layers: every repo has classic `conv_res=true` plus an active thread ruleset with `bypass_actors: []`, `required_review_thread_resolution: true`, `required_approving_review_count: 0`. `enforce_admins` still differs (hyprtrade `true`; drovr and memsira `false`) and that is fine — it is no longer the mechanism. Note this list replaced an earlier one within about an hour, when drovr enabled its classic flag on the strength of the defense-in-depth bullet above; that is the rule working, not a contradiction, and a later audit disagreeing again is expected.

## Updating Pi Extensions

`vstack update-pi[ --check][ --scope global|project]` reinstalls only stale Pi packages. Source of truth: `<scope>/.vstack-source.json` plus `npm:` entries in Pi `settings.json`. Installed versions compare against `pi-extensions/<name>/package.json` (vstack repos) or `npm view <name> version` (npm). Different packages can come from different vstack repos — grouped by `(scope, sourceRepo)` and reinstalled independently. Stale index entries (referenced package no longer installed) are dropped. The pi-extension-manager extension reads the same index for its `↑ X.Y.Z` badge.

## Pi APPEND_SYSTEM.md load order

Pi core auto-discovers exactly one `APPEND_SYSTEM.md`: `<cwd>/.pi/APPEND_SYSTEM.md` first, falling back to `~/.pi/agent/APPEND_SYSTEM.md` only if the project file is missing. Not concatenated by core. Claude bridge can opt into forwarding both with `includeAppendSystemPromptMd`.

## Pi Extension UI Rules

- Inspect multiple `pi-extensions/*` packages first; match existing patterns.
- Popups: title in top border (`\x1b[32m`); tabs then blank line; search = full-width `toolPendingBg` row, `> [cursor]`, no hint; footer owns key hints (`\x1b[33m`); active rows `selectedBg`+text; matches `\x1b[31m`; no decorative cursors.
- Tool rendering: compact one-line calls; bold label, accent target, muted metadata; tree children; success/error/warning status colors; raw output/diffs only when useful or expanded.
- Persistent banners below status: framed, compact counts in header, tree rows, active first, muted hints, collapse/clear when empty.

## Pi Extension Development Workflow

For any `pi-extensions/**` or Pi package behavior change:
1. **Validate before finishing.** Confirm new code is reachable from where it's invoked. Cross-extension calls: `pi.getCommands()` is metadata only; bridge via `globalThis[Symbol.for("vstack.pi.<topic>")]` (see modal-lock, thinking-timer, question-service). If you can't live-test in Pi, say so.
2. **Commit intended Pi package changes** unless user says not to. Stage only intended files; mention unrelated dirty files. If signing fails, retry with `--no-gpg-sign`.
3. **After commit, run `vstack refresh -g`** so the global Pi install picks up committed source state. Refresh after commit, not before. Report commit hash and refresh result.
4. **Don't claim done/fixed/committed/ready until commit + refresh are complete.** If skipped, say so and why.

Worktree/feature branch dev: test via local project Pi settings for that checkout; don't add vstack repo sources pointing at temp/worktree paths.

### Pi slash-command expansion

- `sendUserMessage` still skips slash/skill expansion (`expandPromptTemplates: false`). `pi-bridge send` compensates with hybrid dispatch: client-side expansion for `/skill:<name>` and prompt templates, own-pane `tmux send-keys -l` for extension/TUI commands, raw `sendUserMessage` for plain text/fallback.
- Repeated `/skill:<name>` sends in the same Pi session emit a short `Skill <name> (previously loaded). Invocation: ...` reminder instead of re-expanding the full SKILL.md body. The cache is keyed by `(session_id, skill_name, SKILL.md content hash)`; content-hash changes force a fresh full expansion; `session_shutdown` evicts that session; pi-bridge restart clears the in-memory cache; and the bridge bounds the cache to the 100 most recent sessions.
- From an extension, `ctx.ui.pasteToEditor("/skill:foo\n")` pastes text; newline is bracketed-paste content, not a guaranteed submit. Prefer `pi-bridge send "/skill:foo ..."` when controlling another session.

## Build & Test

```bash
cd cli && cargo build                    # build
cd cli && cargo test                     # unit + integration tests
cli/scripts/integration-check.sh         # integration check in a throwaway temp project
```

## Publishing & Releases

The agent does not auto-publish or auto-release. When the user asks:
- npm publishing of Pi extension packages → `.pi/prompts/npm-deploy.md`
- vstack CLI version bump + GitHub release → `.pi/prompts/gh-release.md`
