---
name: flightdeck
description: "PRIMARY/MAIN AGENT ONLY — do NOT load as a sub-agent. tmux session supervisor for AI harness panes; runs Linear/GitHub issue and plan-file lanes with structured activity JSONL and Rust dashboard."
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
   - Plan-file commands (`plan start <path>`, `plan watch`, `plan close-item`, `plan terminate` when entries use `domain.plan_item`) load `github` and `worktree` only. Do **not** load `linear` or `project-management`.
3. If a lane dependency cannot be loaded after entering issue or plan mode, stop and tell the user. Do not proceed with PR/worktree actions without it.

## Dependency modes

Core Flightdeck is a generic session manager. It needs tmux and the harness adapter for each tracked pane; GitHub, Linear, project-management, and worktree skills load only when an issue or plan lane needs them.

| Lane | Load | Do not load |
|------|------|-------------|
| Session | tmux + selected harness adapter | `github`, `linear`, `project-management`, `worktree` |
| Linear issue | `github`, `linear`, `project-management`, `worktree` | only skip redundant loads |
| GitHub issue | `github`, `worktree` | `linear`, `project-management` |
| Plan file | `github`, `worktree` | `linear`, `project-management` |

`decider` remains optional for agents that want an extra decision aid.

## Mode

You are in **master mode**. Master supervises: it routes prompts, updates state/dashboard, and calls named Flightdeck workflows/scripts. It does not perform per-issue implementation, verification, product-code mutation, or domain mutations directly. Route fixes/checks back through the owning pane/workflow; record only cross-session facts spawned panes cannot see.

Generic session mode is the core path: launch/attach with `flightdeck-session`, supervise with `session-watch.md`, answer generic prompts, and summarize sessions. It skips issue selection, research/plan evaluation, `open-terminal`, merge planning, GitHub/Linear/worktree actions, and project-management flows.

Issue-mode begins only after a Linear or GitHub issue command. Linear mode keeps the research/plan evaluation → spawn (`open-terminal`) → watch loop → merge planning → unwind path. GitHub mode resolves issue context with `gh`, spawns a child with a self-contained prompt through `open-terminal --tracker github`, watches PR/CI/review state, then verifies close/termination from authoritative GitHub state. Plan mode freezes one markdown plan file, decomposes explicit or freeform plan content into PR-sized work items with inferred worktrees/dependencies when absent, sanitizes master-only orchestration context from child briefs, dry-runs the item graph for one user confirmation, spawns each dependency-free item through `flightdeck-session start --kind workflow` with a self-contained `tmp/brief.md`, stores metadata under `domain.plan_item`, and reuses GitHub PR safety gates without loading Linear or project-management.

Communicate with spawned agents through native channels (`pane-respond`): OpenCode HTTP, Claude Channels MCP/JSONL, Pi bridge, Codex JSON-RPC, with tmux capture/send-keys only as fallback (see `patterns/tmux-monitoring.md`). Pause for the user only on scope creep that requires reverting agent work, force-merging against a real content conflict, issue abort, direct `main` mutation when no orchestrator pane is alive, or a novel prompt shape no rule covers. Do not re-implement orchestration gates; answer surfaced prompts and add only cross-session conflict/scope facts.

## Reference docs

Load these on demand; keep this file as the operational quick path.

| Need | Read |
|------|------|
| Master-state JSON, durable run store, activity sidecar, registry shape, `readTrackedEntries` / `writeTrackedEntry` contract | [`SCHEMA.md`](./SCHEMA.md) |
| Plan file format and examples | [`PLAN-FILE.md`](./PLAN-FILE.md) |
| Full scripts table, script arguments, Pi bg-task exit, Pi activity broker, activity sidecar, `daemon-exited` details | [`SCRIPTS.md`](./SCRIPTS.md) |
| Full `prompt-classify` tag catalog, including daemon/event-only tags | [`PROMPT-TAGS.md`](./PROMPT-TAGS.md) |
| Env var tables: master loop, watchdog gates, daemon hygiene, dashboard, adapter tuning | [`ENV.md`](./ENV.md) |
| Watchdog behavior: agent-end, idle-stall, edit-loop, rate-limit | [`WATCHDOGS.md`](./WATCHDOGS.md) |
| Development workflow, parity tests, daemon internals | [`DEVELOPMENT.md`](./DEVELOPMENT.md) |

## Commands

Use the session table for core Flightdeck: tracked tmux-window sessions, harness IO, generic prompts, and summaries. Use Linear/GitHub/Plan tables only after the user enters an issue/PR/worktree domain. Dashboard terms: TrackedEntry row = source-of-truth state; Rust dashboard/TUI = persistent visibility; cycle summary = chat-visible tick report.

### Session management

Generic tmux-window session tracking. These commands do not require a fake issue id.

| Command | Arguments | Workflow / Script | Notes |
|---------|-----------|-------------------|-------|
| `session start` | `--session-id <ID> --title <T> --cwd <path> --harness <H> (--cmd <cmd> \| --prompt <text>) [--kind adhoc\|workflow] [--model <id>] [--effort <level>\|--thinking <level>] [--after-window-id <@ID>] [--no-active-run]` | `scripts/flightdeck-session start` | Creates/reuses the active durable run for real sessions, creates a new tmux window (never a split), launches command/harness, records a generic `.entries[ID]` row, records launch model/effort metadata, exports Flightdeck child env, and best-effort launches/verifies the Rust dashboard before the child window unless `FLIGHTDECK_DASHBOARD=0`. Dashboard failure warns but must not block pane creation; dashboard self-launch uses `--no-active-run`; prompt launches pass harness-aware model/effort argv. |
| `session attach` | `--pane <%PANE_ID> --harness <H> --title <T> [--session-id <ID>] [--kind adhoc] [--model <id>] [--effort <level>\|--thinking <level>]` | `scripts/flightdeck-session attach` | Creates/reuses the active durable run, attaches an existing pane by stable pane id, records supplied or unsupported launch metadata, and best-effort launches/verifies the dashboard unless disabled. Pi attach probes `pi-bridge` when available. |
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

### Plan workflows

Entering these commands loads `github` + `worktree` only. The master analyzes one plan file, previews the item graph, and spawns each item with a self-contained brief through `flightdeck-session start --kind workflow`.

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `plan start` | `<path>` | `workflows/plan/start.md` | Resolve and freeze a markdown plan, decompose explicit or freeform content into work items, infer missing worktrees/dependencies/parallel waves, confirm once, create plan entries, spawn dependency-free items, enter plan watch. |
| `plan watch` | `[ITEM_ID...]` | `workflows/plan/watch.md` → `workflows/shared/session-watch.md` | Plan extension over the generic loop. Handles dependency unblocks, PR/CI/review prompts, `UNKNOWN` merge timers, and gh failure escalation. |
| `plan close-item` | `<ITEM_ID>` | `workflows/plan/close-item.md` | Requires recorded PR plus authoritative `gh pr view` `state === MERGED` and non-null merge commit before cleanup/teardown. Pane text alone is never enough. |
| `plan terminate` | — | `workflows/plan/terminate.md` | Summarizes plan items partitioned by `domain.plan_item`; mixed sessions also include generic, GitHub, and Linear summaries. |

Plan file format reference: [`PLAN-FILE.md`](./PLAN-FILE.md).

### Lane-agnostic status

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `status` | — | inline | Print current pane registry + state machine snapshot from `<FLIGHTDECK_STATE_DIR>/flightdeck-state-<TMUX_SESSION>.json`. Read-only. |

### Run storage helpers

Durable run commands are read/write state helpers only. They do not start dashboard UI or spawn panes. `flightdeck-session start` / `attach` call `run ensure`; terminate/archive workflows call `run terminate-active` through `flightdeck-state archive`. If a start/attach path creates a fresh active run and aborts before registration, `flightdeck-session` terminates that new run while preserving reused active runs.

If a strict permission error mentions `mode=644 expected 600`, tell the user to run `vstack flightdeck migrate-permissions --dry-run` and then `vstack flightdeck migrate-permissions`. Do not recommend blind `chmod -R`: directories must become `0700`, files must become `0600`, and the migration command refuses symlinks, foreign-owned paths, or group/other-writable paths.

| Command | Arguments | Script | Notes |
|---------|-----------|--------|-------|
| `state run create` | `--project-root <path> --tmux-session <name> [--state-dir <dir>]` | `flightdeck-state run create` | Creates a durable run under `~/.vstack/flightdeck/projects/<project-id>/runs/<run-id>/`, writes `metadata.json`, `state.json`, `activity.jsonl`, and sets `active-runs/<tmux-session>.json`. Honors `FLIGHTDECK_STATE_DIR` / `.env.local` unless `--state-dir` is supplied. |
| `state run ensure` | `--tmux-session <name> [--project-root <path>] [--state-dir <dir>]` | `flightdeck-state run ensure` | Lifecycle-safe start/attach helper: reuses only the requested tmux session's active run, creates one when absent, creates fresh after termination, finalizes stale runs only when recorded pane ids are all absent, and fails closed on same-session metadata or liveness failure. Other tmux sessions can have separate active runs. |
| `state run active` | `[--project-root <path>] [--tmux-session <name>\|--all --json]` | `flightdeck-state run active` | Prints one session's active pointer plus run metadata, all active pointers, or `null` if none exists. |
| `state run list` | `[--project-root <path>] [--json]` | `flightdeck-state run list` | Lists known runs newest-first; use `--json` for machine output. |
| `state run show` | `<run-id> [--snapshot <timestamp>] [--project-root <path>]` | `flightdeck-state run show` | Prints run metadata, state, activity path, and snapshot names as JSON. |
| `state run terminate` | `<run-id> [--project-root <path>] [--summary-path <path>]` | `flightdeck-state run terminate` | Marks run metadata/state terminated, writes a final snapshot, copies project-local summary to run `summary.md` when available, and clears only the active pointer for that run. |
| `state run terminate-active` | `--tmux-session <name> [--project-root <path>] [--summary-path <path>]` | `flightdeck-state run terminate-active` | Terminates that tmux session's active run; used by `flightdeck-state archive` before rotating legacy files. |
| `state run import-legacy` | `[--project-root <path>] [--state-dir <dir>]` | `flightdeck-state run import-legacy` | Imports `flightdeck-state-*.json.archive` files into durable run storage without deleting legacy files. |

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
- **GitHub / Plan merge-now gate** — before answering Merge in GitHub or plan mode, run `gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup`. Auto-Merge only when `mergeStateStatus === "CLEAN"`, review is approved (or no pending reviewers), and every required check is `SUCCESS` or `SKIPPED`. `UNKNOWN`, `BEHIND`, `DIRTY`, `BLOCKED`, `HAS_HOOKS`, missing fields, and `FLIGHTDECK_AUTO_MERGE=0` all escalate or route to the documented UNKNOWN/auto-rebase path; never merge from pane text alone. `FLIGHTDECK_AUTO_MERGE=0` also blocks force-merge confirmation and UNKNOWN-timer transitions to force-merge. Plan mode reads/writes `entry.domain.plan_item.pr_number` instead of issue-domain fields.
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
- **GitHub issue / Plan item close** — `github close-issue` requires `domain.github_issue.pr_number` plus authoritative `gh pr view <PR> --json state,mergeStateStatus,mergeCommit` with `state === "MERGED"` and non-null `mergeCommit` before `gh issue close`. `plan close-item` requires the same authoritative PR proof through `domain.plan_item.pr_number` before item cleanup or teardown. If `state === "MERGED"` but `mergeCommit` is null, pause with `reason="gh-pr-merge-commit-missing"`. If `gh issue view <N> --json state` says already `CLOSED`, no-op and log; pane-buffer `MERGED` text is never sufficient.
- **Post-merge local main sync** — after a PR is observably `MERGED`, run `flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json`. The helper validates remote/branch ref components, fetches only the remote-tracking branch with `--no-tags`, `--refmap=`, and an explicit refspec, blocks ignored/untracked file collisions by checking incoming tracked paths against existing local candidates, treats candidate directories as index-aware so tracked-only dir→file fast-forwards are allowed, fast-forwards only clean unambiguous local `main`, and reports `repo.main_synced`, `repo.main_sync_blocked`, or `repo.main_sync_failed`. Do not sync queued auto-merge until a later poll sees real `MERGED`; never reset, stash, discard, delete dirty paths, or force-push to reconcile local `main`.
- **Post-merge artifact cleanup** — offer user-confirmed cleanup only for tracked worktrees and matching local/remote branches with merged-PR proof plus terminal issue/item state. Default keep. Never touch default branches, sibling/dirty worktrees, unmerged branches, or unowned `: gone` branches.

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
- **Backoff ladder** — default `60s, 120s, 300s, 600s, 1800s`, max `5` attempts per pane. Anthropic `retry_after_ms` wins over env ladder. When Flightdeck's Pi subscriber spends the budget, it appends `pi-rate-limit-exhausted` as activity/advisory only and continues; that row does not wake master and does not fall through to `needs_completion`, completion, or blocking. Later independent events or daemon polls handle completion/blocking. Env tuning lives in [`ENV.md`](./ENV.md): `VSTACK_RATE_LIMIT_WATCHDOG=0`, `VSTACK_RATE_LIMIT_MAX_ATTEMPTS`, `VSTACK_RATE_LIMIT_BACKOFF_LADDER`.
- **Classifier + activity signals** — rate-limit decisions tag as `pi-rate-limit-skipped` (classifier rejection; activity-only, reason is `non-assistant` / `no-stopreason` / `stopreason-mismatch` / `no-prose`), `pi-rate-limit-retry` (scheduled), `pi-rate-limit-resolved` (healthy assistant turn reset), `pi-rate-limit-exhausted` (ladder spent; advisory/no-wake), and `pi-rate-limit-decider-error` (missing/failing decider). Treat these as advisory; do not pause master or prompt user on exhausted alone.
- **Layer A vs B** — subagent panes (`pi-agents-tmux`) carry their own vendored stateful watchdog; its budget exhaustion emits `subagents:rate_limit_exhausted` / `agent.rate_limit_exhausted` and runs the extension exhaustion handler for that subagent pane. Flightdeck-managed tracked panes are covered by the daemon's Pi subscriber wake branch, whose `pi-rate-limit-exhausted` row is advisory/no-wake only. Both consume the same pure decision module.

## Scripts

Full script table and event details live in [`SCRIPTS.md`](./SCRIPTS.md). Required quick rules:

- Invoke scripts as `.agents/skills/flightdeck/scripts/<script> [args]` when using installed skill paths.
- Most scripts trampoline into TypeScript under `lib/flightdeck-core/`; `flightdeck-dashboard` is the Rust dashboard trampoline.
- Use `flightdeck-repo-sync main --project-root <PROJECT_ROOT> --remote origin --branch main --json` after verified PR merges; branch only on its JSON `status`.
- Cleanup command: `.agents/skills/worktree/scripts/worktree remove <REGISTERED_WORKTREE>`. If squash merge makes safe branch deletion fail, use `git branch -D <BRANCH>` only after merged-PR proof + user confirmation.
- Use `open-terminal` for issue workflow spawns. Never hand-roll issue tmux/terminal commands.
- Use `flightdeck-session` for generic session `start` / `attach`.
- Use `pane-poll` and `pane-respond` for pane IO; do not bypass adapter routes except as documented fallback.
- Use `prompt-classify` tag names exactly. Full tag catalog lives in [`PROMPT-TAGS.md`](./PROMPT-TAGS.md).

## Schema, watchdogs, and configuration

- Master state + activity sidecar contract lives in [`SCHEMA.md`](./SCHEMA.md). `readTrackedEntries(state)` is the canonical reader; `writeTrackedEntry(state, id, entry)` is the canonical writer and rejects malformed domain combinations.
- Reliability watchdog details live in [`WATCHDOGS.md`](./WATCHDOGS.md).
- Env var tables live in [`ENV.md`](./ENV.md). Operator-facing gates include `FLIGHTDECK_AUTO_MERGE`, `FLIGHTDECK_FORCE_MERGE_AFTER_SECS`, `FLIGHTDECK_AUTO_REBASE`, `FLIGHTDECK_PRE_PR_REVIEW`, `FLIGHTDECK_PRE_PR_REVIEW_MAX_ROUNDS`, `FLIGHTDECK_PRE_PR_REVIEWERS`, dashboard controls, and the `VSTACK_*` watchdog toggles.

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/linear/start.md` | `linear start` (from main) | From-main entry: dashboard, issue selection, research evaluation, parallel-check, spawn, enter Linear watch |
| `workflows/linear/start-new.md` | `linear start new` | Create new issue from main + spawn |
| `workflows/linear/parallel-check.md` | `linear parallel-check` (also nested from `start.md` § 4) | Verify candidate issue set is safe to spawn in parallel |
| `workflows/shared/session-watch.md` | `session watch`, and core loop invoked by issue `linear watch` / `github watch` | Generic state init, entry reconciliation, daemon spawn/ack/yield, polling, generic prompt routing, compaction recovery |
| `workflows/shared/session-handle-prompt.md` | Nested invocation from `session-watch` / issue `linear watch` / `github watch` for generic tags | Generic prompt response surface; no PR/Linear/GitHub/worktree dependency |
| `workflows/shared/pre-pr-review.md` | Nested invocation from GitHub / Plan `handle-prompt.md` § 3 on `pre-pr-ready-for-review` | Master-side reviewer fan-out before child opens PR; owns `domain.<KEY>.review_rounds` and the round-cap escalation. |
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
| `workflows/plan/start.md` | `plan start <path>` | Parse plan file, dry-run preview, create `domain.plan_item` entries, spawn dependency-free items with self-contained `tmp/brief.md` prompts |
| `workflows/plan/watch.md` | `plan watch` | Plan extension over `session-watch`: dependency unblocks, PR/CI/review routing, UNKNOWN timer, gh failure escalation, termination debounce |
| `workflows/plan/handle-prompt.md` | Nested invocation from Plan `watch` for plan/GitHub tags | Reuses GitHub PR handlers adapted to `domain.plan_item`; adds dependency-edge resolution and plan cleanup scope |
| `workflows/plan/close-item.md` | Nested invocation from Plan `watch` on `terminal-state-reached` | Requires recorded PR + authoritative merged PR/merge commit before item cleanup and teardown |
| `workflows/plan/terminate.md` | Nested invocation from Plan `watch` or mixed unwind | Partitions by `domain.plan_item`, emits plan summary, coexists with generic, GitHub, and Linear summaries |

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
3. **Dashboards are mostly read-only and additive.** Rust dashboard renders from on-disk artifacts master and daemon already write; it never bypasses schema. Write affordances are limited to confirmation-gated shells to canonical helpers (`pane-registry remove` for stale entries, `tmux select-window` for focus) plus the Settings popup, which persists dashboard-scoped env overrides to `<project-root>/tmp/flightdeck-settings.toml`.
4. **One daemon per tmux session.** Concurrent Flightdecks within same tmux session are refused via flock. Run separate tmux sessions for parallel Flightdeck instances.
5. **Explicit LLM launch profile.** Every fresh LLM pane Flightdeck creates must have selected model and effort/thinking level, or explicit `launch.reasoning_status` / `unsupported_reason` explaining why harness/session cannot report it. Subagents with generated model/effort definitions are exempt.
6. **User-visible pane references use tracked-entry ids.** Master messages must name panes by `entry.id` only; never invent shorthand labels that are absent from registry/dashboard/tmux metadata.
7. **No hidden scripts or tags.** All scripts must appear in [`SCRIPTS.md`](./SCRIPTS.md). All `prompt-classify` tags must appear in [`PROMPT-TAGS.md`](./PROMPT-TAGS.md).

## Compaction Recovery

Master state is persisted on every state mutation and rehydrated on watch re-entry. Generic entry reconciliation and daemon recovery live in `workflows/shared/session-watch.md` § 6; issue-specific recovery (pane fingerprinting, `unknown_since`, conflict graph, and paused issue re-evaluation) lives in `workflows/linear/watch.md` § 8. Plan-item recovery lives in `workflows/plan/watch.md` § 10 and preserves dependency graph, PR, merge commit, and `unknown_since` fields under `domain.plan_item`.
