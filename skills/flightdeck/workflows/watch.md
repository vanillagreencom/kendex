# Workflow: `watch` — Master Loop

Master mode entry point. Polls every spawned issue pane, classifies their prompts, routes to handlers, plans merges, and drives every tracked issue to a terminal state. Wakes are driven by `flightdeck-daemon` (an external bash poller spawned at session start) — the harness scheduler is no longer load-bearing.

**Inputs**: `[ISSUE_IDS]` — the issue list spawned by flightdeck's `start.md` (auto-passed at handoff). Auto-detect `$TMUX_SESSION` via `tmux display-message -p '#S'` and stable `$SESSION_ID` via `tmux display-message -p '#{session_id}'`.

**Pre-conditions**:
- `$TMUX` set (the SKILL.md mode-switch already gates this — unreachable otherwise).
- flightdeck's `start.md` § 4 just returned from `open-terminal` for one or more issues, OR a state file already exists for compaction-recovery re-entry.
- `[ISSUE_IDS]` non-empty OR an existing `tmp/flightdeck-state-<SESSION>.json` file is present.
- `github` and `linear` skills loaded.

**Post-condition**: master state `terminated: true`, summary file written, control returned to flightdeck's dashboard loop.

---

## § 1: Initialize Master State

1. Resolve session: `SESSION=$(tmux display-message -p '#S')`, `SESSION_ID=$(tmux display-message -p '#{session_id}')`.
2. Init / resume master state:
   ```
   .agents/skills/flightdeck/scripts/flightdeck-state init
   ```
   Idempotent — preserves an existing state file if one exists (compaction-recovery path).
3. Reconcile registry against live tmux windows (drops stale entries from prior sessions whose windows are gone):
   ```
   .agents/skills/flightdeck/scripts/pane-registry reconcile
   ```
4. For each `ISSUE_ID` in the spawn batch, build / refresh registry entry:
   - Look up the spawned window by name (`open-terminal` names windows after the issue ID, lowercased).
   - Determine harness from the agent process running in pane 0 (`tmux list-panes -t <session>:<window> -F '#{pane_index} #{pane_current_command}'`).
   - Determine worktree path (passed by `start.md`; cross-check `git worktree list`).
   - Pin the orchestrator-pane index by fingerprinting (see `patterns/tmux-monitoring.md` § Pane-0 rule). If only one pane, index 0.
   - Resolve the stable `%pane_id` for the orchestrator pane via `tmux display-message -p -t <session>:<window>.<pane> '#{pane_id}'`.
   - Register:
     ```
     .agents/skills/flightdeck/scripts/pane-registry init <ISSUE_ID> \
       --window <window-name> --harness <h> --worktree <path> --pane-index <N>
     ```
5. **Spawn or attach the daemon**. If no daemon is running for this session, spawn one. Pass the master pane and the comma-separated list of inner orchestrator panes. The TS port of the run-loop + subscriber lifecycle is complete and parity-tested, but until one full production cycle on TS, `flightdeck-daemon start` keeps an opt-in gate (`FLIGHTDECK_USE_TS_DAEMON_START=1` or `FLIGHTDECK_USE_TS=1`); without it the trampoline still delegates `start` to `flightdeck-daemon.bash`. Other daemon CLI actions (`status`/`events`/`ack`/`health`/`stop`/`find-window`) run on TS by default.
   ```
   MASTER_PANE="$SESSION:1.<base-pane-index>"  # the pane this watch.md runs in
   INNER_PANES="$(.agents/skills/flightdeck/scripts/pane-registry list --format inner-panes)"
   INNER_HARNESSES="$(.agents/skills/flightdeck/scripts/pane-registry list --format inner-harnesses)"
   .agents/skills/flightdeck/scripts/flightdeck-daemon start \
     --session "$SESSION" \
     --master "$MASTER_PANE" \
     --master-harness "$MASTER_HARNESS" \
     --inner "$INNER_PANES" \
     --inner-harnesses "$INNER_HARNESSES"
   ```

   `MASTER_HARNESS` is `pi | claude | codex | opencode` — the harness running this master. Pi masters require it (or rely on auto-detection via `pi-bridge list`) because bridge delivery can expand `/skill:flightdeck` inline; the daemon routes pi wakes through `pi-bridge send --pid <master_pid>` first, then falls back to `tmux send-keys -l` + Enter if the bridge is unavailable. Other harnesses use the tmux paste path.

   `start` self-daemonizes via `setsid + nohup`: the call blocks until the child writes its PID file, then returns. Do NOT add `&` or harness-specific backgrounding — the daemon survives the calling shell's lifecycle on its own. The daemon refuses via flock if already running for this session, so the call is idempotent and safe on every `watch` re-entry.

   For codex / opencode / pi masters, prefer the tmux-window spawn mode (set `FD_SPAWN_MODE=tmux-window` env or pass `--in-tmux-window`). The daemon runs inside a dedicated tmux window in the same session; lifetime ties to the tmux session (which is the architectural boundary of a flightdeck session anyway). When stdout is a tty (i.e., this mode) the daemon prints a startup banner and tees every `log()` / `warn()` line to the window in addition to the on-disk log, so the window shows live activity instead of being blank — detach mode keeps stdout pointed at the log file and writes only to disk. Detach mode is the default for Claude Code where `run_in_background` reparenting is reliable.
6. **Atomic master-busy lock** — write `tmp/fd-master-<SESSION_KEY>.busy` via temp+mv:
   ```
   .agents/skills/flightdeck/scripts/flightdeck-state master-busy lock --owner-pid "$MASTER_OWNER_PID"
   ```
   This signals the daemon that master is mid-turn and prevents wake delivery during processing.

   `MASTER_OWNER_PID` should be a long-lived PID inside the master's process tree — the harness binary running the agent (pi, claude, codex, opencode) or the calling agent's interpreter. Pi masters can use `pgrep -u $(id -u) -nf '^pi( |$)' || echo ""`. Claude / OpenCode / Codex masters can pass the pid of their CLI process or omit the flag entirely; when the flag is absent the daemon falls back to validating the lock by `master_pane_id` tmux-liveness plus a TTL (`FD_MASTER_TURN_TTL`, default 3600s), which is correct for cases where no stable long-lived pid is exposed. **Do NOT** pass the calling shell's `$$` — it exits before the daemon ever reads the lock file, so the pid check would always report the master as not busy and a wake could land mid-turn.
7. **Drain pending events** for hint-level visibility into which panes are ready:
   ```
   PENDING=$(.agents/skills/flightdeck/scripts/flightdeck-daemon events --session "$SESSION_ID")
   ```
   `PENDING` is JSONL with `{ts, pane_id, hash, tag, reason, stable_age_sec}` per ready pane. Structured question events (`oc-question`, `pi-question`) also include `details: {event_type, request_id, question, harness}`. Use these as routing hints; § 2 polls every tracked pane regardless except when a structured question event already supplies the prompt payload.
8. If resuming, recompute the conflict graph against the live PR set in case PRs moved during compaction:
   ```
   .agents/skills/flightdeck/scripts/pr-conflict-graph <PR1> <PR2> ...
   ```
   Persist via `flightdeck-state set conflict_graph <json>`.

---

## § 2: Poll

At the start of each § 2 cycle, fetch the registry once and batch-poll every non-terminal pane once. Keep the JSONL result in memory for the per-issue loop; use legacy single-pane `pane-poll` only for targeted re-polls after drift recovery or manual debugging:

```
REGISTRY_JSON=$(.agents/skills/flightdeck/scripts/pane-registry list --format json)
POLL_INPUT=$(jq '[.[]
  | select((.state // "waiting") as $s | ["waiting","prompting","submitting","merge-ready"] | index($s))
  | {issue, pane_id, pane_target, harness, worktree, pr_number,
      oc_url, oc_session_id, cc_url, cc_transcript,
      pi_bridge_pid, pi_bridge_socket, cx_ws, cx_thread_id}
]' <<< "$REGISTRY_JSON")
POLL_JSONL=$(printf '%s' "$POLL_INPUT" | .agents/skills/flightdeck/scripts/pane-poll --batch -)
```

Adapter reads through the default TS `pane-poll` are capped by
`FD_ADAPTER_READ_TIMEOUT_SEC` (default 2s, fractional values honored;
see `README.md` daemon tuning table). Panes are still polled
sequentially — async parallelism is a later iteration; if a tick feels
slow, drop the timeout or check `patterns/tmux-monitoring.md` for the
adapter freshness probe details.

For each tracked issue currently in a non-terminal state (`waiting | prompting | submitting | merge-ready`):

0. **Structured-question event check** — if `PENDING` contains an event for this issue's pane with `tag == "oc-question"` or `tag == "pi-question"`, set state to `prompting`, substate to that tag, and carry `details.request_id` + `details.question` into `handle-prompt.md`. Do not try to rediscover this by `capture-pane`; the inline/modal question may not appear in plain assistant text.

0.5. **Pane-hijack check** — only if `orchestration_started` is `false` for this issue:
   - If the orchestration workflow-state file exists at `tmp/workflow-state-<ISSUE>.json` (or wherever `ORCH_STATE_DIR` resolves to), set `orchestration_started: true` via `pane-registry set <ISSUE> orchestration_started true` and proceed to step 1.
   - Otherwise check `(now - spawned_at)`. If elapsed exceeds `FLIGHTDECK_HIJACK_GRACE_SECS` (default 90), the pane was either hijacked for unrelated work or orchestration silently failed to start. Escalate: `paused_for_user = {issue_id, reason: "orchestration-never-started", prompt_text: "<ISSUE> spawned <elapsed>s ago; no workflow-state file. Pane may have been hijacked or orchestration failed to start."}`. Skip the rest of § 2 for this issue.
1. Read this issue's `pane-poll --batch` JSON object from `POLL_JSONL` (one object per issue, same schema as legacy single-pane mode plus `issue`). The batch input came from the registry's immutable `pane_id` when available and falls back to `pane_target` for legacy rows; it also passes `harness`, `worktree`, `pr_number`, and per-harness adapter metadata (`oc_url`/`oc_session_id`, `cc_url`/`cc_transcript`, `pi_bridge_pid`/`pi_bridge_socket`, `cx_ws`/`cx_thread_id`) so adapter reads and the orphan worktree-gone + PR-merged cross-check still run without re-querying `pane-registry` per row:
   ```
   POLL=$(jq -c --arg issue "<ISSUE>" 'select(.issue == $issue)' <<< "$POLL_JSONL" | tail -n1)
   ```
   If a targeted re-poll is needed after fingerprint drift recovery, call legacy single-pane mode with the corrected target:
   ```
   .agents/skills/flightdeck/scripts/pane-poll <pane_id-or-session-window> [pinned-pane-index] \
     --harness <h> \
     --worktree <worktree-path-from-registry> \
     --pr <pr-number-from-registry>
   ```
2. Parse `POLL`. If `dead: true` → `pane-registry set-state <ISSUE> dead` and continue.

   **Pane-fingerprint drift recovery**: if `fingerprint_match: false` AND `pane_index_suggest` is non-null, the orchestrator pane moved (sub-agent restart, layout reflow, harness restart). Re-resolve both the human-readable `pane_target` AND the immutable `pane_id` (the daemon now keys liveness on `pane_id` — see x-harness review finding #4; updating only `pane_target` would leave the daemon watching the old pane id):
   ```
   NEW_TARGET="<session>:<window>.<suggest>"
   NEW_PANE_ID=$(tmux display-message -p -t "$NEW_TARGET" '#{pane_id}' 2>/dev/null || echo "")
   .agents/skills/flightdeck/scripts/pane-registry set <ISSUE> pane_target "\"$NEW_TARGET\""
   [[ -n "$NEW_PANE_ID" ]] && .agents/skills/flightdeck/scripts/pane-registry set <ISSUE> pane_id "\"$NEW_PANE_ID\""
   ```
   Re-poll on the new index this cycle. If `fingerprint_match: false` AND `pane_index_suggest` is null, no sibling matched the orchestrator sentinel either — the pane may be genuinely idle/blank or the agent crashed; treat the read as authoritative for this cycle and let the state machine route normally (often `idle` → no-op).
3. Otherwise update state machine based on `tag`:

   | tag | new state | notes |
   |-----|-----------|-------|
   | `idle` | unchanged | nothing to do |
   | `rendering` | unchanged | re-poll next cycle |
   | `terminal-state-reached` | (handled below) | route to `close-issue.md`; do not enter `prompting` |
   | `bash-permission-prompt` | `prompting` | substate = tag |
   | `cleanup-prompt` | `prompting` | substate = tag |
   | `bot-review-wait-stuck` | `prompting` | substate = tag |
   | `rebase-multi-choice` | `prompting` | substate = tag |
   | `force-push-prompt` | `prompting` | substate = tag |
   | `stale-no-pr-branch` | `prompting` | substate = tag (handler always answers Keep — scope violation from older orchestration build) |
   | `stale-orphan-worktree` | `prompting` | substate = tag (handler always answers Keep) |
   | `audit-relation-prompt` | `prompting` | substate = tag |
   | `merge-now` | `prompting` | substate = tag |
   | `merge-ready-but-unknown` | `prompting` | substate = tag; if `unknown_since` is null, set it now |
   | `force-merge-confirm` | `prompting` | substate = tag |
   | `external-fix-suggestions` | `prompting` | substate = tag |
   | `cycle-fix-suggestions` | `prompting` | substate = tag |
   | `scope-creep-detected` | `prompting` | substate = tag |
   | `descope-related` | `prompting` | substate = tag |
   | `multi-select-tabbed` | `prompting` | substate = tag (handler picks via `--option-multi`) |
   | `awaiting-direction` | `prompting` | substate = tag (handler synthesizes a continuation directive from registry intent) |
   | `generic-multi-choice` | `prompting` | substate = tag (handler auto-decides per § 11 of `handle-prompt.md`, escalates only on novelty/destructive ambiguity) |
   | `oc-question` | `prompting` | substate = tag; handler uses structured event details, not pane text |
   | `pi-question` | `prompting` | substate = tag; handler uses structured event details, including `allowCustom` |

   **`terminal-state-reached` routing**: do not transition to `prompting`. Instead invoke `⤵ workflows/close-issue.md <ISSUE_ID>`. That workflow verifies the signal (two-signal rule), updates master state, and tears down the window. Returns here when done.

4. Hash debounce: if `capture_hash` matches `last_capture_hash` AND `bell == false`, skip routing — the prompt is the same one already handled.
5. Update `last_capture_hash` and `last_polled_at` on every poll.

---

## § 3: Decision Routing

**Process prompting issues SEQUENTIALLY, not in parallel.** Adapter calls (opencode HTTP-attach in Phase 1, future channels/socket/WS) are synchronous — no per-call round-trip cost — but classifier work and decision routing must stay ordered. Concurrent handler invocations across panes interleave decision logs, race the dedup state in the daemon's wake-pending tracker, and create cognitive-load-induced response errors at the master pane. Serialize for ordering, not for latency.

For each issue currently in `state == "prompting"` and not debounced in § 2, **one at a time**:

1. `⤵ workflows/handle-prompt.md <ISSUE_ID> <SUBSTATE_TAG> → § 4` — pass the captured buffer plus the classification tag. For `oc-question` / `pi-question`, pass the structured event `details` (`request_id`, `question`, `harness`) instead of treating the TUI buffer as authoritative. Handler decides the response (auto-answer, escalate, or custom/free-text with combined guidance).
2. After handler returns:
   - If a response was sent: `pane-respond` already cleared the bell and logged the decision via `pane-registry log-decision`. For tmux-fallback panes pass `--confirm-advanced` — it polls until the prompt sentinel is gone (8s timeout, exit 4 on miss) so the loop doesn't move on while the previous send is still in flight. Adapter-mode opencode is naturally synchronous (`opencode run --attach` blocks until the turn completes), so `--confirm-advanced` is a safe no-op there.
   - If escalated to user: master state's `paused_for_user` is now populated; the watch loop yields control to the user. Resumption happens when the user re-invokes `watch`.
3. Re-poll the same window after a confirmed-advanced response to detect the next state (the agent typically advances to its next phase within a few seconds). Only after the prompt has visibly advanced (or `--confirm-advanced` timed out and recovery is logged) move on to the next prompting issue.

**Pre-flight optimization (when ≥ 3 issues are prompting concurrently)**: capture + classify all panes in parallel during § 2 (background subshells writing to per-pane temp files; collect after a barrier). Sequencing constraint applies to § 3 response-send only — capture is read-only and parallelizable.

---

## § 4: Merge Planning

When **at least one** issue's state has reached `merge-ready` (the per-issue agent has emitted a "Merge now" prompt that handler approved, or auto-merge was triggered):

1. `⤵ workflows/merge-plan.md → § 5` — build the conflict graph from current PR file lists, smallest-scope-first ordering, execute the next safe merge.
2. After each merge, the merged issue transitions to `merged` and is removed from the active set. The graph mutates; merge-plan recomputes for the remaining queue.

---

## § 5: Bell Cleanup

`pane-respond` clears the bell on every successful send via the chained `select-window` idiom. The daemon also clears bells via the same idiom after delivering a wake. No additional cleanup needed in the loop. If bells are observed on idle (no prompt) windows during § 2, clear them defensively:

```
.agents/skills/flightdeck/scripts/pane-clear-bell <session>:<window>
```

(Stale bells from earlier prompts the user manually answered.)

---

## § 6: Termination Check

At the end of each poll cycle:

1. Count issues by state. If every tracked issue is in `merged | aborted | dead` AND every issue's `state` is not `prompting` → increment a debounce counter.
2. If the debounce counter reaches `FLIGHTDECK_DEBOUNCE_CYCLES` (default 2) consecutive cycles → `⤵ workflows/terminate.md → END`.
3. Otherwise, fall through to § 7 (Status Dashboard) → § 8 (Yield).

---

## § 7: Status Dashboard

Emit a per-cycle dashboard summarizing the current state of every tracked issue. The user (and any second-party reviewer of the master pane scrollback) reads this to understand what the master agent is doing without inspecting state files. Per SKILL.md "Format Tags Are Literal": fill placeholders, omit empty rows, add nothing else.

For each tracked issue, gather:
- **Phase** — invoke `flightdeck-state phase <ISSUE>` which reads `tmp/workflow-state-<ISSUE>.json` (orchestration's own state) and composes a phase descriptor (e.g., `cycle=2 reviewers=3 pr-review=1`). Falls back to `fd:<state>` from the flightdeck registry when no orchestration state file exists, or `unknown` if neither is present. Do NOT short-cut to `state == "rendering"` from flightdeck's view alone — that hides orchestration progress.
- **Last prompt** — most recent `decisions_log[-1].prompt_tag` from registry, plus a short prompt-text excerpt (truncated to ~50 chars). `—` if no decisions yet.
- **Answer** — most recent `decisions_log[-1].answer` (truncated to ~40 chars). `—` if none.
- **PR** — `registry.<ISSUE>.pr_number`. `—` if not yet opened.

<output_format>
### ✈️ Flightdeck cycle [N] · [SESSION] · [ISO8601]

| Issue | Phase | Last prompt | Answer | PR |
|-------|-------|-------------|--------|----|
| [ISSUE_ID] | [PHASE] | [PROMPT_EXCERPT or —] | [ANSWER_EXCERPT or —] | [#N or —] |

Merge queue: [ISSUE_IDS comma-separated, or —] · Conflicts: [edges or none] · Paused: [issue_id and reason, or —]
</output_format>

Sections with no rows (no tracked issues) are omitted. Footer line is always emitted.

---

## § 8: Yield

End-of-turn handoff to the daemon:

1. **Atomic ack** — drain any newcomer events that arrived during this turn AND clear `WAKE_PENDING` in one operation:
   ```
   FINAL=$(.agents/skills/flightdeck/scripts/flightdeck-daemon ack --session "$SESSION_ID")
   ```
   Race-safe: daemon cannot extend in-flight while master holds the session lock through this action. If `FINAL` is non-empty, process the newcomer events (re-poll the named panes, route to handlers as in § 3). Repeat until ack returns empty.

2. **Release master-busy lock** AFTER ack completes:
   ```
   .agents/skills/flightdeck/scripts/flightdeck-state master-busy unlock
   ```
   Order matters: clearing wake-pending FIRST then releasing busy means the daemon's next tick sees a clean state. Reversing the order leaves a window where daemon could create a new wake before master cleared pending.

3. **End the turn**. The daemon will send the per-harness wake payload to this pane when the next attention-ready event arrives. Wake delivery uses `pi-bridge send --pid <master_pid>` for Pi masters and `tmux load-buffer + paste-buffer + send-keys Enter` for everyone else; Pi falls back to `tmux send-keys -l` + Enter if the bridge is unavailable. Payload is `/skill:flightdeck watch --from-daemon` for Pi, `/flightdeck watch --from-daemon` for Claude/OpenCode/default, and `$flightdeck watch --from-daemon` for Codex (see `wake_payload_for_harness` in `flightdeck-daemon`). Do NOT use `sleep` (blocks the turn) and do NOT use `ScheduleWakeup`-equivalent (no longer needed; daemon owns wake). On Claude Code specifically, you MAY arm a defensive `ScheduleWakeup({delaySeconds: 1800})` as a "if daemon is dead, wake me anyway" safety net — but this is optional, not load-bearing.

If `paused_for_user` is set, do NOT release the busy lock or end the turn. Wait for user to re-invoke `watch` after addressing the pause.

---

## § 9: Compaction Recovery

Master state persists on every mutation. On `watch` re-entry after compaction (or an explicit user resume):

1. `flightdeck-state init` is idempotent — it loads the existing state file.
2. Re-fingerprint each registered window's pane 0 (TUIs may have re-laid-out across compaction). Adapter reads remain primary; tmux capture-pane is the documented fallback.
3. Recompute every issue's `state` from a fresh `pane-poll --batch -` registry snapshot. Persisted state is a hint, not truth.
4. The `unknown_since` timer is preserved across compaction, so the force-merge clock does not reset.
5. Recompute the conflict graph against current PR file lists (PRs may have moved during compaction) and resume the merge queue from where it left off — see § 4.
6. Re-evaluate any `paused_for_user` entry: if the user has acted in the pane in the meantime, reclassify and proceed; otherwise keep the pause.
7. The daemon may have continued running through compaction; § 1 step 5's `flightdeck-daemon start` is idempotent (flock-protected) and is a no-op when the daemon is already alive.
8. Resume from § 2.

---

## Returns

To flightdeck's dashboard loop (`workflows/start.md` § 1), after `terminate.md` writes the summary and emits the user-visible line.
