# Workflow: `github watch` — GitHub Issue-Mode Extension

GitHub issue master loop. It reuses the generic `workflows/shared/session-watch.md` loop for daemon/poll/generic prompt plumbing, then adds GitHub PR/CI/review lifecycle handling.

**Inputs**: optional GitHub issue numbers. When omitted, recover from `tmp/flightdeck-state-<SESSION>.json`.

**Pre-conditions**:
- `$TMUX` set.
- GitHub lane dependencies only: `github` and `worktree`. Do not load `linear` or `project-management`.
- Entries for this lane store metadata under `entry.domain.github_issue`.

**Post-condition**: GitHub issue entries reach `merged`, `aborted`, or `dead`; `workflows/github/terminate.md` writes the GitHub summary.

---

## § 0: Enter through the generic loop

Run `⤵ workflows/shared/session-watch.md` for common mechanics:

1. Initialize/resume master state.
2. Reconcile entries through `flightdeck-state tracked-entries` / `pane-registry list --format json`.
3. Spawn/attach `flightdeck-daemon`.
4. Poll non-terminal entries with `pane-poll --batch -`.
5. Route generic prompts to `workflows/shared/session-handle-prompt.md`.
6. Ack and yield.

GitHub mode adds only the sections below. Do not duplicate generic daemon logic.

---

## § 1: Register / refresh GitHub entries

For each issue number in the spawn batch:

1. Ensure a `kind="issue"` entry exists.
2. Require `entry.domain.github_issue.number == <N>`.
3. Require no GitHub lane metadata under `entry.domain.issue`; that key is Linear-only.
4. If a pre-existing entry uses `domain.issue`, do not mutate it in place. Pause with `reason="domain-mismatch"` so a human can decide whether this is a Linear session.
5. Reconcile only liveness, adapter metadata, `pr_number`, `merge_commit`, and `scope_files_actual`. Preserve decisions and timers such as `unknown_since`.

---

## § 2: GitHub state mapping

| GitHub state | Generic equivalent | Domain fields |
|--------------|--------------------|---------------|
| `waiting` | `waiting` | unchanged |
| `prompting` | `prompting` | `substate=<tag>` |
| `submitting` | `submitting` | child work in progress |
| `merge-ready` | `ready` | `domain.github_issue.phase = "merge-ready"` |
| `merged` | `complete` | `domain.github_issue.outcome = "merged"`, `merge_commit` set |
| `aborted` | `cancelled` | `domain.github_issue.outcome = "aborted"` |
| `dead` | `dead` | pane/window lost |

---

## § 3: GitHub poll additions

During `session-watch.md` § 2, include GitHub domain metadata in the poll input:

```bash
POLL_INPUT=$(jq '[.[]
  | select((.state // "waiting") as $s | ["waiting","prompting","submitting","ready","merge-ready"] | index($s))
  | {id, kind, issue, pane_id, pane_target, harness, cwd, worktree, pr_number,
      oc_url, oc_session_id, cc_url, cc_transcript,
      pi_bridge_pid, pi_bridge_socket, cx_ws, cx_thread_id,
      domain}
]' <<< "$REGISTRY_JSON")
```

GitHub issue-only tags:
- `cleanup-prompt`
- `bot-review-wait-stuck`
- `rebase-multi-choice`
- `force-push-prompt`
- `merge-now`
- `merge-ready-but-unknown`
- `force-merge-confirm`
- `multi-select-tabbed`
- `stale-no-pr-branch`
- `stale-orphan-worktree`

Do not route Linear-only tags in GitHub mode: `audit-relation-prompt`, `descope-related`, `external-fix-suggestions`, `cycle-fix-suggestions`. If one appears, set `paused_for_user = {issue_id: <N>, reason: "domain-mismatch", prompt_text: <excerpt>}`.

`terminal-state-reached` on a GitHub entry invokes `⤵ workflows/github/close-issue.md <N>` after generic completion detection.

---

## § 4: GitHub prompt routing

Process prompting GitHub issues sequentially:

1. Generic tags route to `workflows/shared/session-handle-prompt.md` first.
2. GitHub issue-only tags route to:
   ```
   ⤵ workflows/github/handle-prompt.md <N> <TAG>
   ```
3. If either handler sets `paused_for_user`, stop the cycle and yield.
4. Re-poll the same issue after a response before moving to the next prompt.

---

## § 5: `merge-ready-but-unknown` timer handling

When a prompt or poll classifies `merge-ready-but-unknown`:

1. If `FLIGHTDECK_AUTO_MERGE=0`, set `paused_for_user = {issue_id:<N>, reason:"auto-merge-disabled", prompt_text:<state summary>}` and yield. Do not answer wait, Merge, force-merge, or transition to `force-merge-confirm` while auto-merge is disabled.
2. Re-run authoritative state:
   ```bash
   gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup,files
   ```
3. If `mergeStateStatus` is no longer `UNKNOWN`, clear/ignore `unknown_since` and route to the matching handler (`merge-now`, `pr-merge-conflict`, `behind`, or blocked escalation).
4. If `UNKNOWN` persists and `unknown_since` is missing, set it to now on the tracked entry.
5. If elapsed `< FLIGHTDECK_FORCE_MERGE_AFTER_SECS` (default 240), emit structured log `merge-ready-but-unknown issue=<N> pr=<PR> elapsed=<secs>` and yield for daemon wake.
6. If elapsed `>= FLIGHTDECK_FORCE_MERGE_AFTER_SECS`, re-check `FLIGHTDECK_AUTO_MERGE`; if it is `0`, set `paused_for_user.reason="auto-merge-disabled"` and do not transition to `force-merge-confirm`.
7. If elapsed `>= FLIGHTDECK_FORCE_MERGE_AFTER_SECS`, auto-merge is enabled, and the force-merge predicate from `patterns/conflict-detection.md` holds, transition to `force-merge-confirm`.
8. If elapsed passed threshold but predicate fails, set `paused_for_user` with the failed predicates.

Force-merge predicate requires: `reviewDecision == "APPROVED"` (strict; do not substitute unset review with "no pending reviewers"), all required checks `SUCCESS` or `SKIPPED`, disjoint PR files from recent main changes, `unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS`, and no GitHub authoritative conflict state.

---

## § 6: gh-CLI failure handling

Every `gh pr view`, `gh pr edit`, `gh issue view`, and `gh issue close` call in GitHub workflows follows the same failure policy:

1. Retry once after 2s.
2. On second failure, emit activity warning:
   ```text
   gh-cli-unavailable issue=<N> command=<cmd> stderr=<stderr>
   ```
3. Set:
   ```json
   {"issue_id":"<N>","reason":"gh-cli-unavailable","prompt_text":"<command>\n<stderr>"}
   ```
   under `paused_for_user`.
4. Surface one chat/activity sidecar line: `GitHub CLI unavailable for issue <N>; paused.`
5. Do not merge, close, rebase, or tear down while `gh` state is unavailable.

---

## § 7: GitHub cycle summary

For each tracked GitHub issue, gather:

- Phase: `fd:<state>` or `domain.github_issue.phase`.
- Last prompt/answer from `decisions_log[-1]`.
- PR from `domain.github_issue.pr_number`.
- UNKNOWN timer age from `unknown_since`, if set.

<output_format>
### ✈️ Flightdeck GitHub cycle [N] · [SESSION] · [ISO8601]

| Issue | Phase | Last prompt | Answer | PR | UNKNOWN |
|-------|-------|-------------|--------|----|---------|
| #[N] | [PHASE] | [PROMPT_EXCERPT or —] | [ANSWER_EXCERPT or —] | #[PR or —] | [elapsed or —] |

Paused: [issue number and reason, or —]
</output_format>

---

## § 8: Termination

1. Count GitHub issue entries by `entry.domain.github_issue` presence.
2. Terminal outcomes are `merged`, `aborted`, and `dead`.
3. At `FLIGHTDECK_DEBOUNCE_CYCLES` consecutive terminal cycles (default 2), invoke `⤵ workflows/github/terminate.md`.
4. Mixed sessions with Linear and GitHub entries are partitioned by domain key; both lane summaries are produced.

---

## § 9: Compaction recovery

On re-entry:

1. Run generic recovery from `session-watch.md` first.
2. Re-read `entry.domain.github_issue` for issue number, PR, merge commit, worktree, and actual file count.
3. Preserve `unknown_since` so the UNKNOWN timer does not reset.
4. Re-run `gh pr view` for open PRs unless `gh` is unavailable; unavailable follows § 6.
5. Re-evaluate `paused_for_user`; if the user fixed the issue in the pane or via GitHub, reclassify and proceed.

## Returns

To the daemon ack/yield path or to `github/terminate.md` when all GitHub entries are terminal.