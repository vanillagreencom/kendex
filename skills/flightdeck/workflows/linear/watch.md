# Workflow: `linear watch` — Issue-Mode Extension

Issue-mode master loop. It extends the generic `session-watch.md` loop with PR/Linear/worktree decisions, merge planning, issue cycle summaries, and the issue-specific lifecycle states.

**Inputs**: `[ISSUE_IDS]` from `start.md` or an existing Flightdeck state file on compaction recovery.

**Pre-conditions**:
- `$TMUX` set.
- `workflows/shared/session-watch.md` is the core loop for state init, entry reconciliation, daemon startup, polling, generic prompt routing, and ack/yield.
- Issue-mode skills are loaded now: `github`, `linear`, `worktree`, and `project-management` as needed by the issue workflow. Generic `session-watch.md` does not load or require them.
- `[ISSUE_IDS]` non-empty or `tmp/flightdeck-state-<SESSION>.json` exists.

**Post-condition**: issue entries reach a terminal issue outcome (`merged`, `aborted`, or `dead`), `terminate.md` writes the issue summary, and control returns to the watch loop.

---

## § 0: Enter through the generic loop

Run `⤵ workflows/shared/session-watch.md` for the common mechanics:

1. Initialize/resume master state.
2. Reconcile entries through `flightdeck-state tracked-entries` / `pane-registry list --format json`.
3. Spawn/attach `flightdeck-daemon`.
4. Poll each non-terminal entry with `pane-poll --batch -`.
5. Route generic prompts to `session-handle-prompt.md`.
6. Ack and yield.

Issue mode adds the sections below before/after those generic steps. Do not duplicate generic daemon or prompt-loop logic here.

---

## § 1: Register / refresh issue entries

For each `ISSUE_ID` in the spawn batch, ensure a `kind="issue"` entry exists. Legacy aliases remain valid.

1. Look up the spawned window by issue id (lowercased window name from `open-terminal`).
2. Determine harness, worktree, pane index, stable `%pane_id`, and adapter metadata.
3. Register through the issue alias or explicit entry path:
   ```bash
   .agents/skills/flightdeck/scripts/pane-registry init <ISSUE_ID> \
     --window <window-name> --harness <h> --worktree <path> --pane-index <N>
   ```
   This writes `.entries[ISSUE_ID]` with `kind="issue"` and the issue metadata under `domain.issue`.
4. If resuming, do not overwrite existing decisions or domain fields; reconcile only liveness and pane metadata.

---

## § 2: Issue state mapping

The generic state enum is canonical. Issue-mode entries may carry one of the issue-specific lifecycle states directly in `state`; renderers and merge planning treat them as terminal/near-terminal alongside the generic enum.

| Issue-mode state | Generic equivalent | Domain fields |
|------------------|--------------------|---------------|
| `waiting` | `waiting` | unchanged |
| `prompting` | `prompting` | `substate=<tag>` |
| `submitting` | `submitting` | orchestration in progress |
| `merge-ready` | `ready` | `domain.issue.phase = "merge-ready"` |
| `merged` | `complete` | `domain.issue.outcome = "merged"` |
| `aborted` | `cancelled` | `domain.issue.outcome = "aborted"` |
| `dead` | `dead` | pane/window lost |

Issue workflows write `state` as `merge-ready` / `merged` / `aborted` and set the matching `domain.issue.phase` or `domain.issue.outcome`. Generic readers treat `domain.issue.phase / outcome` as the issue-specific extension.

---

## § 3: Issue poll additions

During `session-watch.md` § 2, issue entries add these checks after generic structured events and before issue handler routing:

Issue mode extends the generic `POLL_INPUT` with issue-domain metadata for `pane-poll` orphan terminal cross-checks and PR/worktree-aware handlers:

```bash
POLL_INPUT=$(jq '[.[]
  | select((.state // "waiting") as $s | ["waiting","prompting","submitting","ready","merge-ready"] | index($s))
  | {id, kind, issue, pane_id, pane_target, harness, cwd, worktree, pr_number,
      oc_url, oc_session_id, cc_url, cc_transcript,
      pi_bridge_pid, pi_bridge_socket, cx_ws, cx_thread_id}
]' <<< "$REGISTRY_JSON")
```

1. **Orchestration hijack/start check** — if `domain.issue.orchestration_started` is false, look for `tmp/workflow-state-<ISSUE>.json`. If absent beyond `FLIGHTDECK_HIJACK_GRACE_SECS` (default 90), set `paused_for_user = {issue_id, reason: "orchestration-never-started", prompt_text: ...}`.
2. **Issue-only tags** — route only when `kind == "issue"`. Tags include:
   - `cleanup-prompt`
   - `bot-review-wait-stuck`
   - `rebase-multi-choice`
   - `force-push-prompt`
   - `stale-no-pr-branch`
   - `stale-orphan-worktree`
   - `audit-relation-prompt`
   - `merge-now`
   - `merge-ready-but-unknown`
   - `force-merge-confirm`
   - `external-fix-suggestions`
   - `cycle-fix-suggestions`
   - `scope-creep-detected`
   - `descope-related`
   - `multi-select-tabbed`
3. **Domain guard** — if an issue-only tag appears on `kind=adhoc` or any non-issue entry, `prompt-classify --entry-kind` / `pane-poll` reports `domain-mismatch`. Log a warning, do not run issue handlers, and surface a master question through `paused_for_user`.
4. **Generic tags on issue entries** — `oc-question`, `pi-question`, `bash-permission-prompt`, `awaiting-direction`, safe `generic-multi-choice`, `terminal-state-reached`, and `pi-bg-task-exit` first route through `session-handle-prompt.md`. After it returns, resume this issue loop with domain state intact.

`terminal-state-reached` on an issue entry invokes `⤵ workflows/linear/close-issue.md <ISSUE_ID>` after the generic completion signal. `close-issue.md` performs the two-signal verification, records the issue outcome, and tears down the window when safe.

---

## § 4: Issue decision routing

Process prompting issues sequentially. For each issue in `state == "prompting"` and not debounced:

1. If `<SUBSTATE_TAG>` is generic, call:
   ```
   ⤵ workflows/shared/session-handle-prompt.md <ISSUE_ID> <SUBSTATE_TAG>
   ```
   Then re-poll and continue issue flow.
2. If `<SUBSTATE_TAG>` is issue-only, call:
   ```
   ⤵ workflows/linear/handle-prompt.md <ISSUE_ID> <SUBSTATE_TAG>
   ```
3. If either handler sets `paused_for_user`, stop the cycle and yield to the user.
4. After a confirmed response, re-poll the same issue before moving to the next prompting issue.

The issue handler surface is limited to PR/Linear/worktree workflow logic: cleanup worktree, bot-review/CI continuation, rebase, force-push, audit relation, merge, descope, review fix suggestions, scope creep, stale-no-pr-branch, and stale-orphan-worktree.

---

## § 5: Merge planning

When at least one issue reaches `merge-ready` (`state = "merge-ready"` plus `domain.issue.phase = "merge-ready"`):

1. Invoke `⤵ workflows/linear/merge-plan.md`.
2. Build/rebuild `pr-conflict-graph` from live PR file lists.
3. Merge the next safe PR using smallest-scope-first conflict ordering.
4. After a merge, set `state = "merged"`, `domain.issue.outcome = "merged"`, and remove the entry from the active merge queue.
5. If a remaining PR becomes `BEHIND`, transition it back to `submitting` so its pane can rebase.

---

## § 6: Issue cycle summary

After generic session status, emit the issue summary expected by current users. This chat table is not the Rust dashboard.

For each tracked issue, gather:

- **Phase** — `flightdeck-state phase <ISSUE>` from orchestration workflow state, falling back to `fd:<state>`.
- **Last prompt** — most recent `decisions_log[-1].prompt_tag` plus a short prompt excerpt.
- **Answer** — most recent `decisions_log[-1].answer`.
- **PR** — `domain.issue.pr_number`.

<output_format>
### ✈️ Flightdeck cycle [N] · [SESSION] · [ISO8601]

| Issue | Phase | Last prompt | Answer | PR |
|-------|-------|-------------|--------|----|
| [ISSUE_ID] | [PHASE] | [PROMPT_EXCERPT or —] | [ANSWER_EXCERPT or —] | [#N or —] |

Merge queue: [ISSUE_IDS comma-separated, or —] · Conflicts: [edges or none] · Paused: [issue_id and reason, or —]
</output_format>

---

## § 7: Termination

At the end of each issue cycle:

1. Count issue entries by state/outcome. Terminal issue outcomes are `merged`, `aborted`, and `dead` (generic `complete`, `cancelled`, `dead`).
2. If every tracked issue is terminal and no issue is `prompting`, increment the debounce counter.
3. At `FLIGHTDECK_DEBOUNCE_CYCLES` consecutive terminal cycles (default 2), invoke `⤵ workflows/linear/terminate.md`.
4. Otherwise return to `session-watch.md` § 5 for ack/yield.

---

## § 8: Compaction recovery

On re-entry, run the generic recovery in `session-watch.md` first, then issue-specific recovery:

1. Re-fingerprint registered issue panes.
2. Recompute issue state from fresh `pane-poll --batch -` output and orchestration workflow state.
3. Preserve `unknown_since` so force-merge timers do not reset.
4. Recompute the conflict graph against current PR file lists.
5. Re-evaluate `paused_for_user`; if the user acted in the pane, reclassify and proceed.

---

## Returns

To flightdeck's issue loop (`workflows/linear/start.md` § 1), after `terminate.md` writes the issue summary and archives state.
