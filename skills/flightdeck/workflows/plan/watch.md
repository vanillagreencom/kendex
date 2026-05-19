# Workflow: `plan watch` — Plan-File Lane Extension

Plan-file master loop. It reuses the generic `workflows/shared/session-watch.md` loop for daemon/poll/generic prompt plumbing, then adds plan dependency resolution and GitHub PR/CI/review lifecycle handling for each item.

**Inputs**: optional plan item ids. When omitted, recover from `<FLIGHTDECK_STATE_DIR>/flightdeck-state-<SESSION>.json`.

**Pre-conditions**:
- `$TMUX` set.
- Plan lane dependencies only: `github` and `worktree`. Do not load `linear` or `project-management`.
- Plan entries store metadata under `entry.domain.plan_item`.

**Post-condition**: plan item entries reach `merged`, `aborted`, or `dead`; `workflows/plan/terminate.md` writes the plan summary.

---

## § 0: Enter through the generic loop

Run `⤵ workflows/shared/session-watch.md` for common mechanics:

1. Initialize/resume master state.
2. Reconcile entries through `flightdeck-state tracked-entries` / `pane-registry list --format json`.
3. Spawn/attach `flightdeck-daemon`.
4. Poll non-terminal entries with `pane-poll --batch -`.
5. Route generic prompts to `workflows/shared/session-handle-prompt.md`.
6. Ack and yield.

Plan mode adds only the sections below. Do not duplicate generic daemon logic.

---

## § 1: Register / refresh plan entries

For each item id in the active plan graph:

1. Ensure an entry exists with `entry.domain.plan_item.item_id == <ITEM_ID>`.
2. Require no `entry.domain.issue` and no `entry.domain.github_issue`; those keys belong to Linear and GitHub issue lanes.
3. If a pre-existing entry uses another domain key, do not mutate it in place. Pause with `reason="domain-mismatch"`.
4. Reconcile only liveness, adapter metadata, `pr_number`, `merge_commit`, `scope_files_actual`, and `phase`. Preserve decisions and timers such as `unknown_since`.
5. Treat `domain.plan_item.plan_path` as traceability only after plan start. Do not pause, block refresh, or block newly unblocked spawns because the mutable source plan moved or disappeared. Spawning/recovery must instead require and verify `domain.plan_item.brief_artifact_path`, `domain.plan_item.brief_sha256`, and `domain.plan_item.plan_snapshot_sha256` under the canonical state-owned `plan-briefs` root as described in § 7.

---

## § 2: Plan state mapping

| Plan state | Generic equivalent | Domain fields |
|------------|--------------------|---------------|
| `waiting-on-dependency` | `waiting` | `domain.plan_item.phase = "waiting-on-dependency"` |
| `spawning` | `spawning` | atomic spawn claim held; worktree/pane transaction in progress |
| `in-progress` | `submitting` | child work in progress |
| `prompting` | `prompting` | `substate=<tag>` |
| `merge-ready` | `ready` | `domain.plan_item.phase = "merge-ready"` |
| `merged` | `complete` | `domain.plan_item.phase = "merged"`, `merge_commit` set |
| `aborted` | `cancelled` | `domain.plan_item.phase = "aborted"` |
| `failed` | `failed` | `domain.plan_item.error = {phase, reason, stderr}` |
| `dead` | `dead` | pane/window lost |

---

## § 3: Poll additions

During `session-watch.md` § 2, include plan domain metadata in the poll input. For plan entries only, pass the poll row as PR-capable so PR prompt tags route to the plan handler; do not mutate the stored entry kind.

```bash
POLL_INPUT=$(jq '[.[]
  | select(.domain.plan_item? != null)
  | select((.state // "waiting") as $s | ["waiting","prompting","submitting","ready","merge-ready"] | index($s))
  | {id, kind:"issue", issue:.domain.plan_item.item_id, pane_id, pane_target, harness, cwd, worktree, pr_number,
      oc_url, oc_session_id, cc_url, cc_transcript,
      pi_bridge_pid, pi_bridge_socket, cx_ws, cx_thread_id,
      domain}
]' <<< "$REGISTRY_JSON")
```

Plan PR tags shared with the GitHub lane:
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

Do not route Linear-only tags in plan mode: `audit-relation-prompt`, `descope-related`, `external-fix-suggestions`, `cycle-fix-suggestions`. If one appears, set `paused_for_user = {entry_id:<ITEM_ID>, reason:"domain-mismatch", prompt_text:<excerpt>}`.

`terminal-state-reached` on a plan entry invokes `⤵ workflows/plan/close-item.md <ITEM_ID>` after generic completion detection.

---

## § 4: Plan prompt routing

Process prompting plan items sequentially:

1. Generic tags route to `workflows/shared/session-handle-prompt.md` first.
2. Plan PR tags route to:
   ```
   ⤵ workflows/plan/handle-prompt.md <ITEM_ID> <TAG>
   ```
3. If either handler sets `paused_for_user`, stop the cycle and yield.
4. Re-poll the same item after a response before moving to the next prompt.

---

## § 5: `merge-ready-but-unknown` timer handling

When a prompt or poll classifies `merge-ready-but-unknown`:

1. If `FLIGHTDECK_AUTO_MERGE=0`, set `paused_for_user = {entry_id:<ITEM_ID>, reason:"auto-merge-disabled", prompt_text:<state summary>}` and yield. Do not answer wait, Merge, force-merge, or transition to `force-merge-confirm` while auto-merge is disabled.
2. Re-run authoritative state:
   ```bash
   gh pr view <PR> --json mergeStateStatus,reviewDecision,statusCheckRollup,files
   ```
3. If `mergeStateStatus` is no longer `UNKNOWN`, clear/ignore `unknown_since` and route to the matching handler (`merge-now`, `pr-merge-conflict`, `behind`, or blocked escalation).
4. If `UNKNOWN` persists and `unknown_since` is missing, set it to now on the tracked entry.
5. If elapsed `< FLIGHTDECK_FORCE_MERGE_AFTER_SECS` (default 240), emit structured log `plan-merge-ready-but-unknown item=<ITEM_ID> pr=<PR> elapsed=<secs>` and yield for daemon wake.
6. If elapsed `>= FLIGHTDECK_FORCE_MERGE_AFTER_SECS`, re-check `FLIGHTDECK_AUTO_MERGE`; if it is `0`, set `paused_for_user.reason="auto-merge-disabled"` and do not transition to `force-merge-confirm`.
7. If elapsed `>= FLIGHTDECK_FORCE_MERGE_AFTER_SECS`, auto-merge is enabled, and the strict force-merge predicate holds, transition to `force-merge-confirm`.
8. If elapsed passed threshold but predicate fails, set `paused_for_user` with the failed predicates.

Strict force-merge predicate requires: `reviewDecision == "APPROVED"` (strict; do not substitute unset review with "no pending reviewers"), all checks `SUCCESS` or `SKIPPED`, disjoint PR files from recent main changes, `unknown_since > FLIGHTDECK_FORCE_MERGE_AFTER_SECS`, and no GitHub authoritative conflict state.

---

## § 6: gh-CLI failure handling

Every `gh pr view`, `gh pr edit`, `gh pr create`, and label/check inspection call in plan workflows follows the same failure policy:

1. Retry once after 2s.
2. On second failure, emit activity warning:
   ```text
   plan-gh-cli-unavailable item=<ITEM_ID> command=<cmd> stderr=<stderr>
   ```
3. Set:
   ```json
   {"entry_id":"<ITEM_ID>","reason":"gh-cli-unavailable","prompt_text":"<command>\n<stderr>"}
   ```
   under `paused_for_user`.
4. Surface one chat/activity sidecar line: `GitHub CLI unavailable for plan item <ITEM_ID>; paused.`
5. Do not merge, close, rebase, spawn dependents, or tear down while `gh` state is unavailable.

If a child pane completes its turn without producing a valid PR URL, master treats this as failed PR creation even if the pane text says the implementation is done. Grep stdout/stderr for a PR URL, validate it as a GitHub pull URL, and on missing or malformed URL set `paused_for_user = {entry_id:<ITEM_ID>, reason:"plan-pr-create-failed", prompt_text:<captured stderr or "child completed without PR URL">}`.

---

## § 7: Dependency-edge resolution

After `workflows/plan/close-item.md` verifies an item merged:

1. Find waiting entries whose `domain.plan_item.depends_on` are all merged with non-null `merge_commit`.
2. Verify the immutable plan item artifacts are present and current enough to proceed:
   - Do not reread `domain.plan_item.plan_path` to rebuild child briefs; the source plan may have changed after start.
   - `domain.plan_item.brief_artifact_path` exists for the unblocked item.
   - The artifact hash matches `domain.plan_item.brief_sha256`.
   - `domain.plan_item.plan_snapshot_sha256` is recorded so the artifact can be traced to the frozen source snapshot.
   - Each merged dependency still has an entry with `domain.plan_item.phase == "merged"` and a live or already-archived worktree record.
3. Before any worktree mutation for a dependent item, atomically claim each unblocked item under the Flightdeck state-lock:
   - Compare-and-swap `entry.state` from `waiting` to `spawning`.
   - Refuse to spawn if `entry.domain.plan_item.pr_number !== null`.
   - Refuse to spawn if `entry.domain.plan_item.merge_commit !== null`.
   - Refuse to spawn if a live pane is already registered for this entry.
4. Create the dependent item's worktree.
5. Write its `<worktree>/tmp/brief.md` from the verified immutable brief artifact and check the write return code. Omitted orchestration context must not be reintroduced for dependency-spawned items.
6. Spawn via `flightdeck-session start --kind workflow --prompt "Read tmp/brief.md and execute end-to-end. Print the PR URL as the LAST line."` and check the return code.
7. Re-register / restore `entry.domain.plan_item` while preserving launch metadata, then transition item to in-progress with `state="submitting"` and `domain.plan_item.phase="in-progress"`.
8. On any create/write/spawn/register failure, remove the brief if written, kill any spawned-but-unregistered pane, mark `state="failed"` with `domain.plan_item.error = {phase:"<PHASE>", reason:"<REASON>", stderr:"<STDERR>"}`, emit activity, and continue to the next unblocked item.
9. Yield.

If multiple items become unblocked simultaneously, spawn them in dependency-graph topological order. Items without dependency overlap may spawn in parallel; overlapping items should stay sequential so conflict graphs remain readable.

---

## § 8: Plan cycle summary

For each tracked plan item, gather:

- Phase: `fd:<state>` or `domain.plan_item.phase`.
- Last prompt/answer from `decisions_log[-1]`.
- PR from `domain.plan_item.pr_number`.
- UNKNOWN timer age from `unknown_since`, if set.
- Dependencies and dependents.

<output_format>
### ✈️ Flightdeck plan cycle [PLAN_TITLE] · [SESSION] · [ISO8601]

| Item | Phase | Last prompt | Answer | PR | UNKNOWN | Dependencies |
|------|-------|-------------|--------|----|---------|--------------|
| [ITEM_ID] | [PHASE] | [PROMPT_EXCERPT or —] | [ANSWER_EXCERPT or —] | #[PR or —] | [elapsed or —] | [ITEM_ID, ... or —] |

Paused: [item id and reason, or —]
</output_format>

---

## § 9: Termination

1. Count plan entries by `entry.domain.plan_item` presence.
2. Terminal outcomes are `merged`, `aborted`, `failed`, and `dead`.
3. At `FLIGHTDECK_DEBOUNCE_CYCLES` consecutive terminal cycles (default 2), invoke `⤵ workflows/plan/terminate.md`.
4. Mixed sessions with Linear, GitHub issue, generic, and plan entries are partitioned by domain key; all applicable lane summaries are produced.

---

## § 10: Compaction recovery

On re-entry:

1. Run generic recovery from `session-watch.md` first.
2. Re-read `entry.domain.plan_item` for item id, dependencies, PR, merge commit, worktree, and actual file count.
3. Preserve `unknown_since` so the UNKNOWN timer does not reset.
4. Re-run `gh pr view` for open PRs unless `gh` is unavailable; unavailable follows § 6.
5. Re-evaluate dependency edges and `paused_for_user`; if the user fixed the issue in the pane or via GitHub, reclassify and proceed.

## Returns

To the daemon ack/yield path or to `plan/terminate.md` when all plan entries are terminal.
