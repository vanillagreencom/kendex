# Skill rules

Read the named section when an orch workflow delegates work, closes a round, coordinates lanes or writes lane output.

## Delegation

| Pattern | When | Flow |
|---------|------|------|
| Spawn + message | A fresh dev, QA or review agent | Spawn, then send the delegation |
| Message only | Re-delegation to a live agent | Send the delegation to the running agent |
| Self-create | No team context | Put the full instructions in the prompt |

When the caller asks for a technical implementation plan:

- Delegate it to the installed `planner` agent.
- Report a missing planner.
- Never plan in the primary session.
- Pass any TPM handoff through the caller.
- The project-management `roadmap plan` command consumes a finished plan and launches no planner.

### Claude Code reviewer names

Omit `name` from a reviewer's `Agent` call, or start the name with the reviewer's canonical agent name, such as `reviewer-correctness`. Claude Code reports the spawn name as `agent_type`. The `reviewer-read-only` hook protects only an `agent_type` that starts with `reviewer-`. A nickname such as `rr-correctness` runs unprotected.

### Model class

- The four model classes are `top`, `standard`, `light` and `fast`.
- An item runs at `standard`.
- The overseer chooses another class only by writing it, with its reason, into the item's brief as `Model class: [CLASS]`.
- Use `top` for work that needs it.
- Use `light` or `fast` for extremely low-stakes work, such as a typo, a label, a config line or a doc sentence. Nothing selects a class below `standard` by default.
- Never derive a class from an estimate, a workflow tier (`micro`, `small`, `standard`), complexity or a risk category.
- Choose effort per task; a class holds no effort.

A fleet launch states the class and its reason on the `launch-lane` request ([lane-launch.md § Lane directive](lane-launch.md#lane-directive)).

When the lane's brief names `Model class:`, carry that field on each dev, review or QA delegation:

- Claude Code: set the `Agent` call's `model` to the family alias `kendex tier-model claude [N]` prints, where `[N]` is the class's rank, top first.
- Pi: set the `subagent` call's `model` to `[CLASS]:[EFFORT]`.
- Codex and Copilot CLI: the agent file's class stands.

### Stored-ID reuse

On Codex MultiAgentV2, apply [Codex thread reuse](#codex-thread-reuse) before choosing a fresh instance.

On other surfaces, before every re-delegation:

1. Read that agent's own context figure and the reuse guard's threshold through the harness status API, for the target working directory and model. Never use the parent's context or cumulative usage.
2. Reuse the stored ID only when the guard permits it, equality at the threshold included.
3. Above the threshold, retire the idle session and start a fresh agent of the same type. Send it the new task with the prior agent's final result attached, and replace the stored ID.
4. When the context figure is unavailable, start fresh.

- An explicit same-session request keeps the guard's refusal text and its fresh-agent remedy.
- Never give a role a second task while its first runs.
- Stall recovery follows [§ Round Closure](#round-closure).

Pi's status calls and its automatic background handoff: [pi-runtime.md § Context before reuse](pi-runtime.md#context-before-reuse).

### Reviewer packet

- Before delegating an opinion, admit the complete reviewer packet: the canonical role and its required standards, the source evidence, the repository, ref, HEAD and dirty bindings, the design and input table, the retained artifacts and the unresolved inputs.
- Give the reviewer its full role context.
- Never launch an opinion with a known mandatory input missing. Report that phase incomplete, naming each missing input.
- The [pre-panel context check](../workflows/review-pr.md#2-prepare-reviewers) still decides attached room. Missing context is no permission to attach.

A complete adverse opinion contains a performed review and actual blockers.

- Missing evidence, an unperformed opinion or an incomplete review establishes neither a pass nor an adverse design judgement.
- Empty findings do not clear an unperformed review.
- The acceptance owner decides any permitted completion of the same pending opinion.

### Subagent waits

A subagent waits with one bounded command through its harness's own wait or monitor mechanism, never with a loop that has no pause. Each harness's mechanism: [watch-delivery.md](watch-delivery.md) and [waiter-launch.md](waiter-launch.md).

### Format Tags Are Literal

`<delegation_format>` and `<output_format>` are exact.

- Fill each `[PLACEHOLDER]`, omit a line whose placeholder is empty, add nothing, and keep the structure and field names verbatim.
- A placeholder holds a schema field, never process prose.
- When a tagged block precedes an ask-user step, present the filled block first, then ask. In a lane the block goes to the ask's own file ([§ Lane Output](#lane-output)).

### Single Return Message

An agent sends exactly one completion message. Treat a second return as a violation: diff it against the first and flag unrequested commits.

### Codex dual-channel completion

Codex delivers one completion over two channels: a `send_input` `MESSAGE`, then a `FINAL_ANSWER` that echoes it. Treat the pair as one completion. Still diff the two: flag a new commit or another change as a second return.

---

## Agent Lifecycle

- Dev agents persist across fix rounds while [§ Delegation](#delegation) permits reuse.
- Shut one down on the user's explicit request, a confirmed stall or a context handoff.

### Reviewer persistence is budget-conditional

On Codex MultiAgentV2, apply [Codex thread reuse](#codex-thread-reuse): a finished thread still holds a slot.

On other surfaces, recompute the reviewer slots at every review-cycle start:

1. Read the budget with `orch-env REVIEWER_SLOT_BUDGET 0`; `0` means unlimited.
2. Send the `record-agents` request with step `slots` through `orch-runtime op --item [ISSUE_ID] --request [REQUEST_FILE]`. It closes each child session whose opener has ended. It answers `live`: the child sessions that still hold a slot.
3. Slots are the budget minus the primary session minus `live`, at least 1.

Within the slots:

- Apply [§ Delegation](#delegation) before reusing reviewers by exact name.
- Spawn only the missing or context-exhausted ones.

Over the slots, or on a thread-limit spawn error, run waves. Each wave's `record-agents` `wave-start` step records the spawn count the harness allowed as `slots_observed`.

Review state lives on disk, never in a reviewer's session memory.

On a surface with a close call, a QA agent spawns and shuts down per task.

### Codex thread reuse

Apply this rule to every Codex spawn, re-delegation, retirement and respawn, review waves and [§ Round Closure](#round-closure) included.

- **Budget.** On MultiAgentV2, before each spawn:
  - Read the cap as `effective_cap` from `.agents/skills/agent-runtime/scripts/agent-runtime subagent room --harness codex`.
  - Call `list_agents` with no path filter. Count every thread spawned in this session, live or finished, descendants included, and the primary session once. Add the primary only when the listing omits it.
  - `room` owns the cap and `list_agents` owns the count in use. Add no script or counter.
  - When either read fails, report that failure instead of estimating capacity.
- **Retirement.**
  - Where the surface exposes `close_agent` (MultiAgent V1), close finished threads through it.
  - MultiAgentV2 has no close call: end the task, with `interrupt_agent` for a running task. The thread stays allocated.
    - Confirm it stopped before reuse.
    - An interrupt frees no slot.
- **Selection.** On MultiAgentV2, reuse the role's finished stored thread when it is eligible, that is, when its fixed runtime instructions permit the target task.
  - A specialist thread qualifies for its own role. A generic thread that completed review work can qualify for another review or for implementation. Never relabel a specialist to override its fixed instructions.
  - Otherwise spawn fresh only when the spawn fits the cap. At the cap, or after a thread-limit spawn error, do not retry the spawn and do not ask the overseer for reuse permission.
  - For a review, select a finished reviewer thread. For implementation, fix or QA work, select a finished thread that did not produce the findings that work addresses.
  - Never give two active tasks the same thread.
  - Obey a target context figure and reuse threshold where the runtime provides them. A context-exhausted thread is ineligible. Where those figures are unavailable, reuse with the complete delegation and the disk artifacts.
- **Delegation.**
  - Prepare one `DELEGATION:` message for a fresh spawn and a reused thread alike: the installed target agent's full instructions and workflow, then the filled literal `<delegation_format>`.
  - Send it through `followup_task` on reuse.
  - Never rely on the thread's former role or memory.
  - Replace the stored runtime id under the target canonical role in `child_sessions` or `review_agent_ids`.
  - End the prior role's assignment before giving the thread another role.
  - Keep the runtime-type metadata true: reuse changes the task, not the thread's runtime type.
- **Waves.** When no finished thread is eligible:
  - Finish the active work on held threads.
  - Then assign pending work in waves through eligible finished threads with `followup_task`, checking eligibility for each assignment.
  - Keep artifact acceptance, round tokens and watchdogs.
  - Report a blocker only when the held threads cannot run the pending work. Name `effective_cap`, every held thread's id and status, and why none is eligible.

Spawn parameters for each Codex surface: [codex-runtime.md § Spawning Codex collaboration agents](codex-runtime.md#spawning-codex-collaboration-agents).

### Round Closure

The orchestrator owns round closure. Every dev or QA delegation runs these steps. The delegating workflow (`dev-start.md` § 2, `dev-fix.md` § 2 step 4, `review-pr-comments.md` § 6.1) holds each command in its order.

1. **Mint the round token** through the workflow's `begin-round` request to `orch-runtime op`, immediately before delegating. Its id is the delegation's `Round ID:` line.
2. **Stamp a fix round.**
   - A fix round first passes [dev-fix.md § 2's base-freshness gate](../workflows/dev-fix.md#2-delegate), recovered and redirected rounds included.
   - It then runs `orch-runtime round --text stamp`. That writes the round's immutable record of HEAD, items and optional `Adds:` paths at `[WORKTREE]/tmp/dev-round-[ISSUE_ID]-[ROUND_ID].json`.
   - A chosen cut adds `--cut`; [dev-round.md § Declared cuts](../schemas/dev-round.md#declared-cuts) owns its acceptance.
   - A missing or mismatched record requires a fresh round. Never recreate one after delegation.
3. **Prune, where selected.** Run this step only where the project's orch instructions select Cargo round cleanup.
   - Send the `prune-round` request, `{"op": "prune-round", "field": "dev"}`, through `orch-runtime op --item [ISSUE_ID] --request [REQUEST_FILE]`. A CI round names `"field": "ci"`.
   - The request prunes the item worktree's Cargo profiles when the volume holding them is at or past `ORCH_ROUND_PRUNE_DISK_PCT` ([settings.md](settings.md)).
   - A non-zero exit stops the delegation: report the reply.
   - Without that selection, skip this step.
4. **Record the delegation time** with the `record-round` request, step `delegated`, after any prune. The escalation's 10-minute quiet window runs from it.
5. **Arm a single-shot watchdog** at the delegation: `orch-runtime dev-return --text check --wait 600 --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]`, with `--expect-items-from-round` on a fix round.
   - Start it as one waiter through [waiter-launch.md](waiter-launch.md). In a lane its `orch-runtime launch-job` carries `--owner [ISSUE_ID]`, so the job's end reaches the lane as a `job-end` directive.
   - Act on its return through steps A and B of the workflow's acceptance table. Re-arm only on a new escalation step, and never poll.
   - [artifact-checks.md](artifact-checks.md) routes a printed verdict and a keyed refusal.
   - A watchdog that returned no verdict, a keyed refusal or another exit status stopped clocking the round. Replace it at once: ONE replacement, never two.
   - A replacement that also ends without a verdict is an environment failure, such as an unbuilt runtime or a machine out of processes. Stop and report it with the status and any keyed line.
6. **Run the check on every wake and at the deadline**: `orch-runtime dev-return --text check --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]`, with `--expect-items-from-round` on a fix round. Act on its `verdict`. Never classify from wording or elapsed time.

On Codex, a dev round that writes a dev-return artifact holds its watchdog through [codex-runtime.md § Delegated round wait](codex-runtime.md#delegated-round-wait), in place of step 5's background launch.

**Acceptance.**

- The acceptance table lives in the delegating workflow (`dev-start.md` § 3, `dev-fix.md` § 2; `review-pr-comments.md` § 6.1 routes to `dev-fix.md`'s).
- The return message is display-only. Only `orch-runtime round --text recover` parses a stalled round's return block from the agent's transcript.
- Tracker corroboration (**B**) applies only where that table names it.

**CI rounds.** `ci-fix.md` writes no dev-return artifact.

- Its CI-fix and integration-analysis delegations mint `ci_round_id`, which opens no dev stage.
- They record the delegation time and arm step 5's watchdog with the CI token; its missing-artifact `wait` is expected.
- They accept on the return message plus a pushed commit.
- When no return arrives, they take [§ Escalation](#escalation).

**Handoff at a mark.**

- A lane at its context or account mark writes its handoff record at once, whatever step of the round is open. The record carries the open step, a committed fix, the review it awaits and the record's paths.
- The successor resumes the round from it.
- A review step is never a precondition of the record.
- On every harness that runs it, the lane's turn-end hook judges both marks. It refuses a session's first turn end at a reached mark, and a later turn end without the record ends the turn with a `lane-stopped` notice to the overseer.
- A hosted Claude Code or Pi lane's account mark is the overseer's: the overseer reads it between turn ends and directs the lane to write the record ([oversee-events.md § Hand off a lane before it runs out](oversee-events.md#hand-off-a-lane-before-it-runs-out)).

**Attached-launch reserve.**

- Before an attached review panel or a process-owned reviewer starts, a lane asks from its own shell: `orch-runtime admission --item [ISSUE_ID] --attached-launch` (attached) or `--checkpoint` (process-owned).
- On every harness, an attached launch keeps `ORCH_HANDOFF_AGENT_RESERVE_TOKENS` ([settings.md](settings.md)) tokens below the context mark for the returns still to come.
- The answer is one JSON line whose `verdict` is `room` or `due`.
- On Codex, an attached launch that the reserve alone refuses answers `alternate-review`, and the panel runs as process-owned reviewers.

### Escalation

Escalate only after the 10-minute quiet window AND a confirmed stall: the task status unchanged, no session-log entry for 10 minutes or more, or the process exited.

1. Re-message once, naming the missing step.
2. Wait 5 minutes.
3. Still inactive: end the stalled task and re-create its tasks. On Codex, choose the instance under [Codex thread reuse](#codex-thread-reuse). Elsewhere, spawn fresh.
4. Re-delegate under a fresh round id. The canonical agent name, which every record is keyed on, stays. A dev-return round runs [§ Round Closure](#round-closure) steps 1 to 5 first.

A dev-return round that stalled takes [§ Stalled round](#stalled-round) instead of this ladder.

### Stalled round

A round is stalled when the watchdog returned `wait`, the harness reports the agent idle, its transcript has not changed since the idle notice, and no process of the round is alive.

- Do not re-message the stalled task.
- Finish recovery before choosing a thread under [Codex thread reuse](#codex-thread-reuse).
- Run `orch-runtime round --text recover --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id] --transcript [PATH]`, with the transcript path from [agent-transcripts.md](agent-transcripts.md).
- Act on its line, which opens `round:` and names the state.
- A bundled round's report carries no `Commit:` line, so a bundled round always takes the `redelegate` steps.

| Line | State |
|---|---|
| `recovered` | The report is the round's artifact |
| `redelegate` | No report, or a report the disk contradicts; `reason` names which |
| `exhausted` | The re-delegated round stalled too; `reason` names why |
| `round-live` | Not a stall |

On `recovered`, run the delegating workflow's acceptance table. A gate refusal such as `unapproved_additions` takes that table's `retry` row.

On `redelegate`:

1. The printed `round-id` is already minted into `dev_round_id`. Run [§ Round Closure](#round-closure) step 3 for it, then step 4.
2. Keep `pre_delegate_sha`.
3. On a fix round, run `orch-runtime round --text stamp` for that id with the whole authorization of the `from` round's record, `[WORKTREE]/tmp/dev-round-[ISSUE_ID]-[FROM].json`: the same items, the same `--source`, the same `--adds` list repeated as the delegation's `Adds:` line, and `--cut` where the record has `cut: true`.
4. On Codex, choose the instance under [Codex thread reuse](#codex-thread-reuse). Elsewhere, shut the idle agent down and spawn fresh.
5. Delegate under that round id and arm its watchdog.

On `exhausted`, stop and report it.

On `round-live`, arm one new watchdog.

#### Directive During A Round

A lane never steers a running dev or fix round by message alone. A harness send (Claude Code `SendMessage`) only queues a message for the agent's next tool round, and returns no receipt. A send is not delivery. The agent's transcript ([agent-transcripts.md](agent-transcripts.md)) is the only record of what the agent read.

1. First write a directive that changes the round's scope into the round's durable brief: the item comment or `tmp/` file the delegation names.
2. Read the transcript for the change. A change read there is "delivered". Anything else, an unreadable transcript included, is "unconfirmed".
3. An unconfirmed directive overrides whatever the watchdog returns, since a report or an `accept` answers the prior scope.
   - At that return, shut the agent down, then run `orch-runtime round --text recover --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id] --directive-unconfirmed`.
   - It ends the worktree's validation runs first. A run it cannot end is its `stop-failed` refusal: stop and report it.
   - Otherwise it mints the replacement round and prints `redelegate`, with `from` naming the original round.
4. Reconcile the original round before anything uses the replacement. Write `[WORKTREE]/tmp/orch-op-[ISSUE_ID].json` with the harness file tool as `{"op": "reconcile-round", "round_id": "[FROM]"}` and run it. Each validation run the stop ended then closes as a stage of the original round ([dev-start.md § Close The Round's Stages](../workflows/dev-start.md#close-the-rounds-stages)):

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request [WORKTREE]/tmp/orch-op-[ISSUE_ID].json
   ```

5. Take the `redelegate` steps. It keeps the uncommitted tree and delegates the updated brief under the fresh round id.
   - On a fix round one thing differs: the fresh round's record holds the updated scope, never the `from` round's authorization.
   - Write its items file and run `orch-runtime round --text stamp` for the fresh id as [dev-fix.md § 2](../workflows/dev-fix.md#2-delegate) step 4 does for a new delegation, with the items, `--source`, `--adds` and `--cut` the updated brief names.

The lane's notice to the overseer says "confirmed in the dev agent's transcript at [TIME]" or "unconfirmed, re-delegating", never "reached" on a send.

---

## Coordination

### Private settings

- A brief or workflow names a setting and its reader, `orch-env NAME DEFAULT` ([scripts/orch-env](../scripts/orch-env)), never the private env file.
- An agent never opens, prints, greps or sources the private env file: `.env.local` or the file `KENDEX_ENV_FILE` names. The one exception is a setup workflow that writes one named secret into it.

### File searches

- A lane, or a dev, fix, review or QA agent, searches files only inside its worktree or under a path it names, with a shell command or with the harness's own search tool. It never searches from `/` or the home folder.
- A source from outside the worktree, such as another project's code, comes from that project's repository at the installed version: `gh api` on the repository at the installed tag, or a shallow clone under the worktree's `tmp/`.
- A review or QA agent clones under a `mktemp -d` of its own, outside the reviewed worktree, never under the worktree's `tmp/`.
- An installed header or package file is read at the path its installation names.
- A source none of these reaches is reported as unread, never sought by a wider search.

### Containers

An issue with children or an `agent:multi` label is a CONTAINER, whatever its title. The one exception is the review audit's in-PR bundle root: an issue whose own PR works the `make_child` items its review audit filed.

- Its Filing record carries `**In-PR bundle**: yes`, which only [review-pr.md § 8](../workflows/review-pr.md#8-summary-and-issue-audit) writes.
- linear's safe issue read reports it as `in_pr_bundle`.
- Every reader takes that one answer, the Ancestor gate and the dev agent's bundle check included.

A container is never orchestrated and never gets a PR.

- Each child is the PR unit.
- Selection works on unblocked children.
- A container stays open while a child is open. It closes when its last child is completed or canceled; a Duplicate child counts as canceled.
- `orch-runtime container-close [CHECKOUT] [PARENT_ID]` closes it and ticks its one box, "Every child Done or cancelled". [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 2 runs it, as does the Verification continuation in [oversee-events.md § Event kinds](oversee-events.md#event-kinds).
- In a confined lane it closes nothing; the overseer's own run closes the container.

### Ancestor gate

- Read current Linear facts with `issues get --format=safe` before each launch or implementation delegation.
- Every selected issue walks its full `parent_id` chain, and the gate applies to the final selection.

Dispatch requires two things: the item's own `state_type` is non-terminal, and the union of its `blocked_by_launch` with every container ancestor's `blocked_by_launch` is empty.

- This field leaves out completed, canceled and post-merge Verifying blockers. In Progress and Backlog blockers still hold dispatch.
- Selection reads the same field: an item whose only blockers are Verifying or Done is unblocked, its relations kept. The safe `issues list` carries it, and the heartbeat's `open-unblocked` line judges by each item's own `blocked_by_launch`.
- Other readers keep `blocked_by_open`, among them the unblocked and blocked split of `issues list --with-relations --format=raw`.
- A dependent that needs a blocker's proven outcome, not only its merged code, states that need in its body. The overseer's queue order holds that dependent through verification.

A selected issue whose live read reports `in_pr_bundle` is the work item, delegated with its children. For it:

- Also read the complete descendant tree through the project-management skill's dependencies reference, § Reading a Full Subtree.
- Read each non-terminal descendant the session will implement with `issues get --format=safe`, and include its external `blocked_by_launch`.
- Leave out blockers that belong to the same bundle: the delegated session orders that work.
- Any remaining launch blocker stops dispatch.

A missing or incomplete parent, descendant or blocker read stops dispatch. `blocked_by` is relation history and decides nothing.

A fleet launch's admission applies the gate again, before any lane is recorded. The runtime reads the item and each container ancestor up its `parent_id` chain, and refuses a launch with a blocker or with a node it could not read whole.

### Sequencing

- Order by data flow (Creates ↔ Consumes), never by agent order.
- An existing blocking relation outranks inference.
- Record relations under linear SKILL.md § Blocked Label vs Issue Relations.
- Only the review audit's in-PR bundle leaves the order inside the bundle to the delegated session.

### Single-PR bundles

Several deliverables ride one session only in these ways:

- An in-PR bundle root, whose live read reports `in_pr_bundle`, delegated with its children.
- A leaf issue with an internal checklist.
- A join: a fleet launch whose paths overlap a running local lane before that lane's review joins the item to it. The holding lane receives a directive opening `joined item=[ITEM] holder=[HOLDER]`, followed by the item's brief, and takes the item into its next dev round.

Run one composite task per sub-issue.

A multi-domain bundle runs its groups one after another, collecting handoff notes between groups.

### Renders

A tracked render lands with its source in the same commit.

### Lane asks

A lane never waits on the overseer for a step its workflow already permits. It asks only at a bound its workflow states, or at a scope change.

### Lane mail

A lane reaches its overseer by the `channel` its host kind declares ([lane-host.md § Host kinds](../schemas/lane-host.md#host-kinds)).

A `session` lane, a Claude cloud session, reaches its overseer through its branch and pull request and nothing else.

- It never asks: this kind never takes a step that needs an answer.
- It reports a blocker through the route its cloud session words state (`runtime/src/effects/cloud-session.txt`), then ends its turn.
- Its brief closes on those words in place of the unattended words, then on the output mode sentence of [§ Lane Output](#lane-output).

The rest of this section is the `mailbox` channel. On every surface, a lane reaches its overseer through the mailbox skill's `lane-mail` and nothing else, never through the harness question tool.

- **Ask.**
  - Every ask gate is `lane-mail ask --item [ISSUE_ID] --file [PATH]`.
  - The question's words cross the `--file`, never argv.
  - Its printed `id=` feeds `lane-mail wait --item [ISSUE_ID] --id [MSGID]`, run under [waiter-launch.md](waiter-launch.md).
- **Notice.**
  - Send what needs no reply with `lane-mail notice --item [ISSUE_ID] --file [PATH]`.
  - Send one only when the work changed since the last notice: a new head, PR, verdict, blocker, request or finish.
- **Turn end.**
  - End a turn only after a `lane-mail` ask or notice, or the lane status file, says where the work stands.
  - A wait that continues updates the lane status file only.
- **Inbox.** Read what the overseer sent with `lane-mail inbox --item [ISSUE_ID]` at every wait point the workflow already has.
- **Close-out.**
  - A lane never removes its own worktree. The overseer's close of the lane releases it ([merge-pr.md](../workflows/merge-pr.md) § 5).
  - The lane sends its close-out notice from its worktree, as every other notice.

Mail reaches an idle lane this way:

- A Claude Code lane arms its mailbox monitor as its launch brief's first step says: `lane-mail watch --item [ISSUE_ID]` through its harness's background wake. It re-arms the monitor at each expiry, and runs the `lane-mail inbox` command each announcement prints ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)).
- A Copilot CLI lane arms `lane-mail watch --once --item [ISSUE_ID]` as a background command, which exits at its first announcement. It re-arms the command after each inbox read.
- A Pi lane arms no monitor: the `pi-hooks` mail wake starts its turn when mail lands ([pi-runtime.md § Lane mailbox wake (Pi)](pi-runtime.md#lane-mailbox-wake-pi)).
- A Codex lane arms no monitor ([codex-runtime.md § Lane mailbox](codex-runtime.md#lane-mailbox)).
- For every harness, the watch's wake duty delivers one line to a lane it reads idle with unread mail. Mail it cannot deliver takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver).

On a harness that runs these hooks (`kendex show hook <name>` names the harnesses a hook does not run on):

- The `lane-mail-deliver` hook hands over anything unread after each tool call, and the `lane-mail-check` hook at the turn end.
- On Copilot CLI, the `lane-mail-start` and `lane-mail-prompt` hooks hand it over at session start and at each prompt.
- While an unread halt stands, the `lane-mail-halt` hook refuses every tool call but the `lane-mail inbox` read that acknowledges it.

Elsewhere a halt takes effect when an inbox read or an ask's wait hands it over. A `lane-mail wait` that hands over a halt acknowledges it, as an inbox read does.

The overseer's side:

- The overseer answers with `lane-mail send --re [MSGID]`, directs with `lane-mail send --directive` and halts with `lane-mail send --halt`.
- A `session` lane's directive is `orch-runtime send --item [ISSUE_ID] --file [PATH]`.
- [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane) owns the overseer's side.

### Question tools

Every lane command the runtime's launch builds carries the words below for its harness. They take the question tool away (agent-runtime's `Harness::question_off_words`).

- A lane started through a harness's own session launcher ([oversee.md](../workflows/oversee.md) § 1) is outside the runtime's launch and keeps its tool. It still never uses it.

| Harness | Question tool | Words that take it away |
|---------|---------------|-------------------------|
| Claude Code | `AskUserQuestion`, and `EnterPlanMode`, whose plan ends in an approval dialog | `--disallowedTools=AskUserQuestion,EnterPlanMode` |
| Codex | `request_user_input`: in Plan mode, which only the person at the pane selects, and in Default mode under the `default_mode_request_user_input` feature | `-c features.default_mode_request_user_input=false` |
| Pi | `question`, registered by pi-questions | `--exclude-tools question` |
| Copilot CLI | `ask_user`, a name the lane-mail hooks do not refuse | `--no-ask-user` |

The overseer, on any harness:

- Its question tool is taken away on each harness above whose launch the runtime builds, while `AGENT_RUNTIME_QUESTION_TOOL` is `off`; `overseer` keeps it for a launched overseer.
- Every question for the owner is `lane-mail ask --item overseer --to owner`, with one chat line naming the ask ([communication-modes.md § Owner asks](communication-modes.md#owner-asks)).
- The setting alone decides, for `start-controller` and `request-transfer` launches.
- Words typed on a hand-started overseer do not carry to its successors; a hand-started overseer keeps its tool and does not use it.

Where the harness runs hooks:

- The `lane-mail-halt` hook refuses the question tools above in a launched lane, naming the `lane-mail ask` and `lane-mail wait` route.
- The `lane-mail-check` hook holds, or reports to the overseer, a launched lane's turn end that sent no `lane-mail` ask or notice and made no update to its lane status file since the last judgement.

A lane that ends its turn to wait on a dispatched agent or an armed wake follows [§ Lane mail](#lane-mail).

Every lane brief also closes on the unattended words, `runtime/src/watch/unattended.txt`.

- On every harness, the runtime's launch closes every local and hosted lane brief on them once, before the output mode sentence of [§ Lane Output](#lane-output) ([lane-directive.md § Brief file](lane-directive.md#brief-file)).
- The watch's relaunch closes its brief on them too.
- A cloud session's brief closes on the cloud session words instead.
- The words never ride Pi's `--append-system-prompt`, which stops Pi reading its discovered `APPEND_SYSTEM.md`.

### Compaction

- The runtime's launch turns automatic compaction off on every Claude Code and Codex lane and controller (agent-runtime's `Harness::compaction_off_words`), so the context mark sees the real window.
- Pi turns it off through its settings file.
- Copilot CLI has no switch for it. A Copilot CLI fleet session keeps its own compaction, and [copilot-runtime.md](copilot-runtime.md) owns its context reader.
- On every harness, the lane's handoff at its mark follows [§ Round Closure](#round-closure), Handoff at a mark, and [oversee-events.md § Hand off a lane before it runs out](oversee-events.md#hand-off-a-lane-before-it-runs-out).

### Tracked issue creation

- A delegated orchestration session (lane) never creates a tracked issue.
- TPM analysis from the project-management skill's audit-issues workflow § 2.1 or § 4.1 runs in a lane or a delegated subagent, never in the overseer session.

A lane records a proposal as a tracker comment:

1. Defer the proposal until its source PR merged or its source commit landed on the base branch. Post a review-born proposal only when it clears [finding-disposition.md § Filing bar](../../reviewer/references/finding-disposition.md#filing-bar).
2. Resolve the lane's tracker. Write the comment to a file with the harness file tool.
   - Its first line is `Proposal: [TITLE]`.
   - It also carries `Source: [SOURCE]`, either `Source PR: [OWNER/REPO#N]` or `Source commit: [LANDED_SHA]` for a direct push, `Priority: [1-4]`, `Reached by: [BEHAVIOR]`, `Reason: [WHY TRACKED WORK IS NEEDED]` and `Evidence: [REPOSITORY_PATH]`.
   - A `review`, `pr-comments` or `local-review` source at priority 2 also carries `Symptom: [OBSERVED_FAILURE]`.
   - The evidence path uses a semantic anchor, never a line number.
   - After those lines, one plain paragraph states the person's problem and what the tracked work buys. Leave the machine fields unquoted and in place.
3. Post it. Linear: `.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file [PATH]`. GitHub: `gh issue comment [NUMBER] --repo [OWNER/REPO] --body-file [PATH]`.
4. Send one `lane-mail notice` whose text is `Proposal comment: [TRACKER] [REPOSITORY|-] [ISSUE_ID] [COMMENT_ID_OR_URL]`. The overseer records that binding in the fleet log; an unbound comment is not a proposal.

A gap a lane finds in a package or a workflow is a proposal through lane mail and the sweep, never a harness memory or a local note. The lane status file carries no proposal.

The project-management skill's proposal-sweep workflow owns the tracker-specific fleet analysis.

- It runs in a subagent the overseer launches, returns issue-mode audit JSON and files nothing.
- The overseer checks that output against live fleet work.
- It then invokes that skill's audit-issues workflow with `--analyzed`, and project-order resumes at its § 2.2.
- The overseer records the created issue ID or a one-line decline against the source comment through the same tracker.

A non-delegated primary session routes creation through TPM, except `plan-issues` and `start-new`, which it runs directly with their workflow's label sets.

### Verifier returns

A verifier the overseer delegates writes its full evidence as one Linear comment on the issue it verified, and writes no report or evidence file for the overseer. It returns exactly one line per requested issue, with no other text, no duplicate and no unrequested issue:

```text
[ISSUE] | verdict: [kept|canceled] | owner: [REPO_PATH_OR_NONE] | Done-when: [ONE_LINE_RESULT] | delta: [EXPECTED_DELTA_LINE_OR_NONE] | project: [PROJECT_NAME_OR_NONE] | agent: [agent:LABEL|none]
```

- Every field is required.
- For an item judged by the filing bar, `kept` means it clears the bar and `canceled` means it falls below the bar.
- If the Filing record's `Reached by:` line names an owner or Jarvis decision that authorizes the work, return `canceled` only for a duplicate and `kept` otherwise.
- When the issue team's project inventory is nonempty, name a project from it on every kept row and every row for an item backed by such a decision. With an empty inventory, return `project: none` and skip project validation.
- When `LINEAR_AGENT_LABELS` is nonempty, return an `agent:` label from that list. With an empty list, return `agent: none` and skip agent validation.
- The return carries no issue body or evidence text.
- The sender and the receiver both apply this contract.

---

## Lane Output

No person reads a lane's pane. The overseer learns a lane's state from `lane-mail`, the lane status file and what the watch reads off the pane.

`ORCH_LANE_OUTPUT` ([settings.md](settings.md)) takes `quiet` or `normal`; `normal` prints every block as written.

- Every launch the runtime makes closes the lane's brief on the sentence for the mode its settings resolve: `runtime/src/effects/lane-output-quiet.txt` or `runtime/src/effects/lane-output-normal.txt` ([lane-directive.md § Brief file](lane-directive.md#brief-file)).
- A brief sent through a harness's own session launcher ([oversee.md](../workflows/oversee.md) § 1) closes on the sentence for the mode `orch-env ORCH_LANE_OUTPUT quiet` prints.
- A lane follows the mode its brief states.
- A lane whose brief states none reads `orch-env ORCH_LANE_OUTPUT quiet`.

The mode governs a lane: a session whose launch brief names a lane status file and a mailbox ([lane-launch.md § Lane directive](lane-launch.md#lane-directive)). A session with no such brief has a person at its pane and prints as written, whatever the setting.

Under `quiet`:

- Print one line per completed step and nothing else of your own: no narration before a step, no recap after it, no closing summary.
- Write a filled `<output_format>` block, never print it.
  - Write it to the artifact the step already owns.
  - Where the step owns none, write it to a file of its own under the worktree's `tmp/`, one file per block, so no later step overwrites what a printed path named.
  - Then print `output: [PATH]` and continue the workflow.
- A block, a request or a comment file a step writes after the pull request merged ([merge-pr.md](../workflows/merge-pr.md) § 5) goes in the item's own folder, never under the main checkout's `tmp`.
  - That folder is the parent of the `result.path` that `orch-runtime state path --item [ISSUE_ID]` prints.
  - The case covers merge-pr's own later steps (§ 6 Present Results) and a caller's steps after it ([micro.md](../workflows/micro.md) § 5).
  - The condition decides the destination, so a block's citation names this rule alone.
  - The overseer reads the file as [oversee-reads.md](oversee-reads.md) § Bounded lane reads states.
- A block standing ahead of an ask gate is that ask's own file. Write it, then send it as `lane-mail ask --file [PATH]` ([§ Lane mail](#lane-mail)): the question carries the block, and the pane carries one line.

The lane status file is never a block destination.

- Under [lane-launch.md § Lane directive](lane-launch.md#lane-directive) it carries the current step, the blocker, the handoff paths, the validation minutes per round, the review line and the merge-attempt record (exit, exact head and returned route), and nothing else.
- Each rewrite keeps the review line and that record.

Never suppress harness output. The prompt, the usage banner, dialogs and the end-of-turn line stay as the harness prints them.

The watch hands each event the pane lines that event's handling reads and no more, capped by `ORCH_WATCH_TAIL_LINES`.

- [oversee-reads.md](oversee-reads.md) § Bounded lane reads takes that payload as the lane's state.
- [oversee-events.md § Event kinds](oversee-events.md#event-kinds) names the lines each kind carries.
- Under `quiet` those lines are the step lines and the `output: [PATH]` lines.

A subagent's own output is outside this rule: the lane reads it in either mode.

- An `<output_format>` block nested inside a `<delegation_format>` is the delegated agent's return shape, not the lane's, and cites nothing.
- Every other block in `../workflows` cites this section.
