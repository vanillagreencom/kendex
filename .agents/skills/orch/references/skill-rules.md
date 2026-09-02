# Skill rules

Rules the orch workflows execute. [../SKILL.md](../SKILL.md) § Skill Rules
routes here; load this file when a workflow cites one of these sections.

## Delegation

| Pattern | When | Flow |
|---------|------|------|
| Spawn + message | Fresh dev, QA, or review agents | Spawn → send delegation |
| Message only | Re-delegation to a live agent | Send delegation to the running agent |
| Self-create | No team context | Full instructions in the prompt |

**No duplicate spawns.** Never spawn a fresh agent while the same role is alive. Reuse by stored ID; respawn only after one recovery attempt or a confirmed stuck/closed status.

### Format Tags Are Literal

`<delegation_format>` and `<output_format>` are exact: fill `[PLACEHOLDERS]`, omit lines whose placeholder is empty, add nothing else, keep structure and field names verbatim. Placeholders hold schema fields only, never process prose. When a tagged block precedes an ask-user step, present the filled block first, then ask.

### Single Return Message

An agent sends exactly one completion message. A second return is a violation: diff it against the first and flag unrequested commits.

**Codex dual-channel completion.** The Codex runtime delivers one completion over two channels, a `send_input` `MESSAGE` then a `FINAL_ANSWER` echoing it: treat the pair as **one completion** and deduplicate it. Still diff them; a new commit or extra changes is a genuine second return and is flagged.

---

## Agent Lifecycle

`SPAWN → DELEGATE → WORK → RETURN (single message) → IDLE / RE-DELEGATE`.

**Dev agents persist** for the whole session, re-delegated for every fix round. Shut down only on explicit user request or a confirmed stall.

**Reviewer persistence is budget-conditional.** Reviewer slots = `orch-env REVIEWER_SLOT_BUDGET 0` minus the primary session minus live `child_sessions` entries whose `status` is `active` (no `status` counts as active), minimum 1, recomputed at every review-cycle start; `0` means unlimited. Within budget, reuse reviewers by exact name and spawn only the missing subset. Over budget, or on a thread-limit spawn error, run waves and persist the wave size as `reviewer_slots_observed`. Review state lives on disk, never in reviewer session memory.

QA agents spawn and shut down per agent.

### Round Closure

The orchestrator owns round closure. Every dev/QA delegation carries three mechanics:

1. **Round token.** Immediately before delegating, run `workflow-state new-round-id [ISSUE_ID] dev_round_id` for the `Round ID:` line and re-stamp `dev_delegated_at`. A fix round also runs `dev-round-write`, which records HEAD, items, and optional `Adds:` paths in an immutable round record under the worktree's `tmp/`. A missing or mismatched record requires a fresh round; never recreate one after delegation. The round that cuts an oversized branch is stamped `dev-round-write --cut`, which is what lets it be recorded at all; acceptance then refuses it unless the branch came back to the cap.
2. **Arm a single-shot wall-clock watchdog** at the same moment: one backgrounded `dev-artifact-check --wait 600 --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`): returns when the artifact lands (`accept`/`retry`) or at the deadline (`wait`). Run A/B on its return; re-arm only on a new escalation step, never poll. [artifact-checks.md](artifact-checks.md).
3. **Run the check on every wake and at the deadline.** Never classify from wording or elapsed time. `dev-artifact-check --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`) prints `verdict`; act on it.

The acceptance table lives in the delegating workflow (`dev-start.md` § 3, `dev-fix.md` § 2, `review-pr-comments.md` § 6.1); the return message is display-only; tracker corroboration (**B**) applies only where that table names it. `ci-fix.md` (no dev-return artifact) is accepted by its return message plus the escalation ladder.

**Escalation.** Only after the 10-minute quiet window AND a confirmed stall (task status unchanged, no session-log entries for 10+ minutes, or the process exited): re-message once naming the missing step → wait 5 minutes → still inactive: shut down, re-create tasks, respawn, re-delegate. The respawn takes a fresh runtime instance and a fresh round id; the canonical agent name is the identity every record is keyed on and stays as it was.

---

## Coordination

**Containers.** An issue with children or an `agent:multi` label and no `(one PR)` title marker is a CONTAINER. A container is never orchestrated and never gets a PR. Each child is the PR unit, selection operates on unblocked children, and the container closes LAST when its final child merges.

**Ancestor gate.** Every selected issue walks its full `parent_id` chain. An enclosing `(one PR)` bundle REPLACES the selection. Dispatch requires the item's own `state_type` non-terminal and the union of its `blocked_by_open` with every container ancestor's `blocked_by_open` empty. `blocked_by` remains relation history and does not decide dispatch.

**Sequencing.** Order by data flow (Creates ↔ Consumes), never by agent ordering; existing blocking relations outrank inference. Cross-bundle relations go on the parent issues; dependent children of one container get child-blocks-child relations, which ARE the execution order; only an explicit `(one PR)` bundle leaves intra-bundle ordering to the delegated session.

**Single-PR bundles.** Exactly three opt-ins delegate all children as one session: a parent marked `(one PR)`, a delegation carrying `Audit Bundle: yes`, or a leaf issue with an internal checklist. One composite task per sub-issue; multi-domain bundles process groups sequentially, collecting handoff notes between groups.

**Tracked issue creation.** Route every tracked issue through TPM (project-management), never create one directly from an orchestration session, except where a workflow step specifies it with its label set (`plan-issues`, `start-new`, the `merge-pr` rebundle).
