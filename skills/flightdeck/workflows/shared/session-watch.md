# Workflow: `session-watch` — Generic Session Loop

Generic Flightdeck loop for tracked tmux-window sessions. It owns session state initialization, entry reconciliation, daemon startup, polling, generic prompt routing, and ack/yield. It deliberately does **not** depend on GitHub, Linear, PR state, issue worktrees, or merge planning.

**Inputs**: optional `[ENTRY_ID...]` filter. When omitted, watch every non-terminal row from `flightdeck-state tracked-entries` / `pane-registry list --format json`.

**Pre-conditions**:
- `$TMUX` set.
- At least one tracked entry exists, or the caller is resuming a state file after compaction.
- Entries were created by `flightdeck-session start|attach`, issue-mode `open-terminal`, or a compatible `pane-registry init-entry` path.

**Post-condition**: generic entries are advanced through `waiting | prompting | submitting | ready | complete | cancelled | dead`; the daemon is acked and the master yields until the next wake, unless `paused_for_user` is set.

---

## Generic state model

| State | Meaning |
|-------|---------|
| `waiting` | Entry is alive and no prompt is ready. |
| `prompting` | A generic prompt/event is ready for `session-handle-prompt.md`. |
| `submitting` | A response was sent and the entry is expected to continue. |
| `ready` | Entry reported useful completion but is still available for review/cleanup. |
| `complete` | Entry finished successfully; no more action expected. |
| `cancelled` | Entry was intentionally stopped or declined. |
| `dead` | Pane/window disappeared unexpectedly. |

Issue mode adds `merge-ready`, `merged`, and `aborted` for the PR lifecycle; `watch.md` maps them onto the generic states via `domain.issue.phase` / `domain.issue.outcome`. Generic `workflow` / `adhoc` entries stay domain-neutral even when they record a top-level `pr_number`; they do not load GitHub, infer PR state, or run repository sync without an explicit PR-capable domain workflow.

---

## § 1: Initialize state and daemon

1. Resolve the tmux session name and stable session id:
   ```bash
   SESSION=$(tmux display-message -p '#S')
   SESSION_ID=$(tmux display-message -p '#{session_id}')
   ```
2. Initialize/resume master state with a long-lived owner PID:
   ```bash
   MASTER_OWNER_PID="${MASTER_OWNER_PID:-${PPID:-}}"
   FLIGHTDECK_OWNER_PID="$MASTER_OWNER_PID" \
     .agents/skills/flightdeck/scripts/flightdeck-state init
   ```
3. Reconcile tracked entries through the TrackedEntry seam:
   ```bash
   .agents/skills/flightdeck/scripts/pane-registry reconcile
   REGISTRY_JSON=$(.agents/skills/flightdeck/scripts/pane-registry list --format json)
   ```
   `pane-registry list --format json` is backed by `flightdeck-state tracked-entries` (canonical `.entries` view) and preserves `kind` for domain routing.
4. Verify the Rust dashboard is present for live work, unless explicitly disabled:
   ```bash
   INNER_PANES="$(.agents/skills/flightdeck/scripts/pane-registry list --format inner-panes-live)"
   if [[ -n "$INNER_PANES" && "${FLIGHTDECK_DASHBOARD:-1}" != "0" ]]; then
     if ! .agents/skills/flightdeck/scripts/flightdeck-dashboard launch 2>&1; then
       echo "dashboard-launch-failed session=$SESSION" >&2
       # Keep going: prompt/daemon supervision remains canonical, but do not call the cycle summary a dashboard.
     fi
   fi
   ```
   `flightdeck-dashboard launch` verifies the tracked `flightdeck-dashboard` entry and pane, ignores stale same-name windows, and is guarded against recursive launches from the dashboard's own `flightdeck-session start`.
5. Spawn or attach the daemon idempotently after checking daemon status for live work:
   ```bash
   MASTER_PANE="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}')}"
   INNER_HARNESSES="$(.agents/skills/flightdeck/scripts/pane-registry list --format inner-harnesses-live)"
   if [[ -n "$INNER_PANES" ]] && ! .agents/skills/flightdeck/scripts/flightdeck-daemon status --session "$SESSION" >/dev/null 2>&1; then
     daemon_start_err="$(mktemp -t flightdeck-daemon-start.XXXXXX)"
     daemon_start_rc=0
     daemon_respawn_failed=0
     .agents/skills/flightdeck/scripts/flightdeck-daemon start \
       --session "$SESSION" \
       --master "$MASTER_PANE" \
       --master-harness "$MASTER_HARNESS" \
       --inner "$INNER_PANES" \
       --inner-harnesses "$INNER_HARNESSES" 2>"$daemon_start_err" || daemon_start_rc=$?
     if (( daemon_start_rc == 4 )); then
       MASTER_PANE="${TMUX_PANE:-$(tmux display-message -p '#{pane_id}')}"
       daemon_start_rc=0
       .agents/skills/flightdeck/scripts/flightdeck-daemon start \
         --session "$SESSION" \
         --master "$MASTER_PANE" \
         --master-harness "$MASTER_HARNESS" \
         --inner "$INNER_PANES" \
         --inner-harnesses "$INNER_HARNESSES" 2>"$daemon_start_err" || daemon_start_rc=$?
     fi
     if (( daemon_start_rc == 1 )) && .agents/skills/flightdeck/scripts/flightdeck-daemon status --session "$SESSION" >/dev/null 2>&1; then
       echo "daemon-respawn-raced session=$SESSION"
       daemon_start_rc=0
     fi
     if (( daemon_start_rc != 0 )); then
       cat "$daemon_start_err" >&2
       echo "daemon-respawn-failed session=$SESSION rc=$daemon_start_rc" >&2
       daemon_respawn_failed=1
     fi
     rm -f "$daemon_start_err"
     if (( daemon_respawn_failed == 1 )); then
       # Do NOT yield/end this turn. The master loop is not armed for wakes.
       return 1 2>/dev/null || exit 1
     fi
   fi
   ```
   On every watch tick with live tracked entries, master MUST check `flightdeck-daemon status --session "$SESSION"`. If it reports `no daemon`, master MUST respawn with the current alive inner pane list from `pane-registry list --format inner-panes-live` / `inner-harnesses-live`, capture the `flightdeck-daemon start` exit code + stderr, and log the respawn in the cycle notes. Exit `4` means stale `--master`: re-resolve from `$TMUX_PANE` and retry once. Exit `1` may be a lock race: if `flightdeck-daemon status` then reports running, log `daemon-respawn-raced` and continue. Any remaining non-zero exit must surface `daemon-respawn-failed` to the user; do NOT yield/end the turn because the master loop is not armed for wakes.
6. Acquire the master-busy lock before processing:
   ```bash
   .agents/skills/flightdeck/scripts/flightdeck-state master-busy lock --owner-pid "$MASTER_OWNER_PID"
   ```
7. Drain pending daemon events for routing hints:
   ```bash
   PENDING=$(.agents/skills/flightdeck/scripts/flightdeck-daemon events --session "$SESSION_ID")
   ```

---

## § 2: Poll entries

Build one batch from normalized tracked entries. Generic mode selects all non-terminal generic states and carries `id`, `kind`, and adapter metadata so `pane-poll` can classify with domain guards.

```bash
REGISTRY_JSON=$(.agents/skills/flightdeck/scripts/pane-registry list --format json)
POLL_INPUT=$(jq '[.[]
  | select((.state // "waiting") as $s | ["waiting","prompting","submitting","ready"] | index($s))
  | {id, kind, issue, pane_id, pane_target, harness, cwd,
      oc_url, oc_session_id, cc_url, cc_transcript,
      pi_bridge_pid, pi_bridge_socket, cx_ws, cx_thread_id}
]' <<< "$REGISTRY_JSON")
POLL_JSONL=$(printf '%s' "$POLL_INPUT" | .agents/skills/flightdeck/scripts/pane-poll --batch -)
```

For each tracked entry:

1. Prefer structured pending events from `PENDING` when present:
   - `oc-question` / `pi-question`: set `state=prompting`, `substate=<tag>`, and pass `details.request_id`, `details.question`, and `details.harness` to `session-handle-prompt.md`.
   - `pi-bg-task-exit`: set `state=prompting`, `substate=pi-bg-task-exit`, and pass `details.task` to `session-handle-prompt.md`.
   - `daemon-exited`: treat as a daemon lifecycle event, not an inner-pane prompt. Record the reason, verify `flightdeck-daemon status --session <S>`, and follow the respawn contract in § 1 / § 6 before yielding.
2. Otherwise read the entry's row from `POLL_JSONL` by stable `pane_id`/`pane_target` and update:

   | tag | new state | route |
   |-----|-----------|-------|
   | `idle` | unchanged | no-op |
   | `rendering` | unchanged | re-poll next cycle |
   | `dead` / `dead: true` | `dead` | no prompt routing |
   | `terminal-state-reached` | `complete` | generic completion signal; issue mode may verify via `close-issue.md` |
   | `bash-permission-prompt` | `prompting` | `session-handle-prompt.md` |
   | `awaiting-direction` | `prompting` | `session-handle-prompt.md` |
   | `generic-multi-choice` | `prompting` | `session-handle-prompt.md` safe bounded-choice policy |
   | `oc-question` | `prompting` | structured question handler |
   | `pi-question` | `prompting` | structured question handler |
   | `pi-bg-task-exit` | `prompting` | background-task exit handler |
   | `daemon-exited` | unchanged | daemon lifecycle respawn path (§ 1 / § 6), no pane handler |
   | `domain-mismatch` | `prompting` | guard escalation, no destructive action |

3. Hash debounce still applies: if `capture_hash == last_capture_hash` and `bell == false`, skip handler routing for that row.
4. Persist `last_capture_hash`, `last_polled_at`, and any non-empty `window_name_current` from `pane-poll` on every successful poll.

### Handler guards

`prompt-classify --entry-kind <kind>` (and the TS classifier option used by `pane-poll`) rewrites issue-only tags on non-issue entries to `domain-mismatch`. Missing kind fails closed: issue-only tags classify as `domain-mismatch` with a warning. If entry lookup misses, the caller should pass `--entry-kind-unknown`; that sentinel also routes issue-only tags to `domain-mismatch`. The watch loop must then:

1. Log a warning naming the original prompt shape if available.
2. Do **not** run issue handlers, touch worktrees, query PRs, merge, force-push, or clean up.
3. Set `paused_for_user = {entry_id, reason: "domain-mismatch", prompt_text: <buffer/event excerpt>}` so the master surfaces a question to the user.

If a generic tag appears on an issue entry, route it through `session-handle-prompt.md` first. After the generic handler returns, resume the issue-mode extension in `watch.md` with the issue's domain state intact.

---

## § 3: Generic decision routing

Process `state == "prompting"` entries sequentially. Do not answer panes in parallel; adapter calls and decision logs must remain ordered.

```
⤵ workflows/shared/session-handle-prompt.md <ENTRY_ID> <SUBSTATE_TAG>
```

Pass structured event details for `oc-question`, `pi-question`, and `pi-bg-task-exit`. Pass the captured buffer for text-classified prompts.

After a successful response:

1. `pane-respond` clears the bell and logs the decision.
2. Move the entry to `submitting` or back to `waiting`, depending on the handler result.
3. Re-poll that entry once after `--confirm-advanced` when using tmux fallback.

If the handler escalates, leave `paused_for_user` populated and do not release the busy lock until the user resumes.

---

## § 4: Cycle summary

Emit a sessions-first cycle summary. This chat table is not the Rust dashboard. Omit PR/Linear/worktree columns.

<output_format>
### ✈️ Flightdeck sessions [N] · [SESSION] · [ISO8601]

| Entry | Kind | State | Last prompt | Answer |
|-------|------|-------|-------------|--------|
| [ENTRY_ID] | [adhoc|workflow|issue] | [STATE] | [PROMPT_EXCERPT or —] | [ANSWER_EXCERPT or —] |

Paused: [entry_id and reason, or —]
</output_format>

---

## § 5: Yield

1. Atomically ack daemon events:
   ```bash
   FINAL=$(.agents/skills/flightdeck/scripts/flightdeck-daemon ack --session "$SESSION_ID")
   ```
   If `FINAL` is non-empty, process those newcomer events before yielding.
2. Release the master-busy lock after ack:
   ```bash
   .agents/skills/flightdeck/scripts/flightdeck-state master-busy unlock
   ```
3. End the turn. The daemon owns wake delivery and sends the harness-specific payload back to the master.

If `paused_for_user` is set, do not release/yield as a normal cycle; wait for the user to re-invoke the relevant watch command.

---

## § 6: Compaction recovery

On re-entry, `flightdeck-state init` is idempotent. Reconcile entries, re-poll through `pane-registry list --format json`, treat persisted state as a hint, and resume at § 2.

Compaction recovery MUST verify dashboard presence and daemon liveness before yielding again. If any non-terminal tracked entry has a live pane and `FLIGHTDECK_DASHBOARD != 0`, run `flightdeck-dashboard launch` before daemon respawn; stale same-name windows do not satisfy the invariant. If `flightdeck-daemon status --session <S>` says `no daemon`, respawn the daemon with `pane-registry list --format inner-panes-live` and the matching `inner-harnesses-live` list. Capture `flightdeck-daemon start` exit code + stderr using the § 1 contract: exit `4` → re-resolve master from `$TMUX_PANE` and retry once; exit `1` + `flightdeck-daemon status` running → log `daemon-respawn-raced` and proceed; any remaining failure → surface `daemon-respawn-failed` and do NOT yield/end the turn. On success, log `daemon-respawned` with the session id and inner panes before continuing. Do not assume a prior `--in-tmux-window` daemon survived compaction or user window cleanup.

---

## Returns

To the caller's session loop, or to `watch.md` when issue mode is extending the generic loop.
