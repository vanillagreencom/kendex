# Skill rules

Rules the orch workflows execute. [../SKILL.md](../SKILL.md) § Skill Rules routes here; load this file when a workflow cites one of these sections.

## Delegation

| Pattern | When | Flow |
|---------|------|------|
| Spawn + message | Fresh dev, QA, or review agents | Spawn → send delegation |
| Message only | Re-delegation to a live agent | Send delegation to the running agent |
| Self-create | No team context | Full instructions in the prompt |

**No duplicate spawns.** Never spawn a fresh agent while the same role is alive. Reuse by stored ID; respawn only after one recovery attempt or a confirmed stuck/closed status.

### Format Tags Are Literal

`<delegation_format>` and `<output_format>` are exact: fill `[PLACEHOLDERS]`, omit lines whose placeholder is empty, add nothing else, keep structure and field names verbatim. Placeholders hold schema fields only, never process prose. When a tagged block precedes an ask-user step, present the filled block first, then ask; in a lane that block goes to the ask gate's own file instead ([§ Lane Output](#lane-output)).

### Single Return Message

An agent sends exactly one completion message. A second return is a violation: diff it against the first and flag unrequested commits.

**Codex dual-channel completion.** The Codex runtime delivers one completion over two channels, a `send_input` `MESSAGE` then a `FINAL_ANSWER` echoing it: treat the pair as **one completion** and deduplicate it. Still diff them; a new commit or extra changes is a genuine second return and is flagged.

---

## Agent Lifecycle

`SPAWN → DELEGATE → WORK → RETURN (single message) → IDLE / RE-DELEGATE`.

**Dev agents persist** for the whole session, re-delegated for every fix round. Shut down only on explicit user request or a confirmed stall.

**Reviewer persistence is budget-conditional.** Reviewer slots = `orch-env REVIEWER_SLOT_BUDGET 0` minus the primary session minus live `child_sessions` entries whose `status` is `active` (no `status` counts as active), minimum 1, recomputed at every review-cycle start; `0` means unlimited. Within budget, reuse reviewers by exact name and spawn only the missing subset. Over budget, or on a thread-limit spawn error, run waves and persist the wave size as `reviewer_slots_observed`. Review state lives on disk, never in reviewer session memory.

QA agents spawn and shut down per agent.

A tracked render lands with its source in the same commit; `ORCH_SIZE_RENDER_ROOTS` names the roots where `branch-size-check` classifies paired mirrors.

### Round Closure

The orchestrator owns round closure. Every dev/QA delegation carries three mechanics:

1. **Round token.** Immediately before delegating, run `workflow-state new-round-id [ISSUE_ID] dev_round_id` for the `Round ID:` line and re-stamp `dev_delegated_at`. A fix round also runs `dev-round-write`, which records HEAD, items, the size report, and optional `Adds:` paths in an immutable round record under the worktree's `tmp/`. A missing or mismatched record requires a fresh round; never recreate one after delegation. A chosen cut uses `dev-round-write --cut`; [dev-round.md § Declared cuts](../schemas/dev-round.md#declared-cuts) owns its acceptance rule.
2. **Arm a single-shot wall-clock watchdog** at the same moment: one backgrounded `dev-artifact-check --wait 600 --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`): returns when the artifact lands (`accept`/`retry`) or at the deadline (`wait`). Run A/B on its return; re-arm only on a new escalation step, never poll. The one exception is a watchdog that returned NO verdict — a keyed refusal, or any exit status outside the verdict set — which means it stopped clocking the round before the round ended: replace it immediately rather than at the next escalation step, because the alternative is the untimed round this rule exists to prevent. **ONE replacement, never two.** A watchdog ends without a verdict because its own probe broke, and those failures persist — a `jq` that cannot run, a machine out of processes — so a replacement that also ends without one is an environment failure, not a round to keep clocking: stop there and report it, naming the status and the keyed line if one arrived. Arming a third, or waiting for the probe to recover, spends processes on a machine that has none and leaves the failure unreported. Statuses are in each check's `--help`; [artifact-checks.md](artifact-checks.md).
3. **Run the check on every wake and at the deadline.** Never classify from wording or elapsed time. `dev-artifact-check --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`) prints `verdict`; act on it.

The acceptance table lives in the delegating workflow (`dev-start.md` § 3, `dev-fix.md` § 2, `review-pr-comments.md` § 6.1); the return message is display-only; tracker corroboration (**B**) applies only where that table names it. `ci-fix.md` (no dev-return artifact) is accepted by its return message plus the escalation ladder.

**Escalation.** Only after the 10-minute quiet window AND a confirmed stall (task status unchanged, no session-log entries for 10+ minutes, or the process exited): re-message once naming the missing step → wait 5 minutes → still inactive: shut down, re-create tasks, respawn, re-delegate. The respawn takes a fresh runtime instance and a fresh round id; the canonical agent name is the identity every record is keyed on and stays as it was.

---

## Coordination

**Containers.** An issue with children or an `agent:multi` label and no `(one PR)` title marker is a CONTAINER. A container is never orchestrated and never gets a PR. Each child is the PR unit, selection operates on unblocked children, and the container closes LAST when its final child merges.

**Ancestor gate.** Every selected issue walks its full `parent_id` chain. An enclosing `(one PR)` bundle REPLACES the selection. Dispatch requires the item's own `state_type` non-terminal and the union of its `blocked_by_open` with every container ancestor's `blocked_by_open` empty. `blocked_by` remains relation history and does not decide dispatch.

**Sequencing.** Order by data flow (Creates ↔ Consumes), never by agent ordering; existing blocking relations outrank inference. Cross-bundle relations go on the parent issues; dependent children of one container get child-blocks-child relations, which ARE the execution order; only an explicit `(one PR)` bundle leaves intra-bundle ordering to the delegated session.

**Single-PR bundles.** Exactly three opt-ins delegate all children as one session: a parent marked `(one PR)`, a delegation carrying `Audit Bundle: yes`, or a leaf issue with an internal checklist. One composite task per sub-issue; multi-domain bundles process groups sequentially, collecting handoff notes between groups.

**Lane mail.** A delegated orchestration session (lane) reaches its overseer through `scripts/lane-mail` and nothing else. Every ask gate in a lane is `lane-mail ask --item [ISSUE_ID] --file [PATH]`, whose printed `id=` feeds `lane-mail wait --item [ISSUE_ID] --id [MSGID]` run under [waiter-launch.md](waiter-launch.md); the question's own words cross the `--file`, never argv. The harness question tool is never used in a lane, on any surface. A lane sends what needs no reply with `lane-mail notice`, and reads what the overseer sent with `lane-mail inbox --item [ISSUE_ID]` at every wait point it already has. On a harness that runs these hooks ([hooks/README.md](https://github.com/vanillagreencom/kendex/blob/main/hooks/README.md)), the `lane-mail-deliver` hook hands over anything unread after each tool call and the `lane-mail-check` hook at the lane's turn end, and while an unread halt stands the `lane-mail-halt` hook refuses every tool call but the `lane-mail inbox` read that acknowledges it. Elsewhere the lane reads mail only at its `lane-mail inbox` wait points, so a halt takes effect there. The overseer answers with `lane-mail send --re [MSGID]`, directs with `lane-mail send --directive` and halts with `lane-mail send --halt`; [oversee.md](../workflows/oversee.md) § 4 owns its side.

**Tracked issue creation.** A delegated orchestration session (lane) never creates a tracked issue. TPM analysis from [audit-issues](../../project-management/workflows/audit-issues.md) § 2.1 / § 4.1 runs in a lane or delegated subagent, never in the overseer session. Defer a proposal until its source PR has merged. Resolve the lane's tracker before recording it. Linear uses `.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file [PATH]`; GitHub uses `gh issue comment [NUMBER] --repo [OWNER/REPO] --body-file [PATH]`. The first line is `Proposal: [TITLE]`. The comment also carries `Source: [SOURCE]`, `Source PR: [OWNER/REPO#N]`, `Priority: [1-4]`, `Reached by: [BEHAVIOR]`, `Reason: [WHY TRACKED WORK IS NEEDED]`, and `Evidence: [REPOSITORY_PATH]`. A `review`, `pr-comments`, or `local-review` source at priority 2 also carries `Symptom: [OBSERVED_FAILURE]`. The evidence path uses a semantic anchor, never a line number. After the write, send one `lane-mail notice` whose text is `Proposal comment: [TRACKER] [REPOSITORY|-] [ISSUE_ID] [COMMENT_ID_OR_URL]`. The overseer records that durable binding in the fleet log. An unbound comment is not a proposal. The lane status file carries no proposal. Project-management's [proposal-sweep](../../project-management/workflows/proposal-sweep.md) workflow owns tracker-specific fleet analysis. Its TPM lane produces issue-mode audit JSON and files nothing. The overseer checks that output against live fleet work before it invokes [audit-issues](../../project-management/workflows/audit-issues.md) with `--analyzed`; project-order resumes at § 2.2. It records the created issue ID or one-line decline against the source comment through the same tracker. A non-delegated primary session routes creation through TPM, except for `plan-issues`, `start-new`, and the `merge-pr` rebundle, which it may run directly with their workflow-specified label sets.

**Verifier returns.** A verifier delegated by the overseer writes its full evidence as one Linear comment on the issue it verified. It writes no report or evidence file for the overseer. Its return contains one line per issue in this shape: `[ISSUE] | verdict: [kept|canceled] | owner: [REPO_PATH_OR_NONE] | Done-when: [ONE_LINE_RESULT] | delta: [EXPECTED_DELTA_LINE_OR_NONE]`. `kept` means the issue clears the filing bar. `canceled` means it does not. The return contains no issue body or evidence text.

---

## Lane Output

Nobody reads a lane's pane. The overseer learns a lane's state from lane-mail, the lane status file and the watch's marker reads, so every narration, recap and closing summary a lane prints is output tokens with no reader.

`orch-env ORCH_LANE_OUTPUT quiet` resolves the mode: `normal` prints every block as written, and every other value, an unset setting and a typo included, is `quiet`.

The mode governs a lane, a session whose launch brief names a lane status file and a mailbox ([oversee.md](../workflows/oversee.md) § 3 Lane directive). A session with no such brief has a person at its pane and prints as written, whatever the setting resolves to.

Under `quiet` a lane prints one line per completed step and nothing else of its own: no narration of a step before it runs, no recap after it, no closing summary. A filled `<output_format>` block is written, not printed — to the artifact the step already owns, and to the lane status file where the step owns none. The lane then prints `output: [PATH]` and stops.

The lane status file holds at most 40 non-empty lines ([oversee.md](../workflows/oversee.md) § 3 Lane directive). A block that would push it past that goes to a file under the worktree's `tmp/` instead, named in the same printed line.

A block standing ahead of an ask gate is that gate's own file: write it, then send it as `lane-mail ask --file [PATH]` ([§ Coordination](#coordination)), so the question carries the filled block and the pane carries the printed line alone.

Harness output is never suppressed. The prompt, the usage banner, dialogs and the end-of-turn line stay as the harness prints them, so the watch's marker reads and the pane judge in [lane-state.sh](../scripts/lib/lane-state.sh) are unchanged. A subagent's own output is outside this rule: the lane reads it, and it is paid in either mode. So an `<output_format>` block nested inside a `<delegation_format>` is the delegated agent's return shape, not the lane's, and cites nothing; every other block in `../workflows` cites this section.
