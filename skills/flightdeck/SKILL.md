---
name: flightdeck
description: "Generic tmux session manager for AI harness panes; optional issue mode supervises issue/PR workflows, prompt handling, merge planning, and unwind."
license: MIT
user-invocable: true
dependencies:
  required: []
  optional: [decider, github, linear, project-management, worktree]
metadata:
  author: vanillagreen
  version: "0.2.0"
---

# Flightdeck

> If you're modifying flightdeck scripts, the daemon, or `lib/flightdeck-core/` — read [`DEVELOPMENT.md`](./DEVELOPMENT.md) first for the test workflow, debugging entry points, and operational caveats.

## STOP — Required Setup

1. Verify `$TMUX` is set for every Flightdeck command. If unset, **exit immediately with no-op**: print `Flightdeck requires tmux; skipping.` and return control to the caller. Flightdeck does nothing outside tmux.
2. Determine the lane before loading dependencies:
   - Generic session commands (`session start`, `session attach`, `session watch`, `session status`, `session stop`, `session remove`) require only tmux plus the selected harness adapter (`pi-bridge`, OpenCode HTTP, Claude Channels, Codex app-server, or tmux fallback). Do **not** load `github`, `linear`, `project-management`, or `worktree`.
   - Linear issue commands (`linear start [ISSUE_ID]`, `linear start new`, `linear start self`, `linear parallel-check`, `linear watch`, `linear merge-plan`, `linear close-issue`, `linear terminate` when entries use `domain.issue`) load `github`, `linear`, `project-management`, and `worktree` on demand.
   - GitHub issue commands (`github start <N>`, `github start new`, `github watch`, `github close-issue`, `github terminate` when entries use `domain.github_issue`) load `github` and `worktree` only. Do **not** load `linear` or `project-management`.
3. If an issue-workflow dependency cannot be loaded after entering issue mode, stop and tell the user. Do not proceed with issue/PR/worktree actions without it.

## Dependency modes

Core Flightdeck is a generic session manager. It needs tmux and the harness adapter for each tracked pane; GitHub, Linear, project-management, and worktree skills are issue-mode dependencies only.

| Lane | Load | Do not load |
|------|------|-------------|
| Session | tmux + selected harness adapter | `github`, `linear`, `project-management`, `worktree` |
| Linear issue | `github`, `linear`, `project-management`, `worktree` | only skip redundant loads |
| GitHub issue | `github`, `worktree` | `linear`, `project-management` |

`decider` remains optional for agents that want an extra decision aid.

## Mode

You are in **master mode**. Master supervises: it routes prompts, updates state/dashboard, and calls named Flightdeck workflows/scripts. It does not perform per-issue implementation, verification, product-code mutation, or domain mutations directly. Route fixes/checks back through the owning pane/workflow; record only cross-session facts spawned panes cannot see.

Generic session mode is the core path: launch/attach with `flightdeck-session`, supervise with `session-watch.md`, answer generic prompts, and summarize sessions. It skips issue selection, research/plan evaluation, `open-terminal`, merge planning, GitHub/Linear/worktree actions, and project-management flows.

Issue-mode begins only after a Linear or GitHub issue command. Linear mode keeps the research/plan evaluation → spawn (`open-terminal`) → watch loop → merge planning → unwind path. GitHub mode resolves issue context with `gh`, spawns a child with a self-contained prompt through `open-terminal --tracker github`, watches PR/CI/review state, then verifies close/termination from authoritative GitHub state.

Communicate with spawned agents through native channels (`pane-respond`): OpenCode HTTP, Claude Channels MCP/JSONL, Pi bridge, Codex JSON-RPC, with tmux capture/send-keys only as fallback (see `patterns/tmux-monitoring.md`). Pause for the user only on scope creep that requires reverting agent work, force-merging against a real content conflict, issue abort, direct `main` mutation when no orchestrator pane is alive, or a novel prompt shape no rule covers. Do not re-implement orchestration gates; answer surfaced prompts and add only cross-session conflict/scope facts.

## Reference docs

Load these on demand; keep this file as the operational quick path.

| Need | Read |
|------|------|
| Master-state JSON, activity sidecar, registry shape, `readTrackedEntries` / `writeTrackedEntry` contract | [`SCHEMA.md`](./SCHEMA.md) |
| Full scripts table, script arguments, Pi bg-task exit, Pi activity broker, activity sidecar, `daemon-exited` details | [`SCRIPTS.md`](./SCRIPTS.md) |
| Full `prompt-classify` tag catalog, including daemon/event-only tags | [`PROMPT-TAGS.md`](./PROMPT-TAGS.md) |
| Env var tables: master loop, watchdog gates, daemon hygiene, dashboard, adapter tuning | [`ENV.md`](./ENV.md) |
| Watchdog behavior: agent-end, idle-stall, edit-loop, rate-limit | [`WATCHDOGS.md`](./WATCHDOGS.md) |
| Development workflow, parity tests, daemon internals | [`DEVELOPMENT.md`](./DEVELOPMENT.md) |

## Commands

Use the session table for core Flightdeck: tracked tmux-window sessions, harness IO, generic prompts, and summaries. Use Linear/GitHub tables only after the user enters an issue/PR/worktree domain. Dashboard terms: TrackedEntry row = source-of-truth state; Rust dashboard/TUI = persistent visibility; cycle summary = chat-visible tick report.

### Session management

Generic tmux-window session tracking. These commands do not require a fake issue id.

| Command | Arguments | Workflow / Script | Notes |
|---------|-----------|-------------------|-------|
| `session start` | `--session-id <ID> --title <T> --cwd <path> --harness <H> (--cmd <cmd> \| --prompt <text>) [--kind adhoc\|workflow] [--model <id>] [--effort <level>\|--thinking <level>]` | `scripts/flightdeck-session start` | Creates a new tmux window (never a split), launches command/harness, records a generic `.entries[ID]` row, records launch model/effort metadata, exports Flightdeck child env, and launches/verifies the Rust dashboard unless `FLIGHTDECK_DASHBOARD=0`. Prompt launches pass harness-aware model/effort argv. |
| `session attach` | `--pane <%PANE_ID> --harness <H> --title <T> [--session-id <ID>] [--kind adhoc] [--model <id>] [--effort <level>\|--thinking <level>]` | `scripts/flightdeck-session attach` | Attaches an existing pane by stable pane id, records supplied or unsupported launch metadata, and launches/verifies the dashboard unless disabled. Pi attach probes `pi-bridge` when available. |
| `session watch` | `[ENTRY_ID...]` | `workflows/shared/session-watch.md` | Generic daemon/poll/handler loop. Verifies dashboard presence on re-entry before daemon yield. Routes only generic handlers and guards issue-only tags as `domain-mismatch`; no GitHub/Linear/worktree dependency. |
| `session prompt routing` | nested from `session watch` | `workflows/shared/session-handle-prompt.md` | Generic prompt handlers for structured questions, bash permission prompts, safe bounded choices, terminal completion, `pi-bg-task-exit`, and `domain-mismatch`. |
| `session status` | — | inline / `flightdeck-state tracked-entries` | Read-only normalized `.entries` snapshot. |
| `session stop` / `session remove` | `<ENTRY_ID>` | `pane-registry teardown-entry` / `pane-registry remove` | Teardown uses stable `pane_id` and accepts issue-mode plus generic terminal states. `remove` drops the `.entries` row. |

### Linear issue workflows

Entering these commands loads Linear issue-mode dependencies on demand. Use GitHub commands for numeric GitHub issues and session commands for non-issue work.

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `linear start` | `[ISSUE_ID]` | `workflows/linear/start.md` | From-main issue entry: dashboard, issue selection, research evaluation, parallel-check, spawn (`open-terminal`), enter Linear watch loop. |
| `linear start new` | `[title]` | `workflows/linear/start-new.md` | Create new issue + spawn through the Linear issue workflow path. |
| `linear start self` | — | inline | Initialize master Linear issue session only; await further issue commands. |
| `linear parallel-check` | `[ISSUE_IDS]` | `workflows/linear/parallel-check.md` | Verify candidate issue set is safe to spawn in parallel. |
| `linear watch` | `[ISSUE_IDS]` | `workflows/linear/watch.md` → `workflows/shared/session-watch.md` | Linear issue-mode extension over the generic loop. Tracks issue-specific lifecycle states, routes PR/Linear/worktree handlers, and resumes merge planning. |
| `linear merge-plan` | — | `workflows/linear/merge-plan.md` | Build PR conflict graph and choose smallest-safe merge order for Linear issue entries. |
| `linear close-issue` | `<ISSUE_ID>` | `workflows/linear/close-issue.md` | Verify terminal issue outcome, record issue fields, and tear down issue window safely. |
| `linear terminate` | — | `workflows/linear/terminate.md` | Produce issue/PR/new-issue recommendation summary when issue entries exist; mixed sessions also include generic session summary. |

### GitHub issue workflows

Entering these commands loads `github` + `worktree` only. Child panes receive self-contained prompts; do not invoke a master-side Flightdeck supervisor workflow inside the child.

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `github start` | `<N> [--repo OWNER/REPO]` | `workflows/github/start.md` | Resolve `gh issue view`, create/reuse worktree branch `issue-<N>`, launch with `open-terminal --tracker github`, register `domain.github_issue`, enter GitHub watch. |
| `github start new` | `[title] [--repo OWNER/REPO]` | `workflows/github/start-new.md` | Create a GitHub issue, then run `github start <N>`. |
| `github watch` | `[N...]` | `workflows/github/watch.md` → `workflows/shared/session-watch.md` | GitHub extension over the generic loop. Handles PR/CI/review prompts, `UNKNOWN` merge timers, and gh failure escalation. |
| `github close-issue` | `<N>` | `workflows/github/close-issue.md` | Requires recorded PR plus authoritative `gh pr view` `state === MERGED` and non-null merge commit before closing/no-oping issue. Pane text alone is never enough. |
| `github terminate` | — | `workflows/github/terminate.md` | Summarizes GitHub entries partitioned by `domain.github_issue`; mixed sessions also include generic and Linear summaries. |

### Lane-agnostic status

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `status` | — | inline | Print current pane registry + state machine snapshot from `<FLIGHTDECK_STATE_DIR>/flightdeck-state-<TMUX_SESSION>.json`. Read-only. |

## Skill Rules

Decision rules grouped by domain. Pattern docs under `patterns/` hold examples and edge cases. Read the matching pattern doc whenever its prompt class appears.

### Tmux monitoring (`patterns/tmux-monitoring.md`)

- **Pane-0 rule**: every read targets `<session>:<window>.<idx>` explicitly (enforced by `pane-poll`). Default-pane captures break when sub-agents spawn additional panes. Index is pinned per window at registry init via fingerprinting.
- **Bell clearing** after sending input — atomic chained idiom (no flicker, enforced by `pane-respond` / `pane-clear-bell`):
  ```
  tmux select-window -t <session>:<window> \; select-window -t <ORIG>
  ```
- **Capture-pane scrollback**: `-S -200` for classification (enough for prompt + options, not the whole buffer).

### Prompt handlers (`patterns/prompt-handlers.md`)

- **Cleanup scope** — answer YES iff the target path equals the asking pane's registered worktree. NEVER for sibling worktrees. Extract the path from prompt text and compare to the registry entry. Some agents propose batch cleanup; that's wrong.
- **Combine guidance with option pick** — when picking an option triggers immediate sub-agent delegation (rebase, fix), sub-agent guidance must ride in the SAME input. `pane-respond` rejects `rebase-multi-choice` payloads missing the preserve / apply / verify triplet.
- **Bot-review prompt response** — on a Skip/Wait/Abort prompt, decide from `gh pr view <PR> --json statusCheckRollup,reviewDecision,labels`. Skip if bot check is `SUCCESS` and `reviewDecision == APPROVED` (or unset with no pending reviewers). Real pending reviewer → escalate. Master never re-invokes `bot-review-wait` itself.
- **GitHub merge-now gate** — before answering Merge in GitHub mode, run `gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup`. Auto-Merge only when `mergeStateStatus === "CLEAN"`, review is approved (or no pending reviewers), and every required check is `SUCCESS` or `SKIPPED`. `UNKNOWN`, `BEHIND`, `DIRTY`, `BLOCKED`, `HAS_HOOKS`, missing fields, and `FLIGHTDECK_AUTO_MERGE=0` all escalate or route to the documented UNKNOWN/auto-rebase path; never merge from pane text alone. `FLIGHTDECK_AUTO_MERGE=0` also blocks force-merge confirmation and UNKNOWN-timer transitions to force-merge.
- **Rebase-multi-choice guidance** — payload must follow the preserve / apply / verify triplet:
  - **Preserve**: function signatures / parameter splits / new wrappers from upstream merge that must NOT be reverted.
  - **Apply**: field renames / type updates / local refactors that go ON TOP of the preserved shape.
  - **Verify**: exact test invocation proving both sides intact.
- **Parent vs related** — accept `child of <current-PR-issue>` when scopes don't intersect another live worktree's PR files (expansion bias). Reject → use `related` or pick a different parent. Capture each new issue's proposed parent/project/scope at decision time for end-of-session report.
- **Verify-don't-trust** — never advance issue state on an agent claim alone. After structural change (rebase done, conflicts resolved, fields renamed), run verification grep against the worktree. For rebases: check function signatures and rename counts in every conflict file.

### Conflict detection (`patterns/conflict-detection.md`)

- **`defer-ci`** label blocks heavy CI lanes (Lint, Cross-Platform, Linux Integration, Bench, Fixture Sync) but NOT bot reviews. Bot review runs with `defer-ci`; CI runs after label drops.
- **File-level conflict graph** — build edges from `gh pr view <N> --json files`. Two PRs with file-set intersection conflict; merge order is topological + smallest-scope-first.
- **UNKNOWN-state timer** — GitHub `mergeStateStatus` can stay `UNKNOWN` for minutes after upstream `main` moves. Force-merge predicate: `APPROVED ∧ all_checks_in {SUCCESS, SKIPPED} ∧ disjoint(PR_files, main_files_recently_changed) ∧ unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS ∧ FLIGHTDECK_AUTO_MERGE != 0`.
- **GitHub issue close** — `github close-issue` requires `domain.github_issue.pr_number` plus authoritative `gh pr view <PR> --json state,mergeStateStatus,mergeCommit` with `state === "MERGED"` and non-null `mergeCommit` before `gh issue close`. If `state === "MERGED"` but `mergeCommit` is null, pause with `reason="gh-pr-merge-commit-missing"`. If `gh issue view <N> --json state` says already `CLOSED`, no-op and log; pane-buffer `MERGED` text is never sufficient.

### Decision biases (`patterns/decision-biases.md`)

- **Scope-creep detector** — `scope_files_actual` (from `gh pr view --json files`) vs `scope_files_declared` (parsed from issue description). `actual > 2× declared` → escalate. Don't auto-revert.
- **Smaller-PR-first** — when two PRs overlap, smaller merges first; bigger absorbs the rebase. Reverse order forces smaller PR to rebase against bigger restructure.
- **Rule of three** — don't extract a shared helper across <3 sibling files. At 2 sites abstraction shape isn't visible; at 3 rule is satisfied.
- **Expansion bias** — prefer inline fixes in current PR over new issues, UNLESS reason is concrete (different scope, different agent, requires measurement, blocked dep, architectural decision). "Tidiness" is not a reason.
- **Merge-order tiebreakers**: (1) smallest scope first, (2) overlapping files: smaller first, (3) else: any order.

### Structured questions (`patterns/opencode-questions.md`, `patterns/pi-questions.md`)

- **Never pass off-list labels.** Pick `--answer` / `--answer-multi` values from `question.questions[i].options[].label`. Pi `--answer-text` only when matching tab has `allowCustom=true`; OpenCode free-form requires `--reject` + follow-up `opencode run --attach --session <SID> "<text>"`.
- **Pi inner agent completions** are advisory. Re-poll the outer orchestrator only; never call `subagent` / `steer_subagent` / `get_subagent_result` against an orchestrator's inner panes.

### Rate-limit recovery (`WATCHDOGS.md`, `lib/flightdeck-core/src/daemon/rate-limit-watchdog.ts`)

- **Do not escalate rate-limited panes as "stuck".** A tracked Pi pane rate-limit envelope routes through the rate-limit watchdog instead of the normal wake path. User/toolResult messages, missing stop reasons, and prose outside the assistant envelope are ignored.
- **Backoff ladder** — default `60s, 120s, 300s, 600s, 1800s`, max `5` attempts per pane. Anthropic `retry_after_ms` wins over env ladder. After exhaustion the watchdog stops retrying and the pane falls through to normal `needs_completion` handling. Env tuning lives in [`ENV.md`](./ENV.md): `VSTACK_RATE_LIMIT_WATCHDOG=0`, `VSTACK_RATE_LIMIT_MAX_ATTEMPTS`, `VSTACK_RATE_LIMIT_BACKOFF_LADDER`.
- **Classifier + activity signals** — rate-limit decisions tag as `pi-rate-limit-retry` (scheduled) and `pi-rate-limit-exhausted` (ladder spent). Treat these as advisory; do not pause master or prompt user unless exhausted tag fires.
- **Layer A vs B** — subagent panes (`pi-agents-tmux`) carry their own vendored watchdog; Flightdeck-managed tracked panes are covered by the daemon's Pi subscriber wake branch. Both consume the same pure decision module.

## Scripts

Full script table and event details live in [`SCRIPTS.md`](./SCRIPTS.md). Required quick rules:

- Invoke scripts as `.agents/skills/flightdeck/scripts/<script> [args]` when using installed skill paths.
- Most scripts trampoline into TypeScript under `lib/flightdeck-core/`; `flightdeck-dashboard` is the Rust dashboard trampoline.
- Use `open-terminal` for issue workflow spawns. Never hand-roll issue tmux/terminal commands.
- Use `flightdeck-session` for generic session `start` / `attach`.
- Use `pane-poll` and `pane-respond` for pane IO; do not bypass adapter routes except as documented fallback.
- Use `prompt-classify` tag names exactly. Full tag catalog lives in [`PROMPT-TAGS.md`](./PROMPT-TAGS.md).

## Schema, watchdogs, and configuration

- Master state + activity sidecar contract lives in [`SCHEMA.md`](./SCHEMA.md). `readTrackedEntries(state)` is the canonical reader; `writeTrackedEntry(state, id, entry)` is the canonical writer and rejects malformed domain combinations.
- Reliability watchdog details live in [`WATCHDOGS.md`](./WATCHDOGS.md).
- Env var tables live in [`ENV.md`](./ENV.md). Operator-facing gates include `FLIGHTDECK_AUTO_MERGE`, `FLIGHTDECK_FORCE_MERGE_AFTER_SECS`, `FLIGHTDECK_AUTO_REBASE`, dashboard controls, and the `VSTACK_*` watchdog toggles.

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/linear/start.md` | `linear start` (from main) | From-main entry: dashboard, issue selection, research evaluation, parallel-check, spawn, enter Linear watch |
| `workflows/linear/start-new.md` | `linear start new` | Create new issue from main + spawn |
| `workflows/linear/parallel-check.md` | `linear parallel-check` (also nested from `start.md` § 4) | Verify candidate issue set is safe to spawn in parallel |
| `workflows/shared/session-watch.md` | `session watch`, and core loop invoked by issue `linear watch` / `github watch` | Generic state init, entry reconciliation, daemon spawn/ack/yield, polling, generic prompt routing, compaction recovery |
| `workflows/shared/session-handle-prompt.md` | Nested invocation from `session-watch` / issue `linear watch` / `github watch` for generic tags | Generic prompt response surface; no PR/Linear/GitHub/worktree dependency |
| `workflows/linear/watch.md` | `linear watch` (issue entry) or invoked at end of `start.md` after spawn | Linear issue-mode extension over `session-watch`: load issue skills, track issue-specific lifecycle states, route issue-only handlers, plan merges, terminate |
| `workflows/linear/handle-prompt.md` | Nested invocation from issue `linear watch` for issue-only tags | PR/Linear/worktree prompt response surface only |
| `workflows/linear/close-issue.md` | Nested invocation from `linear watch` § 2 on `terminal-state-reached` | Verify two-signal terminal state, update master state, kill window, keep registry entry for terminate reporting/final cleanup |
| `workflows/linear/merge-plan.md` | Nested invocation from `linear watch` § 4 | Conflict-graph build + smallest-first merge ordering |
| `workflows/linear/terminate.md` | Nested invocation from issue `linear watch` or generic session unwind | Generic session summary for ad-hoc/workflow entries; issue/PR/new-issues recommendation summary when any issue entry exists; master-state finalization |
| `workflows/github/start.md` | `github start <N>` | Fetch GitHub issue context, compose self-contained child prompt, spawn branch `issue-<N>` with `open-terminal --tracker github`, register `domain.github_issue`, enter watch |
| `workflows/github/start-new.md` | `github start new` | Create a GitHub issue, then launch it through `github/start.md` |
| `workflows/github/watch.md` | `github watch` | GitHub issue extension over `session-watch`: PR/CI/review routing, UNKNOWN timer, gh failure escalation, termination debounce |
| `workflows/github/handle-prompt.md` | Nested invocation from GitHub `watch` for GitHub tags | GitHub PR prompt response surface: merge gate, UNKNOWN/force-merge, bot review, rebase, force-push, cleanup |
| `workflows/github/close-issue.md` | Nested invocation from GitHub `watch` on `terminal-state-reached` | Requires recorded PR + authoritative merged PR/merge commit before issue close/no-op and teardown |
| `workflows/github/terminate.md` | Nested invocation from GitHub `watch` or mixed unwind | Partitions by `domain.github_issue`, emits GitHub summary, coexists with generic and Linear summaries |

## Workflow Execution

These rules apply to boundary workflows (`start.md`, `start-new.md`, `terminate.md`, `close-issue.md`, and per-tag handlers in `session-handle-prompt.md` / `handle-prompt.md`). The `session-watch.md` generic loop and `watch.md` issue extension are reactive; their inner decisions are judgment calls subject to their workflow text.

### Sequential Section Execution

Process sections sequentially. Execute all sub-sections within a section before proceeding. Never skip steps because outcome seems predictable, visible state looks unchanged, or summary seems obvious. Workflow text is the decision authority.

### Nested Workflow Invocation

Nested workflows (marked with `⤵`) must be invoked through the harness's workflow invocation mechanism — never inlined or substituted with ad-hoc commands. If marker includes a return point (`→ § X`), record it before invoking.

### Format Tags Are Literal

`<output_format>`, `<recommendation_format>`, `<launch_now_format>`, and other XML-tagged content blocks define exact emitted content:

1. Fill `[PLACEHOLDERS]` with actual values.
2. Omit lines/sections where placeholder value is empty or not applicable.
3. Add nothing else — no commentary, extra fields, rewording, or explanations before/after.
4. Do not paraphrase — use exact structure, headings, and field names from the tag.

The user-visible output blocks at the end of `terminate.md` (`<generic_output_format>` / `<empty_output_format>` / `<issue_output_format>`) and `close-issue.md` (`<output_format>`) are tagged for this reason: emit them in full, not as summary lines.

## Implementation Constraints

1. **Aggressive autonomy on known shapes; escalate on novel shapes.** The classifier returns a tag for known prompt shapes. Generic `generic-multi-choice` uses bounded safe policy in `session-handle-prompt.md`; issue-only prompts use `handle-prompt.md`. Both escalate when options are destructive, ambiguous, or novel. They do NOT blindly pick the first option.
2. **Daemon-driven wake; no blocking sleeps.** `flightdeck-daemon` owns wake delivery for every harness. Master ends each turn after `flightdeck-daemon ack` + `flightdeck-state master-busy unlock`. Never `sleep`. Wake payload reference: `/flightdeck` (claude/opencode/default), `$flightdeck` (codex), `/skill:flightdeck` (pi). Claude Code MAY arm `ScheduleWakeup({delaySeconds: 1800})` as defensive fallback.
3. **Dashboards are read-only and additive.** Rust dashboard renders from on-disk artifacts master and daemon already write; it never bypasses schema. Only write affordances are confirmation-gated shells to canonical helpers (`pane-registry remove` for stale entries, `tmux select-window` for focus).
4. **One daemon per tmux session.** Concurrent Flightdecks within same tmux session are refused via flock. Run separate tmux sessions for parallel Flightdeck instances.
5. **Explicit LLM launch profile.** Every fresh LLM pane Flightdeck creates must have selected model and effort/thinking level, or explicit `launch.reasoning_status` / `unsupported_reason` explaining why harness/session cannot report it. Subagents with generated model/effort definitions are exempt.
6. **No hidden scripts or tags.** All scripts must appear in [`SCRIPTS.md`](./SCRIPTS.md). All `prompt-classify` tags must appear in [`PROMPT-TAGS.md`](./PROMPT-TAGS.md).

## Compaction Recovery

Master state is persisted on every state mutation and rehydrated on watch re-entry. Generic entry reconciliation and daemon recovery live in `workflows/shared/session-watch.md` § 6; issue-specific recovery (pane fingerprinting, `unknown_since`, conflict graph, and paused issue re-evaluation) lives in `workflows/linear/watch.md` § 8.
