# Oversee events

Read when [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) handles a watch event. Apply Judgement rules to every event, then look up its Event kinds entry. The event entry supplies the condition and the required action.

## Judgement rules

Review panels take the [pre-panel context check](../workflows/review-pr.md#2-prepare-reviewers) before any attached reviewer starts.

The overseer owns fleet judgement, not just liveness; every `oversee.md` § 4 event is handled under these rules.

The fleet log is the oversee state's `fleet_log[]` ([schemas/workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), which exists before the first append per `oversee.md` § 3 Lane record. Every record a rule below asks for is one append, `[KIND]` being `proposal`, `ruling`, `close`, `peer` or `use1` and `[ITEM]` the issue or repository it is about. `[ONE_LINE]` carries text the overseer did not author, so the record crosses a file and never argv ([SKILL.md](../SKILL.md) § Harness-Safe Shell): write it with the harness file-write tool, then bind the path.

Append each record before replacing the file for the next one.

The record carries no time: `orch-runtime state log append` stamps `at` from its own clock. It refuses a record that is not a JSON object as `fleet-log-record`, an `at` that does not read `YYYY-MM-DDThh:mm:ssZ` and name a real instant as `fleet-log-at-invalid`, one later than its clock as `fleet-log-at-future`, and `[ONE_LINE]` longer than `ORCH_FLEET_LOG_ROW_BYTES` bytes, default 600, as `fleet-log-row-bytes`.

```json
{"kind":"[KIND]","item":"[ITEM]","text":"[ONE_LINE]"}
```

```bash
.agents/skills/orch/scripts/orch-runtime state log append --fleet tmp/fleet-log-record.json
```

A standing instruction from the owner is one row of the oversee record's `standing[]` array, and its lift one `ruling` row: [communication-modes.md § Recording](communication-modes.md#recording).

### Lane proposals

Record each lane's `Proposal comment:` notice in the fleet log as an authorized tracker, repository, issue, and returned comment ID or URL binding.

Partition pending authorized comments by tracker and source PR repository.

For each batch, launch one fresh one-shot canonical `tpm` subagent, the catalog's planning agent that owns the creation bar, priority, placement, duplicate and cancellation analysis, on the lowest-cost model the surface exposes, with the launch call, surface rule, single-return capture and retirement of the `triage` verifier under § Event kinds, naming `tpm` where that call names `maintainer`.

A proposal sweep creates no carrier item and starts no lane, and its TPM analysis never runs in the overseer.

Send it the project-management skill's proposal-sweep workflow with a brief that supplies a checkout of the source repository on this host as its worktree, the batch tracker, tracker repository, source repository, fleet issue IDs, and authorized and resolved comment bindings.

Accept the return only when it contains no other text and parses as one issue-mode audit object whose `tracker` type, and for GitHub its `repository`, equal the batch's.

Its proposal rows are its `create` and `skip` rows: each carries exactly one `proposal_sources[]` entry by `index`, each entry names a distinct authorized binding of this batch, and no entry points at another row.

A proposal whose source PR has not merged has no row and stays pending for the next sweep.

Stop without a reply or fleet-log outcome on a launch, capture, parse, or validation failure.

Write the accepted object with the harness file-write tool to `tmp/proposal-audit-[UTC_EPOCH].json` in the overseer's checkout, `[UTC_EPOCH]` fresh per batch.

Check its rows against live fleet work, then invoke the project-management skill's audit-issues workflow from `oversee.md` § 1 as `audit-issues --analyzed tmp/proposal-audit-[UTC_EPOCH].json` under `PM_CREATE_AUTONOMY`. Its normal route parses the tracker, runs its tracker preflight and label inventory, skips TPM analysis, and continues through its §§ 5-7.

For Linear, reply with `.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --parent [COMMENT_ID] --body-file [PATH]`. For GitHub, use `gh issue comment [NUMBER] --repo [OWNER/REPO] --body-file [PATH]`; its first line is `Proposal outcome for [COMMENT_URL]:`. Each outcome carries the created issue ID or one-line decline.

Record the source and outcome in the fleet log.

### Heartbeat backstop for lane proposals

At each `heartbeat` and before fleet close, run the Lane proposals sweep with every fleet issue in its tracker and repository batch. This catches a comment posted without another event.

### Heartbeat backlog audit

At each `heartbeat`, apply [Heartbeat audit](heartbeat-audit.md), independently of the lane-proposal sweep and the fleet-lane `triage` verifier.

### Heartbeat design review

At each `heartbeat`, apply [Design review](design-review.md)'s `heartbeat` row to every `running` lane.

### Cut scope blowups

A PR whose diff outgrows its issue's Done-when goes back to the contract: keep the oversized work on a branch, land the contract.

Machinery no issue ordered, a new subsystem, scanner or lexer, is cut, never reviewed into shape.

### End spirals

A round whose finding shares a root cause with one a prior round patched is dispositioned by [references/finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence), which states the branches and their limits.

Bots drip-feeding one class get the class exhausted in one audit pass, then dispositions without pushes.

After five bot rounds on one PR, the lane answers the standing threads once and starts no further fix round. The review gate and the user's merge authorization still apply.

The overseer never orders a blanket `Declined` across a PR's open findings: each one is dispositioned on its own mechanism, and a label-only decline violates [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow).

### Fix the source

The same finding class on a third PR is a mechanism gap: file it and route the smallest deterministic check (a guard lane, a preflight rule, a refusing script) or one sentence in the owning skill through a lane as its own item. The overseer still implements nothing.

Deterministic beats prose where it stays simple; complex or brittle machinery is worse than either.

A package or workflow gap is never a harness memory or a local note: a lane's is a proposal ([skill-rules.md § Coordination, Tracked issue creation](skill-rules.md#coordination)), and the overseer's own is filed as File one item alone below states.

### File one item alone

Before filing, read [Design review](design-review.md).

One item the overseer files itself, a class under Fix the source above or an issue an `owner-note` asks for, goes through the project-management skill's audit-issues workflow as `audit-issues --single [FILE_PATH]`, the file holding that one item per that skill's audit-issues input schema with `source: "oversee"`, `parent_issue: null` and the fleet's `tracker`.

After filing, append one fleet-log `ruling` whose text starts `filed ` and names the filed item, its Location file(s) and its defect-class rule, stated as the rule every site breaks. `--issues` is for a batch: its TPM run sweeps the whole backlog for cancellations.

### Rule once for the fleet

A ruling that answers one lane's question is sent to every lane in the same situation and recorded in the fleet log.

### Held merges

Under `ORCH_MERGE_AUTONOMY=ask` (`oversee.md` § 3) the lane's merge question arrives as `lane-question`.

Read the gate results without reproducing them, then relay the question to the user, worded as communication's [questions](../../communication/references/questions.md) requires.

Send `MERGE` to the lane only after the user authorizes it, or send exactly one directive the user gave. A directive may carry the authorization ("with that landed, MERGE stands"), and the lane then merges once the change is in without a second answer.

Under `ask` a `disarmed` pr-watch line on a `land=lane` record is not a wake; on a running `land=handoff` record it launches the landing lane (`pr-watch` below).

### Lanes merge their own pull requests

A lane whose gates read met merges its own head by [merge-pr.md](../workflows/merge-pr.md) § 5 step 1, where `pr-merge` picks the route. The overseer runs no normal merge for a lane.

Its own GitHub App acts for the head approvals [copilot-head-notices.md](copilot-head-notices.md) sets, and for nothing else except an emergency merge in a consumer whose ruleset lists that app as a bypass actor, which that step's "Who acts" names.

A merge group that cannot pass because a CI input read from the default branch broke takes the recovery route in review-gate's `SKILL.md` § 4. Operations.

### Hand off a lane before it runs out

The `lane-mail-check` turn-end hook reads the lane's context through its harness adapter, from the transcript, or on Copilot CLI from the reading its kendex Copilot extension recorded from Copilot's `session.usage_info`, against the limit Copilot compacts at, and where none stands from Copilot's statusLine session record ([copilot-runtime.md](copilot-runtime.md#measurement)). Which marks the hook judges on each kind of lane, the turn end it refuses, and when the lane writes the record below: [skill-rules.md § Round Closure](skill-rules.md#round-closure).

Copilot honours a turn-end block 8 times in a row and then ends the turn unheld; the refusal returns at the session's next turn end.

Between a lane's turn ends, read `tmp/lane-mail/[ITEM]/context.json` under its `mail_root`, a hosted lane's through `lane-host cat --item [ITEM] [PATH]`. Treat a record whose `harness` differs from the lane record's, or whose nonempty `session_id` differs from a nonempty one the lane record binds, as another session's. Read the lane's account mark between turn ends too, with `orch-runtime accounts pick --fleet --lane [ACCOUNT] --harness [HARNESS] --min-headroom-pct [ORCH_HANDOFF_HEADROOM_PCT]`, the judge the turn-end hook asks, `[ACCOUNT]` being the lane record's `account`; a Claude or Pi lane adds `--native-model [MODEL]`, `[MODEL]` being the lane record's `model`, as the hook does. A `result.exit` of `0` is room. At `3`, a `result.answer` of `walled` is the mark reached, its `result.record.verdict` `walled` or `seat-reserve`; a `result.answer` of `reserved`, `retired` or `excluded` is the account refused by its owner's setting, not a mark: tell the owner. Any other answer leaves the mark unknown, never room. These two reads judge every mark [skill-rules.md § Round Closure](skill-rules.md#round-closure) leaves to the overseer, and are the backstop for a lane whose hook refuses nothing, such as one past its account mark with no turn end since.

The shared context rule, which the runtime's one context judge applies (`orch-runtime marks --item [ITEM] --context [TOKENS]:[WINDOW]`, the turn-end hook's call), without an agent reserve, requires handoff at 400000 tokens used, or strictly past the effective percentage of the printed window. `ORCH_HANDOFF_CONTEXT_PCT` accepts 1 to 100 and defaults to `90`; values above `90` use `90`. A lower setting requests an earlier handoff only after usage strictly exceeds that percentage. Equality at any percentage does not trigger handoff, unless the independent token limit is reached. The token limit applies even when capacity is unknown. Below that token limit, unknown capacity remains unmeasured. Capacity means the limit before automatic compaction, or the actual window when automatic compaction is disabled; [skill-rules.md](skill-rules.md#coordination), Compaction, defines the harness controls.

`ORCH_HANDOFF_AGENT_RESERVE_TOKENS` reserves nonnegative whole tokens for attached agent returns before the earlier context mark. Its default is `150000`. The reserve applies only to the attached-launch refusal, and only while an attached agent this session launched may still be out. On Claude Code the hook reads that roster from the session's task registry where the payload carries one, else from the transcript's Agent-call results, task notifications, teammate idle notifications and sends; an unreadable roster, or an entry neither read classifies, is unknown. On Codex the hook reads ordered collaboration calls and results from the rollout. A full unfiltered list replaces earlier unknown observations only when its call does not overlap a launch or followup. Pending calls and unreadable current observations keep the roster unknown. After waiting for agents, call `list_agents` with no path filter to observe their returns. Other harnesses read no roster, so their rosters are unknown. While the reserve applies, the existing tool hook refuses attached launches at or above that mark minus the reserve, including equality. A launch refused by the reserve alone, below the plain mark, with an agent out names waiting for the attached agents to return, the job runner or a separate session, and no handoff. With the roster unknown no return can be observed, so that refusal names the job runner or a separate session, and for a lane its handoff record, never a wait. The reserve protects only a new launch. The turn-end judge and the overseer's own marks (`orch-runtime marks --fleet`) use the plain rule above, even with an agent out, because a succession waits for every attached child ([oversee.md](../workflows/oversee.md) § Succession step 1) or names each unfinished one in the handoff. Missing required context also refuses the launch. Claude Code, Pi and Copilot CLI enforce this launch rule. Codex enforces it for `spawn_agent` and for `followup_task`, which starts a new turn on an attached agent, under any tool namespace. `send_message` only queues a message and is admitted. OpenCode installs advisory instructions only. Longer work uses the orch job runner ([waiter-launch.md, Launch](waiter-launch.md#launch)) or a separate session, with its run directory on the handoff. The general wait and emergency recovery rule is the Jarvis `long-session.md`, Handoff, contract.

A reading is stale when it is older than an hour while `session-rows.jsonl` beside it holds a later Stop row. Treat no record, another session's record, an unreadable record and a stale one as unknown, never as room. Apply the shared context rule only to a current measured reading. A reading whose `window` is null or 0 and whose `tokens` are below 400000 has unknown capacity: direct the lane to write its handoff record. If the context or account mark requires handoff and no handoff record stands, tell the lane to write its handoff record. Send the directive through lane mail ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)). When the lane writes its record: [skill-rules.md § Round Closure](skill-rules.md#round-closure). It writes the `record-handoff` request below to `tmp/handoff-request-[ISSUE_ID].json` with the harness file tool, runs it, and exits. The request carries no time: the runtime stamps `written_at` from its own clock, refuses a given stamp that is not ISO 8601 UTC as `handoff-written-at-invalid` and one later than its clock as `handoff-written-at-future`, and refuses an unconsumed standing record with other content as `handoff-differs`; a record a relaunch resumed, which carries `resumed_at`, is replaced by the next handoff ([workflow-state.md](../schemas/workflow-state.md) `handoff` row). The watch reports `handoff [ISSUE_ID]` once. Relaunch the item through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), which uses the handoff record as durable recovery state; a copilot lane's relaunch starts a fresh session on that record rather than resuming the one that handed off.

```json
{"op":"record-handoff","merged":["[PR]"],"remaining":["[STEP]"],"branch":"[BRANCH]","worktree":"[WORKTREE_PATH]","open_pr":[PR_NUMBER_OR_NULL],"traps":["[TRAP]"]}
```

```bash
.agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request tmp/handoff-request-[ISSUE_ID].json
```

Include any in-flight foreground validation in `traps`. State whether it survives the agent's scope and carry the run and recovery details required by [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation). A queued run whose parent is gone follows that interruption route.

The record, the event and the relaunch are surface-independent. On surface 2 read a lane's context through the harness's own session tooling and hand off at the same mark; surface 3 has no lane to hand off.

On a hosted fleet, also run `lane-host list`: a row not `available` whose item, the last segment of repository/item, has no `running` lane record is a sandbox with no live claim; surface it to the user.

The runtime's `marks --fleet` judges the overseer's shared context mark, account headroom, projected wall time at `ORCH_OVERSEER_WALL_MINUTES`, and process memory under its inherited cap. The turn-end hook supplies its current reading, and the watch supplies the recorded reading between turn ends. An unread or unmeasured trigger is never room. The watch reports a reached mark as `overseer-mark`; when it repeats, and what its line names under each `ORCH_OVERSEER_SUCCESSION` value, a succession owner's command among them: [overseer-session-events.md § Event kinds](overseer-session-events.md#event-kinds). A silent interval does not mean the mark lifted. `ORCH_OVERSEER_SUCCESSION=off` disables the account-trigger refusals. The context refusal remains until this session records its handoff. At a trigger, follow [oversee.md § Succession](../workflows/oversee.md#succession).

A dead or walled overseer takes no turn and calls no succession, so the watch judges its session, and it tells the owner of each death it says through the overseer mailbox's owner channel. The events, whether the watch requests recovery and with what successor, and the owner's notice: [overseer-session-events.md](overseer-session-events.md), `overseer-dead` and `overseer-walled`. The successor reads available output from the predecessor's children before repeating their tasks.

### Keep the report's inputs current

After each `oversee.md` § 2 selection, `orch-runtime state set --fleet /launch_queue '["[ITEM]",...]'` with the items not yet launched, in launch order. The queue is the order and the tracker the membership: the `heartbeat` handling below adds what the tracker says the fleet owes.

A question sent to the owner is an owner ask ([communication-modes.md § Owner asks](communication-modes.md#owner-asks)), and the report's Waiting on you row reads the unresolved ones from the mailbox itself; nothing is recorded in the state for it.

### Decide without the user

The ask set is [communication-modes.md](communication-modes.md) § Ask set, which nothing here narrows or widens. Any other call takes the option that costs nothing and is recorded in the fleet log as that file's § Recording requires.

## Direct-push cycle records

A direct push raises no PR `merged` event. When a lane reports a successful direct push to the base branch, close it with the pushed commit as the close's `delivery`, so the close writes its cycle. Run from a checkout of that repository: the cycle reads the commit there and the push from that repository, the lane record's `repo` or else the checkout's own. Write the request to `[REQUEST_FILE]` with the harness file tool, then run it:

```json
{"op":"close-lane","item":"[ITEM_KEY]","delivery":{"commit":{"commit":"[PUSHED_SHA]"}}}
```

```bash
.agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] op --fleet --request [REQUEST_FILE]
```

The cycle carries the lane record's launch tier; a record with none adds the note `oversee-cycle: launch-tier-missing item=[ITEM_KEY]`. `merged` is the time the push reached the base branch, as GitHub's repository activity log records it, never the commit's own date; where that read fails, `merged` is null and the note `oversee-cycle: merged-unread commit=[SHA] cause=[CAUSE]` names the cause. Unknown fields print `-`. A cycle the close cannot record leaves the lane with none and the note `cycle-unrecorded cause=[CAUSE]`; the close goes on. The notes are the reply's `.result.notes`, and the cycle's line joins the fleet log as a `cycle` row.

## Event kinds

Each event is one `EVENT` line; its fields are the event's render in [watch/events.rs](../runtime/src/watch/events.rs), and a heading below names the fields its handling reads.

`watch-step-failed step=[DUTY] count=[N]` means the scheduler duty named (`mail`, `native-observation`, `tracker`, `verification`, `report`, `reconcile`, `heartbeat`, `wake`, `github` or `retention`) failed whole or in part on its last run: `N` counts its failures in a row, and the line prints on the first and every `ORCH_OVERSEER_MARK_REPEAT`th after, so a standing failure does not wake this session every pass; the count is the run's, and a restart prints once more. The lines and rows of a run that failed in part stand, the duty runs again at its next cadence, and the other duties go on. Read the cause under the same words in `oversee-watch.err` beside the fleet state: `step=tracker` with `lane-close-failed item=[ITEM] cause=[KEY]` lines under it names each GitHub-tracked lane whose issue read was refused, its close deferred to the next pass; `step=mail` with `item=[TARGET] [CAUSE]` lines names each mailbox the turn could not read, every other box delivered. A hosted read that failed is the lane duty's partial failure under the same words: `host-capabilities-unread host= cause=` for a provider whose capability line could not be read (asked once per host per pass, for the hosts of in-flight lanes alone, so a parked, done or stopped record's gone provider hides no live lane's line), `start-stall-unread`, `lane-long-rounds-unread`, `pr-read-failed`, `state-read-failed` for a watch state directory or close marker it could not read, and `lane-close-unconfirmed` (`cloud-stall-closed` below). Correct the cause the line names; a malformed fleet record is corrected against [workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state).

`tracker-quota` means this pass could not finish its tracker reads. Keep owner answers unread. An absent owed or Verifying line during this hold is unavailable evidence, not proof that no work remains. Follow the linear skill's quota contract and its `patterns/workflow-actions.md` for held writes. Mail, available GitHub and lane checks, and report-due checks continue. The heartbeat repeats the scheduling receipt while it stands.

`github-auth-failed cause=[CAUSE]` means the GitHub duty's sign-in was refused and the github skill's credential ladder, run again, selected no working credential, so every GitHub read of the fleet fails and none of that duty's lines print. The line prints on the pass that reads it, and the watch sends the owner one notice through the overseer mailbox's owner channel on the duty's next pass; nothing repeats while the cause stands, and a pass whose GitHub reads answer clears it. The duty's `watch-step-failed step=github` line carries the ladder's words, and the watch runs the ladder again at most once per long pass while the failure stands. Sign `gh` in again, or renew the token the ladder reads; the next GitHub pass takes it.

A lane's successful direct-push completion closes through [§ Direct-push cycle records](#direct-push-cycle-records).

To wake a lane below is to send it the directive as [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane) says.

### `merged`

every PR the watch reported `refresh-ready` gets `EVENT merged <PR> kendex/refresh <repo>` at its merge, once across restarts. This line triggers the base-move check for open lane PRs whose files the refresh changed. Approval while open and an unmerged close print no merged line. A refresh has no owning lane; handle its base-move check and follow the repository's declared refresh owner.

For an item PR, the PR is in; the owning lane finishes `merge-pr.md` § 5 on its own, and where its worktree or sandbox is gone the runtime's close completes the item's branch boxes from the PR body's `## Done-when evidence` section ([lane-reach.md § Lane close](lane-reach.md#lane-close)). A GitHub merge alone is not lane completion.

The watch closes a parked or stopped item the tracker reads terminal through the runtime close on the `terminal` ground, `lane-closed`, or `lane-close-refused` with its cause on stderr. That close writes the lane's merge cycle with it, for the first of the item's merged pull requests that is the lane's own, the record's `parked` or `pending_pr` pull request, else one in its repository, or in the repositories read for a record naming none, unless the record's `cycle` already names it. Before every terminal close the watch reads the lane's merges itself, the same read the GitHub duty makes, over the lane's repository, `ORCH_CONNECTED_REPOS` and the watch's `--repo` values, whatever `merged` line an earlier pass said. The cycle's `cycle item=...` line comes before the `lane-closed` line in the stream. A parked record whose pull request is open or queued stays parked, whatever the tracker state. A resumed record whose retained PR is OPEN also stays in the fleet, including after failed create leaves it stopped; [workflow-state.md](../schemas/workflow-state.md#oversee-state) owns the retained identity. A parked Done item with an unchecked Done-when box takes the parked-merged rule after its recorded pull request merges. A stopped Done item with an unchecked box also stays open for Recovery relaunch, including after a parked resume starts the sandbox but fails to create the harness.

A cycle the close cannot record is `lane-close-failed item=[ITEM] step=cycle cause=[CAUSE]` on the watch's stderr, `cause=merged-unread` for a merge read that failed; the close goes on with no cycle in every case. While the close is held or left open the next pass reads the record's `cycle` again and records a cycle still missing; once the close ends the lane, nothing records it, and the stderr line is the report. The cycle uses the recorded launch tier and does not invent a missing tier. Read its cycle line under the verdict rules below. The class target forgives one clean final-head CI run and the merge group. [runtime/src/ops/cycle.rs](../runtime/src/ops/cycle.rs) owns the class bases. The cycle row keeps lane-controlled time as `lane=` and end-to-end open-to-merge time as `open=`. The rollup, `orch-runtime cycle rollup`, shows both medians and the miss share on lane-controlled time.

The cycle row is the report for a Done item with no open box; no lane completion check or relaunch is required. A parked item with work left takes the `parked-merged` rule, which records the cycle once relaunch brings its sandbox up.

For a running item, the lane's close writes its cycle. The watch closes a merged hosted lane with its merge as the close's `delivery` ([lane-reach.md § Lane close](lane-reach.md#lane-close)). Close a local lane once it has finished `merge-pr.md` § 5, adding `"delivery":{"pr":{"pr":[PR_NUMBER],"repo":"[OWNER/REPO]"}}` to the close request § Direct-push cycle records shows, from the overseer's base checkout, or from a checkout of the lane's repository where its `mail_root` is another repository's worktree, as `oversee.md` § 3 runs `lane-mail` for it. The close writes the `cycle item=...` line, and a `repeat-miss` line where it makes the third miss on one phase, to the fleet log as `cycle` rows. A `verdict=miss` line needs nothing more; a `repeat-miss` line is three lanes missing on one phase, and files one CI or process issue in that repository naming the phase, the lanes and the `causes` the line gives each, per [skill-rules.md § Coordination](skill-rules.md#coordination). A refusal is reported and never blocks the rest of this rule.

A hosted item stays in the watch until its `lane-closed` or `lane-close-refused` event, per § Event kinds. Send it nothing while it is still inside that run, and read a reported failure there rather than advancing the item.

For a parked or stopped item this rule ends here. Items whose tracker reads terminal close in the watch. A parked item with work left gets `parked-merged` and its resumed lane runs `merge-pr.md` § 5 steps 2-6.

For an item that is not parked, follow the repository's declared refresh owner in its consumer instructions. On a hosted fleet, run `.agents/skills/orch/scripts/sync-base` in the control checkout. The first sync can receive the item merge before the owner's refresh commit exists; it is not refresh completion. Keep refresh and verification with the declared owner outside the control host, and run `sync-base` again after its reviewed outputs merge. Report a failed owner workflow. Consumer refresh stays in each consumer's own Actions through the refresh workflow the review-gate skill's adoption reference describes.

On a local fleet, run `.agents/skills/orch/scripts/post-merge --command-only` in the overseer's base checkout when a declared workflow owns refresh. When the local fleet is the refresh owner, run `.agents/skills/orch/scripts/post-merge` without a mode flag. After either local mode succeeds, run the repo's lifecycle check. All post-merge modes retain checkout changes; report those diffs to their declared owner. A later sync can refuse pending changes; report that refusal and preserve the changes. Stop on a failed step and report its status.

When the fleet's LAST item completes, run the `heartbeat` triage pass before closing out, whatever the tracker; items living in Linear also get `.agents/skills/orch/scripts/orch-runtime reconcile-items`, whose exit-0 reply carries its findings in `result.findings` and its box lines in `result.lines` (a GitHub-item fleet skips that with a note). Report both with the close-out.

### `parked-merged [ITEM] pr=[N] repo=[OWNER/REPO]`

the wait PR merged and the item has work left. A dependency park selects `parked.until_pr`, even with no own `parked.pr`; its own PR merge cannot clear that wait. A queue park selects `parked.pr`.

Relaunch through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), whose parked rule starts the sandbox with `lane-host start` first, since the runtime's launch starts no stopped sandbox; a sandbox the provider does not confirm started keeps the record parked. The relaunch starts the harness fresh on the kept disk, and the item's handoff record carries its context.

For a dependency park, the lane rebases and continues the held step; record no cycle for the dependency's merge. For a queue park, record the item's cycle under `merged` once the sandbox is up; the lane finishes `merge-pr.md` § 5 steps 2-6 and § 6.

The watch repeats this hand before each heartbeat while the record still reads parked. Recovery relaunch rewrites the record before harness creation, so replay cannot start a second harness. Report a capacity refusal and handle the next repeat.

### `parked-closed [ITEM] pr=[N] repo=[OWNER/REPO]`

the dependency PR closed without merging. The watch reports it once. Resolve the hold or resume the lane through the same Recovery relaunch route.

### `lane-exited`

the window is alive but the harness under it is gone (the lane's closing lines follow the event and say why; `payload-noise-only lines=N` in their place means the lane deleted its own worktree and the shell has drawn nothing since).

A lane stopped by a harness session limit ("You've hit your session limit · resets 9:50am") is not dead: relaunch it on another account the account judge picks, through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), or wait for the shown reset and use Recovery relaunch on the original account. The relaunch's brief carries its continuation, so nothing is pasted after it ([lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch)).

A lane that reported `handoff` on an earlier run is relaunched per that event, not resumed or nudged.

A hosted lane whose item the merged check read merged and whose worktree the host no longer has (its `.git` read through `lane-host cat`) is closed by the watch through the runtime close, its merge the close's `delivery`, at its `lane-exited` or `idle-after-return` line, `lane-closed` with its archive line under it; one whose worktree stands is inside its merge close-out or resumed and is left. A tracker quota hold defers the close, retried while the line still stands.

Any other exit is the `window-gone` rule below.

### `overseer-dead`, `overseer-walled`, `overseer-reserve`, `overseer-context-unmeasured`, `overseer-context-stale`, `overseer-mark`

the overseer's own session: [overseer-session-events.md](overseer-session-events.md).

### `handoff`

the item's lane recorded its handoff and exited: relaunch it per § Judgement rules, Hand off a lane; the record follows the event line. When `cause` is `model-switched`, the relaunch names the recorded `model`, as the model-switch recovery composes its `launch-lane` request from the record after it stops the predecessor: a local one through the runtime close, a hosted one through `lane-host stop` ([lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch)).

A native remote lane dispatches its predecessor stop through the launch identity owner. Report `stop_failure` cause and process identity when that field stands on the handoff. A handoff alone does not confirm that its predecessor stopped: a relaunch refuses `lane-live` while the record reads in flight, so end the lane first as [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) says.

### `lane-closed`

from the hosted lane duty, the watch ran the runtime close under the [Lane close contract](lane-reach.md#lane-close); from the terminal close of a parked or stopped record, the runtime close confirmed, and no line follows. Record the hosted close's line below in the fleet log, the provider's `kept=PATH`, `kept=none` for no archive, `kept=sandbox` for a close that ended the harness and kept the sandbox, or `closed=absent item=ITEM` for a host that no longer held the item and ran no archive pass ([lane-host.md](../schemas/lane-host.md) `close`).

### `lane-close-refused`

from the terminal close of a parked or stopped record, the runtime close refused: read its cause on the watch's stderr, `lane-close-refused item=[ITEM] cause=[CAUSE]`; the refusal is held, asked no more, until the record or the verdict moves. From the hosted lane duty, the provider's close refused, the close's `.result.observation` reading `host_close` `refused`, and the sandbox stays. Surface the `path=` line that follows to the user; its value is the checkout the close stopped on, never the path that stopped it. Render-only drift is saved as a binary patch under the hosted clone's `tmp`, restored, and refreshed before close, and the provider refuses on any of several conditions. An untraced change in the checkout is the common one; a saved patch that does not carry a path the close was about to restore or remove is another. Several of them leave every changed path inside the generated inventory, so a hunt for an untraced path can find none. Inspect the directory and never force the close.

### A by-hand close's answers

the runtime close run by hand ([lane-reach.md § Lane close](lane-reach.md#lane-close)) answers in `.result.word`, or refuses at exit 1 with `refusal.key` and its fields. Report the refusal or the observation to the user. Never type into the pane to end the harness instead. A lane its state reads working, asking or unjudged refuses `lane-live state=[STATE]`, an idle one whose item stays open and whose merge has not landed `lane-live state=idle`, and a walled one `lane-live state=walled` with the `account=` reading and any `resets=` still ahead: the close ends no live lane.

`unconfirmed` is a close whose effect left something standing: its intent stays open and `.result.observation` names what stands, such as `timeout_pid` for a harness that outlived its signal, `identity` `unreadable` for a process read that failed, `wake` `live` for the detached turn the record's `wake` names, still running, `validate` `stop-failed` for a validation run the stop could not end, `item_files` `failed` for the item's files it could not archive, or `host_close` `refused`, `failed` or `unanswered` for the provider's close. Correct the cause and run the same close again: the repeat acts on the handles the intent recorded. `failed` is a close its effect refused before anything was signalled, the cause in `.result.observation`: an unanswered ask below, `ask-check-failed` for a mailbox read that failed, or `lane-moved` for a lane relaunched under the close.

On a hosted lane the close stops the harness through the provider before its close transition, and refuses where that stop does not answer: `stop-failed` names the failed step as `cause=`, `cause=provider status=[N]` with the provider's own lines above the refusal, `cause=answer-unparsed` for a stop answer the close could not read; `exit-timeout` is a harness whose pane did not read exited within `ORCH_LANE_CLOSE_SECS` after the stop, `processes=` the count the provider signalled; `lane-host-busy` is a provider call at its cap, `step=` naming it. The window and record stay.

A hosted stop by `lane-host-ssh` refusing `stop-identity-invalid` is a clone whose `.git/lane-host-pid` holds no pid and start: remove that file and close again, which stops the lane by its worktree. `cause=provider status=4` under `"mode": "keep-sandbox"` is a hosted item whose worktree its own close-out removed, under a stop that finds the harness by that directory: the stop has no directory to find the harness by, and only a full close, which notes `stop-skipped item=[ITEM] harness=[HARNESS] cause=worktree-removed` in `.result.notes`, closes it: its host close ends the harness where the provider's `close` ends the sandbox, and otherwise the window kill hangs up the lane's ssh session. That reading needs the provider's `stop-worktree-removed item=[ITEM]` line above the refusal; `cause=provider status=4` without it is the provider's own `4`, such as a sandbox it stopped, whose line above names it: start the sandbox, then close again.

### A close refused on an unanswered ask

the lane asked the overseer a question through `lane-mail ask` and is waiting for the answer: a hosted lane's close refuses `ask-unanswered` with the `ask=` it found, and a local lane's answers `failed` with `ask-unanswered` in its observation. Closing the lane ends the session that answer would reach, so answer it as [lane-reach.md § Lane close](lane-reach.md#lane-close) states, then run the same close again.

An exited lane takes no such refusal, its session being gone; a stopped record of an open item does, because the sandbox `"mode": "keep-sandbox"` kept can be relaunched into a session that reads the reply. So a keep on an exited lane records `stopped` and refuses nothing, and the later full close of that record, while its item stays open, refuses until the ask is answered. Only an answer lifts it: a relaunch writes none, so a lane relaunched to clear this refusal spends a session and meets it again. `mail-read-failed` is the mailbox failing to read: fix what its `cause=` names rather than closing a lane nothing measured.

### A close refused on the lane's identity

a hosted lane whose record names no harness refuses `harness-unsupported harness=unknown` at its stop: nothing names which harness to stop. Run it again with `"harness"` set to `claude`, `codex`, `pi` or `copilot` in the request.

An `issue-N` record carrying no tracker refuses as `tracker-read-failed cause=key-ambiguous`, that key being what a GitHub lane and a Linear lane are both given: it wants `"tracker"` set to `linear` or `github`, and a GitHub lane's repository, read from nothing, wants `"repo": "[OWNER/REPO]"` besides, else `cause=repo-missing`. Act on that refusal's `cause=`, which names which read did not answer; `cause=read-failed` is the tracker CLI itself failing. `source=derived` is a tracker read from the item key and `source=given` one the record or the request carried. Each field fills only a field the record leaves null or absent, and one that contradicts a value the record carries refuses as `record-invalid` rather than repointing the lane.

An exited lane closes without any of the three, but its files leave the state directory only where its tracker answers, the reply noting `item-files-kept cause=[CAUSE]` where it does not: add `"tracker"` or `"repo"` to that close for a record carrying neither, since a second close of a `done` record never reaches the removal; otherwise its files stay until a later close-out of the item ([schemas/workflow-state.md § Item close-out](../schemas/workflow-state.md#item-close-out)), and the retention duty takes only its workflow state, once its lane record's end is past `ORCH_RECORD_RETENTION_DAYS` and its worktree is gone or kept on purpose ([§ Prune](../schemas/workflow-state.md#prune)).

### `lane-relaunched [ITEM] lane=[DIR] from=[DIR]`

under `ORCH_WALL_RELAUNCH=auto` (default) the watch ran the usage-limit route itself: the shared judge read the lane walled, the runtime's account judge (`orch-runtime accounts pick`) qualified `lane=` for the model the record names with the spent `from=` excluded, and the watch started the record's own relaunch detached from the lane's checkout, its output at the `log=` line: the runtime close on the `no_landing` ground retires the walled harness, then a `launch-lane` request on `lane=` launches the record's harness, model, effort, host, tracker and repository with its refresh choice and permission, the spent account excluded, on the `start` brief, whose workflow reads the item's handoff record ([lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch)). This notice requires no operator launch action.

A walled lane on a host whose kind declares a local pane has its harness stopped through `lane-host stop --item --harness` before the relaunch; a stop the provider refuses or does not confirm is `wall-relaunch-refused lane=[LANE] reason=stop-failed exit=[RC]`, and one it does not answer is `reason=stop-unanswered cause=[CAUSE]`, under the `usage-limit` line, and nothing starts.

While that launch runs, inside `ORCH_WATCH_PREPARE_SECS`, its missing window is no `window-gone`. A failed detached launch reports `lane-prepare-failed` with `reason=relaunch-failed`, its exit status and log, even when the window stays open. A launch that exceeds that bound reports `lane-prepare-stuck`. A walled lane holding an unanswered ask is not relaunched, and a replacement whose launch fails leaves the lane stopped; the watch says either as `lane-prepare-failed ITEM reason=relaunch-failed exit=N log=L`.

The watch's refusal lines name what it never does: relaunch a lane the judge reads `working`, or onto the spent account before its reset.

A wall forced on a scratch lane by removing its account's login, with another account qualifying, takes this route and counts as the wall a check needs; the watch's `EVENT lane-relaunched` line and the lane record naming the new lane directory are the evidence.

### `usage-limit`

the watch left the wall to the overseer: `ORCH_WALL_RELAUNCH=ask`, no lane qualified (`pick none`), or a `wall-relaunch-refused lane=[LANE] reason=[REASON]` line under the event names the step that stopped it. `reason=context-unavailable cause=[CAUSE]` is a record the relaunch cannot compose its requests from: `checkout-unrecorded` or `checkout-unavailable` for a launch checkout it names none of or that is gone, `provider-relative` for a provider path that is not absolute, `permission-choice-unrepresentable` for a recorded permission flag whose value the harness's table lacks, `brief-unspelled` or `tracker-unknown` for a record whose start brief it cannot spell, and a brief or request file it could not write. `reason=spent-account` is a pick that named the spent account. `reason=stop-failed exit=[RC]` is a hosted stop the provider refused or did not confirm, `cause=` in place of `exit=` naming a `lane-host` that never started, and `reason=stop-unanswered` one that gave no answer within its bound or ended by a signal or a status of 128 or above, the shipped ssh provider's 255 for a failed ssh among them: the harness may still run, so nothing starts beside it (`lane-relaunched` above). `reason=stop-unjudged` is a host whose capability line could not be read, and `reason=marker-unwritten` or `reason=launch-failed` a relaunch that could not start.

The line under the event is the judge's answer where one ran: `pick lane=[DIR]`, `pick none`, or `pick unjudged [CAUSE]`, the cause being the account judge's own where it could not judge, or `named-lane-answer` for an answer only a named account gets. A record naming no harness, model or account asks no pick, and the event carries no pick line.

Read the lines under it and confirm the banner is the harness's own, not a limit phrase the lane printed; a lane still working is left alone.

With `wall_kind=auth`, the shared judge found a login failure, a wall with no reset: the event carries no `resets=`, and the account judge never picks an account whose credential no longer answers, whatever harness the launch names, since its row reads unmeasured ([runtime/src/ops/accounts.rs](../runtime/src/ops/accounts.rs)). Recovery is a relaunch on another account, the `launch-lane` request's `account`, never the walled one; when none qualifies, report blocked recovery and ask the operator to sign in.

Before any manual stop, apply [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch).

Under `ask` with `pick lane=[DIR]`, only for a lane that rule admits, take the steps the watch takes under `auto`: on a hosted `pane=local` lane run `lane-host stop --item [ITEM] --harness [HARNESS]` and require its `stopped item=[ITEM] processes=[COUNT]` line, keep the window, which that route's runtime close closes, then run [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) with `[DIR]` as the request's `account`.

For an admitted lane with no account of that harness qualifying, pick another terminal harness and relaunch with the one-sentence continuation brief from `handoff.md` § 2, including the matching path from the prior harness's transcript store.

When no replacement qualifies and the event has `resets=`, keep the existing window and wait for that reset: it announces `usage-limit-passed`, and the overseer sends its one-line continuation nudge. A `resets=` pinned from a clock or weekday is an upper bound, so read the lines under the event. Never launch onto the spent account again until its reset, and never park a lane against an estimate of your own when `resets=` states the time.

A wall reported without `resets=` is announced once and nothing announces it again: if none qualifies, report the blocked recovery and keep the existing window until a replacement qualifies. The spent account's `account` event or heartbeat roster line settles which case this is, routed per `account` below: `status=expired` goes to the operator and a walled account to its reset.

A weekly-limit report from a claimed lane's harness, with a `resets=` still ahead, is also recorded for that config dir, so the account judge and its roster read the account walled until that reset even where its usage reading shows room. The report is the banner the harness drew on the lane's screen, or for a Pi lane the error its turn ended on; a banner the lane quotes records nothing. `account-wall: record-unwritten config_dir=[DIR]` on the watch's stderr is that record failing: the watch tries again each pass, and until one succeeds launch nothing on that config dir before the reset.

### `usage-limit-passed`

read the lines under the event first, the banner with the screen on both sides of it, as for `usage-limit` above: a lane still working is left alone. Confirmed, the wall named by `resets=` has already lifted and the lane is still sitting under the limit banner. Send it a one-line continuation nudge; do not move the item and do not wait. The nudge is the whole remedy: this event never licenses a fresh launch onto that account, and a nudge that does not take means the wall still stands.

### `account <alias> ... change=<kinds> was=<status>/<verdict>`

an account the fleet launches on changed since the last compared reading, as the runtime's account judge read it; its fields are the roster row's, the text the `heartbeat`'s `account-roster` lines print too; `word=` is the roster line's alone, the judge's own word for the account: `reserve` for a seat the provider reserves, never picked; `retired:<date>` for an account `ORCH_LANE_RETIRE` or the provider's plan end retires from that UTC day, picked until then.

An unmeasured reading leaves that comparison unchanged and emits no event unless its status is `expired` or `retired`.

An `account-end-contradicted <alias> config_dir=<dir> ends=<date> source=<setting or provider> status=<status>` line under the roster is a retired account whose credential still answers: correct the retire statement its `source=` names, or take the account out of the fleet; nothing launches on it meanwhile.

Take the first arm below that matches the new reading. `change=reset` is context and never a route of its own.

  1. `status=expired` → no reset brings the account back: its login is dead, or its token renewal ([runtime/src/ops/accounts/renewal.rs](../runtime/src/ops/accounts/renewal.rs)) ended `expired`. Tell the operator to log in to that account once, or to run the codex command its row's `detail` names in `orch-runtime accounts roster`'s `result.rows[].record`, in the shape [communication-modes.md](communication-modes.md) § Status report gives. Never park a lane on it.
  2. `status=plan_ended` → no reset brings the account back either: its plan ended or its organization disabled subscription access, so the reading is `verdict=walled` with `binding_bucket=plan` and `binding_resets_at=-`. Tell the operator that only the owner can restore the plan or the organization's access, or take the account out of the fleet, in the shape [communication-modes.md](communication-modes.md) § Status report gives. Never park a lane on it.
  3. Any other status with `verdict=unmeasured` → nothing measured the account. Launch nothing new on it, and handle its status word per [lane-directive.md § No lane has room](lane-directive.md#no-lane-has-room).
  4. `verdict=walled` → the account's binding bucket is at or above `ORCH_LANE_MAX_PCT`: launch nothing on it before `binding_resets_at`. Beside `change=reset`, the preceding bucket reset and another bucket binds until the new time. Where `binding_bucket=model` the wall is one model's, and the judge decides a launch of another model; `runtime/src/ops/accounts.rs` owns that rule. Where `binding_bucket=credits` the account is a grant, a Pi `anthropic/` API grant or a Claude cloud credit, at or below `ORCH_LANE_CLOUD_CREDIT_FLOOR`, and nothing reopens it (`binding_resets_at=-`): launch nothing on it, and direct each live lane on it to write its handoff record; the relaunch takes the account the judge returns.
  5. `verdict=room` → the account has capacity. Resume any launch the judge refused for want of an account. Where `binding_bucket=credits` on a `harness=codex` account the capacity is its credit balance above `ORCH_LANE_CODEX_CREDIT_FLOOR`, its plan windows spent; the judge hands it out only when no Codex account has plan room. Where `binding_bucket=credits` on a grant, a Pi `anthropic/` API grant or a Claude cloud credit, the grant has more than `ORCH_LANE_CLOUD_CREDIT_FLOOR` dollars left and is tier 0, which the judge spends first ([runtime/src/ops/accounts.rs](../runtime/src/ops/accounts.rs)). Nudge a lane parked on this account with the one-line continuation nudge only where its `usage-limit` carried no `resets=`; a lane parked with `resets=` gets its nudge from `usage-limit-passed`.

### `model-capacity`

resend one continuation line through Pane paste; the next pass watches the lane again. Never relaunch the lane: the selected model stopped one turn, not the session.

### `idle-after-return`

read the closing lines under the event.

A Pi lane is idle by the Stop row its own hook wrote at its turn end, never by its pane; the lines under the event are its pane's.

A line that carries `cause=[WORD]` names that Stop row's own stop reason, copied as the harness wrote it. A finished turn carries none: the harness's ordinary end, Pi's `stop` and Anthropic's `end_turn`, is dropped, and every other word (`length`, `error`, `toolUse`, `aborted`, a carrier's own) is copied verbatim. `cause=length` is a turn the model's output limit cut, not a finished round: the lane is not available, the lines under the event are not its closing report, and it takes the one-line continuation nudge.

A lane that has returned is available for another fleet launch; a lane still inside `merge-pr.md` § 5 step 1 is blocked on its queue wait, which reads as work in flight rather than idle. A merged hosted lane whose worktree is gone is closed by the watch at this line as `lane-exited` above states.

A directive for an idle lane is sent as [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane) says.

A line that carries `stop-cause=allow-all-blocked-by-policy` follows [copilot-runtime.md § Allow-all blocked by policy](copilot-runtime.md#allow-all-blocked-by-policy) instead of a directive, and that section names the `session-record=` reasons.

- A lane is a stalled-round candidate, not an available lane, only when the lines under the event show its round watchdog finished with no waiter still running, its status file names a dev or fix round as its current step, and its workflow state's `dev_round_id` has no `tmp/dev-return-[ISSUE_ID]-[DEV_ROUND_ID].json` in its worktree. A lane whose watchdog is still armed is work in flight, as the queue wait above is. Read the state file and test for the artifact as `oversee.md` § Bounded lane reads reads the status file. Send the lane a directive to check the stall conditions in [skill-rules.md § Stalled round](skill-rules.md#stalled-round), and to recover the round only when every one holds.
- A lane whose session ended AFTER its PR merged but before `merge-pr.md` § 5 steps 2-6 finished → send it `merge-pr [PR_NUMBER]` as a directive per `oversee-lanes.md` § Talking to a lane, then relaunch it per [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). The order is fixed: the relaunch's continuation line tells the lane to read its inbox first, so a directive already waiting there is what binds the pull request number. That run's already-merged route skips the merge and runs the tracker sync, project verification and worktree removal the dead lane never reached. The relaunch runs in the record's `mail_root` as it stands. The rule below does not reach this lane: its PR did merge.

### `lane-ready`

a hosted lane whose record carried a `prepare` object, handed to a background job while its host prepared it, is up, and the watch carries it from this pass; the line goes out once. Nothing to do.

### `lane-prepare-failed`

`log=` names the failed launch's output. `reason=relaunch-failed` is a completed automatic recovery failure, with `exit=` naming its status, read from the wall relaunch's marker, or with no `exit=` where the launch's intent settled it failed; its log holds the `op`'s replies, whose `.result.effect.report.intent.observation` names the cause. Keep any surviving window and fix the cause in the log before another launch. Other reasons name a preparation job that failed and closed its window, a lane whose record stopped with a `prepare.reason`, reported once. `reason=wait-failed` is the host's own preparation: close the lane through the runtime close ([lane-reach.md § Lane close](lane-reach.md#lane-close)), which closes the host from the `stopped` record, and launch the item again once. `reason=launch-failed` is a launch step on a ready host, named in the log: fix that cause, then relaunch through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). A second failure is surfaced to the user.

### `lane-prepare-stuck`

with `reason=relaunch-pending`, the automatic recovery exceeded `ORCH_WATCH_PREPARE_SECS`, read from its marker. Its job owns completion while it runs; once the job has ended with its launch unconfirmed, the watch's reconcile of that launch's intent owns it on the long cadence. Read its log and keep the window, and start no second recovery while either holds it. A launch the runtime holds open over an unanswered preparation step, a cloud lane's included, follows [lane-directive.md § Launch gate](lane-directive.md#launch-gate).

Other outcomes mean the record has read `preparing` longer than `ORCH_WATCH_PREPARE_SECS` with no outcome, reported once per preparation. A `prepare.line` record is a saved foreground busy continuation a released launcher wrote ([lane-host.md § Provider protocol](../schemas/lane-host.md#provider-protocol)): send the item's `launch-lane` request again with the same host, account and harness, under [Recovery relaunch](lane-directive.md#recovery-relaunch). Keep its sandbox and any pane it already started. A `prepare.log` record belongs to a background job: read the log's tail, close the lane through the runtime close, which stops that job and closes its window and host, then launch the item again once. A relaunch over that active job would race it for the same window and record. A second stuck preparation is surfaced to the user.

### `lane-stalled [ITEM] age=[SECONDS] state=finished`

the open pull request of a lane whose host kind declares `status=none` has left draft. Launch the item's landing lane in this pass, as `disarmed` for a `land=handoff` record says. Send no directive and wait for no approval. The watch never closes a finished lane.

### `lane-stalled [ITEM] age=[SECONDS] state=out-of-credit`

the pull request is still draft, and the account roster the lane duty reads for a draft reads its account locked or `remaining_dollars` at or below zero. Send no directive. Close the lane through the runtime close ([lane-reach.md § Lane close](lane-reach.md#lane-close)) and relaunch it as `cloud-stall-closed` below says.

Both state lines go out on their first reading, repeat every `ORCH_OVERSEER_MARK_REPEAT` passes while the word stands, and report a changed word at once. Missing or unread draft and credit readings keep the age route below.

### `lane-stalled [ITEM] age=[SECONDS]` without `state=`

a running lane whose host kind declares `status=none`, a Claude cloud session, has an open pull request whose head and body have not moved for `ORCH_WATCH_LANE_STALL_SECS`, as the lane duty reads them through the GitHub API: it may be running a long step, waiting on a question, out of credit or ended, and no read of a cloud session's state tells these apart: Claude Code 2.1.295 documents none (`claude agents --json` and `claude logs` read only this machine's background sessions). A record naming no `repo` is read against the repositories `ORCH_CONNECTED_REPOS` lists.

With no pull request open, the line names a lane a push started, as `start-stalled` below says, whose item branch head has not moved for `ORCH_WATCH_LANE_STALL_SECS`: read the branch's newest commit message and any report committed on it in place of the pull request body.

Where they record a pull request create the session token was refused, lacking Pull requests write, or another blocker its session words have it record there, that is the owner's step: report it to the user and send no directive.

Otherwise read the pull request body with `gh pr view`, or that branch, and send one directive through `orch-runtime send` ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)), which records the send on the lane record as `directive_send`.

The watch then holds the bound: with no push and no body change within `ORCH_CLOUD_STALL_MINUTES` of a send whose `directive_send.at` is at or after the stall began, it closes the lane itself and reports `cloud-stall-closed`. A send recorded `archived` or `failed` is a session the directive cannot reach: close the record through the runtime close at once and relaunch it as `cloud-stall-closed` says.

Keep no stall count per repository: a fleet whose cloud lanes keep stalling drops cloud from `ORCH_LANE_PREFERENCE`. The line repeats every `ORCH_OVERSEER_MARK_REPEAT` passes while it stands.

### `start-stalled [ITEM] age=[SECONDS]`

`ORCH_WATCH_START_STALL_SECS` have passed since the record's `running_at`, the time its launch or relaunch recorded it `running`, with no status file under its `mail_root`, on any harness, or, for a lane whose host kind declares `files=none`, neither an open pull request on the item branch nor a push to that branch since launch: the lane never started its workflow. The watch reads a push as a branch head committed at or after the record's `session_since`, or a head it saw move between two of its reads. Such a session pushes an empty first commit at once and opens its pull request only at finish, so any push is its start, the push that records a refused create included, and `start-stalled` never reports a pushed lane: `lane-stalled` above reports one whose branch then stops moving, and reads a refused create there. Such a cloud lane's pane is only its session's local client, which no pane event reports: send it one directive, which the watch bounds as `lane-stalled` above says.

A lane whose host kind declares `files=verb` has its status file read through `lane-host cat` after `touch` confirms the host; a fetch that fails is `start-stall-unread` on the duty's failure line and no event.

For any other lane, the event carries no pane payload, so read the lane's state with `.agents/skills/orch/scripts/orch-runtime lane status --item [ITEM]` and its pane per `oversee.md` § Bounded lane reads. Send a lane idle at its brief its directive per [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane), and answer a harness dialog per [lane-reach.md § Per harness](lane-reach.md#per-harness). Relaunch an exited or `unjudged` lane once through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). The line repeats every `ORCH_OVERSEER_MARK_REPEAT` passes while the file is missing, so a line already acted on needs nothing more. A relaunch renews `running_at` and so the window: a `start-stalled` line whose `age=` counts from after the relaunch is a second stall, surfaced to the user.

### `cloud-stall-closed [ITEM] directive_age=[SECONDS]`

a stalled cloud lane left its recorded directive unanswered for `ORCH_CLOUD_STALL_MINUTES`, nothing pushed since, and the lane duty closed it through the runtime close, which writes the lane record; its `lane-closed` lines with the archive line come before this one, and the fleet-log `close` row names the send's result, the CLI's words and the credit reading from `directive_send`.

The watch records that it asked by a marker, `lane-close.[ITEM]` under its own state directory, created exclusively before the close starts and kept, where the close answered closed or gave no answer, until the next pass reads the lane record out of flight; a close that closed nothing removes it, so the next pass may ask again. The finished-hosted close takes the same marker. A marker standing beside a lane whose record still reads open, a runtime that died between the ask and the answer among its causes, is a close the watch cannot confirm: the watch asks no second close and says `lane-close-unconfirmed item=[ITEM] marker=[PATH]` on the duty's failure line every pass while it stands. That lane is the operator's to close, and the marker, at the path the line names, is the operator's to remove with it.

A provider close that refused is `lane-close-refused` with the refused path and the lane kept; a tracker quota hold defers the close with no line and the pass asks again.

Archive nothing yourself: report the session id to the owner, who archives it.

Relaunch the item as a hosted lane on its branch: choose the host under [oversee.md § 3 Placement](../workflows/oversee.md#3-launch), never `claude-cloud`, and use [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) with the request's `host` naming it. A hosted relaunch starts fresh on the `start` brief, which runs the standard cycle on the branch the cloud lane left. Name the fleet-log cause in the relaunch's own `ruling` row.

### `lane-long [ITEM] age=[SECONDS] review_rounds=[COUNT] fix_receipts=[COUNT] validation_runs=[COUNT] restacks=[COUNT] repeated_class_rounds=[COUNT] stage=[STEP]`

a `running` or `parked` lane is `ORCH_WATCH_LANE_AGE_SECS` past its record's `launched_at` (default 12600 seconds, 3.5 hours), which every later launch over the record keeps, a relaunch, a handoff's and a next phase's alike. `stage=` is the `Step:` line of the lane's status file, read on this disk for a local kind and through `lane-host cat` for a `files=verb` kind; `parked` for a parked lane, `unread` where the read failed, `none` where the lane writes no file (a `files=none` kind) or its file names no step.

The line repeats once per further `ORCH_WATCH_LANE_AGE_SECS` of age. `review_rounds=` adds the first internal review panel, re-review cycles and comment-review iterations from workflow state. `fix_receipts=` counts `stages` entries whose `kind` is `fix`, not `cycles`, which can count fixed items. `validation_runs=` counts each validation run start in the lane worktree, `orch-runtime validate start` and the `dev-validate-run` entry over it, including finished, bounded and running runs before round acceptance; restack validation runs count too. The start publishes its inventory at `tmp/validation-runs`. A missing, unreadable or invalid inventory reads `unread`. `restacks=` reads workflow state `restacks`, one per completed restack whatever validation route followed it ([workflow-state.md](../schemas/workflow-state.md)). `repeated_class_rounds=` counts later distinct patch commits that repeat an equal cause or a shared location/owner key in `pr_comment_review.patched_causes`, once per commit, across internal and comment reviews. The optional `owner` comes from the item's `Owner:` line. Key equality is the [dev-round schema](../schemas/dev-round.md)'s contract. This count covers recorded patches only; it cannot show a review that recorded no class. With no patch entry, `repeated_class_rounds` reads `unread`. With no `stages` list, `fix_receipts` reads `unread`. An absent `restacks` field counts as zero.

A hosted lane's counts are its workflow state and run index read through the provider; a read that failed counts `unread`. All five counts read `unread` when state is absent or unread, the lane writes no files, or it is parked. The watch reads no parked lane file.

For any `stage=` but `parked`, read the lane record: its status file per `oversee.md` § Bounded lane reads, its workflow state, and its pull request's `github.sh pr-timeline`. A `parked` lane's disk is stopped, so read none of its files: read the overseer's own lane record, its `parked` `{pr, head, repo, at}` and `pauses`, and that pull request's `github.sh pr-timeline`; a park happens only in [merge-pr.md](../workflows/merge-pr.md) § 5 step 1's queue wait, so the cause is the merge queue or the time before the park.

Before naming the cause, apply [Design review](design-review.md) when its trigger holds, including its wider read for missing counts. Name the cause: long tests, a stuck state or wait, a review loop, scope growth, or the merge queue. If no design review starts, record the cause in the fleet log as a `ruling` whose text starts `long-reason`. Where the cause is in the system, not in this one item, file its source fix under Fix the source in § Judgement rules.

### `window-gone`, or any lane whose session ended with no merged PR

inspect its worktree and PR state. A lane whose item the tracker reads completed or canceled has ended its work, a no-change round's item among them ([start-worktree.md § 2](../workflows/start-worktree.md#2-implement)): close it through the runtime close ([lane-reach.md § Lane close](lane-reach.md#lane-close)) and relaunch nothing. Otherwise re-launch once with the same brief through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). The relaunch is the item's `launch-lane` request over its standing record, and its route resumes the bound session or starts fresh on the brief, as that section says. A second death is surfaced to the user, not retried. After the relaunched lane finishes, close it through the runtime close ([lane-reach.md § Lane close](lane-reach.md#lane-close)); do not reconstruct the pane, host, and state steps by hand.

### `lane-unreadable [LANE] cause=[WORD]`

the lane duty could not read the lane's recorded pane, its process or its screen this pass, for the cause named. The line prints when the cause first appears or changes, nothing while it stands, and a pass that reads the lane clears it. The lane keeps its last judged state, the pass judges nothing more of it, and the reading is never `window-gone` or `lane-exited`: relaunch nothing on it alone. A cause that stands across passes is a fault of the recorded tmux server or of the lane's `mail_root` to read and correct.

### `stray-window [PANE] window=[ID] server=[PID] name=[NAME]`

a window on the fleet's tmux session whose pane no lane record, overseer record, open launch intent or intent receipt names, and that is not the watch's or the controller's own pane; `server=` is the tmux server's process id. The watch reports it once while it stands, again only after it went and came back, and never closes or adopts it. Read what opened it, a window a person opened by hand or a launch whose record was lost among the causes, then close it or register it.

### `lane-question`

the lane's own question, and the only shape one arrives in.

Answer it when available evidence already decides it, apply the ruling, record it in the fleet log, and send the answer back per `oversee-lanes.md` § Talking to a lane. Repo state, the issue body, a stated convention, scope-narrowing calls subject to [requirement-change review](design-review.md#inputs-and-actions), and a lane's own well-argued recommendation are available evidence. A pure cut back to main's behaviour, or a cut of surface the Done-when does not need, takes no table.

Relay any other question to the user only where [communication-modes.md](communication-modes.md) § Ask set puts it, using the question format that section links. A merge question under `ORCH_MERGE_AUTONOMY=ask` follows Held merges above and always goes to the user.

An answer that accepts a step the lane's workflow would otherwise ask about carries that acceptance in its envelope, whose id the lane's round close names as the overseer's act; which ids that field admits is the `stages[].authorization` row of [workflow-state.md § Field Definitions](../schemas/workflow-state.md#field-definitions), and [dev-start.md § Close The Round's Stages](../workflows/dev-start.md#close-the-rounds-stages) writes it. With no such act the lane's close names no authorization and `submit-pr` asks as its mode says.

Every emitted question is answered: the lane is blocked in `lane-mail wait` on this line. An overseer resuming a fleet reads what it still owes with `lane-mail pending --item [ISSUE_ID]`, adding `--root [MAIL_ROOT] --host` for a lane whose record puts it on another host.

### `lane-notice`

the lane reported something it is not waiting on. Act on it where it needs acting on; it needs no reply. A `copilot-*` notice takes [copilot-head-notices.md](copilot-head-notices.md). A `copilot-fallback` notice whose first line carries `cause=` is sent by the lane's review call itself, and can arrive twice where a send's answer was lost; one with no `cause=` is the lane's own, from its triage's `timeout` row ([review-pr-comments.md § 7.2](../workflows/review-pr-comments.md#72-copilot-head-route)).

A notice naming a merge-group ejection that `queue-watch` read as `reach: outside`, with the failed checks, their reach, the run links and the head, reports red checks the item's change does not select: a defect outside the item, which the lane's own merge route ([merge-pr.md](../workflows/merge-pr.md) § 5) does not fix. Before filing, apply [Design review](design-review.md)'s filing row, which matches it against recent `filed ` rulings; then file it once through [File one item alone](#file-one-item-alone), naming the failed checks and the run links. A notice that row matches to an earlier filing is recorded against that filing in the fleet log, never filed again.

### `directive-read [ITEM] [ID]`

the lane's mailbox cursor passed the directive: the lane has it. Nothing is owed; a sent directive is confirmed by this line alone.

### `directive-unread [ITEM] [ID] age=[SECONDS]`

the directive has waited `ORCH_DIRECTIVE_UNREAD_SECS` or longer with the lane's cursor short of it: the watch reports it on the first mail turn at that age. Its repeats run on one counter per mailbox, which every report of an unread directive starts over: the directives still unread are reported again once `ORCH_OVERSEER_MARK_REPEAT` mail turns pass with no such report. Reach the lane by its state, under its row in [lane-reach.md § Lane states](lane-reach.md#lane-states). `directive-read` follows once it reads it.

### `owner-note`

a note to the overseer mailbox, which carries owner and delegate notes; its text follows. `from=owner` is routing, not authorship; a record names the stated speaker per [communication-modes.md § Recording](communication-modes.md#recording).

Every text and `options:` line under `lane-question`, `lane-notice`, `peer-note`, `owner-note` and `owner-ask-resolved` is indented two spaces, so only a watch record begins with `EVENT`.

Act on it, or record it in the fleet log as a ruling; a standing instruction is one row of the oversee record's `standing[]` array instead ([communication-modes.md § Recording](communication-modes.md#recording)).

Where a reply is owed, send it as `lane-mail notice --item overseer --to owner --ref [ID]`, the event's id as `--ref`, so the owner reads it on the channel the note came from ([overseer takeover § 1](../workflows/oversee-takeover.md#1-read-the-mailbox-and-handoff)); a question back is an owner ask. Follow [communication-modes.md § Owner delivery](communication-modes.md#owner-delivery) for reply routing; an identical send within the minute appends nothing and refuses `duplicate id=[FIRST_ID]`, and a notice text the owner received within 24 hours refuses `owner-notice-repeated` naming that notice's id, so a second reply takes its own words.

The watch reports each `lane-question`, `lane-notice`, `directive-unread`, `owner-note`, `owner-ask-resolved` and `peer-note`, and each `directive-read` for a directive read after its lane is first watched, at least once, and a stop between its print and the commit of its row or cursor reports it again: an id already seen is a repeat.

### `owner-ask-resolved [ASK_ID] by=[text|default] id=[ANSWER_ID]`

an answer to an owner ask; its text follows. The owner can answer more than once, each with its own answer id. Record the ruling per [communication-modes.md § Recording](communication-modes.md#recording). When the overseer has its ruling, close with `lane-mail resolve --item overseer --id [ASK_ID]` and send a notice with `--ref [ASK_ID]` naming what stood. `by=default` supplies the recommendation only for an unanswered deadline. What a reply after the close reaches, on each channel: [communication-modes.md § Owner asks](communication-modes.md#owner-asks).

### `owner-ask-closed [ASK_ID] by=[explicit|text|default]`

the separate close record. An answered deadline closes without a default answer; the owner's words stand.

### `peer-note [REPOSITORY] [ID] kind=[KIND]`

a peer repository's overseer wrote to this one; its text follows. Answer `kind=ask` alone, per [peer-mail.md](peer-mail.md); `kind=answer` carries `re=[ASK_ID]` and is recorded against that ask of this overseer's, and `kind=directive` needs no reply. Record the exchange in the fleet log.

### `lane-asking`

a harness dialog, never a question for the overseer: a permission prompt, a trust prompt, a model picker. Answer it in the lane's own dialog per [lane-reach.md § Per harness](lane-reach.md#per-harness).

A line that carries `stop-cause=allow-all-blocked-by-policy` is a Copilot lane launched with allow-all whose policy blocks it: follow [copilot-runtime.md § Allow-all blocked by policy](copilot-runtime.md#allow-all-blocked-by-policy) and do not answer the prompt. A Copilot lane launched without allow-all carries no cause, and its prompt is answered as above. That section also names each `session-record=` reason a Copilot lane's line can carry.

### `report-due`

the status report is due.

Run `.agents/skills/orch/scripts/orch-runtime report render --state [OVERSEE_STATE] --repo [REPO]`, one `--repo` per watch `--repo` value; it reads the `ORCH_CONNECTED_REPOS` repositories after them as the watch does. Write the work's outcomes with communication's [summary template](../../communication/references/reports.md#summary-template) to `[PATH]`, then run `.agents/skills/orch/scripts/orch-runtime report write --state [OVERSEE_STATE] --repo [REPO] --summary-file [PATH]` with the same values. The rendered body is the report's whole read of the fleet: a record is read from its home by item only where a row needs explaining, and no state file is printed.

Paste the `write` reply's `result.body` into the chat unchanged: it is the content of the file `result.path` names, so chat and file carry one report. The summary is in neither: it is the text of the report notice `write` sends the owner, posted as the file's Slack comment, `result.notice_id` its id. `write` sends that notice and is the only send of a report and its summary: never send the summary as a separate notice, before or after `write`.

During `ORCH_REPORT_QUIET_HOURS` (default midnight to 7 am in `ORCH_OWNER_TIME_ZONE`, default `America/Los_Angeles`), `write` sends no owner notice. Empty quiet hours turns suppression off. The first due report after the window sends the morning brief. Its summary follows that template and covers the work since the last report sent to the owner, including overnight merges. Decisions needed and critical notices remain immediate at any hour. The written file ends the cadence event without advancing the last-sent baseline when no notice was sent.

A `write` whose notice send failed has written the report file and kept its attempt beside it, which ends the event. Fix the cause its refusal names, then run the same `write` with the same summary within the same UTC minute, which sends the notice once ([communication-modes.md § Status report](communication-modes.md#status-report)). Past that minute a second `write` refuses `report-exists`: send the notice by hand, `lane-mail notice --item overseer --to owner --attach [FILE] --file [SUMMARY_PATH]`, `[FILE]` being the report's path. A hand send refused `owner-notice-repeated` means the first send landed: the owner holds that text, and the id it names is the receipt.

A `write` refused `report-unjudged cause=summary-stale ask=[ID]` names an owner ask the summary cites that has closed: summarize again against `lane-mail pending --item overseer --to owner` and run the same `write`.

Any other refused `render` or `write` names its cause on its first stderr line: fix it and run the report again, and where it stands, tell the user the report is blocked and why. The watch reports a due line once, not on every pass, so do not wait for the event to repeat.

### `triage`

team-wide: run `oversee.md` § Bounded issue reads and set `[ISSUES]` to the emitted identifiers.

Take out of `[ISSUES]` each Linear mirror `oversee.md` § Outside contributions judges on GitHub, recorded as it says.

Cross-check `gh issue list --repo [REPO] --state open` for the first repository: an open GitHub issue whose Linear mirror, the item whose `github_sync` names it, is Done is residue, so close it on GitHub naming the pull request that fixed it; one with no mirror and no `outside-contribution` event means the GitHub-to-Linear sync broke, so send one owner notice naming the issue.

Read each issue team's complete live project inventory and reuse it for project selection and validation. Stop without writing `triaged` if a project read fails or is incomplete.

Launch one fresh canonical `maintainer` verifier with the source repository and the lowest-cost model the surface exposes. The launch call is Claude's generated-agent tool, Codex `spawn_agent` after `scripts/spawn-adapter spawn maintainer` followed by `send_input`, OpenCode `functions.task`, or Pi `subagent`, as [SKILL.md § Runtime Notes](../SKILL.md#runtime-notes) specifies. On the terminal surface, call it from the overseer session. On the managed-session surface, use that surface's native call. In sequential mode, make the same call and wait for it before resuming.

Send it the team project inventories and this task: `Verify only these Linear issues: [ISSUES]. For each issue, read its full body and source and apply the filing bar regardless of lane authorship. Follow the Verifier returns contract in .agents/skills/orch/references/skill-rules.md under Coordination for evidence, project and agent selection, and the final return.` The [Verifier returns contract](skill-rules.md#coordination) governs both the task and acceptance.

Capture only the single final return defined by [skill-rules.md § Single Return Message](skill-rules.md#single-return-message). Once that return is captured, or on any launch, capture, parse, or validation failure after the launch, retire the verifier through the surface's own shut-down call before any further launch: a finished subagent can keep holding a runtime thread slot ([DEVELOPMENT.md § Reviewer slot budget](https://github.com/vanillagreencom/kendex/blob/main/skills/orch/DEVELOPMENT.md#reviewer-slot-budget)). Validate the final return against that contract. Stop without writing `triaged` on a launch, capture, parse, or validation failure.

For each valid kept item, read its project and labels live with `linear.sh issues get [ID]`. If the team inventory is nonempty and the project is missing, or a required agent label is missing, set only the missing fields in one `linear.sh issues update [ID]`: pass `--project` only when the team inventory is nonempty and no project exists; pass `--labels` only when `LINEAR_AGENT_LABELS` is nonempty and no agent label exists, merging the selected agent label with all current labels under the linear skill's `--labels` rule. Leave existing projects and agent labels unchanged. With an empty `LINEAR_AGENT_LABELS`, preserve all current labels and skip agent-label assignment. Stop without writing that item's `triaged` record if its read or update fails.

Route each valid kept item or cancel it, then record the terminal verdict in the fleet state's `triaged` list; every pass emits the item again until that record exists. `triaged` is the verdict log the watch rebuilds its triage keys from ([workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)).

### `outside-contribution`

[oversee.md § Outside contributions](../workflows/oversee.md#outside-contributions).

### `refresh-failing`

send one owner notice for every `report=initial`, naming the repository, the failed-run count and the cause, even when the cause matches an earlier incident. For `report=repeat`, notify only when the cause changes. A consumer fleet's overseer applies this rule to its own repository too.

### `main-push-failing` (a red push or nightly scheduled run on main)

link an open item that covers the failed jobs and suite, or file one item in the repository's tracker through File one item alone above. Include the run link (`https://github.com/[REPO]/actions/runs/[RUN]`), failed jobs and cause. Send the owner a notice with that item and run link.

### `main-push-budget` (a selected completed Skill Tests run carries budget warnings)

link an open maintenance item that covers the named suites or jobs, or file one item in the repository's tracker through File one item alone above. Include the run link (`https://github.com/[REPO]/actions/runs/[RUN]`) and each distinct warning from `warnings=`. The event reports once per run after all annotation reads succeed.

### `main-workflow-absent` (a workflow `ORCH_MAIN_WORKFLOWS` names is read by nothing, so its red runs reach no one)

with `cause=branch`, read the repository's `.github/workflows/` for the renamed or removed file; with `cause=unwatched`, check the entry's `OWNER/REPO` against the watch's `--repo` values and `ORCH_CONNECTED_REPOS`. Correct the entry, or the connected list, in the overseer repository's settings in a reviewed change. Where the repository has its own overseer, ask it which workflow holds its nightly run with `lane-mail peer ask --repo [REPO] --file [PATH]` ([peer-mail.md](peer-mail.md)). Restart the watch after the change merges.

### `security-alert`, `security-alerts-unread`, and a `heartbeat`'s `bot-fix` line

[security-alerts.md](security-alerts.md).

### `pr-watch`

handle every attention line.

A `refresh-ready` line takes Consumer refresh approval below before checking lane ownership. Any other line on a PR no `lanes[]` record or triaged item owns is neither a wake nor an arm. An approved, green `kendex/refresh` pull request in a fleet repository is the exception: the refresh workflow arms every class itself, and the overseer arms one a dequeue or a failed arm left unarmed by the queue route of [merge-pr.md](../workflows/merge-pr.md) § 5 step 1.

A line on a PR a PARKED record's `parked.pr` names is a resume, whatever its kind below says about waking: the lane is needed again, and "wake the owning lane" reads as [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), whose parked rule starts the sandbox with `lane-host start` before the relaunch, the record still parked where the provider does not confirm it; the relaunch starts the harness fresh on the kept disk. A `disarmed` line on a parked pull request is also how a dequeue nothing else reported reads: the reducer prints it for an approved pull request neither queued nor armed, so the queue needs no other reading, and under `ORCH_MERGE_AUTONOMY=ask` that line is still a resume: the lane is what holds the PR for the user's answer.

What each kind MEANS is `pr-watch.sh --help`; what follows is only what the overseer does about it. A detail ending in `(QUEUED: dequeue before pushing)` rides several kinds and outranks all of them: the lane dequeues before it can push anything.

  - `refresh-ready` → apply [copilot-head-notices.md § Consumer refresh approval](copilot-head-notices.md#consumer-refresh-approval) immediately. No owning lane or quiet-period expiry is required. That route owns the proof, review and same-head approval requirements.
  - `ci-failed` → for a PR no lane owns, including the refresh PR, read the failed run with `github.sh ci-logs [PR]` and route the cause through File one item alone above; approve nothing and re-run nothing until the cause is known. A running lane record's PR is not a wake while its merge wait holds it. A parked record's PR is a resume as above.
  - `threads-open` → verify the count against the API, then wake the owning lane with it.
  - `changes-requested` → wake the owning lane: a standing objection is the lane's to answer, never the overseer's to dismiss.
  - `disarmed` → a `running` record whose `kind` declares `land=handoff` in [lane-host.md § Host kinds](../schemas/lane-host.md#host-kinds), a `claude-cloud` record, never merges and has no mailbox to ask through, so under either `ORCH_MERGE_AUTONOMY` its `disarmed` line is a wake that launches the item's landing lane. Choose the landing host under [oversee.md § 3 Placement](../workflows/oversee.md#3-launch), then use [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). The relaunch's `brief_file` holds `/orch merge-pr [PR_NUMBER]`, and its request names `host` as [oversee.md § 3](../workflows/oversee.md#3-launch) Placement says. Its run merges by the route of merge-pr.md § 5 under the lanes app identity and completes the item; under `ask` that landing lane asks its merge question through lane-mail, and Held merges above applies. For a `land=lane` record, under `auto`, a PR whose owning `lanes[]` record is `running` is not a wake: a PR the admin route takes stays unarmed until that lane's own direct attempt in [merge-pr.md](../workflows/merge-pr.md) § 5 step 1, and the lane owns its merge. For a record no lane runs, relaunch the lane into the merge route of that step through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch); a parked record resumes as above. Under `ask` a `land=lane` record's line is not a wake, the lane holds the PR for § Judgement rules, Held merges. The merge route stays the lane's reply-pass discipline; the overseer never adopts it as its own step.
  - `awaiting-stale` → no approval has reached the head within the quiet period: Copilot is down, out of AI credit, or gave no verdict. Apply the overseer's fallback approval, [copilot-head-notices.md § Fallback approval](copilot-head-notices.md#fallback-approval).
  - `head-moved` → the reduction describes the preceding head. Do nothing; the next pass reads the new head.
  - `error` → many producers, and each line's own detail carries its remedy: follow that. An unevaluated PR is never healthy.

### `verifying-deadline [ITEM] box=[N] trigger=[JSON_TEXT] status=[due|overdue] deadline=[UTC|null]`

that due or overdue box's saved key changed. The same event with `boxes=0` reports the first read with no open boxes. Run [verify.md](../workflows/verify.md) with the event's item and box lines. Apply Verification below to that item and box even when reconciliation omits them.

### `verifying-invalid [ITEM]`

the item's checklist cannot be judged: a branch-provable box still open on a Verifying item, or post-merge metadata the parser refuses. The watch's stderr carries the parser's rule and box under `verifying-invalid issue=[ITEM]`, and the line prints once while the item stays invalid. Correct the item's checklist in the tracker; the next pass judges it again.

### Verification

Each `verifying [ITEM] box=[N] trigger=[JSON_TEXT] status=[due|overdue|blocked|waiting] deadline=[UTC|-] [merged=[UTC]] blocked_by=[ids|-] reading=[JSON_TEXT] where=[JSON_TEXT] why=[JSON_TEXT]` line names an open post-merge box on a merged item, or an unproved box beside a container's child box, "Every child Done or cancelled". A container line has `trigger="outcome"`, `deadline=-` and no merge time; its reading is the box text.

Acceptance follows [SKILL.md § The Cycle, The overseer reads results](../SKILL.md#the-cycle).

Event blocks print only due or overdue boxes whose number, trigger, status or deadline key changed within the saved verifying-deadline row. Changes to reading, where, why or blocked_by alone wait for the heartbeat. Boxes with waiting or blocked status have no individual keys in that row and print at heartbeat. The heartbeat prints every box regardless of queued or active lane records. The first read of an item with no open boxes raises `verifying-deadline [ITEM] boxes=0` once; the heartbeat repeats its completion line.

The status order is `overdue`, `blocked`, `waiting`, then `due`. A box at or past its deadline reads `overdue`, including a box with an open blocker. Without an expired deadline, an open blocker means `blocked`; an unfired trigger means `waiting`; otherwise the box reads `due`. `blocked_by` lists open blocker ids, separated by commas, or `-` for none. An unfired release has no deadline and reads `waiting` unless blocked; its line prints `deadline=-` and `merged=<UTC>`. A matching release starts its deadline at publication, within 72 hours. A `+Nh` deadline after a merge or time trigger counts from the merge or the stated time. The release read also runs for blocked items.

Invalid items print `verifying-invalid issue=<id>` with their parser rule and box on stderr, and raise `EVENT verifying-invalid [ITEM]` once while the item stays invalid; the pass continues and commits the valid due set. `orch-runtime reconcile-items` returns these box lines in its exit-0 reply's `result.lines`, their counts in `result.counts` (`due`, `overdue`, `blocked`, `waiting`, `items`), and each item with an overdue box as a `verifying-overdue` finding in `result.findings`.

On each due or overdue box, apply that acceptance rule in that pass and post an evidence comment on the item. Write one `N: text` line per proved box in `[EVIDENCE_FILE]` under the checkout's `tmp/`; the text cites the evidence comment. Include already-ticked boxes whose Evidence line is absent, using the evidence comment already posted for them.

For a merged item, a pass ticks and completes with `issues complete [ITEM] --post-merge-at [MERGED_AT] --done-when-met [N] --evidence-file [EVIDENCE_FILE]`. For that merged-item route, bind `[MERGED_PR_URL]` to the item's linked merged PR URL and read `[MERGED_AT]` from that PR with `env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [MERGED_PR_URL] --json mergedAt --jq .mergedAt`. An absent or unreadable timestamp is a completion failure. The completion command keeps Verifying while another box remains open and sets Done after the last one. A merged item's `verifying [ITEM] boxes=0` line requires completion with the same selected PR's timestamp. If checked boxes lack Evidence lines, select their numbers and supply the evidence file from the existing comments. Omit both evidence flags only when every checked box already carries its Evidence line.

A container is due once every child is Done or Canceled, and closes with no holder read. Its `boxes=0` line runs `env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime container-close [MAIN_REPO_ROOT] [ITEM]`. A container `box=[N] trigger="outcome"` line names an outcome the parent still holds: move it into its own child item, a leaf blocked by the siblings it measures whose holder completes it with `issues complete [CHILD] --summary-file [SUMMARY_FILE] --done-when-met [N] --evidence-file [EVIDENCE_FILE]`, `[SUMMARY_FILE]` a nonempty summary of the read under `tmp/`, and remove the box from the parent. The open child keeps the parent open. The container close ticks the parent's child box with each child's state as Evidence, posts or reuses the Bundle Complete summary, and completes required effects through `issues complete`, including on a Done parent. A parent whose every child was canceled is set Canceled. A container uses no `--post-merge-at` and no `[MERGED_AT]` read.

Preserve the close's stderr diagnostics; a refusal is its `container-close: [KEY] ...` line there, at exit 1, or exit 2 for a malformed parent id. `closed [ITEM]` records successful closure and required effects. `deferred [CHILD_IDS...]` keeps the container open until those children complete. A bare `deferred` means the lock wait expired. `held [ITEM] [HOLD_RESET]` carries the selected retry deadline and follows linear's `patterns/workflow-actions.md` § Quota Holds. A nonzero exit records unfinished required work even when the parent is already Done; retry the same close after its named cause is resolved. Its `completion-refused` prints each refused row; follow each row's `remedy` before the retry. The container close supplies no merge time.

On a failed check, apply [orch § The Cycle](../SKILL.md#the-cycle). For evidence still unreadable at its deadline, apply [verify.md § Resolve missing evidence](../workflows/verify.md#2-resolve-missing-evidence). For each due or overdue box, select the reader and message under [communication-modes.md § Owner-only verification](communication-modes.md#owner-only-verification).

After either completion route sets the item Done, close its parent through [merge-pr.md § 5 step 2](../workflows/merge-pr.md#5-execute-the-merge), repeating for container ancestors. Record closures and diagnostics in the verification evidence comment.

### `heartbeat`

a lane whose mail, clone or state read still fails draws no heartbeat line: its duty's `watch-step-failed` line names it ([§ Event kinds](#event-kinds)).

The plain open pull request lines carry repo, number, branch and title and no arm or queue state: a parked record's pull request the list still shows open, with no reducer line on it, stays parked, and its dequeue reads as the reducer's `disarmed` line under `pr-watch` above, never from this list.

Then, for each hosted `running` lane whose pull request the list shows open and whose reducer lines name nothing, run the park verb as [oversee-lanes.md § Parking a merge wait](oversee-lanes.md#parking-a-merge-wait) states, on a fleet whose provider implements the `stop-sandbox` and `start` pair, which `lane-host-ssh` does not; the verb's own read is the only judge of queued or armed and `CLEAN`, and its refusal is the answer where the lane is not ready.

Read the `account-roster` lines under the open PRs as the fleet's current capacity, the runtime's account judge's reading, routed per `account` above; `account-roster unread` means no account was read, never that none has room.

Then each `owed [ITEM] state=[STATE] priority=[N] lane=[LANE] verdict=[VERDICT]` line: an item the tracker holds as owed work, with no running, preparing or parked record, that `launch_queue` lacks; a parked item with work left over its merged pull request is named by the `parked-merged` lines ahead of the `heartbeat` line and takes that rule. `priority=-` is no priority, which ranks after every numbered one. `verdict=queue` → gate it as `oversee.md` § 2 Select Work does; one that passes goes into `launch_queue` at its priority position, relaunched per `oversee.md` § 3 Recovery relaunch where `lane=` names a record, and one that fails is reported to the owner with the reason it cannot run, in the chat and the next status report's summary. A record with no harness, or whose host lists no account its pick would judge, is `queue`: its launch picks the account. Every account read behind a verdict is the record's own host's, the one its relaunch stays on. `verdict=merged pr=[N]` → the record carries the `cycle` of pull request N's merge while the tracker still holds the item: where that merge finished the item, complete it in the tracker; where the item went back to work after it, queue it as for `queue`. `verdict=dated` → the judge found every account for the record's harness and model walled: launch and queue nothing, and name the item with its `until=` reset in the chat when first judged so and in that summary; each heartbeat judges it again. `verdict=unjudged` → the host's account listing failed, or the judge measured no account or failed, named on stderr as `heartbeat-accounts-unread` or `heartbeat-pick-unread` where a read failed, so the next heartbeat judges it.

Then the triage pass: run `oversee.md` § Bounded issue reads. Drop IDs already recorded in the fleet state's `triaged`, and send the remaining candidate IDs through the `triage` verifier. Judge only issues a fleet lane filed: the candidate set is each lane item's created-issue records in workflow state (`audit_issues_created`, `pr_comment_review.issues_created`) plus each lane PR body's Created Issues section; the created-since listing backstops trackers without that state. Anything outside the set is left alone. Record each verdict by writing `{"issue": "[ID]", "verdict": "[kept|canceled]", "reason": "[ONE_LINE]"}` to `tmp/triage-verdict-[ID].json` with the harness file-write tool and running `orch-runtime state append-file --fleet /triaged tmp/triage-verdict-[ID].json`, in the state `oversee.md` § 3 Lane record creates before the first append; the next pass runs on its own.

### `reconcile-refused intent=[ID] refusal=[KEY]`

the reconcile duty could not complete or mark the open intent named, and `refusal` is the store's or the effect's key. Read the intent with `orch-runtime state inspect --fleet`; correct what the key names, a lane record gone under its close (`lane-missing`) or a replaced obligation set (`set-replaced`), or report the open intent to the operator, as [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) says of an intent no reconcile settles. The line prints when the refusal is new or its key changed, never on every pass; a deferral to a live owner prints nothing.

### `notice-unmarked intent=[ID] cause=[KEY]`

the owed failure notice of the intent named was sent and the store refused its `sent` mark under `cause`: the owner holds the notice, and the next reconcile sends it again until the mark lands. Read the intent and correct the cause.

### `directive-send-unsettled item=[ITEM] cause=[KEY]`

the session send `orch-runtime send` recorded owed on the lane named has no receipt that settles it, and every later send to that lane is refused `directive-send-owed` until it is settled. `cause` is `receipt-missing` where the mailbox program gave no receipt (killed, no answer within its bound, or the verb ended before keeping one), `receipt-unnamed`, `receipt-invalid` or `receipt-unreadable` for the kept receipt under `[STATE_DIR]/directive-send/[ITEM].[RECEIPT].json`, or the store's key where a kept receipt's mark was refused. Look there first: a kept receipt needs only its refusal corrected, and the next reconcile stamps it. With no receipt, read the session itself for whether the directive arrived, then settle the record by hand: write `{"op": "record-directive-send", "item": "[ITEM]", "write": {"stage": "failed", "cause": "[WHY]"}}` to a file and run `.agents/skills/orch/scripts/orch-runtime op --fleet --request [FILE]`; the record reads `failed` with that cause and `owner: operator`, and the next send proceeds. Send again only where the session shows the directive did not arrive. The line prints when the cause is new or changed, never on every pass.

### `watch-taken-over pid=[PID] start=[START|none] reason=gone|replace`

this watch took the claim record over from the runner named: `gone` for a record whose process had ended or whose pid another process reused, `replace` for the live runner its start named for replacement and stopped first; `start=none` names a claim record that carries no start. Nothing is owed: the line says why the claim moved, so a log that resumes after a gap is read as one watch's.

### `idle-unread [TARGET]`, `wake-delivered [TARGET]`, `wake-unconfirmed [TARGET] cause=[C]`, `wake-limit [TARGET] harness=[H] cause=[C]`

the wake duty found `TARGET`, `overseer` or a lane's item, positively idle with unread mail. `wake-delivered` says the one nudge line was pasted and the session's own file confirmed a new user turn; `wake-unconfirmed` says the line was pasted and no new user turn confirmed it within the bound, `cause` the verb's word; `wake-limit` names the harness and why no wake was delivered, a Codex lane whose process runs among the causes. On `wake-limit` for a lane, deliver the mail per [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver); for the overseer, this session, run `lane-mail inbox --item overseer`. For the overseer on `wake-unconfirmed` or `wake-limit`, the watch tells the owner on its next pass through the overseer mailbox's owner channel, naming the unread envelope and the cause, once per unread state. The nudge repeats only once the target's unread state changes.
