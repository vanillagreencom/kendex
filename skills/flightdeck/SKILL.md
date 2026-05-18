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
2. Determine the command mode before loading dependencies:
   - Generic session commands (`session start`, `session attach`, `session watch`, `session status`, `session stop`, `session remove`) require only tmux plus the selected harness adapter (`pi-bridge`, OpenCode HTTP, Claude Channels, Codex app-server, or tmux fallback). Do **not** load `github`, `linear`, `project-management`, or `worktree` for generic session commands.
   - Linear issue workflow commands (`start [ISSUE_ID]`, `start new`, `parallel-check`, issue `watch`, `merge-plan`, `close-issue`, `terminate` when entries use `domain.issue`) load `github`, `linear`, `project-management`, and `worktree` on demand. Redundant loads are no-ops.
   - GitHub issue workflow commands (`github start <N>`, `github start new`, `github watch`, `github close-issue`, `github terminate` when entries use `domain.github_issue`) load `github` and `worktree` only. Do **not** load `linear` or `project-management` for GitHub mode.
3. If an issue workflow dependency cannot be loaded after entering issue mode, stop and tell the user. Do not proceed with issue/PR/worktree actions without it.

---

## Dependency modes

Core Flightdeck is a generic session manager. It requires tmux and the harness adapters needed for the tracked panes only; it does not require GitHub, Linear, project-management, or worktree skills.

### Linear issue-mode dependencies (load when entering Linear issue workflows)

- `github` — PR inspection, merge state, checks, review threads, file lists.
- `linear` — issue metadata, created follow-ups, cycle/todo recommendation checks.
- `worktree` — issue branch/worktree ownership and cleanup scope.
- `project-management` — cycle planning, audits, roadmaps, research issue wrappers used by issue workflows.

### GitHub issue-mode dependencies (load when entering GitHub issue workflows)

- `github` — issue/PR inspection, merge state, checks, reviews, issue close.
- `worktree` — issue branch/worktree ownership and cleanup scope.

GitHub mode intentionally does **not** load `linear` or `project-management`.

`decider` remains optional for agents that want an extra decision aid, but core session management does not require it.

---

## Mode

You are in **master mode**. Master supervises: it routes prompts, updates state/dashboard, and calls named Flightdeck workflows/scripts. It does not perform per-issue implementation, verification, product-code mutation, or domain mutations directly. Route fixes/checks back through the owning pane/workflow; record only cross-session facts spawned panes cannot see.

Generic session mode is the core path: launch/attach with `flightdeck-session`, supervise with `session-watch.md`, answer generic prompts, and summarize sessions. It skips issue selection, research/plan evaluation, `open-terminal`, merge planning, GitHub/Linear/worktree actions, and project-management flows.

Issue-mode global arc begins only after entering a Linear or GitHub issue workflow command. Linear mode keeps the existing research/plan evaluation → spawn (`open-terminal`) → watch loop → merge planning → unwind path. GitHub mode resolves issue context with `gh`, spawns a child with a self-contained prompt through `open-terminal --tracker github`, watches PR/CI/review state, then verifies close/termination from authoritative GitHub state. Communicate with spawned agents through native channels (`pane-respond`): opencode HTTP, Claude Channels MCP/JSONL, Pi bridge, Codex JSON-RPC, with tmux capture/send-keys only as fallback (see `patterns/tmux-monitoring.md`). Pause for the user only on scope creep that requires reverting agent work, force-merging against a real content conflict, issue abort, direct `main` mutation when no orchestrator pane is alive, or a novel prompt shape no rule covers. Do not re-implement orchestration gates; answer surfaced prompts and add only cross-session conflict/scope facts.

## Commands

Use the session-management table for the core Flightdeck product: tracked tmux-window sessions, harness IO, generic prompts, and summaries. Dashboard terms are distinct: TrackedEntry row = source-of-truth state; Rust dashboard/TUI = persistent visibility launched by default; cycle summary = chat-visible tick report, not a dashboard replacement. Use the issue-workflow table only after the user enters the issue/PR/worktree domain; those workflows layer on `session-watch.md` / `session-handle-prompt.md` rather than replacing them.

### Session management

Generic tmux-window session tracking. These commands do not require a fake issue id.

| Command | Arguments | Workflow / Script | Notes |
|---------|-----------|-------------------|-------|
| `session start` | `--session-id <ID> --title <T> --cwd <path> --harness <H> (--cmd <cmd> \| --prompt <text>) [--kind adhoc\|workflow] [--model <id>] [--effort <level>\|--thinking <level>]` | `scripts/flightdeck-session start` | Creates a new tmux window (never a split), launches the command/harness, sets `FLIGHTDECK_MANAGED=1` + `FLIGHTDECK_CHILD_PANE=1`, records launch model/effort metadata, and records a generic `.entries[ID]` row. Prompt LLM launches pass harness-aware model/effort argv (Pi `--model` + `--thinking`, Claude `--model` + `--effort`, Codex `-m` + `model_reasoning_effort`; OpenCode validates `--model` via `opencode models` and records effort unsupported). Launches/verifies the Rust dashboard by default unless `FLIGHTDECK_DASHBOARD=0`. |
| `session attach` | `--pane <%PANE_ID> --harness <H> --title <T> [--session-id <ID>] [--kind adhoc] [--model <id>] [--effort <level>\|--thinking <level>]` | `scripts/flightdeck-session attach` | Attaches an existing pane without launching a new window, records supplied or unsupported model/effort metadata, and launches/verifies the Rust dashboard unless disabled. Pi attach also probes `pi-bridge` by pane pid and records `pi_session_id`/socket metadata when available. |
| `session watch` | `[ENTRY_ID...]` | `workflows/shared/session-watch.md` | Generic daemon/poll/handler loop for tracked entries. Verifies dashboard presence on re-entry before daemon yield. Routes only generic handlers and guards issue-only tags as `domain-mismatch`; no GitHub/Linear/worktree dependency. |
| `session prompt routing` | nested from `session watch` | `workflows/shared/session-handle-prompt.md` | Generic prompt handlers for structured questions, bash permission prompts, safe bounded choices, terminal completion, `pi-bg-task-exit`, and `domain-mismatch`. |
| `session status` | — | inline / `flightdeck-state tracked-entries` | Read-only normalized `.entries` snapshot. |
| `session stop` / `session remove` | `<ENTRY_ID>` | `pane-registry teardown-entry` / `pane-registry remove` | Teardown uses stable `pane_id` and accepts the issue-mode lifecycle (`merged|aborted|dead`) plus the generic lifecycle (`complete|cancelled`) as terminal states. `remove` drops the `.entries` row. |

### Linear issue workflows

Linear issue/PR/worktree workflows. Entering these commands loads Linear issue-mode dependencies on demand. Command names stay unchanged in this phase.

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `start` | `[ISSUE_ID]` | `workflows/linear/start.md` | From-main issue entry. Dashboard, issue selection, research evaluation, parallel-check, spawn (`open-terminal`), enter issue watch loop. |
| `start new` | `[title]` | `workflows/linear/start-new.md` | Create new issue + spawn through the issue workflow path. |
| `start self` | — | inline | Initialize master issue session only, await further issue commands. |
| `parallel-check` | `[ISSUE_IDS]` | `workflows/linear/parallel-check.md` | Verify a candidate issue set is safe to spawn in parallel. |
| `watch` | `[ISSUE_IDS]` | `workflows/linear/watch.md` → `workflows/shared/session-watch.md` | Issue-mode extension over the generic loop. Tracks issue-specific lifecycle states, routes PR/Linear/worktree handlers, and resumes merge planning. |
| `merge-plan` | — | `workflows/linear/merge-plan.md` | Build PR conflict graph and choose smallest-safe merge order for issue entries. |
| `close-issue` | `<ISSUE_ID>` | `workflows/linear/close-issue.md` | Verify terminal issue outcome, record issue fields, and tear down the issue window safely. |
| `terminate` | — | `workflows/linear/terminate.md` | If any tracked entry is `kind=issue`, produce the issue/PR/new-issue recommendation summary; mixed sessions also include generic session summary. |
| `status` | — | inline | Print current pane registry + state machine snapshot from `tmp/flightdeck-state-<TMUX_SESSION>.json`. Read-only. |

### GitHub issue workflows

Plain GitHub issue/PR/worktree workflows. Entering these commands loads `github` + `worktree` only. The child pane receives a self-contained prompt; do not invoke a master-side flightdeck supervisor workflow inside the child.

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `github start` | `<N> [--repo OWNER/REPO]` | `workflows/github/start.md` | Resolve `gh issue view`, create/reuse worktree branch `issue-<N>`, launch with `open-terminal --tracker github`, register `domain.github_issue`, enter GitHub watch. |
| `github start new` | `[title] [--repo OWNER/REPO]` | `workflows/github/start-new.md` | Create a GitHub issue, then run `github start <N>`. |
| `github watch` | `[N...]` | `workflows/github/watch.md` → `workflows/shared/session-watch.md` | GitHub extension over the generic loop. Handles PR/CI/review prompts, `UNKNOWN` merge timers, and gh failure escalation. |
| `github close-issue` | `<N>` | `workflows/github/close-issue.md` | Requires recorded PR number plus authoritative `gh pr view` `state === MERGED` and non-null merge commit before closing/no-oping issue. Missing merge commit pauses visibly. Pane text alone is never enough. |
| `github terminate` | — | `workflows/github/terminate.md` | Summarizes GitHub entries partitioned by `domain.github_issue`; mixed sessions also include generic and Linear summaries. |

### Planning (cross-call to `project-management`, Linear issue mode only)

| Command | Workflow | Notes |
|---------|----------|-------|
| `cycle-plan` | `⤵ .agents/skills/project-management/workflows/cycle-plan.md` | TPM-driven cycle planning |
| `audit-issues` | `⤵ .agents/skills/project-management/workflows/audit-issues.md` | Issue audit (project / project-order / issue [IDs] / --issues file) |
| `roadmap plan` / `create` | `⤵ .agents/skills/project-management/workflows/roadmap-plan.md` / `roadmap-create.md` | Roadmap planning + execution |
| `research-spike` | `⤵ .agents/skills/project-management/workflows/research-spike.md` | Initiate a research issue with assets |
| `research-complete` | `⤵ .agents/skills/project-management/workflows/research-complete.md` | Route a completed research issue |

## Skill Rules

Decision rules grouped by domain. Each pattern doc under `patterns/` has the full context, examples, and edge cases — the bullets below are the quick-reference rules. Read the matching pattern doc whenever its prompt class appears.

### Tmux monitoring (`patterns/tmux-monitoring.md`)

- **Pane-0 rule**: every read targets `<session>:<window>.<idx>` explicitly (enforced by `pane-poll`). Default-pane captures break when sub-agents spawn additional panes. Index is pinned per window at registry init via fingerprinting.
- **Bell clearing** after sending input — atomic chained idiom (no flicker, enforced by `pane-respond` / `pane-clear-bell`):
  ```
  tmux select-window -t <session>:<window> \; select-window -t <ORIG>
  ```
- **Capture-pane scrollback**: `-S -200` for classification (enough for prompt + options, not the whole buffer).

### Prompt handlers (`patterns/prompt-handlers.md`)

- **Cleanup scope** — answer YES iff the target path equals the asking pane's registered worktree. NEVER for sibling worktrees (parallel sessions still using them). Extract the path from the prompt text and compare to the registry entry. Some agents propose batch cleanup; that's wrong.
- **Combine guidance with the option pick** — when picking an option triggers immediate sub-agent delegation (rebase, fix), the sub-agent guidance must ride in the SAME input. `pane-respond` rejects rebase-multi-choice payloads missing the preserve/apply/verify triplet.
- **Bot-review prompt response** — on a Skip/Wait/Abort prompt, decide from `gh pr view <PR> --json statusCheckRollup,reviewDecision,labels`. Skip if the bot check is `SUCCESS` and `reviewDecision == APPROVED` (or unset with no pending reviewers). Real pending reviewer → escalate. Master never re-invokes `bot-review-wait` itself.
- **GitHub merge-now gate** — before answering Merge in GitHub mode, run `gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup`. Auto-Merge only when `mergeStateStatus === "CLEAN"`, review is approved (or no pending reviewers), and every required check is `SUCCESS` or `SKIPPED`. `UNKNOWN`, `BEHIND`, `DIRTY`, `BLOCKED`, `HAS_HOOKS`, missing fields, and `FLIGHTDECK_AUTO_MERGE=0` all escalate or route to the documented UNKNOWN/auto-rebase path; never merge from pane text alone. `FLIGHTDECK_AUTO_MERGE=0` also blocks force-merge confirmation and UNKNOWN-timer transitions to force-merge.
- **Rebase-multi-choice guidance** — payload must follow the **preserve / apply / verify** triplet:
  - **Preserve**: function signatures / parameter splits / new wrappers from the upstream merge that must NOT be reverted.
  - **Apply**: field renames / type updates / local refactors that go ON TOP of the preserved shape.
  - **Verify**: the exact test invocation proving both sides intact.
- **Parent vs related** (audit prompts) — accept `child of <current-PR-issue>` when scopes don't intersect another live worktree's PR files (expansion bias). Reject → use `related` or pick a different parent. Capture each new issue's proposed parent/project/scope at decision time for the end-of-session report.
- **Verify-don't-trust** — never advance an issue's state on an agent's claim alone. After any structural change (rebase done, conflicts resolved, fields renamed), run a verification grep against the worktree. For rebases: check function signatures and rename counts in every conflict file.

### Conflict detection (`patterns/conflict-detection.md`)

- **`defer-ci`** label blocks heavy CI lanes (Lint, Cross-Platform, Linux Integration, Bench, Fixture Sync) but NOT bot reviews. Bot review runs with `defer-ci`; CI runs after the label drops.
- **File-level conflict graph** — build edges from `gh pr view <N> --json files`. Two PRs with file-set intersection conflict; merge order is topological + smallest-scope-first.
- **UNKNOWN-state timer** — GitHub's `mergeStateStatus` stays `UNKNOWN` for minutes after upstream `main` moves. Force-merge predicate: `APPROVED ∧ all_checks_in {SUCCESS, SKIPPED} ∧ disjoint(PR_files, main_files_recently_changed) ∧ unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS ∧ FLIGHTDECK_AUTO_MERGE != 0`.
- **GitHub issue close** — `github close-issue` requires `domain.github_issue.pr_number` plus authoritative `gh pr view <PR> --json state,mergeStateStatus,mergeCommit` with `state === "MERGED"` and non-null `mergeCommit` before `gh issue close`. If `state === "MERGED"` but `mergeCommit` is null, pause with `reason="gh-pr-merge-commit-missing"`. If `gh issue view <N> --json state` says already `CLOSED`, no-op and log; pane-buffer `MERGED` text is never sufficient.

### Decision biases (`patterns/decision-biases.md`)

- **Scope-creep detector** — `scope_files_actual` (from `gh pr view --json files`) vs `scope_files_declared` (parsed from issue description). `actual > 2× declared` → escalate. Don't auto-revert.
- **Smaller-PR-first** — when two PRs overlap, the smaller one merges first; the bigger absorbs the rebase. Reverse order forces the smaller PR to rebase against a bigger restructure.
- **Rule of three** — don't extract a shared helper across <3 sibling files. At 2 sites the abstraction shape isn't visible; at 3 the rule is satisfied.
- **Expansion bias** — prefer inline fixes in the current PR over new issues, UNLESS the reason is concrete (different scope, different agent, requires measurement, blocked dep, architectural decision). "Tidiness" is not a reason.
- **Merge-order tiebreakers**: (1) smallest scope first, (2) overlapping files: smaller first, (3) else: any order.

### Structured questions (`patterns/opencode-questions.md`, `patterns/pi-questions.md`)

- **Never pass off-list labels.** Pick `--answer` / `--answer-multi` values from `question.questions[i].options[].label`. Pi `--answer-text` only when the matching tab has `allowCustom=true`; opencode free-form requires `--reject` + a follow-up `opencode run --attach --session <SID> "<text>"`.
- **Pi inner agent completions** are advisory. Re-poll the outer orchestrator only; never call `subagent`/`steer_subagent`/`get_subagent_result` against an orchestrator's inner panes.

### Rate-limit recovery (`lib/flightdeck-core/src/daemon/rate-limit-watchdog.ts`)

- **Do not escalate rate-limited panes as "stuck".** When a tracked Pi pane (master or child) emits an assistant `message_end` with `role: "assistant"`, `stopReason: "error"`, and canonical rate-limit prose in the assistant envelope (`errorMessage` or `content[].text`: `temporarily limiting requests`, `Rate limited`, `429`, `too many requests`), the daemon's Pi subscriber routes the event through the rate-limit watchdog instead of the normal wake path. User/toolResult messages, missing stop reasons, and prose outside the assistant envelope are ignored. The watchdog suppresses the `needs_completion` synthetic outbox that the agent-end-watchdog would otherwise fire and schedules a `pi-bridge steer "API rate limit was detected. Try to continue from where you left off."` at the computed retry time.
- **Backoff ladder** — default `60s, 120s, 300s, 600s, 1800s`, max `5` attempts per pane. An Anthropic-provided `retry_after_ms` wins over the env ladder. After exhaustion the watchdog stops retrying and the pane falls through to the normal `needs_completion` path. Env tuning: `VSTACK_RATE_LIMIT_WATCHDOG=0` disables; `VSTACK_RATE_LIMIT_MAX_ATTEMPTS` overrides the attempt cap; `VSTACK_RATE_LIMIT_BACKOFF_LADDER` overrides the ladder.
- **Classifier + activity signals** — the Pi wake-event classifier tags rate-limit decisions as `pi-rate-limit-retry` (scheduled) and `pi-rate-limit-exhausted` (ladder spent). Subagent panes additionally publish `subagents:rate_limited`, `subagents:rate_limit_retry`, `subagents:rate_limit_resolved`, and `subagents:rate_limit_exhausted` through the Pi activity broker, which the daemon mirrors into the activity sidecar. Treat these as advisory; do not pause master or prompt the user unless the exhausted tag fires.
- **Layer A vs B** — subagent panes (`pi-agents-tmux`) carry their own vendored watchdog; flightdeck-managed tracked panes are covered by the daemon’s Pi subscriber wake branch. Both consume the same pure decision module (parity-tested), so the contract above applies regardless of which layer owns the pane.

## Scripts

```bash
.agents/skills/flightdeck/scripts/<script> [args]
```

**Implementation:** Most scripts are TypeScript under
`skills/flightdeck/lib/flightdeck-core/`. Trampolines under `scripts/`
exec `bun .../src/bin/<script>.ts`; `flightdeck-dashboard` is the Rust dashboard trampoline under `lib/flightdeck-dashboard/`. `bun` remains a hard runtime dependency for the TypeScript scripts.
Functional + integration tests live under `lib/flightdeck-core/tests/`.

| Script | Purpose |
|--------|---------|
| `open-terminal` | Spawn issue worktree(s) with selected harness + optional `--model`/`--effort`. **Never hand-roll issue tmux/terminal commands — use this for issue workflow spawns.** Linear is default; `--tracker github` accepts numeric issues, creates branch `issue-<N>`, fetches `gh issue view`, and emits a self-contained child prompt (no supervisor slash-command recursion). Tmux fallback delegates to `flightdeck-session` in issue mode. |
| `flightdeck-session` | Generic session launcher/attacher. `start` creates a tmux window and registers `.entries[id]`; `attach` records an existing Pi pane by stable pane id. |
| `parallel-groups` | Read/manage parallel issue groups. |
| `flightdeck-state` | Atomic CRUD on `tmp/flightdeck-state-<TMUX_SESSION>.json` (`init`/`get`/`set`/`append`/`increment`/`tracked-entries`/`write-entry`/`archive`), activity JSONL sidecar commands (`activity path\|append\|tail\|export`), and master-busy lock (`master-busy lock\|unlock\|check`). See `workflows/shared/session-watch.md` § 1 for lock semantics. |
| `flightdeck-daemon` | External wake driver. Polls inner panes, normalizes turn-end events, wakes master with a per-harness payload. Actions: `start \| stop \| status \| health \| events \| ack`. `start` exits `4` for stale `--master` (distinct from usage/missing dependency exit `2`). Master respawn trigger: `status --session <S>` says `no daemon` while live entries exist; source panes via `pane-registry list --format inner-panes-live` / `inner-harnesses-live`, re-resolve `$TMUX_PANE` and retry once on exit `4`, and do not yield on unresolved start failure. Full contract: `workflows/shared/session-watch.md` § 1 / § 6; adapter freshness: `patterns/tmux-monitoring.md`. |
| `flightdeck-dashboard` | Rust TUI dashboard binary. Subcommands: `tui`, `daemon {start,stop,status,health,tail}`, `launch`, `supervise`. The TUI has keyboard/mouse navigation, help/theme/filter/detail/confirm popups, dashboard badge/chip legend, cost/token totals, and two confirmation-gated writes that shell to canonical helpers (`pane-registry remove` for stale entries, `tmux select-window` for focus). Lives in `skills/flightdeck/lib/flightdeck-dashboard/`. See `DEVELOPMENT.md` for the build + test workflow. |
| `codex-app-server-spawn` / `-stop` | Idempotent bring-up/teardown of the per-session codex `app-server --listen ws://...` shared by all `codex --remote` panes. |
| `pane-registry` | TrackedEntry↔pane mapping CRUD. `init-entry` writes `.entries[id]`; `init <ISSUE>` is an alias for `init-entry --kind issue`. `find-by-pane` emits `{id,kind}` JSON. `list --format json\|inner-panes\|inner-harnesses\|inner-panes-live\|inner-harnesses-live` feeds `pane-poll --batch -` and `flightdeck-daemon start`; use the `*-live` pair for daemon respawn. |
| `pane-poll` | Pane state read. Preferred: `--batch -` from `pane-registry list --format json` (one JSONL object per tracked entry). Passes `kind` to `prompt-classify` so issue-only tags on ad-hoc entries become `domain-mismatch`. Legacy single-pane mode for drift re-polls / manual debug. See `patterns/tmux-monitoring.md` for per-harness adapter routes. |
| `pane-respond` | Send response to a pane. Modes: free-text payload, `--option N`, `--option-multi`, `--keys` (rejected without `--keys-allow-tmux`), `--question <reqID> --answer\|--answer-multi\|--answer-text\|--answers-json\|--reject`. Validates rebase-multi-choice payloads for the preserve/apply/verify triplet. See `patterns/prompt-handlers.md` for mode selection and `patterns/opencode-questions.md` / `patterns/pi-questions.md` for question routing. |
| `pane-clear-bell` | Atomic chained-command bell clear (no flicker). |
| `pr-conflict-graph` | File-intersection adjacency for a list of PR numbers via `gh pr view --json files`. |
| `label-add` / `label-remove` (in `skills/github/scripts/commands/`) | Add/remove GitHub labels via `gh pr edit` / `gh issue edit`. Emit `pr.labeled` / `pr.unlabeled` / `issue.labeled` / `issue.unlabeled` activity rows when `FLIGHTDECK_MANAGED=1`; silent otherwise. Wrapped by the `github` skill — flightdeck issue workflows call them indirectly. |
| `prompt-classify` | Regex/sentinel + computed-tag matcher mapping pane state to a handler tag: `rendering`, `terminal-state-reached`, `bash-permission-prompt`, `force-merge-confirm`, `merge-ready-but-unknown`, `merge-now`, `bot-review-wait-stuck`, `rebase-multi-choice`, `force-push-prompt`, `cleanup-prompt`, `audit-relation-prompt`, `descope-related`, `external-fix-suggestions`, `cycle-fix-suggestions`, `scope-creep-detected` [computed], `multi-select-tabbed`, `awaiting-direction`, `generic-multi-choice`, `domain-mismatch`, `idle`. `--entry-kind` guards issue-only tags on non-issue entries; omitted kind and `--entry-kind-unknown` fail closed as `domain-mismatch`. Daemon/event-only tags: `oc-question`, `pi-question`, `pi-subagent-completion`, `pi-bg-task-exit`, `pi-activity-broker`, `pi-rate-limit-retry`, `pi-rate-limit-exhausted`, `daemon-exited`. |

`pi-bg-task-exit` (vstack#15): the Pi subscriber matches `pi-bridge stream` events of shape `{ type: "event", event: "message_end", data.message.customType: "vstack-background-tasks:event", data.message.details.eventType: "exit" }` and appends a canonical wake row to `WAKE_EVENTS_LOG`:

```
{"ts":"<iso>","pane_id":"%18","harness":"pi","event_type":"bg-task-exit","sequence":17,"task":{"id":"bg-3","status":"failed","exitCode":null,"command":"...","outputBytes":89},"classifier_tag":"pi-bg-task-exit","hash":"<12hex>"}
```

The daemon (`lib/flightdeck-core/src/daemon/loop.ts`) treats the tag as canonical, appends to the per-session events file via `appendEvent`, extends `WAKE_PENDING.in_flight`, and wakes master before emitting structured activity. Non-exit bg-task subscriber signals (for example `details.eventType: "output"`) append activity-only `pi-bg-task-activity` rows with `activity_event_type` and `sequence`; the daemon records them as `bg_task.output_matched` activity without waking master. Master routes terminal rows through `workflows/shared/session-watch.md` § 2 → `workflows/shared/session-handle-prompt.md` § 7; issue mode may then resume `workflows/linear/handle-prompt.md` § 4 for PR/CI/bot-review recovery. The classifier never sees these messages — they are system-role customType messages, not assistant text — so `prompt-classify` has no matching tag and only the daemon path produces them.

`pi-activity-broker`: Pi extensions publish through `globalThis[Symbol.for("vstack.pi.activity")]`; `pi-session-bridge` streams each publication as `{type:"event", event:"vstack_activity", data:{...}}`. The Pi subscriber appends an activity-only `pi-activity-broker` row to `WAKE_EVENTS_LOG`. The TS daemon copies the subset payload into `flightdeck-activity-<session>.jsonl` with the tracked pane id and never wakes master. Set `FLIGHTDECK_PI_ACTIVITY_BROKER=0` to disable this broker drain and rely on legacy custom-message wake paths only.

Activity sidecar: `flightdeck-state init` records `activity_path` beside the master state as `flightdeck-activity-<TMUX_SESSION>.jsonl`. `flightdeck-state activity path|append|tail|export` exposes the path, appends a normalized event, tails recent rows, or exports JSONL/Markdown. `activity export` accepts `--session <name>` and `--state-file <path>` for parity with `path` / `tail` / `append`, so dashboards and post-mortems can resolve sidecars without an active tmux session. Retention caps are 5,000 events and 10 MiB per live sidecar; oversized `details` are truncated to a 16 KiB budget. Daemon emission is curated: daemon/subscriber lifecycle, wake-delivery failures, subagent completions, bg-task exit/output rows, questions, and Pi broker rows. Workflow/github/linear helper emission is gated by `FLIGHTDECK_MANAGED=1 || FLIGHTDECK_ACTIVITY_FILE` so standalone wrapper use stays silent.

`daemon-exited`: the daemon emits this lifecycle row during cleanup when it exits for `master-gone`, `signal-term`, `signal-int`, or another recorded reason. It writes directly to the per-session `EVENTS_FILE` under `SESSION_LOCK` (not `WAKE_EVENTS_LOG`), with `pane_id` set to the master pane id so pane-keyed drains include it:

```
{"ts":"<iso>","pane_id":"%25","event_type":"daemon-exited","reason":"master-gone","master_id":"%25","pid":12345,"hash":"<12hex>","tag":"daemon-exited","stable_age_sec":0,"details":{"event_type":"daemon-exited","reason":"master-gone","master_id":"%25","pid":12345}}
```

`session-watch.md` routes `daemon-exited` as a daemon-lifecycle signal, not a pane-prompt classification. It records the reason and follows the master respawn flow in `workflows/shared/session-watch.md` § 1 / § 6 before yielding.

## Schema — master state

Master state lives at `<project-root>/<FLIGHTDECK_STATE_DIR>/flightdeck-state-<TMUX_SESSION_NAME>.json` (default `tmp/`). Activity history lives beside it as `flightdeck-activity-<TMUX_SESSION_NAME>.jsonl` and is exposed through `flightdeck-state activity path|append|tail|export`. Both survive compaction; terminate rotates state to `*-<terminated_at>.json.archive` and activity to `*-<terminated_at>.jsonl.archive` in the same `flightdeck-state archive` flow (see `terminate.md § 6`). The archive preserves the full session history (including merged-issue `decisions_log`, `pr_number`, `merge_commit`) so post-completion dashboards and post-mortem inspection have the whole session history — do not call `pane-registry remove-merged` between `set terminated true` and `archive`. Dashboard snapshot loaders fall back to the newest matching `*.json.archive` when the live file is gone, so the completed-session view keeps rendering until a new `flightdeck start` rewrites the live file. Daemon-private files in `FD_STATE_DIR` are keyed by `SESSION_KEY=s<N>` instead (see `patterns/tmux-monitoring.md`).

Auto-archive on session start: `flightdeck-session start` rolls the live file to a `.json.archive` sibling before fresh init when (a) `terminated == true` or (b) the file has tracked entries but ZERO `pane_id` is currently alive in tmux. Removes the need to manually prune leftover state from prior tmux sessions or crashed masters. `flightdeck-session start` also exports `FLIGHTDECK_ENTRY_ID` into the launched child environment (consumed by `github.sh` / `linear.sh` wrappers to auto-bind activity events to the right entry) and captures the current `git rev-parse --abbrev-ref HEAD` of the entry's cwd into `entry.branch` (informational; not refreshed when the agent switches branches mid-session) and onto every `pr.*` activity row's `refs.branch`.

Readers call `readTrackedEntries(state)` to get the canonical `TrackedEntry` map. Malformed non-object entry values are skipped with a stderr warning; malformed internal `entry.id` values warn and fall back to the map key. `writeTrackedEntry(state, id, entry)` validates non-empty ids (including `entry.domain.issue.id` when present), accepts the optional `entry.domain.github_issue` shape, rejects unknown `entry.domain.*` sub-keys, rejects entries that set both `domain.issue` and `domain.github_issue`, and writes `.entries[id]`. Linear issue-mode metadata lives under `entry.domain.issue` (`pr_number`, `worktree`, `merge_commit`, etc.). GitHub issue-mode metadata lives under `entry.domain.github_issue` (`number`, `url`, `worktree`, `pr_number`, `merge_commit`, `scope_files_actual`). Generic `adhoc`/`workflow` rows may also carry top-level `pr_number` and `worktree` for traceability without becoming issue-mode entries; readers must keep those separate from issue-domain routing. Dashboard renderers surface the nested issue views and generic top-level traceability fields without changing issue-domain routing.

```json
{
  "session_id": "<TMUX_SESSION_NAME>",
  "started_at": "<ISO8601>",
  "activity_path": "<project-root>/tmp/flightdeck-activity-<TMUX_SESSION_NAME>.jsonl",
  "activity_archive_path": null,
  "activity_schema_version": 1,
  "terminated": false,
  "owner": {
    "harness": "claude|opencode|codex|pi|unknown",
    "pane_id": "%25",
    "pane_target": "<TMUX_SESSION>:<window>.<pane>",
    "cwd": "<absolute cwd>",
    "pid": 1752875,
    "pi_session_id": "<pi-session-id-or-null>",
    "pi_bridge_socket": "<pi-bridge-socket-or-null>",
    "discovery_error": "<warning-or-null>"
  },
  "entries": {
    "<ENTRY_ID>": {
      "id": "<ENTRY_ID>",
      "title": "<human label>",
      "kind": "adhoc|issue|workflow",
      "state": "waiting|prompting|submitting|ready|complete|cancelled|dead",
      "substate": null,
      "harness": "claude|opencode|codex|pi|unknown",
      "cwd": "<absolute cwd>",
      "window": "<window-name-or-index>",
      "pane_target": "<TMUX_SESSION>:<window>.<pane>",
      "pane_id": "%403",
      "pr_number": null,
      "worktree": null,
      "launch": {
        "model": "<resolved-model-or-null>",
        "effort": "<resolved-effort-or-thinking-or-null>",
        "requested_model": "<explicit-or-env-model-or-null>",
        "requested_effort": "<explicit-or-env-effort-or-null>",
        "resolved_model": "<resolved-model-or-null>",
        "resolved_effort": "<resolved-effort-or-thinking-or-null>",
        "model_source": "explicit|env|auto|null",
        "effort_source": "explicit|env|auto|null",
        "argv": ["<resolved>", "<harness>", "argv>"],
        "reasoning_status": "configured|recorded|unsupported|not-applicable",
        "unsupported_reason": "<reason-or-null>",
        "cmd": "<command-or-null>"
      },
      "adapter": {
        "pi_bridge_pid": 0, "pi_bridge_socket": "<path-or-null>", "pi_session_id": "<id-or-null>",
        "oc_url": "<server-url-or-null>", "oc_session_id": "<id-or-null>",
        "cc_url": "<server-url-or-null>", "cc_transcript": "<path-or-null>",
        "cx_ws": "<ws-url-or-null>", "cx_thread_id": "<id-or-null>"
      },
      "domain": {
        "issue": {
          "id": "<ISSUE_ID>",
          "worktree": "<absolute path>",
          "pr_number": 0,
          "scope_files_declared": 5,
          "scope_files_actual": 27,
          "orchestration_started": true
        },
        "github_issue": {
          "number": 120,
          "url": "https://github.com/OWNER/REPO/issues/120",
          "worktree": "<absolute path>",
          "pr_number": 0,
          "merge_commit": null,
          "scope_files_actual": 27
        }
      },
      "branch": "<git-branch-or-null>",
      "last_capture_hash": "sha256:...",
      "last_response_at": "<ISO8601>",
      "spawned_at": "<ISO8601>",
      "last_polled_at": "<ISO8601>",
      "decisions_log": []
    }
  },
  "merge_queue": ["<ISSUE_ID>", "<ISSUE_ID>"],
  "conflict_graph": {
    "edges": [["<ISSUE_A>", "<ISSUE_B>"]],
    "computed_at": "<ISO8601>"
  },
  "paused_for_user": null
}
```

Tracked entry state enum: `state ∈ {waiting, prompting, submitting, ready, complete, cancelled, dead}`. Issue-mode workflows additionally use `{merge-ready, merged, aborted}` for issue-specific lifecycle states; these map onto the generic enum via `domain.issue.phase` / `domain.issue.outcome` for Linear or `domain.github_issue.phase` / `domain.github_issue.outcome` for GitHub (e.g. `merged → complete + outcome="merged"`). `entryIdForIssue(issueId)` returns the issue id unchanged after validation (empty/invalid ids return null); `issueIdForEntry(entry)` reads `entry.domain.issue.id` or, for `kind: "issue"`, `entry.id`. GitHub entries use numeric `domain.github_issue.number` for lane-specific routing. `owner` is metadata written by `flightdeck-state init`; `owner.pid` is the owner harness PID supplied by `FLIGHTDECK_OWNER_PID` (falling back to parent PID), and `owner.discovery_error` records Pi bridge metadata lookup failures when the owner harness is Pi. Dashboard renderers use `owner.pane_id` to keep the persistent dashboard owner-scoped by default. `paused_for_user` carries `{entry_id|issue_id, reason, prompt_text}` when a guard or issue-mode pause fires.

## Reliability watchdogs

Four operator-facing watchdogs run inside the daemon and the `pi-agents-tmux` extension. Agents do not interact with them; they emit activity rows and synthetic outbox payloads when child sessions misbehave.

- **agent-end** (`VSTACK_AGENT_END_WATCHDOG`, default on; grace `VSTACK_AGENT_END_WATCHDOG_GRACE_SEC`=10s) — if a child agent emits `agent_end` without writing a `complete_subagent` outbox within the grace window, the watchdog synthesizes a `needs_completion` outbox so the parent never silently stalls. Emits `agent.needs_completion` activity.
- **idle-stall** (`VSTACK_STALL_WATCHDOG`, default on; `VSTACK_STALL_WATCHDOG_INTERVAL_SEC`=60s, `VSTACK_STALL_WATCHDOG_THRESHOLD_SEC`=300s) — polls bridge-idle subagent panes whose outbox has not landed and fires a synthetic `blocked` outbox after the threshold. Emits `agent.idle_stalled`.
- **edit-loop** (`VSTACK_EDIT_LOOP_DETECTOR`, default on; `VSTACK_EDIT_LOOP_THRESHOLD_N`=5, `VSTACK_EDIT_LOOP_WINDOW_SEC`=120) — counts edit-tool failures inside a child agent's window; on threshold breach synthesizes a `blocked` outbox + `agent.edit_loop_blocked` activity row.
- **rate-limit** (`VSTACK_RATE_LIMIT_WATCHDOG`, default on; `VSTACK_RATE_LIMIT_MAX_ATTEMPTS`=5, `VSTACK_RATE_LIMIT_BACKOFF_LADDER`=`60,120,300,600,1800` seconds) — on a detected Claude API rate-limit error, schedules an exponential-backoff steer-retry. Emits `agent.rate_limit_detected` / `agent.rate_limit_retry` / `agent.rate_limit_exhausted` and short-circuits the canonical wake path while a retry is pending.

All four can be hard-disabled by setting the gate env var to `0`. The canonical decision modules and parity rules live in `DEVELOPMENT.md`.

## Configuration

Master-loop env vars consulted by workflows:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` | `240` | UNKNOWN-state wait threshold before considering force-merge (predicate also requires APPROVED + green + disjoint) |
| `FLIGHTDECK_STATE_DIR` | `tmp` | Project-relative master-state file directory |
| `FLIGHTDECK_ACTIVITY_FILE` | unset | Explicit activity JSONL target for wrapper/workflow emitters and `flightdeck-state activity append`; when unset, managed workflows use `activity_path` from master state. |
| `FLIGHTDECK_DEBOUNCE_CYCLES` | `2` | Consecutive poll cycles required for "all-done" termination check |
| `FLIGHTDECK_AUTO_MERGE` | `1` | When `0`, merge-now, force-merge-confirm, and UNKNOWN-timer force-merge transitions escalate instead of auto-answering. For sessions where the human gate is desired (compliance, big-blast-radius PRs) |
| `FLIGHTDECK_AUTO_REBASE` | `0` | GitHub lane only: when `1`, a `BEHIND` PR prompt may answer Update Branch / auto-rebase if all other safety predicates hold. Default `0` escalates. |
| `FLIGHTDECK_HIJACK_GRACE_SECS` | `90` | Seconds after spawn that master tolerates no orchestration `workflow-state-<ISSUE>.json` before escalating "orchestration-never-started". Catches hijacked panes / failed launches. |
| `FLIGHTDECK_LAUNCH_MODEL` | unset | Default `open-terminal` / `flightdeck-session --prompt` model override when the workflow/user does not pass `--model`. |
| `FLIGHTDECK_LAUNCH_EFFORT` | unset | Default `open-terminal` / `flightdeck-session --prompt` effort/thinking override when the workflow/user does not pass `--effort`. |
| `FLIGHTDECK_OPENCODE_VALIDATE_MODEL` | `1` | When launching OpenCode, require `opencode models` to list the selected provider/model before passing `--model`. Set `0` only for local smoke tests with custom shims. |
| `FLIGHTDECK_PI_ACTIVITY_BROKER` | `1` | Set to `0` to ignore `pi-session-bridge` `vstack_activity` broker rows and rely on legacy Pi wake messages only. |
| `FLIGHTDECK_ENTRY_ID` | auto | Exported by `flightdeck-session start` into spawned panes (and inherited by their tool wrappers). When set, `github.sh` / `linear.sh` / `label-*` activity rows auto-bind `refs.entry_id` so cross-source activity ties back to the tracked entry. Do not set by hand. |

Watchdog gates (operator-facing; see § Reliability watchdogs for behavior):

| Variable | Default | Purpose |
|----------|---------|---------|
| `VSTACK_AGENT_END_WATCHDOG` | `1` | Toggle for the agent-end watchdog. |
| `VSTACK_AGENT_END_WATCHDOG_GRACE_SEC` | `10` | Grace seconds before synthesizing a `needs_completion` outbox. |
| `VSTACK_STALL_WATCHDOG` | `1` | Toggle for the idle-stall watchdog. |
| `VSTACK_STALL_WATCHDOG_INTERVAL_SEC` | `60` | Poll cadence for idle-stall detection. |
| `VSTACK_STALL_WATCHDOG_THRESHOLD_SEC` | `300` | Bridge-idle threshold before synthesizing a `blocked` outbox. |
| `VSTACK_EDIT_LOOP_DETECTOR` | `1` | Toggle for the edit-loop detector. |
| `VSTACK_EDIT_LOOP_THRESHOLD_N` | `5` | Edit-tool failure count within the window that trips the detector. |
| `VSTACK_EDIT_LOOP_WINDOW_SEC` | `120` | Sliding window for edit-loop counting. |
| `VSTACK_RATE_LIMIT_WATCHDOG` | `1` | Toggle for the rate-limit retry watchdog. |
| `VSTACK_RATE_LIMIT_MAX_ATTEMPTS` | `5` | Maximum retry attempts before surfacing `agent.rate_limit_exhausted`. |
| `VSTACK_RATE_LIMIT_BACKOFF_LADDER` | `60,120,300,600,1800` | Comma-separated seconds per attempt; clamped to `MAX_ATTEMPTS`. |

Daemon hygiene env vars (operator-facing; details in `DEVELOPMENT.md`):

| Variable | Default | Purpose |
|----------|---------|---------|
| `FD_BELL_WAKE_INTERVAL_SEC` | `60` | Per-pane-per-tag bell-wake rate-limit; suppresses storm-y duplicates within the window. |
| `FD_RECONCILE_INTERVAL_SEC` | `5` | Mid-session reconcile cadence: spawn subscribers for newly tracked panes, reap subscribers for departed panes, drop dead `.entries` rows. |
| `FD_HEARTBEAT_OWNER_CGROUP` | `1` | Set to `0` to skip the optional `MemoryCurrent` / `MemoryPeak` cgroup probe attached to heartbeat events. |


Rust dashboard env vars:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FLIGHTDECK_DASHBOARD` | `1` | When `0`, `flightdeck-dashboard launch` exits `0` silently. |
| `FLIGHTDECK_DASHBOARD_WINDOW` | `flightdeck` | Tmux window name used by the dashboard launch hook. |
| `FLIGHTDECK_DASHBOARD_MOTION` | `full` | Animation intensity: `full`, `reduced`, or `off`. `NO_MOTION` / `NO_COLOR` force `off` regardless of this setting. CLI `--motion` overrides it. |
| `FLIGHTDECK_DASHBOARD_THEME` | `moon` | Color theme: `moon`, `dawn`, `pantera`, or `system`. CLI `--theme` overrides it; the theme picker popup changes the live theme for the current run. |
| `FLIGHTDECK_DAEMON_RUST` | `0` | Opt-in to the Rust daemon wake side / subscriber absorption. Default off keeps the canonical TypeScript daemon in charge of wake delivery. |
| `FLIGHTDECK_DASHBOARD_BELL` | `1` | Set to `0` to suppress the terminal bell on a new pause-for-user edge. The dashboard never auto-focuses tmux windows. |
| `FLIGHTDECK_DASHBOARD_COST_POLL_SECS` | `5` | Cost-source poll interval in seconds. |
| `FLIGHTDECK_DASHBOARD_PRICING_FILE` | bundled table | Optional pricing TOML override for dashboard cost calculations; malformed files warn and fall back to bundled rates. |
| `FLIGHTDECK_DASHBOARD_QUICK_FOCUS` | `0` | Set to `1` to let `g` focus the selected tmux window without a confirmation popup. |
| `TMUX_PROBE_TTL` | `5` | Cached `tmux list-panes` TTL used to mark stale dashboard rows. |
| `FLIGHTDECK_DASHBOARD_STALE_WARN_SECS` | `30` | Stale-chip warning threshold in seconds. |
| `FLIGHTDECK_DASHBOARD_STALE_DEAD_SECS` | `300` | Stale/dead chip threshold in seconds. |
| `FLIGHTDECK_DASHBOARD_STOP_GRACE_MS` | `5000` | Advanced daemon stop grace before SIGKILL escalation, in milliseconds. Tests may lower it. |
| `FLIGHTDECK_DASHBOARD_READY_FD` | internal | Readiness pipe fd used by detached daemon startup; not user-configurable. |
| `FLIGHTDECK_DASHBOARD_TEST_WEDGE_SIGNALS` | unset | Test-only hook that wedges signal handling. Do not set in normal sessions. |
| `FLIGHTDECK_DASHBOARD_TEST_SUBSCRIBE_PAUSE_FILE` | unset | Test-only socket subscribe interleaving hook. Do not set in normal sessions. |
| `FLIGHTDECK_DASHBOARD_TEST_SUBSCRIBE_RELEASE_FILE` | unset | Test-only release file for the subscribe interleaving hook. Do not set in normal sessions. |

Daemon tuning (`FD_*`) is in DEVELOPMENT.md. Most `FD_*` knobs run inside the
daemon and do not affect master operation directly, but two are
consulted on the master poll path through the TS `pane-poll`:
`FD_ADAPTER_READ_TIMEOUT_SEC` (default `2`, fractional values honored)
caps each adapter read subprocess so one stale adapter cannot dominate
a tick, and `FD_ADAPTER_FRESHNESS_TTL` (default `5`) gates freshness
probe caching.

Additional tuning:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FD_ADAPTER_READ_TIMEOUT_SEC` | `2` | Bounds per-adapter read subprocesses in `pane-poll` (fractional values honored). Stale adapters fall through to tmux capture rather than wedging the tick. |

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/linear/start.md` | `start` (from main) | From-main entry: dashboard, issue selection, research evaluation, parallel-check, spawn, enter watch |
| `workflows/linear/start-new.md` | `start new` | Create new issue from main + spawn |
| `workflows/linear/parallel-check.md` | `parallel-check` (also nested from `start.md` § 4) | Verify candidate issue set is safe to spawn in parallel |
| `workflows/shared/session-watch.md` | `session watch`, and core loop invoked by issue `watch` | Generic state init, entry reconciliation, daemon spawn/ack/yield, polling, generic prompt routing, compaction recovery |
| `workflows/shared/session-handle-prompt.md` | Nested invocation from `session-watch` / issue `watch` for generic tags | Generic prompt response surface; no PR/Linear/GitHub/worktree dependency |
| `workflows/linear/watch.md` | `watch` (issue entry) or invoked at end of `start.md` after spawn | Issue-mode extension over `session-watch`: load issue skills, track issue-specific lifecycle states, route issue-only handlers, plan merges, terminate |
| `workflows/linear/handle-prompt.md` | Nested invocation from issue `watch` for issue-only tags | PR/Linear/worktree prompt response surface only |
| `workflows/linear/close-issue.md` | Nested invocation from `watch` § 2 on `terminal-state-reached` | Verify two-signal terminal state, update master state, kill window, keep registry entry for terminate reporting/final cleanup |
| `workflows/linear/merge-plan.md` | Nested invocation from `watch` § 4 | Conflict-graph build + smallest-first merge ordering |
| `workflows/linear/terminate.md` | Nested invocation from issue `watch` or generic session unwind | Generic session summary for ad-hoc/workflow entries; issue/PR/new-issues recommendation summary when any issue entry exists; master-state finalization |
| `workflows/github/start.md` | `github start <N>` | Fetch GitHub issue context, compose self-contained child prompt, spawn branch `issue-<N>` with `open-terminal --tracker github`, register `domain.github_issue`, enter watch |
| `workflows/github/start-new.md` | `github start new` | Create a GitHub issue, then launch it through `github/start.md` |
| `workflows/github/watch.md` | `github watch` | GitHub issue extension over `session-watch`: PR/CI/review routing, UNKNOWN timer, gh failure escalation, termination debounce |
| `workflows/github/handle-prompt.md` | Nested invocation from GitHub `watch` for GitHub tags | GitHub PR prompt response surface: merge gate, UNKNOWN/force-merge, bot review, rebase, force-push, cleanup |
| `workflows/github/close-issue.md` | Nested invocation from GitHub `watch` on `terminal-state-reached` | Requires recorded PR + authoritative merged PR/merge commit before issue close/no-op and teardown |
| `workflows/github/terminate.md` | Nested invocation from GitHub `watch` or mixed unwind | Partitions by `domain.github_issue`, emits GitHub summary, coexists with generic and Linear summaries |

## Workflow Execution

These rules apply to flightdeck's boundary workflows (`start.md`, `start-new.md`, `terminate.md`, `close-issue.md`, and per-tag handlers in `session-handle-prompt.md` / `handle-prompt.md`). The `session-watch.md` generic loop and `watch.md` issue extension are reactive by nature — their inner decisions are judgment calls and not subject to these rules.

### Sequential Section Execution

Process sections sequentially. Execute all sub-sections within a section before proceeding to the next. Never skip steps because the outcome seems predictable, or rationalize skipping based on visible state ("nothing changed since last poll", "the summary is obvious", "the user can see this"). The workflow text is the decision authority, not the agent's assessment.

### Nested Workflow Invocation

Nested workflows (marked with `⤵`) must be invoked through the harness's workflow invocation mechanism — never inlined or substituted with ad-hoc commands. If the marker includes a return point (`→ § X`), record it before invoking.

### Format Tags Are Literal

`<output_format>`, `<recommendation_format>`, `<launch_now_format>`, and any other XML-tagged content blocks define exact content for emission. When emitting tagged content:

1. **Fill `[PLACEHOLDERS]`** with actual values.
2. **Omit lines/sections** where the placeholder value is empty or not applicable.
3. **Add nothing else** — no commentary, no extra fields, no rewording, no explanations before or after the content.
4. **Do not paraphrase** — use the exact structure, headings, and field names from the tag.

The user-visible output blocks at the end of `terminate.md` (`<generic_output_format>` / `<empty_output_format>` / `<issue_output_format>`) and `close-issue.md` (`<output_format>`) are tagged for this reason: the agent must emit them in full, not collapse to a summary line.

## Implementation Constraints

1. **Aggressive autonomy on known shapes; escalate on novel shapes.** The classifier returns a tag for known prompt shapes. Generic `generic-multi-choice` uses the bounded safe policy in `session-handle-prompt.md`; issue-only prompts use `handle-prompt.md`. Both escalate when options are destructive, ambiguous, or genuinely novel. They do NOT blindly pick the first option.
2. **Daemon-driven wake; no blocking sleeps.** `flightdeck-daemon` (spawned by `session-watch.md` § 1; issue `watch.md` reuses that core loop) owns wake delivery for every harness. Master ends each turn after `flightdeck-daemon ack` + `flightdeck-state master-busy unlock`. Never `sleep`. Wake payload reference: `/flightdeck` (claude/opencode/default), `$flightdeck` (codex), `/skill:flightdeck` (pi). Claude Code MAY optionally arm `ScheduleWakeup({delaySeconds: 1800})` as a defensive fallback.
3. **Dashboards are read-only and additive.** The Rust `flightdeck-dashboard` renders mission-control UX from the on-disk artifacts master and the daemon already write; it never bypasses the schema. The only write affordances are confirmation-gated shells to canonical helpers (`pane-registry remove` for stale entries, `tmux select-window` for focus). No harness-specific shortcut paths that bypass the on-disk schema in any other renderer.
4. **One daemon per tmux session.** Concurrent flightdecks within the same tmux session are refused via flock. Run separate sessions for parallel flightdeck instances.
5. **Explicit LLM launch profile.** Every fresh LLM pane Flightdeck creates must have a selected model and effort/thinking level, or an explicit `launch.reasoning_status`/`unsupported_reason` explaining why that harness/session cannot report it. Subagents with generated model/effort definitions are exempt.
6. **All scripts must appear in this SKILL.md's Scripts table.** No "hidden" scripts. README.md mirrors the table for human readers.

## Compaction Recovery

Master state is persisted on every state mutation and rehydrated on watch re-entry. Generic entry reconciliation and daemon recovery live in `workflows/shared/session-watch.md` § 6; issue-specific recovery (pane fingerprinting, `unknown_since`, conflict graph, and paused issue re-evaluation) lives in `workflows/linear/watch.md` § 8.
