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

1. **Round token.** Immediately before delegating, run `workflow-state new-round-id [ISSUE_ID] dev_round_id` for the `Round ID:` line and re-stamp `dev_delegated_at`. `dev_delegated_at` marks the delegation: the escalation's 10-minute quiet window is measured from it, the watchdog armed at the same moment keeps its own clock and never reads it, and `round-recover` accepts a reported pass only from a validation run started at or after it, so a delegation that skips the re-stamp re-admits an earlier round's passing run. A fix round also runs `dev-round-write`, which records HEAD, items, the size report, and optional `Adds:` paths in an immutable round record under the worktree's `tmp/`. A missing or mismatched record requires a fresh round; never recreate one after delegation. A chosen cut uses `dev-round-write --cut`; [dev-round.md § Declared cuts](../schemas/dev-round.md#declared-cuts) owns its acceptance rule. Between the round-id stamp and the `dev_delegated_at` stamp, so its time never counts against the agent's quiet window, `round-prune [ISSUE_ID]` reads the use of the volume holding the item worktree's `target/`. At or past `ORCH_ROUND_PRUNE_DISK_PCT` (default 75) it prunes that worktree's Cargo profiles under the item's own lease, however recent, and leaves `node_modules/` and `.next/`, which nothing reinstalls between rounds; it records the bytes under `round_prunes` in workflow state. Below the mark it prunes nothing, so the round's validation starts warm. It resolves its own target: the worktree the state names, else the linked worktree holding the state's branch, with the lease owner its branch's issue id and the Cargo target `CARGO_TARGET_DIR` names, `target/` by default. A state matching no worktree records `no-worktree` and the round goes ahead; a Cargo target outside the worktree's `target/` is past the prune's reach, so past the mark it records `target-elsewhere` and exits 1. It runs between rounds, so no validation run deletes anything. A non-zero exit stops the delegation: report its lines, because a round delegated past the mark with its target not reclaimed starts its validation on a full disk.
2. **Arm a single-shot wall-clock watchdog** at the same moment: one backgrounded `dev-artifact-check --wait 600 --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`): returns when the artifact lands (`accept`/`retry`) or at the deadline (`wait`). Run A/B on its return; re-arm only on a new escalation step, never poll. The one exception is a watchdog that returned NO verdict — a keyed refusal, or any exit status outside the verdict set — which means it stopped clocking the round before the round ended: replace it immediately rather than at the next escalation step, because the alternative is the untimed round this rule exists to prevent. **ONE replacement, never two.** A watchdog ends without a verdict because its own probe broke, and those failures persist — a `jq` that cannot run, a machine out of processes — so a replacement that also ends without one is an environment failure, not a round to keep clocking: stop there and report it, naming the status and the keyed line if one arrived. Arming a third, or waiting for the probe to recover, spends processes on a machine that has none and leaves the failure unreported. Statuses are in each check's `--help`; [artifact-checks.md](artifact-checks.md).
3. **Run the check on every wake and at the deadline.** Never classify from wording or elapsed time. `dev-artifact-check --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`) prints `verdict`; act on it.

The acceptance table lives in the delegating workflow (`dev-start.md` § 3, `dev-fix.md` § 2, `review-pr-comments.md` § 6.1); the return message is display-only, except that `round-recover` parses a stalled round's return block from the agent's transcript; tracker corroboration (**B**) applies only where that table names it. `ci-fix.md` (no dev-return artifact) is accepted by its return message plus the escalation ladder.

**Escalation.** Only after the 10-minute quiet window AND a confirmed stall (task status unchanged, no session-log entries for 10+ minutes, or the process exited): re-message once naming the missing step → wait 5 minutes → still inactive: shut down, re-create tasks, respawn, re-delegate. The respawn takes a fresh runtime instance and a fresh round id; the canonical agent name is the identity every record is keyed on and stays as it was. A round accepted on a dev-return artifact skips this ladder when it is a stalled round.

**Stalled round.** The watchdog returned `wait`, the harness reports the agent idle, its transcript has not changed since the idle notice, and no process of the round is alive. Never message that agent. Run `round-recover --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id] --transcript [PATH]`, with the path from [agent-transcripts.md](agent-transcripts.md), and act on its line. A bundled round's report carries no `Commit:` line, so a bundled round always takes the `redelegate` row.

| Line | Action |
|---|---|
| `recovered` | The report is now the round's artifact. Run the delegating workflow's acceptance table; a gate refusal such as `cut_not_shrunk` or `unapproved_additions` takes that table's `retry` row. |
| `redelegate` | No report, or a report the disk contradicts; the printed `reason` names which. The printed `round-id` is already minted into `dev_round_id`. Run `round-prune [ISSUE_ID]` for it, then re-stamp `dev_delegated_at`, keep `pre_delegate_sha`, and on a fix round run `dev-round-write` for that id with the whole authorization of the printed `from` round's record, `[WORKTREE]/tmp/dev-round-[ISSUE_ID]-[FROM].json`: the same items, the same `--adds` list, repeated as the delegation's `Adds:` line, and `--cut-from-round` on that path when the record has `cut: true`. Shut the idle agent down, spawn a fresh instance, delegate under that id, and arm its watchdog. |
| `exhausted` | The re-delegated round stalled too, with no report or a report the disk contradicts; the printed `reason` names which. Stop and report it. |
| `round-live` | Not a stall. Arm one new watchdog. |

---

## Coordination

**Containers.** An issue with children or an `agent:multi` label and no `(one PR)` title marker is a CONTAINER. A container is never orchestrated and never gets a PR. Each child is the PR unit, selection operates on unblocked children, and the container closes LAST when its final child merges.

**Ancestor gate.** Every selected issue walks its full `parent_id` chain. An enclosing `(one PR)` bundle REPLACES the selection. Dispatch requires the item's own `state_type` non-terminal and the union of its `blocked_by_open` with every container ancestor's `blocked_by_open` empty. `blocked_by` remains relation history and does not decide dispatch.

**Sequencing.** Order by data flow (Creates ↔ Consumes), never by agent ordering; existing blocking relations outrank inference. Cross-bundle relations go on the parent issues; dependent children of one container get child-blocks-child relations, which ARE the execution order; only an explicit `(one PR)` bundle leaves intra-bundle ordering to the delegated session.

**Single-PR bundles.** Exactly three opt-ins delegate all children as one session: a parent marked `(one PR)`, a delegation carrying `Audit Bundle: yes`, or a leaf issue with an internal checklist. One composite task per sub-issue; multi-domain bundles process groups sequentially, collecting handoff notes between groups.

**Lane mail.** A delegated orchestration session (lane) reaches its overseer through `scripts/lane-mail` and nothing else. Every ask gate in a lane is `lane-mail ask --item [ISSUE_ID] --file [PATH]`, whose printed `id=` feeds `lane-mail wait --item [ISSUE_ID] --id [MSGID]` run under [waiter-launch.md](waiter-launch.md); the question's own words cross the `--file`, never argv. The harness question tool is never used in a lane, on any surface. A lane sends what needs no reply with `lane-mail notice`, and reads what the overseer sent with `lane-mail inbox --item [ISSUE_ID]` at every wait point it already has. As its first step, and again at each expiry, a lane arms a standing monitor on its mailbox, `lane-mail watch --item [ISSUE_ID]`, through its harness's background wake per [watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor), and runs the `lane-mail inbox` command each announcement prints. Mail therefore wakes an idle Claude Code or Pi lane by itself, and a send's receipt tells the overseer whether that monitor is running; a Codex lane arms none, and the overseer wakes it ([codex-runtime.md § Lane mailbox](codex-runtime.md#lane-mailbox)). On a harness that runs these hooks ([hooks/README.md](https://github.com/vanillagreencom/kendex/blob/main/hooks/README.md)), the `lane-mail-deliver` hook hands over anything unread after each tool call and the `lane-mail-check` hook at the lane's turn end, and while an unread halt stands the `lane-mail-halt` hook refuses every tool call but the `lane-mail inbox` read that acknowledges it. Elsewhere the lane reads mail only at its `lane-mail inbox` wait points, so a halt takes effect there. The overseer answers with `lane-mail send --re [MSGID]`, directs with `lane-mail send --directive` and halts with `lane-mail send --halt`; [oversee.md](../workflows/oversee.md) § 4 owns its side.

**Question tools.** Every command `open-terminal` builds carries the words that take the harness question tool away, and a `--cmd` launch on a harness that has words below carries them inside its command or is refused as `launch-question-tool-missing`. A `--cmd` launch naming no harness is not judged, so its command carries the words by hand, and a lane started through a harness's own session launcher ([oversee.md](../workflows/oversee.md) § 1) is outside `open-terminal`. The words live in `scripts/lib/lane-launch.sh` beside each harness's model and effort spellings.

| Harness | Question tool | Words that take it away |
|---------|---------------|-------------------------|
| Claude Code | `AskUserQuestion`, and `EnterPlanMode`, whose plan ends in an approval dialog | `--disallowedTools=AskUserQuestion,EnterPlanMode` |
| Codex | `request_user_input`: in Plan mode, which only the person at the pane selects, and in Default mode under the `default_mode_request_user_input` feature | `-c features.default_mode_request_user_input=false` |
| Pi | `question`, registered by pi-questions | `--exclude-tools question` |
| OpenCode | `question`, a permission; its one per-launch switch is the `OPENCODE_PERMISSION` environment variable, which no launcher here sets | none: an OpenCode lane keeps its question tool |
| Overseer, any harness | The harness's own tool stays on by default, because the owner answers there | `ORCH_OVERSEER_QUESTION_TOOL=off` gives every successor `oversee-succeed` launches that harness's words, and it alone decides: words typed on a hand-started overseer do not carry to its successors |

**Tracked issue creation.** A delegated orchestration session (lane) never creates a tracked issue. TPM analysis from [audit-issues](../../project-management/workflows/audit-issues.md) § 2.1 / § 4.1 runs in a lane or delegated subagent, never in the overseer session. Defer a proposal until its source PR has merged. Resolve the lane's tracker before recording it. Linear uses `.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file [PATH]`; GitHub uses `gh issue comment [NUMBER] --repo [OWNER/REPO] --body-file [PATH]`. The first line is `Proposal: [TITLE]`. The comment also carries `Source: [SOURCE]`, `Source PR: [OWNER/REPO#N]`, `Priority: [1-4]`, `Reached by: [BEHAVIOR]`, `Reason: [WHY TRACKED WORK IS NEEDED]`, and `Evidence: [REPOSITORY_PATH]`. A `review`, `pr-comments`, or `local-review` source at priority 2 also carries `Symptom: [OBSERVED_FAILURE]`. The evidence path uses a semantic anchor, never a line number. After the write, send one `lane-mail notice` whose text is `Proposal comment: [TRACKER] [REPOSITORY|-] [ISSUE_ID] [COMMENT_ID_OR_URL]`. The overseer records that durable binding in the fleet log. An unbound comment is not a proposal. A gap in a package or a workflow is a proposal through lane mail and the sweep, never a harness memory or a local note, because memory reaches one session on one machine and the package reaches every consumer. The lane status file carries no proposal. Project-management's [proposal-sweep](../../project-management/workflows/proposal-sweep.md) workflow owns tracker-specific fleet analysis. Its TPM lane produces issue-mode audit JSON and files nothing. The overseer checks that output against live fleet work before it invokes [audit-issues](../../project-management/workflows/audit-issues.md) with `--analyzed`; project-order resumes at § 2.2. It records the created issue ID or one-line decline against the source comment through the same tracker. A non-delegated primary session routes creation through TPM, except for `plan-issues`, `start-new`, and the `merge-pr` rebundle, which it may run directly with their workflow-specified label sets.

**Verifier returns.** A verifier delegated by the overseer writes its full evidence as one Linear comment on the issue it verified. It writes no report or evidence file for the overseer. Its return contains one line per issue in this shape: `[ISSUE] | verdict: [kept|canceled] | owner: [REPO_PATH_OR_NONE] | Done-when: [ONE_LINE_RESULT] | delta: [EXPECTED_DELTA_LINE_OR_NONE]`. `kept` means the issue clears the filing bar. `canceled` means it does not. The return contains no issue body or evidence text.

---

## Lane Output

No person reads a lane's pane. The overseer learns a lane's state from lane-mail, the lane status file and what the watch reads off the pane, so every narration, recap and closing summary a lane writes for a human reader is output tokens nobody spends.

`orch-env ORCH_LANE_OUTPUT quiet` resolves the mode: `normal` prints every block as written, and every other value, an unset setting and a typo included, is `quiet`.

The mode governs a lane, a session whose launch brief names a lane status file and a mailbox ([oversee.md](../workflows/oversee.md) § 3 Lane directive). A session with no such brief has a person at its pane and prints as written, whatever the setting resolves to.

Under `quiet` a lane prints one line per completed step and nothing else of its own: no narration of a step before it runs, no recap after it, no closing summary. A filled `<output_format>` block is written, not printed — to the artifact the step already owns, and where the step owns none to a file of its own under the worktree's `tmp/`, one file per block so no later step overwrites what a printed path named. The lane then prints `output: [PATH]` and nothing more; the workflow continues.

A block a step writes after the item worktree is gone goes under `[MAIN_REPO_ROOT]/tmp`, the repository root `git-context common-root` prints and [merge-pr.md](../workflows/merge-pr.md) § 1 binds and creates, so the printed path outlives the tree it reports on; the overseer reads it with `lane-host cat --item [ISSUE_ID] [PATH]`, as it reads the status file ([oversee.md](../workflows/oversee.md) § Bounded lane reads). The case is any block a workflow renders after merge-pr.md § 5 step 6 removed that worktree, whether the step is merge-pr's own (§ 6 Present Results, for example) or one its caller returns to after running merge-pr.md § 4-7 ([micro.md](../workflows/micro.md) § 5, for example). The condition decides the destination, so a block's citation names this rule alone and never a destination of its own.

The lane status file is never a block destination. It carries the current step, blocker and handoff paths ([oversee.md](../workflows/oversee.md) § 3 Lane directive) and nothing else: that section has the lane REWRITE it and bounds it at 40 non-empty lines, so a block written there is destroyed by the next step's rewrite, leaving the path already printed naming something else, or it evicts the very lines the file exists to carry.

A block standing ahead of an ask gate is that gate's own file: write it, then send it as `lane-mail ask --file [PATH]` ([§ Coordination](#coordination)), so the question carries the filled block and the pane carries the printed line alone.

Harness output is never suppressed. The prompt, the usage banner, dialogs and the end-of-turn line stay as the harness prints them, so the watch's marker reads and the pane judge in [lane-state.sh](../scripts/lib/lane-state.sh) are unchanged.

`oversee-watch` gives each event the pane lines that event's handling reads and no more, and [oversee.md](../workflows/oversee.md) § Bounded lane reads takes that payload as the lane's state; which lines a kind carries, and how many, is `oversee-watch --help` and `ORCH_WATCH_TAIL_LINES`. Under `quiet` those lines are the one line per completed step and the `output: [PATH]` lines, so the overseer reads what the lane did and opens a named file for the block itself. A subagent's own output is outside this rule: the lane reads it, and it is paid in either mode. So an `<output_format>` block nested inside a `<delegation_format>` is the delegated agent's return shape, not the lane's, and cites nothing; every other block in `../workflows` cites this section.
