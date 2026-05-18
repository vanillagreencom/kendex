# Workflow: `github watch` — GitHub Issue-Mode Extension

GitHub issue-mode master loop. It extends the generic `workflows/shared/session-watch.md` loop with PR/CI/review decisions and the GitHub issue lifecycle states.

**Inputs**: `[ISSUE_NUMBERS]` from `github start`, or an existing Flightdeck state file on compaction recovery.

**Pre-conditions**:
- `$TMUX` set.
- `workflows/shared/session-watch.md` is the core loop for state init, entry reconciliation, daemon startup, polling, generic prompt routing, and ack/yield.
- GitHub-mode skills are loaded now: `github` and `worktree`. Generic `session-watch.md` does not load or require them.
- `[ISSUE_NUMBERS]` non-empty or `tmp/flightdeck-state-<SESSION>.json` exists.

**Post-condition**: GitHub issue entries reach a terminal issue outcome (`merged`, `aborted`, or `dead`), `terminate.md` writes the GitHub summary, and control returns to the watch loop.

---

## § 0: Enter through the generic loop

Run `⤵ workflows/shared/session-watch.md` for the common mechanics:

1. Initialize/resume master state.
2. Reconcile entries through `flightdeck-state tracked-entries` / `pane-registry list --format json`.
3. Spawn/attach `flightdeck-daemon`.
4. Poll each non-terminal entry with `pane-poll --batch -`.
5. Route generic prompts to `session-handle-prompt.md`.
6. Ack and yield.

GitHub mode adds the sections below before/after those generic steps. Do not duplicate generic daemon or prompt-loop logic here.

---

## § 1: Register / refresh GitHub issue entries

For each `ISSUE_ID` in the spawn batch, ensure a `kind="issue"` entry exists. Numeric issue ids are used as entry ids.

1. Require `ISSUE_ID` to match `^[0-9]+$`.
2. Look up the spawned window by issue id (window name from `open-terminal --tracker github`).
3. Determine harness, worktree, pane index, stable `%pane_id`, and adapter metadata.
4. Fetch issue metadata for display and validation:
   ```bash
   gh issue view "$ISSUE_ID" --json number,title,state,url,labels,closed,closedAt
   ```
5. Register through the issue alias or explicit entry path:
   ```bash
   .agents/skills/flightdeck/scripts/pane-registry init "$ISSUE_ID" \
     --window <window-name> --harness <h> --worktree <path> --pane-index <N>
   ```
   This writes `.entries[ISSUE_ID]` with `kind="issue"` and GitHub issue metadata under `domain.issue`.
6. If resuming, do not overwrite existing decisions or domain fields; reconcile only liveness and pane metadata.

---

## § 2: GitHub issue state mapping

The generic state enum is canonical. GitHub issue-mode entries may carry one of the issue-specific lifecycle states directly in `state`; renderers treat them as terminal/near-terminal alongside the generic enum.

| GitHub issue-mode state | Generic equivalent | Domain fields |
|-------------------------|--------------------|---------------|
| `waiting` | `waiting` | unchanged |
| `prompting` | `prompting` | `substate=<tag>` |
| `submitting` | `submitting` | issue agent is working |
| `merge-ready` | `ready` | `domain.issue.phase = "merge-ready"` |
| `merged` | `complete` | `domain.issue.outcome = "merged"` |
| `aborted` | `cancelled` | `domain.issue.outcome = "aborted"` |
| `dead` | `dead` | pane/window lost |

GitHub workflows write `state` as `merge-ready` / `merged` / `aborted` and set the matching `domain.issue.phase` or `domain.issue.outcome`. Generic readers treat `domain.issue.phase / outcome` as the issue-specific extension.

---

## § 3: GitHub poll additions

During `session-watch.md` § 2, GitHub issue entries add these checks after generic structured events and before GitHub handler routing:

GitHub mode extends the generic `POLL_INPUT` with issue-domain metadata for `pane-poll` orphan terminal cross-checks and PR/worktree-aware handlers:

```bash
POLL_INPUT=$(jq '[.[]
  | select((.state // "waiting") as $s | ["waiting","prompting","submitting","ready","merge-ready"] | index($s))
  | {id, kind, issue, pane_id, pane_target, harness, cwd, worktree, pr_number,
      oc_url, oc_session_id, cc_url, cc_transcript,
      pi_bridge_pid, pi_bridge_socket, cx_ws, cx_thread_id}
]' <<< "$REGISTRY_JSON")
```

1. **Start check** — if `domain.issue.orchestration_started` is false, look for `tmp/workflow-state-<ISSUE>.json`. If absent beyond `FLIGHTDECK_HIJACK_GRACE_SECS` (default 90), set `paused_for_user = {issue_id, reason: "issue-agent-never-started", prompt_text: ...}`.
2. **GitHub issue-only tags** — route only when `kind == "issue"`. Tags include:
   - `cleanup-prompt`
   - `bot-review-wait-stuck`
   - `rebase-multi-choice`
   - `force-push-prompt`
   - `merge-now`
   - `force-merge-confirm`
   - `multi-select-tabbed`
3. **Domain guard** — if an issue-only tag appears on `kind=adhoc` or any non-issue entry, `prompt-classify --entry-kind` / `pane-poll` reports `domain-mismatch`. Log a warning, do not run GitHub handlers, and surface a master question through `paused_for_user`.
4. **Generic tags on issue entries** — `oc-question`, `pi-question`, `bash-permission-prompt`, `awaiting-direction`, safe `generic-multi-choice`, `terminal-state-reached`, and `pi-bg-task-exit` first route through `session-handle-prompt.md`. After it returns, resume this GitHub issue loop with domain state intact.

`terminal-state-reached` on a GitHub issue entry invokes `⤵ workflows/github/close-issue.md <ISSUE_ID>` after the generic completion signal. `close-issue.md` performs the two-signal verification, closes the GitHub issue if the PR merge did not auto-close it, records the outcome, and tears down the window when safe.

---

## § 4: GitHub issue decision routing

Process prompting GitHub issues sequentially. For each issue in `state == "prompting"` and not debounced:

1. If `<SUBSTATE_TAG>` is generic, call:
   ```
   ⤵ workflows/shared/session-handle-prompt.md <ISSUE_ID> <SUBSTATE_TAG>
   ```
   Then re-poll and continue issue flow.
2. If `<SUBSTATE_TAG>` is GitHub issue-only, call:
   ```
   ⤵ workflows/github/handle-prompt.md <ISSUE_ID> <SUBSTATE_TAG>
   ```
3. If either handler sets `paused_for_user`, stop the cycle and yield to the user.
4. After a confirmed response, re-poll the same issue before moving to the next prompting issue.

The GitHub handler surface is limited to PR/CI/review workflow logic: cleanup worktree, bot-review/CI continuation, rebase, force-push, merge, force-merge confirmation, and tabbed selections that reference PR review or merge/rebase actions.

---

## § 5: PR readiness checks

When a GitHub issue reaches `merge-ready` (`state = "merge-ready"` plus `domain.issue.phase = "merge-ready"`):

1. Re-fetch PR state for `domain.issue.pr_number`:
   ```bash
   gh pr view <PR> --json state,mergeStateStatus,reviewDecision,statusCheckRollup,files,labels
   ```
2. If review is approved, all required checks are `SUCCESS` or `SKIPPED`, and merge state is clean, direct the per-issue pane through the `merge-now` prompt path.
3. If merge state is `UNKNOWN`, record/read `unknown_since` and let `handle-prompt.md` apply the bounded force-merge predicate only when `force-merge-confirm` appears.
4. If checks failed, reviews requested changes, or conflicts are present, transition back to `submitting` so the issue pane can fix and re-prompt.
5. Do not build a cross-issue merge queue in GitHub mode. Each GitHub issue is gated independently at prompt time.

---

## § 6: GitHub issue cycle summary

After generic session status, emit the GitHub issue summary expected by current users. This chat table is not the Rust dashboard.

For each tracked GitHub issue, gather:

- **Phase** — `flightdeck-state phase <ISSUE>` from workflow state, falling back to `fd:<state>`.
- **Last prompt** — most recent `decisions_log[-1].prompt_tag` plus a short prompt excerpt.
- **Answer** — most recent `decisions_log[-1].answer`.
- **PR** — `domain.issue.pr_number`.
- **Issue state** — `gh issue view <ISSUE> --json state` when cheap.

<output_format>
### ✈️ Flightdeck GitHub cycle [N] · [SESSION] · [ISO8601]

| Issue | Phase | Last prompt | Answer | PR | GitHub state |
|-------|-------|-------------|--------|----|--------------|
| #[ISSUE_ID] | [PHASE] | [PROMPT_EXCERPT or —] | [ANSWER_EXCERPT or —] | [#N or —] | [OPEN|CLOSED|—] |

Paused: [issue_id and reason, or —]
</output_format>

---

## § 7: Termination

At the end of each GitHub issue cycle:

1. Count GitHub issue entries by state/outcome. Terminal issue outcomes are `merged`, `aborted`, and `dead` (generic `complete`, `cancelled`, `dead`).
2. If every tracked GitHub issue is terminal and no issue is `prompting`, increment the debounce counter.
3. At `FLIGHTDECK_DEBOUNCE_CYCLES` consecutive terminal cycles (default 2), invoke `⤵ workflows/github/terminate.md`.
4. Otherwise return to `session-watch.md` § 5 for ack/yield.

---

## § 8: Compaction recovery

On re-entry, run the generic recovery in `session-watch.md` first, then GitHub issue-specific recovery:

1. Re-fingerprint registered issue panes.
2. Recompute issue state from fresh `pane-poll --batch -` output and workflow state.
3. Preserve `unknown_since` so force-merge timers do not reset.
4. Re-fetch PR and GitHub issue state for active issue entries.
5. Re-evaluate `paused_for_user`; if the user acted in the pane, reclassify and proceed.

---

## Returns

To flightdeck's GitHub issue loop (`workflows/github/start.md` § 4), after `terminate.md` writes the GitHub issue summary and archives state.
