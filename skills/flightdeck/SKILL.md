---
name: flightdeck
description: "Master session lifecycle for multi-issue parallel dev work: dashboard, spawn, oversee tmux panes, answer prompts, plan merges, drive every tracked issue to merged or aborted."
license: MIT
user-invocable: true
dependencies:
  required: [github, linear, project-management]
  optional: [decider, worktree]
metadata:
  author: vanillagreen
  version: "0.2.0"
---

# Flightdeck

> If you're modifying flightdeck scripts, the daemon, or `lib/flightdeck-core/` — read [`DEVELOPMENT.md`](./DEVELOPMENT.md) first. It has the TS port status, parity-test workflow, debugging entry points, and operational caveats.

## STOP — Required Setup

1. Verify `$TMUX` is set. If unset, **exit immediately with no-op**: print `Flightdeck requires tmux; skipping.` and return control to the caller. Flightdeck does nothing outside tmux.
2. Load `github`, `linear`, and `project-management` skills if not already loaded. Redundant loads are no-ops.

If a required skill cannot be loaded, stop and tell the user. Do not proceed without them.

---

## Mode

You are in **master mode**. Observe-and-direct only:

- **You do NOT** write code in worktrees, run builds/tests, or invoke per-issue orchestration workflows (`bot-review-wait`, `ci-wait`, `merge-pr`, etc.). Per-issue work happens inside the spawned panes; you supervise.
- **You DO** own the master arc end to end — dashboard → research/plan evaluation → spawn (`open-terminal`) → watch loop → merge planning → unwind — and answer prompts that surface from the spawned panes via `pane-respond`.
- **You communicate with spawned agents through their native channels**: opencode via HTTP `/session/<id>/message`, claude via Channels MCP push + JSONL tail, pi via Unix-socket bridge, codex via JSON-RPC over WebSocket. `pane-respond` routes into the matching send path. Tmux `capture-pane` / `send-keys` is only the fallback when the channel is unavailable (see `patterns/tmux-monitoring.md`).
- **You pause for the user only on**: scope creep that requires reverting agent work, force-merging against a real content conflict (not `UNKNOWN`), an issue abort, flightdeck mutating `main` directly when no orchestrator pane is alive, or a novel prompt shape no rule covers.
- **You do NOT re-implement orchestration gates**. When the orchestrator surfaces a prompt (merge-now, audit-relation, fix-suggestions), its upstream conditions are already checked. Answer the prompt; don't re-validate CI / mergeable / thread state. The only checks master adds are cross-session conflict graph and multi-pane scope drift — things only master sees.

## Commands

### Session management

Generic tmux-window session tracking. These commands do not require a fake issue id.

| Command | Arguments | Workflow / Script | Notes |
|---------|-----------|-------------------|-------|
| `session start` | `--session-id <ID> --title <T> --cwd <path> --harness <H> (--cmd <cmd> \| --prompt <text>) [--kind adhoc\|workflow]` | `scripts/flightdeck-session start` | Creates a new tmux window (never a split), launches the command/harness, sets `FLIGHTDECK_MANAGED=1` + `FLIGHTDECK_CHILD_PANE=1`, and records a generic `.entries[ID]` row. Pi `--prompt` launch starts `pi` directly and records bridge metadata when discovery succeeds. |
| `session attach` | `--pane <%PANE_ID> --harness pi --title <T> [--session-id <ID>] [--kind adhoc]` | `scripts/flightdeck-session attach` | Attaches an existing pane without launching a new window. For Pi, probes `pi-bridge` by pane pid and records `pi_session_id`/socket metadata when available. |
| `session watch` | `[ENTRY_ID...]` | Phase 3 pending | Generic watch split is not landed yet; current daemon/watch paths still share issue-mode prompt handling. |
| `session status` | — | inline / `flightdeck-state tracked-entries` | Read-only normalized `.entries`/legacy `.issues` snapshot. |
| `session stop` / `session remove` | `<ENTRY_ID>` | `pane-registry teardown-entry` / `pane-registry remove` | Teardown uses stable `pane_id`; issue remove remains the legacy cleanup path. Generic removal cleanup is still being expanded. |

### Issue workflows

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `start` | `[ISSUE_ID]` | `workflows/start.md` | From-main entry. Dashboard, issue selection, research evaluation, parallel-check, spawn (`open-terminal`), enter watch loop. |
| `start new` | `[title]` | `workflows/start-new.md` | Create new issue + spawn. |
| `start self` | — | inline | Initialize master session only, await further commands. |
| `parallel-check` | `[ISSUE_IDS]` | `workflows/parallel-check.md` | Verify a candidate set is safe to spawn in parallel. |
| `watch` | `[ISSUE_IDS]` | `workflows/watch.md` | Master oversight loop. Invoked at the end of `start.md` after spawn; can be re-entered manually after compaction. |
| `status` | — | inline | Print current pane registry + state machine snapshot from `tmp/flightdeck-state-<TMUX_SESSION>.json`. Read-only. |

### Planning (cross-call to `project-management`)

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
- **Rebase-multi-choice guidance** — payload must follow the **preserve / apply / verify** triplet:
  - **Preserve**: function signatures / parameter splits / new wrappers from the upstream merge that must NOT be reverted.
  - **Apply**: field renames / type updates / local refactors that go ON TOP of the preserved shape.
  - **Verify**: the exact test invocation proving both sides intact.
- **Parent vs related** (audit prompts) — accept `child of <current-PR-issue>` when scopes don't intersect another live worktree's PR files (expansion bias). Reject → use `related` or pick a different parent. Capture each new issue's proposed parent/project/scope at decision time for the end-of-session report.
- **Verify-don't-trust** — never advance an issue's state on an agent's claim alone. After any structural change (rebase done, conflicts resolved, fields renamed), run a verification grep against the worktree. For rebases: check function signatures and rename counts in every conflict file.

### Conflict detection (`patterns/conflict-detection.md`)

- **`defer-ci`** label blocks heavy CI lanes (Lint, Cross-Platform, Linux Integration, Bench, Fixture Sync) but NOT bot reviews. Bot review runs with `defer-ci`; CI runs after the label drops.
- **File-level conflict graph** — build edges from `gh pr view <N> --json files`. Two PRs with file-set intersection conflict; merge order is topological + smallest-scope-first.
- **UNKNOWN-state timer** — GitHub's `mergeStateStatus` stays `UNKNOWN` for minutes after upstream `main` moves. Force-merge predicate: `APPROVED ∧ all_checks_in {SUCCESS, SKIPPED} ∧ disjoint(PR_files, main_files_recently_changed) ∧ unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS`.

### Decision biases (`patterns/decision-biases.md`)

- **Scope-creep detector** — `scope_files_actual` (from `gh pr view --json files`) vs `scope_files_declared` (parsed from issue description). `actual > 2× declared` → escalate. Don't auto-revert.
- **Smaller-PR-first** — when two PRs overlap, the smaller one merges first; the bigger absorbs the rebase. Reverse order forces the smaller PR to rebase against a bigger restructure.
- **Rule of three** — don't extract a shared helper across <3 sibling files. At 2 sites the abstraction shape isn't visible; at 3 the rule is satisfied.
- **Expansion bias** — prefer inline fixes in the current PR over new issues, UNLESS the reason is concrete (different scope, different agent, requires measurement, blocked dep, architectural decision). "Tidiness" is not a reason.
- **Merge-order tiebreakers**: (1) smallest scope first, (2) overlapping files: smaller first, (3) else: any order.

### Structured questions (`patterns/opencode-questions.md`, `patterns/pi-questions.md`)

- **Never pass off-list labels.** Pick `--answer` / `--answer-multi` values from `question.questions[i].options[].label`. Pi `--answer-text` only when the matching tab has `allowCustom=true`; opencode free-form requires `--reject` + a follow-up `opencode run --attach --session <SID> "<text>"`.
- **Pi inner agent completions** are advisory. Re-poll the outer orchestrator only; never call `subagent`/`steer_subagent`/`get_subagent_result` against an orchestrator's inner panes.

## Scripts

```bash
.agents/skills/flightdeck/scripts/<script> [args]
```

**Implementation status:** Default is the TypeScript port under
`skills/flightdeck/lib/flightdeck-core/`. Each ported script ships as a
trampoline that execs `bun .../src/bin/<script>.ts` unless the operator
opts out to the canonical bash sibling via `FLIGHTDECK_USE_TS_<SCRIPT>=0`
(per-script) or `FLIGHTDECK_USE_TS=0` (global). `bun` is therefore a
hard runtime dependency. Currently ported: `prompt-classify`,
`flightdeck-state`, `parallel-groups`, `pane-registry`, `pane-poll`,
`pane-respond`, `flightdeck-daemon` (CLI surface — `status`/`events`/
`ack`/`find-window`/`health`/`stop` are TS by default). The daemon
`start` sub-action has a complete TS run-loop + subscriber lifecycle
port that is parity-tested, but its runtime default still forwards to
the bash sibling; opt in with `FLIGHTDECK_USE_TS_DAEMON_START=1` (or
`FLIGHTDECK_USE_TS=1`). The `.bash` siblings remain in place as the
opt-out target until one full production cycle on TS defaults is
complete. Parity tests for every port live under
`lib/flightdeck-core/tests/parity/`.

| Script | Purpose |
|--------|---------|
| `open-terminal` | Spawn issue worktree(s) with selected harness + optional `--model`/`--effort`. **Never hand-roll issue tmux/terminal commands — use this for issue workflow spawns.** Tmux fallback now delegates to `flightdeck-session` in issue mode. |
| `flightdeck-session` | Generic session launcher/attacher. `start` creates a tmux window and registers `.entries[id]`; `attach` records an existing Pi pane by stable pane id. |
| `parallel-groups` | Read/manage parallel issue groups. |
| `flightdeck-state` | Atomic CRUD on `tmp/flightdeck-state-<TMUX_SESSION>.json` (`init`/`get`/`set`/`append`/`increment`/`tracked-entries`/`write-entry`/`archive`) and master-busy lock (`master-busy lock\|unlock\|check`). See `workflows/watch.md` § 1 for lock semantics. |
| `flightdeck-daemon` | External wake driver. Polls inner panes, normalizes turn-end events, wakes master with a per-harness payload. Actions: `start \| stop \| status \| health \| events \| ack`. See `patterns/tmux-monitoring.md` for adapter freshness + tmux-fallback semantics; the script's own header comment for daemon internals. |
| `codex-app-server-spawn` / `-stop` | Idempotent bring-up/teardown of the per-session codex `app-server --listen ws://...` shared by all `codex --remote` panes. |
| `pane-registry` | TrackedEntry↔pane mapping CRUD. `init-entry` writes `.entries[id]` and dual-writes `.issues[id]` for `kind=issue`; legacy `init <ISSUE>` remains an issue-mode alias. `find-by-pane` emits `{id,kind}` JSON. `list --format json\|inner-panes\|inner-harnesses` feeds `pane-poll --batch -` and `flightdeck-daemon start`. |
| `pane-poll` | Pane state read. Preferred: `--batch -` from `pane-registry list --format json` (one JSONL object per issue). Legacy single-pane mode for drift re-polls / manual debug. See `patterns/tmux-monitoring.md` for per-harness adapter routes. |
| `pane-respond` | Send response to a pane. Modes: free-text payload, `--option N`, `--option-multi`, `--keys` (rejected without `--keys-allow-tmux`), `--question <reqID> --answer\|--answer-multi\|--answer-text\|--answers-json\|--reject`. Validates rebase-multi-choice payloads for the preserve/apply/verify triplet. See `patterns/prompt-handlers.md` for mode selection and `patterns/opencode-questions.md` / `patterns/pi-questions.md` for question routing. |
| `pane-clear-bell` | Atomic chained-command bell clear (no flicker). |
| `pr-conflict-graph` | File-intersection adjacency for a list of PR numbers via `gh pr view --json files`. |
| `prompt-classify` | Regex/sentinel + computed-tag matcher mapping pane state to a handler tag: `rendering`, `terminal-state-reached`, `bash-permission-prompt`, `force-merge-confirm`, `merge-ready-but-unknown`, `merge-now`, `bot-review-wait-stuck`, `rebase-multi-choice`, `force-push-prompt`, `cleanup-prompt`, `audit-relation-prompt`, `descope-related`, `external-fix-suggestions`, `cycle-fix-suggestions`, `scope-creep-detected` [computed], `multi-select-tabbed`, `awaiting-direction`, `generic-multi-choice`, `idle`. Daemon/event-only tags: `oc-question`, `pi-question`, `pi-subagent-completion`, `pi-bg-task-exit`.

`pi-bg-task-exit` (vstack#15): the Pi subscriber matches `pi-bridge stream` events of shape `{ type: "event", event: "message_end", data.message.customType: "vstack-background-tasks:event", data.message.details.eventType: "exit" }` and appends a canonical wake row to `WAKE_EVENTS_LOG`:

```
{"ts":"<iso>","pane_id":"%18","harness":"pi","event_type":"bg-task-exit","task":{"id":"bg-3","status":"failed","exitCode":null,"command":"...","outputBytes":89},"classifier_tag":"pi-bg-task-exit","hash":"<12hex>"}
```

The daemon (`scripts/flightdeck-daemon.bash` + `lib/flightdeck-core/src/daemon/loop.ts`) treats the tag as canonical, appends to the per-session events file via `appendEvent`, extends `WAKE_PENDING.in_flight`, and wakes master. Master routes through `workflows/watch.md` § 2.0a → `workflows/handle-prompt.md` § 1.4. The classifier never sees these messages — they are system-role customType messages, not assistant text — so `prompt-classify` has no matching tag and only the daemon path produces them. |

## Schema — master state

Master state lives at `<project-root>/<FLIGHTDECK_STATE_DIR>/flightdeck-state-<TMUX_SESSION_NAME>.json` (default `tmp/`). Survives compaction; rotated to `*-<terminated_at>.json.archive` on terminate (see `terminate.md § 5`). The archive preserves the full `.issues` map (including merged-issue `decisions_log`, `pr_number`, `merge_commit`) so post-completion dashboards and post-mortem inspection have the whole session history — do not call `pane-registry remove-merged` between `set terminated true` and `archive`. pi-flightdeck's `buildSnapshot` falls back to the newest matching `*.json.archive` when the live file is gone, so the completed-session view in the dashboard / popup keeps rendering until a new `flightdeck start` rewrites the live file. Daemon-private files in `FD_STATE_DIR` are keyed by `SESSION_KEY=s<N>` instead (see `patterns/tmux-monitoring.md`).

Schema `1.1` is additive. `flightdeck-state init` writes `schema_version: 1.1`, keeps the v1 `.issues`, `.merge_queue`, and `.conflict_graph` fields, and adds `.entries` for the neutral `TrackedEntry` model. Older v1 readers ignore `schema_version` and `.entries`; issue-mode readers continue using `.issues`. New core readers must call `readTrackedEntries(state)` instead of touching `.issues` directly: it projects legacy `.issues` records first, then overlays valid `.entries` records by id so `.entries` wins on collisions but issue-only legacy updates remain visible. Malformed non-object `.entries` values are skipped with a stderr warning; malformed internal `entry.id` values warn and fall back to the map key. `writeTrackedEntry(state, id, entry)` validates non-empty ids, including `entry.domain.issue.id` when present, writes `.entries[id]`, and projects `kind: "issue"` entries back to `.issues[issueId]` for compatibility. Unknown future `schema_version` values warn on read (including `phase`) and refuse writes unless `FLIGHTDECK_ALLOW_FUTURE_SCHEMA=1` is set. This mirrors the pi-flightdeck render seam; do not fork renderer-only `.issues` reads back into core logic.

```json
{
  "schema_version": 1.1,
  "session_id": "<TMUX_SESSION_NAME>",
  "started_at": "<ISO8601>",
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
      "launch": { "model": "<model-or-null>", "effort": "<effort-or-null>", "cmd": "<command-or-null>" },
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
        }
      },
      "last_capture_hash": "sha256:...",
      "last_response_at": "<ISO8601>",
      "spawned_at": "<ISO8601>",
      "last_polled_at": "<ISO8601>",
      "decisions_log": []
    }
  },
  "issues": {
    "<ISSUE_ID>": {
      "window": "<window-name>",
      "pane_target": "<TMUX_SESSION>:<window>.0",
      "pane_id": "%403",
      "harness": "claude|opencode|codex|pi",
      "launch": { "model": "<model-or-null>", "effort": "<effort-or-null>" },
      "worktree": "<absolute path>",
      "pr_number": 0,
      "oc_url":  "<server-url-or-null>",  "oc_session_id": "<id-or-null>",  "oc_port": 0,
      "cc_url":  "<server-url-or-null>",  "cc_session_uuid": "<uuid-or-null>",  "cc_port": 0,  "cc_transcript": "<path-or-null>",
      "pi_bridge_pid": 0,  "pi_bridge_socket": "<path-or-null>",  "pi_session_id": "<id-or-null>",
      "cx_ws":   "<ws-url-or-null>",  "cx_thread_id": "<id-or-null>",
      "state": "prompting",
      "substate": "merge-ready-but-unknown",
      "unknown_since": "<ISO8601>",
      "last_capture_hash": "sha256:...",
      "last_response_at": "<ISO8601>",
      "spawned_at": "<ISO8601>",
      "last_polled_at": "<ISO8601>",
      "orchestration_started": true,
      "scope_files_declared": 5,
      "scope_files_actual": 27,
      "decisions_log": [
        {"ts": "<ISO8601>", "prompt_tag": "cleanup-prompt", "answer": "yes-own-only"}
      ],
      "merge_commit": "<git-sha-or-null>"
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

Legacy issue state enum: `state ∈ {waiting, prompting, submitting, merge-ready, merged, aborted, dead}`. `TrackedEntry.state` keeps those values for issue-mode compatibility and also allows generic session states (`ready`, `complete`, `cancelled`) for future non-issue entries. `entryIdForIssue(issueId)` currently returns the issue id unchanged after validation (empty/invalid ids return null); `issueIdForEntry(entry)` reads `entry.domain.issue.id` or, for `kind: "issue"`, `entry.id`. `owner` is additive metadata written by `flightdeck-state init`; `owner.pid` is the owner harness PID supplied by `FLIGHTDECK_OWNER_PID` (falling back to parent PID), and `owner.discovery_error` records Pi bridge metadata lookup failures when the owner harness is Pi. pi-flightdeck uses `owner.pane_id` to keep the persistent dashboard owner-scoped by default, while older readers ignore the field. `paused_for_user` carries `{issue_id, reason, prompt_text}` when an aggressive-mode pause fires.

## Configuration

Master-loop env vars consulted by workflows:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FLIGHTDECK_FORCE_MERGE_AFTER_SECS` | `240` | UNKNOWN-state wait threshold before considering force-merge (predicate also requires APPROVED + green + disjoint) |
| `FLIGHTDECK_STATE_DIR` | `tmp` | Project-relative master-state file directory |
| `FLIGHTDECK_DEBOUNCE_CYCLES` | `2` | Consecutive poll cycles required for "all-done" termination check |
| `FLIGHTDECK_AUTO_MERGE` | `1` | When `0`, the `merge-now` handler escalates instead of auto-answering. For sessions where the human gate is desired (compliance, big-blast-radius PRs) |
| `FLIGHTDECK_HIJACK_GRACE_SECS` | `90` | Seconds after spawn that master tolerates no orchestration `workflow-state-<ISSUE>.json` before escalating "orchestration-never-started". Catches hijacked panes / failed launches. |
| `FLIGHTDECK_LAUNCH_MODEL` | unset | Default `open-terminal --model` override when the workflow/user does not pass `--model`. |
| `FLIGHTDECK_LAUNCH_EFFORT` | unset | Default `open-terminal --effort` / thinking override when the workflow/user does not pass `--effort`. |

Daemon tuning (`FD_*`) is in README.md. Most `FD_*` knobs run inside the
daemon and do not affect master operation directly, but two are
consulted on the master poll path through the TS `pane-poll`:
`FD_ADAPTER_READ_TIMEOUT_SEC` (default `2`, fractional values honored)
caps each adapter read subprocess so one stale adapter cannot dominate
a tick, and `FD_ADAPTER_FRESHNESS_TTL` (default `5`) gates freshness
probe caching.

TS-port toggles:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FLIGHTDECK_USE_TS` | unset (treated as `1`) | Global opt-out switch. Set to `0` to route every trampolined script back to its `.bash` sibling. Per-script flags below override. |
| `FLIGHTDECK_USE_TS_<SCRIPT>` | unset (treated as `1`) | Per-script opt-out (e.g. `FLIGHTDECK_USE_TS_PROMPT_CLASSIFY=0`). Useful for isolating a regression to one script while keeping the rest on TS. |
| `FLIGHTDECK_USE_TS_DAEMON_START` | unset (treated as `0`) | Opt-in for the TS daemon `start` run-loop. The TS port is complete and parity-tested, but `start` still defaults to the bash sibling until one full production cycle on TS. |
| `FD_ADAPTER_READ_TIMEOUT_SEC` | `2` | Bounds per-adapter read subprocesses in TS `pane-poll` (fractional values honored). Stale adapters fall through to tmux capture rather than wedging the tick. |

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/start.md` | `start` (from main) | From-main entry: dashboard, issue selection, research evaluation, parallel-check, spawn, enter watch |
| `workflows/start-new.md` | `start new` | Create new issue from main + spawn |
| `workflows/parallel-check.md` | `parallel-check` (also nested from `start.md` § 4) | Verify candidate issue set is safe to spawn in parallel |
| `workflows/watch.md` | `watch` (entry) or invoked at end of `start.md` after spawn | Master oversight loop — initialize state, poll panes, route prompts, plan merges, terminate |
| `workflows/handle-prompt.md` | Nested invocation from `watch` § 3 | Per-pane prompt classification + response |
| `workflows/close-issue.md` | Nested invocation from `watch` § 2 on `terminal-state-reached` | Verify two-signal terminal state, update master state, kill window, keep registry entry for terminate reporting/final cleanup |
| `workflows/merge-plan.md` | Nested invocation from `watch` § 4 | Conflict-graph build + smallest-first merge ordering |
| `workflows/terminate.md` | Nested invocation from `watch` § 6 | Final summary, new-issues report, next-cycle recommendation, master-state finalization |

## Workflow Execution

These rules apply to flightdeck's boundary workflows (`start.md`, `start-new.md`, `terminate.md`, `close-issue.md`, and per-tag handlers in `handle-prompt.md`). The `watch.md` loop body is reactive by nature — its inner decisions are judgment calls and not subject to these rules.

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

The user-visible output blocks at the end of `terminate.md` and `close-issue.md` are `<output_format>` tagged for this reason: the agent must emit them in full, not collapse to a summary line.

## Implementation Constraints

1. **Aggressive autonomy on known shapes; escalate on novel shapes.** The classifier returns a tag for known prompt shapes. `generic-multi-choice` still tries the bounded auto-decide policy in `handle-prompt.md` § 11; it escalates only when options are destructive, ambiguous, or genuinely novel. It does NOT blindly pick the first option.
2. **Daemon-driven wake; no blocking sleeps.** `flightdeck-daemon` (spawned in `watch.md` § 1) owns wake delivery for every harness. Master ends each turn after `flightdeck-daemon ack` + `flightdeck-state master-busy unlock`. Never `sleep`. Wake payload reference: `/flightdeck` (claude/opencode/default), `$flightdeck` (codex), `/skill:flightdeck` (pi). Claude Code MAY optionally arm `ScheduleWakeup({delaySeconds: 1800})` as a defensive fallback.
3. **Pi dashboard is read-only and additive.** Optional `pi-flightdeck` extension renders mission-control UX from the on-disk artifacts master already writes; never bypasses the schema. No harness-specific shortcuts that bypass the on-disk schema in other harnesses either. See README.md.
4. **One daemon per tmux session.** Concurrent flightdecks within the same tmux session are refused via flock. Run separate sessions for parallel flightdeck instances.
5. **All scripts must appear in this SKILL.md's Scripts table.** No "hidden" scripts. README.md mirrors the table for human readers.

## Compaction Recovery

Master state is persisted on every state mutation and rehydrated on `watch` re-entry. The `unknown_since` force-merge timer survives compaction. Procedure: `workflows/watch.md` § 9.
