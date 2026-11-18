# Oversee events

Read when [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) handles a line of the watch's log. Apply § Judgement rules to every line, then take the line's entry under § Event kinds.

## Judgement rules

The overseer owns the fleet's judgement as well as its liveness. It implements nothing itself: a fix goes to a lane as an item.

Review panels take the [pre-panel context check](../workflows/review-pr.md#2-prepare-reviewers) before any attached reviewer starts.

A rule below that asks for a record asks for one fleet-log row: the fleet state's `fleet_log[]` ([workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)). `[KIND]` is `proposal`, `ruling`, `close`, `peer` or `use1`, and `[ITEM]` is the issue or repository the row is about. `[ONE_LINE]` holds text the overseer did not author, so it crosses a file, never argv ([SKILL.md § Harness-Safe Shell](../SKILL.md#harness-safe-shell)). Write the row to a file with the harness file-write tool, then append it:

```json
{"kind":"[KIND]","item":"[ITEM]","text":"[ONE_LINE]"}
```

```bash
.agents/skills/orch/scripts/orch-runtime state log append --fleet tmp/fleet-log-record.json
```

Append each row before writing the file for the next one. Leave `at` out: the append stamps it from the runtime's clock. The append refuses a file that holds no JSON object (`fleet-log-record`), a given `at` that is not a real UTC instant (`fleet-log-at-invalid`) or is later than the clock (`fleet-log-at-future`), and a `text` longer than `ORCH_FLEET_LOG_ROW_BYTES` bytes (`fleet-log-row-bytes`).

A standing instruction from the owner, and its lift, follow [communication-modes.md § Recording](communication-modes.md#recording).

### Lane proposals

A lane posts each proposal as a tracker comment and reports it with a `Proposal comment:` notice.

1. Record each `Proposal comment:` notice in the fleet log: the tracker, the repository, the issue, and the comment's ID or URL.
2. Group the pending comments by tracker and by the source pull request's repository. A proposal whose source pull request has not merged waits for the next sweep.
3. For each group, launch one fresh one-shot canonical `tpm` subagent on the lowest-cost model the surface offers, by the launch call § `triage` names, with `tpm` in place of `maintainer`. Send it the project-management skill's `workflows/proposal-sweep.md` with a brief naming: a checkout of the source repository on this host as its worktree, the group's tracker, tracker repository and source repository, the fleet's issue IDs, and the group's comment bindings. The sweep creates no carrier item and starts no lane, and its analysis never runs in the overseer.
4. Capture its single final return, then retire it as § `triage` says.
5. Accept the return only when it holds no other text and parses as one issue-mode audit object whose `tracker`, and for GitHub whose `repository`, equal the group's. Each `create` and `skip` row carries exactly one `proposal_sources[]` entry by `index`; each entry names a distinct binding of this group, and no entry points at another row.
6. On a launch, capture, parse or validation failure, stop: post no reply and record no outcome.
7. Write the accepted object with the harness file-write tool to `tmp/proposal-audit-[UTC_EPOCH].json` in the overseer's checkout, `[UTC_EPOCH]` fresh per group.
8. Check its rows against live fleet work. Then run the project-management skill's `workflows/audit-issues.md` as `audit-issues --analyzed tmp/proposal-audit-[UTC_EPOCH].json` under `PM_CREATE_AUTONOMY`.
9. Reply to each comment with its outcome: the created issue's ID or a one-line decline. On Linear, run `.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --parent [COMMENT_ID] --body-file [PATH]`. On GitHub, run `gh issue comment [NUMBER] --repo [OWNER/REPO] --body-file [PATH]`, the body's first line `Proposal outcome for [COMMENT_URL]:`.
10. Record each source and its outcome in the fleet log.

### Heartbeat backstop for lane proposals

At each `heartbeat` and before fleet close, run § Lane proposals over every fleet issue in its tracker and repository group. This catches a comment posted with no notice.

### Heartbeat backlog audit

At each `heartbeat`, apply [heartbeat-audit.md](heartbeat-audit.md), apart from the proposal sweep and the `triage` verifier.

### Heartbeat design review

At each `heartbeat`, apply [design-review.md](design-review.md)'s `heartbeat` row to every `running` lane.

### Cut scope blowups

A pull request whose diff outgrows its issue's Done-when goes back to the contract: the oversized work stays on a branch, and the contract lands.

Machinery no issue ordered, such as a new subsystem, scanner or lexer, is cut, never reviewed into shape.

### End spirals

A round whose finding shares a root cause with one a prior round patched is dispositioned by [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence).

A bot that drip-feeds one finding class gets the class exhausted in one audit pass, then dispositions without pushes.

After five bot rounds on one pull request, the lane answers the standing threads once and starts no further fix round. The review gate and the owner's merge authorization still apply.

The overseer never orders a blanket `Declined` across a pull request's open findings. Each finding is dispositioned on its own mechanism; a label-only decline breaks [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow).

### Fix the source

The same finding class on a third pull request is a mechanism gap. File it, and route through a lane, as its own item, the smallest deterministic check (a guard lane, a preflight rule, a refusing script) or one sentence in the owning skill.

A deterministic check beats prose where it stays simple. Complex or brittle machinery is worse than either.

A package or workflow gap is never a harness memory or a local note. A lane's gap is a proposal ([skill-rules.md § Coordination](skill-rules.md#coordination)). The overseer files its own through § File one item alone.

### File one item alone

1. Read [design-review.md](design-review.md) before filing.
2. Write the one item, a class under § Fix the source or an issue an `owner-note` asks for, to a file in the project-management skill's audit-issues input form, with `source: "oversee"`, `parent_issue: null` and the fleet's `tracker`.
3. Run the project-management skill's `workflows/audit-issues.md` as `audit-issues --single [FILE_PATH]`. `--issues` is for a batch: its TPM run sweeps the whole backlog for cancellations.
4. Append one fleet-log `ruling` whose text starts `filed ` and names the filed item, its Location files and its defect-class rule, stated as the rule every site breaks.

### Rule once for the fleet

Send a ruling that answers one lane's question to every lane in the same situation, and record it in the fleet log.

### Held merges

Under `ORCH_MERGE_AUTONOMY=ask` a lane's merge question arrives as `lane-question`.

1. Read the gate results the lane reports. Do not reproduce them.
2. Relay the question to the owner, worded as the communication skill's [questions reference](../../communication/references/questions.md) requires.
3. Send `MERGE` to the lane only after the owner authorizes it, or send the one directive the owner gave. A directive may carry the authorization ("with that landed, MERGE stands"); the lane then merges once the change is in, with no second answer.

A merge hold is a person who disabled a pull request's automatic merge: `queue-watch` reads it as `cause: merge_hold`, with `disarmed_by` naming that person, never a fault. The lane asks about it through `lane-mail ask`, so it arrives as `lane-question`: relay it to the owner as above, naming who holds it.

### Lanes merge their own pull requests

A lane whose gates read met merges its own head by [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 1. The overseer runs no normal merge for a lane.

The overseer's own GitHub App acts for the head approvals [copilot-head-notices.md](copilot-head-notices.md) sets. It acts for nothing else, except an emergency merge in a consumer whose ruleset lists that app as a bypass actor, as that step's "Who acts" names.

A merge group that cannot pass because a CI input read from the default branch broke takes the recovery route in the review-gate skill's `SKILL.md` § 4. Operations.

### Hand off a lane before it runs out

The `lane-mail-check` turn-end hook judges a lane's context and account marks at each turn end, refuses the turn end at a mark, and tells the lane to write its handoff record. Which marks it judges, the record and when the lane writes it: [skill-rules.md § Round Closure](skill-rules.md#round-closure). Copilot CLI, as measured, honours a turn-end block eight times in a row and then ends the turn unheld; the refusal returns at the session's next turn end. The overseer judges the same marks between turn ends, and for a lane whose hook refuses nothing:

1. Read `tmp/lane-mail/[ITEM]/context.json` under the lane's `mail_root`; for a hosted lane, `.agents/skills/orch/scripts/orch-runtime host cat --item [ITEM] [PATH]`. A record whose `harness` differs from the lane record's, or whose `session_id` differs from the one the lane record binds, is another session's. A reading older than an hour while `session-rows.jsonl` beside it holds a later Stop row is stale.
2. Judge a current reading with `orch-runtime marks --item [ITEM] --context [TOKENS]:[WINDOW]`, the hook's own judge. A lane reaches its context mark at `ORCH_HANDOFF_CONTEXT_TOKENS` tokens used, or past `ORCH_HANDOFF_CONTEXT_PCT` of its window; [settings.md](settings.md) owns the defaults. A reading with no window and fewer tokens than that count has unknown capacity: direct the lane to write its handoff record.
3. Read the account mark with `.agents/skills/orch/scripts/orch-runtime lane pick --fleet --lane [ACCOUNT] --harness [HARNESS] --min-headroom-pct [ORCH_HANDOFF_HEADROOM_PCT]`, `[ACCOUNT]` the lane record's `account`. A Claude or Pi lane adds `--native-model [MODEL]`, the lane record's `model`. The reply's `answer`: `lane` is room; `walled` is the mark reached; `reserved`, `retired` or `excluded` is the account refused by its owner's setting, which you tell the owner. Any other answer leaves the mark unknown.
4. Treat no record, another session's record, an unreadable or stale one, and an unknown mark as unknown, never as room.
5. Where a mark is reached and no handoff record stands, send the lane a directive to write its handoff record ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)).
6. On the lane's `handoff` line, relaunch the item through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), which resumes from the handoff record. A Copilot lane's relaunch starts a fresh session on that record.

The attached-launch reserve, `ORCH_HANDOFF_AGENT_RESERVE_TOKENS`, is the hook's own refusal of a new attached launch near the mark. Longer work uses the orch job runner ([waiter-launch.md § Launch](waiter-launch.md#launch)) or a separate session, with its run directory on the handoff.

A handoff record names any in-flight foreground validation in `traps`, with whether it survives the agent's scope and the run and recovery details [dev SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation) requires.

On a hosted fleet, also read `.agents/skills/orch/scripts/orch-runtime host list`. Tell the owner of each row whose item has no `running` lane record: it is a sandbox no lane claims.

### The overseer's own marks

`orch-runtime marks --fleet` judges the overseer's context mark, its account headroom, its projected wall time at `ORCH_OVERSEER_WALL_MINUTES`, and its process memory under its cap. The turn-end hook hands it the current reading, and the watch the recorded one between turn ends. An unread or unmeasured mark is never room. The watch reports a reached mark as `overseer-mark`; [overseer-session-events.md § Event kinds](overseer-session-events.md#event-kinds) says when it repeats and what it names under each `AGENT_RUNTIME_CONTROLLER_SUCCESSION` value. A silent interval does not mean the mark lifted. At a mark, follow [oversee.md § Succession](../workflows/oversee.md#succession).

A dead or walled overseer takes no turn, so the watch judges its session and tells the owner of each death. The events and the recovery: [overseer-session-events.md](overseer-session-events.md). A successor reads the output its predecessor's children left before it repeats their tasks.

### Keep the report's inputs current

After each [oversee.md § 2](../workflows/oversee.md#2-select-work) selection, write the items not yet launched, in launch order:

```bash
.agents/skills/orch/scripts/orch-runtime op --fleet --request-json '{"op":"record-overseer-ledger","entry":"launch-queue","items":["[ITEM]",...]}'
```

The request refuses an empty or repeated item as `launch-queue-entry`. The queue holds the order and the tracker the membership: § `heartbeat` adds what the tracker says the fleet owes.

A question sent to the owner is an owner ask ([communication-modes.md § Owner asks](communication-modes.md#owner-asks)). The report reads the open asks from the mailbox; nothing is recorded for them in the state.

### Decide without the user

The ask set is [communication-modes.md § Ask set](communication-modes.md#ask-set), which nothing here narrows or widens. Any other call takes the option that costs nothing, recorded in the fleet log as [communication-modes.md § Recording](communication-modes.md#recording) requires.

## Direct-push cycle records

A direct push raises no `merged` line. When a lane reports a successful direct push to the base branch, close the lane with the pushed commit as the close's `delivery`, so the close writes its cycle.

1. Work from a checkout of that repository: the cycle reads the commit there, and the push from the lane record's `repo` or else the checkout's own.
2. Write the request to `[REQUEST_FILE]` with the harness file-write tool:

   ```json
   {"op":"close-lane","item":"[ITEM_KEY]","delivery":{"commit":{"commit":"[PUSHED_SHA]"}}}
   ```

3. Run it:

   ```bash
   .agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] op --fleet --request [REQUEST_FILE]
   ```

4. Read the reply's `.result.notes`. The cycle carries the lane record's launch tier, `launch-tier-missing` where the record has none. `merged` is the time the push reached the base branch in GitHub's activity log, never the commit's date; `merged-unread` names a failed read. The cycle's line joins the fleet log as a `cycle` row.

## Event kinds

The watch writes one line per event to its log beside the fleet state. A line that starts `EVENT ` is the event; [watch/events.rs](../runtime/src/watch/events.rs) `Event::render` holds every form. Lines that follow an event without `EVENT ` belong to it: a pane tail or banner, unindented; a message's payload, indented two spaces, with an `options:` line where the message offered options; a heartbeat's or report's body.

A field in brackets below is a value; every other word is printed as shown. To wake a lane below is to send it a directive as [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane) says.

### `watch-step-failed`

`EVENT watch-step-failed step=[DUTY] count=[N]`: the duty named (`mail`, `native-observation`, `tracker`, `verification`, `report`, `reconcile`, `heartbeat`, `wake`, `github` or `retention`) failed, whole or in part, `N` times in a row. The line prints on the first failure and on every `ORCH_OVERSEER_MARK_REPEAT`th after. A run that failed in part keeps the lines it printed; the duty runs again at its next cadence, and the other duties go on.

1. Read the cause in `oversee-watch.err` beside the fleet state, under the same `watch-step-failed step=[DUTY] count=[N]` words.
2. Correct what the cause names. A malformed fleet record is corrected against [workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state).

A lane whose mail, clone or state read fails draws no other line: this one names it. The hosted words under it:

- `snapshot-unwritten host=[HOST] path=[DIR] cause=[CAUSE]` under `step=mail`: the mail duty could not write its local copy of that host's lane mail files, so those lanes' mail is unread this pass. Correct the cause at the path named.
- `host-capabilities-unread host=[HOST] cause=[CAUSE]`: the provider's capability line did not read, so that host's lanes are not judged this pass. Correct the provider or its host.
- `host-busy count=[N] cap=[N] verb=[VERB] item=[ITEM]`: every slot of the provider's call pool stayed taken past its wait, so the call ran nothing. The pools are `ORCH_LANE_HOST_MAX_CALLS` for `create`, `wait`, `start`, `close`, `stop` and `stop-sandbox`, and `ORCH_LANE_HOST_SHORT_MAX_CALLS` for every other verb, shared by every checkout and overseer of this home. The next pass asks again.

### `tracker-quota`

`EVENT tracker-quota status=[STATE] reset=[ISO|unavailable] limit=[KIND]`: the pass could not finish its tracker reads. Keep owner answers unread. A missing owed or Verifying line during the hold is unread evidence, not proof that no work remains. Follow the linear skill's quota contract and its `patterns/workflow-actions.md` for held writes. Mail, GitHub, lane and report checks go on.

### `github-auth-failed`

`EVENT github-auth-failed cause=[CAUSE]`: the GitHub duty's sign-in was refused, and the github skill's credential ladder found no working credential, so no GitHub line prints. The watch tells the owner through the overseer mailbox's owner channel. Sign `gh` in again, or renew the token the ladder reads; the next GitHub pass takes it.

### `watch-taken-over`

`EVENT watch-taken-over pid=[PID] start=[START|none] reason=gone`: this watch took over the claim of a runner whose process ended, or whose pid another process reuses. `start=none` is a claim that recorded no start. Nothing is owed: read the log on as one watch's.

### `reconcile-refused`

`EVENT reconcile-refused intent=[ID] refusal=[KEY]`: the reconcile duty could not complete or mark the open intent named. The line prints when the key is new or changes.

1. Read the intent with `.agents/skills/orch/scripts/orch-runtime state inspect --fleet`.
2. Correct what the key names, or report the open intent to the operator, as [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) says of an intent no reconcile settles.

### `notice-unmarked`

`EVENT notice-unmarked intent=[ID] cause=[KEY]`: the intent's owed failure notice reached the owner, and the store refused its `sent` mark. Read the intent with `orch-runtime state inspect --fleet` and correct the cause.

### `directive-send-unsettled`

`EVENT directive-send-unsettled item=[ITEM] cause=[KEY]`: a directive `orch-runtime send` recorded owed on the lane has no receipt that settles it. Every later send to that lane refuses `directive-send-owed` until it is settled. The line prints when the cause is new or changes.

`cause` is `receipt-missing` where the mailbox program kept no receipt, `receipt-unnamed`, `receipt-invalid` or `receipt-unreadable` for a kept receipt under the state directory's `directive-send/`, or the store's key where the receipt's mark was refused.

1. Look under `directive-send/` first. A kept receipt needs only its refusal corrected; the next reconcile stamps it.
2. With no receipt, read the session for whether the directive arrived.
3. Settle the record: write `{"op":"record-directive-send","item":"[ITEM]","write":{"stage":"failed","cause":"[WHY]"}}` to a file and run `.agents/skills/orch/scripts/orch-runtime op --fleet --request [FILE]`. The record reads `failed` with that cause and `owner: operator`, and the next send proceeds.
4. Send again only where the session shows the directive did not arrive.

### `merged`

`EVENT merged [PR] [ITEM] [OWNER/REPO]`: a pull request of the lane's item merged, `[ITEM]` lowercased; the line prints once per merge. A GitHub merge alone does not complete the lane.

- A running item: the lane finishes [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) itself. Where its worktree or sandbox is gone, the runtime close completes the item's branch boxes from the pull request body's `## Done-when evidence` section ([lane-reach.md § Lane close](lane-reach.md#lane-close)). The watch closes a merged lane whose work has left its host at its `lane-exited` or `idle-after-return` line, the merge as the close's `delivery`. Close any other local lane once it has finished `merge-pr.md` § 5: add `"delivery":{"pr":{"pr":[PR_NUMBER],"repo":"[OWNER/REPO]"}}` to the request § Direct-push cycle records shows, and run it from the overseer's base checkout, or from a checkout of the lane's repository where its `mail_root` is another repository's worktree.
- A parked or stopped item: the watch closes it on the terminal ground once the tracker reads it ended, after reading the lane's merges itself; the close writes the lane's merge cycle. A parked record whose pull request is still open or queued stays parked. A parked item with work left takes § `parked-merged`.
- A Done item with no open box: its cycle row is its report; no relaunch is owed.
- `[ITEM]` `kendex/refresh`: a refresh pull request the watch reported `refresh-ready` merged. It has no owning lane. Check whether the open lane pull requests touch the files the refresh changed, and follow the repository's declared refresh owner.

A confined lane's own `container-close` and `state remove` do nothing: each prints `container-close: left cause=confined owner=overseer` or `state-remove: left cause=confined owner=overseer` and exits 0 (`main.rs::step_aside`). The overseer's route runs both for that lane: the container close of § Verification, and the item close-out with `.agents/skills/orch/scripts/orch-runtime state remove --item [ITEM]` at the lane's close.

A hosted lane stays in the watch until its `lane-closed` or `lane-close-refused` line. Send it nothing while that close runs.

The close writes the `cycle item=...` line, and a `repeat-miss` line where it makes the third miss on one phase, to the fleet log as `cycle` rows. A `verdict=miss` line needs nothing more. A `repeat-miss` line is three lanes missing on one phase: file one CI or process issue in that repository naming the phase, the lanes and each lane's `causes` ([skill-rules.md § Coordination](skill-rules.md#coordination)). The rollup, `orch-runtime cycle rollup`, prints the per-class totals; [cycle.rs](../runtime/src/ops/cycle.rs) owns the class bases.

A cycle the close cannot record is `lane-close-failed item=[ITEM] step=cycle cause=[CAUSE]` on the watch's stderr. The watch holds the close and asks again each pass; the stderr line is the report.

After the item's merge, follow the repository's declared refresh owner in its consumer instructions:

- On a hosted fleet, keep refresh and verification with the declared owner outside the control host, and run `.agents/skills/orch/scripts/sync-base` in the control checkout after the owner's reviewed outputs merge. Report a failed owner workflow.
- On a local fleet, run `.agents/skills/orch/scripts/post-merge --command-only` in the overseer's base checkout where a declared workflow owns refresh, or `.agents/skills/orch/scripts/post-merge` where the local fleet owns it. Then run the repository's lifecycle check. Both modes keep checkout changes: report those diffs to their declared owner. Stop on a failed step and report its status.

When the fleet's last item completes, run the `heartbeat` triage pass before closing out. A Linear fleet also runs `.agents/skills/orch/scripts/orch-runtime reconcile-items`: its exit-0 reply carries its findings in `result.findings` and its box lines in `result.lines`. Report both with the close-out.

### `parked-merged`

`EVENT parked-merged [ITEM] pr=[N] repo=[OWNER/REPO]`: the pull request a parked item waited on merged, and the item has work left. A dependency park waits on `parked.until_pr`; a queue park on `parked.pr`. The watch repeats the line before each heartbeat while the record reads parked.

1. Relaunch through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). The relaunch starts the harness fresh on the kept disk; the item's handoff record carries its context.
2. A dependency park: the lane rebases and continues the held step. Record no cycle for the dependency's merge.
3. A queue park: the lane finishes `merge-pr.md` § 5 steps 2 to 6 and § 6, and its close records the item's cycle.

Report a capacity refusal and act on the next repeat.

### `parked-closed`

`EVENT parked-closed [ITEM] pr=[N] repo=[OWNER/REPO]`: the pull request a dependency park waited on closed unmerged. The line prints once. Resolve the hold, or resume the lane through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch).

### `park-owed`

`EVENT park-owed [ITEM] result=[RESULT]`: the watch asked again for the park a stopped record owes, a record whose sandbox stands with a `park_owed` member. It asks each pass and prints a result once per distinct result. `parked` needs nothing. Any other result is the park's refusal or failure: its key and fields, `unanswered [CAUSE]`, `refused path=[PATH]` or `deferred`. Read it against [oversee-lanes.md § Parking a merge wait](oversee-lanes.md#parking-a-merge-wait). A refusal that stands is resolved by a relaunch through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) or a close through [lane-reach.md § Lane close](lane-reach.md#lane-close).

### `lane-closed`

`EVENT lane-closed [ITEM]`: the watch ran the runtime close under [lane-reach.md § Lane close](lane-reach.md#lane-close), for a hosted lane or for a parked or stopped record the tracker reads ended. Record a hosted close's line under it in the fleet log: `kept=[PATH]`, `kept=none` for no archive, `kept=sandbox` for a close that ended the harness and kept the sandbox, or `closed=absent item=[ITEM]` for a host that no longer held the item ([lane-host.md](../schemas/lane-host.md) `close`).

### `lane-close-refused`

`EVENT lane-close-refused [ITEM]`: the watch's close refused.

- A parked or stopped record's close: read `lane-close-refused item=[ITEM] cause=[CAUSE]` on the watch's stderr. The watch asks no more until the record or the verdict moves.
- A hosted close the provider refused: the sandbox stays. Tell the owner the `path=` line under the event: the checkout the close stopped on. Inspect that directory and never force the close.

### `lane-close-failed`, `lane-close-unanswered`, `lane-close-unconfirmed`

Lines of the watch's own closes on its stderr, under a `watch-step-failed` line; no `EVENT` line goes with them.

- `lane-close-failed item=[ITEM] [CAUSE]`: the watch's close of that lane failed, the cause the close's own. `lane-close-failed item=[ITEM] step=cycle cause=[CAUSE]` is a cycle the close could not record (§ `merged`). Correct the cause the line names.
- `lane-close-unanswered item=[ITEM] [CAUSE]`: the provider's close gave no answer within its bound, so the sandbox may or may not be closed. Read the host with `orch-runtime host list` before closing again.
- `lane-close-unconfirmed item=[ITEM] marker=[PATH]`: an earlier close's end was never read; § `cloud-stall-closed` says what the operator does.

### Close answers

The runtime close run by the overseer ([lane-reach.md § Lane close](lane-reach.md#lane-close)) answers in `.result.word`, or refuses at exit 1 with `refusal.key` and its fields. Report a refusal or an observation to the owner. Never type into the pane to end the harness instead.

- `lane-live state=[STATE]`: the lane is still live; the close ends no live lane.
- `unconfirmed`: the close left something standing, named in `.result.observation`, and its intent stays open. Correct the cause and run the same close again; the repeat acts on the handles the intent recorded.
- `failed`: the close refused before it signalled anything, the cause in `.result.observation`.
- `ask-unanswered`: the lane is waiting in `lane-mail ask` for an answer. A hosted lane's close refuses with the `ask=` it found; a local lane's answers `failed` with `ask-unanswered` in its observation. Answer the ask as [lane-reach.md § Lane close](lane-reach.md#lane-close) says, then run the same close again. Only an answer lifts it: a relaunch writes none. An exited lane takes no such refusal.
- `mail-read-failed`: the mailbox did not read. Fix what its `cause=` names.
- `harness-unsupported harness=unknown`: a hosted lane's record names no harness to stop. Run the close again with `"harness"` set to `claude`, `codex`, `pi` or `copilot` in the request.
- `tracker-read-failed cause=key-ambiguous`: an `issue-N` record carries no tracker. Set `"tracker"` to `linear` or `github`, and for GitHub `"repo":"[OWNER/REPO]"` too. A field fills only a field the record leaves empty; one that contradicts the record refuses `record-invalid`.
- `item-files-kept cause=[CAUSE]` in `.result.notes`: the lane closed, and its files stay because its tracker did not answer. Add `"tracker"` or `"repo"` to that close for a record carrying neither; otherwise they stay until a later close-out of the item ([workflow-state.md § Item close-out](../schemas/workflow-state.md#item-close-out)).
- A hosted stop that did not answer refuses `stop-failed`, its `cause=` the failed step, with the provider's own lines above it; `exit-timeout` is a harness whose pane did not read exited within `ORCH_LANE_CLOSE_SECS`. The window and the record stay. For a Copilot CLI lane in a `pane=local` window, the same stop is held `unconfirmed` with `host_stop: stop-failed` in `.result.observation`, after the harness has exited and its window has closed; the record stays. Correct the cause and close again.
- `cause=provider status=4` with the provider's `stop-worktree-removed item=[ITEM]` line above it: the item's own close-out removed its worktree, so the stop has nothing to find the harness by. Only a full close closes it. Without that line, the `4` is the provider's own, such as a stopped sandbox: start the sandbox, then close again.

### `lane-exited`

`EVENT lane-exited [LANE]`: the window is alive and the harness under it is gone. The lane's closing lines follow and say why. `payload-noise-only lines=[N]` in their place means the lane deleted its own worktree and its shell has drawn nothing since.

- A lane at a harness session limit ("You've hit your session limit · resets 9:50am") is walled, not dead: § `usage-limit` applies.
- A lane that reported `handoff` is relaunched per § `handoff`, never nudged.
- A lane whose merge landed and whose work has left its host: the watch closes it at this line with its merge as the close's `delivery`.
- Any other exit: § `window-gone`.

### `window-gone`

`EVENT window-gone [LANE]`, or any lane whose session ended with no merged pull request:

1. Inspect its worktree and pull request.
2. A lane whose item the tracker reads completed or canceled has ended its work, a no-change round's item among them ([start-worktree.md § 2](../workflows/start-worktree.md#2-implement)): close it through the runtime close ([lane-reach.md § Lane close](lane-reach.md#lane-close)) and relaunch nothing.
3. Otherwise relaunch it once with the same brief through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch).
4. Tell the owner of a second death; do not retry it.
5. After the relaunched lane finishes, close it through the runtime close. Do not rebuild the pane, host and state steps by hand.

### `lane-unreadable`

`EVENT lane-unreadable [LANE] cause=[WORD]`: the watch could not read the lane's pane, process or screen this pass. The line prints when the cause first appears or changes; a pass that reads the lane clears it. The lane keeps its last judged state. It is never `window-gone` or `lane-exited`: relaunch nothing on this line alone. A cause that stands across passes is a fault of the recorded tmux server or of the lane's `mail_root`: read and correct it.

### `stray-window`

`EVENT stray-window [PANE] window=[ID] server=[PID] name=[NAME]`: a window of the fleet's tmux session that no lane record, overseer record, open intent or receipt names. `server=` is the tmux server's process id. The watch reports it once while it stands and never closes or adopts it. Find what opened it, such as a window a person opened or a launch whose record was lost, then close it or register it.

### `handoff`

`EVENT handoff [ITEM]`: the item's lane recorded its handoff and exited; the record follows the line. Relaunch it through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), which composes the request from the record. A record whose `cause` is `model-switched` relaunches on the record's `model`.

A handoff does not confirm that its session stopped: a relaunch refuses `lane-live` while the record reads in flight. End the lane first, as that section says. Report a `stop_failure` cause and process identity where the record carries one.

### `idle-after-return`

`EVENT idle-after-return [LANE]`, then an optional note: the lane read idle on two passes in a row, or a local Codex lane read idle after its turn. Read the closing lines under it.

- A local lane reads working from its prompt or first tool row until a passed Stop; a held Stop stays working, and Claude Code StopFailure ends the turn. Pane dialogs and walls take priority except on Pi; Codex's current failed-turn marker below its last prompt and above its idle composer can end a Working row. Hosted Pi lanes use their own Stop rows; other hosted lanes keep their provider's screen reading.
- `cause=[WORD]` is Claude Code's StopFailure `error`, or a Stop row's own stop reason where it is not the harness's ordinary end. `cause=length` is a turn the model's output limit cut: the lane has not finished, and it takes a one-line continuation directive.
- `cause=api-error` is a turn its provider's API ended. The watch resumes a lane the wake reaches once, with no line, so this line is the second such end, a resume the wake could not type, or a lane the wake does not reach: wake the lane with a continuation directive.
- `stop-cause=allow-all-blocked-by-policy` follows [copilot-runtime.md § Allow-all blocked by policy](copilot-runtime.md#allow-all-blocked-by-policy) instead of a directive; that section names the `session-record=` reasons.
- A lane whose merge landed and whose work has left its host is closed by the watch at this line.
- A lane inside `merge-pr.md` § 5 step 1 waits on its queue: that is work in flight, not idle.

Otherwise the lane has returned and is free for another fleet launch.

A lane is a stalled-round candidate only when the lines show its round watchdog finished with no waiter still running, its status file names a dev or fix round as its current step, and its worktree holds no `tmp/dev-return-[ISSUE_ID]-[DEV_ROUND_ID].json` for its workflow state's `dev_round_id`. Read the state file and test for the file as [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads) reads the status file. Send the lane a directive to check the conditions in [skill-rules.md § Stalled round](skill-rules.md#stalled-round), and to recover the round only when every one holds.

A lane whose session ended after its pull request merged, before `merge-pr.md` § 5 steps 2 to 6 finished:

1. Send it `merge-pr [PR_NUMBER]` as a directive.
2. Then relaunch it through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). The relaunch tells the lane to read its inbox first, so the waiting directive binds the pull request number. Its already-merged route skips the merge and runs the tracker sync, project verification and worktree removal.

### `lane-asking`

`EVENT lane-asking [LANE]`, then an optional note: a harness dialog, never a question for the overseer: a permission prompt, a trust prompt, a model picker. Answer it in the lane's own dialog per [lane-reach.md § Per harness](lane-reach.md#per-harness).

A note `stop-cause=allow-all-blocked-by-policy` is a Copilot lane launched with allow-all that its policy blocks: follow [copilot-runtime.md § Allow-all blocked by policy](copilot-runtime.md#allow-all-blocked-by-policy) and do not answer the prompt. That section also names each `session-record=` reason.

### `model-capacity`

`EVENT model-capacity [LANE]`: the selected model stopped one turn, not the session. Send one continuation line; the next pass watches the lane again. Never relaunch the lane.

### `lane-ready`

`EVENT lane-ready [ITEM]`: a hosted lane whose host prepared it in a background job is up, and the watch carries it from this pass. The line prints once. Nothing is owed.

### `lane-prepare-failed`

`EVENT lane-prepare-failed [ITEM] reason=[REASON] [exit=[RC]] log=[PATH]`: a launch failed; `log=` holds its output.

- `reason=relaunch-failed`: the watch's own wall relaunch failed, `exit=` its status, or no `exit=` where the launch's intent settled it failed. Its log holds the `op` replies; `.result.effect.report.intent.observation` names the cause. Keep any window that stands, fix the cause, then relaunch.
- `reason=wait-failed`: the host's own preparation failed. Close the lane through the runtime close ([lane-reach.md § Lane close](lane-reach.md#lane-close)), which closes the host from the `stopped` record, and launch the item again once.
- `reason=launch-failed`: a launch step on a ready host failed, named in the log. Fix the cause, then relaunch through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch).

Tell the owner of a second failure.

### `lane-prepare-stuck`

`EVENT lane-prepare-stuck [ITEM] age=[N]s log=[PATH] [reason=relaunch-pending]`: a preparation ran past `ORCH_WATCH_PREPARE_SECS` with no outcome. The line prints once per preparation.

- `reason=relaunch-pending`: the watch's wall relaunch is still out. Its job owns completion while it runs; once the job ended with its launch unconfirmed, the reconcile duty owns it. Read the log, keep the window, and start no second recovery.
- A launch the runtime holds open over an unanswered preparation step follows [lane-directive.md § Launch gate](lane-directive.md#launch-gate).
- A record with `prepare.log` belongs to a background job: read the log's tail, close the lane through the runtime close, which stops that job and closes its window and host, then launch the item again once. A relaunch over that job races it for the same window and record.

Tell the owner of a second stuck preparation.

### `start-stalled`

`EVENT start-stalled [ITEM] age=[SECONDS]`: `ORCH_WATCH_START_STALL_SECS` passed since the record's `running_at` with no status file under its `mail_root`, or, for a host kind that declares `files=none`, with no open pull request and no push on the item branch. The lane never started its workflow. The line repeats every `ORCH_OVERSEER_MARK_REPEAT` passes while it stands, so a line already acted on needs nothing more.

- A cloud lane (`files=none`): send it one directive; the watch bounds it as § `lane-stalled` says.
- A host kind that declares `files=verb` has its status file read through the provider; a failed read is `start-stall-unread` on the duty's `watch-step-failed` line, and no event.
- Any other lane: read its state with `.agents/skills/orch/scripts/orch-runtime lane status --item [ITEM]` and its pane per [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads). Wake a lane idle at its brief. Answer a harness dialog per [lane-reach.md § Per harness](lane-reach.md#per-harness). Relaunch an exited or unjudged lane once through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch).

A relaunch renews `running_at`. A `start-stalled` line whose `age=` counts from after the relaunch is a second stall: tell the owner.

### `lane-stalled`

`EVENT lane-stalled [ITEM] age=[SECONDS] [state=[STATE]]`: a running cloud lane, a host kind that declares `status=none`. The line repeats every `ORCH_OVERSEER_MARK_REPEAT` passes while it stands, and a changed `state=` prints at once.

- `state=finished`: its open pull request left draft. Launch the item's landing lane in this pass, as § `pr-watch` says for `disarmed` on a `land=handoff` record. Send no directive and wait for no approval.
- `state=out-of-credit`: the pull request is still draft, and the account roster reads its account locked or out of credit. Send no directive. Close the lane through the runtime close and relaunch it as § `cloud-stall-closed` says.
- No `state=`: the pull request's head and body, or with no pull request the item branch's head, have not moved for `ORCH_WATCH_LANE_STALL_SECS`. A record naming no `repo` is read in the fleet's own repository, then in the `ORCH_CONNECTED_REPOS` ones; a fleet repository that cannot be named fails the read. No read tells a long step, a waiting question, spent credit and an ended session apart:
  1. Read the pull request body with `gh pr view`, or the branch's newest commit message and any report committed on it.
  2. Where they record a blocker that is the owner's, such as a pull request create the session token was refused, tell the owner and send no directive.
  3. Otherwise send one directive through `.agents/skills/orch/scripts/orch-runtime send --item [ITEM] --file [PATH]` ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)), which records it on the lane record as `directive_send`.
  4. With no push and no body change within `ORCH_CLOUD_STALL_MINUTES` of that send, the watch closes the lane and prints `cloud-stall-closed`. A send recorded `archived` or `failed` cannot reach the session: close the record through the runtime close at once and relaunch it as § `cloud-stall-closed` says.

Keep no stall count per repository: a fleet whose cloud lanes keep stalling drops cloud from `ORCH_LANE_PREFERENCE`.

### `cloud-stall-closed`

`EVENT cloud-stall-closed [ITEM] directive_age=[SECONDS]`: a stalled cloud lane left its directive unanswered past `ORCH_CLOUD_STALL_MINUTES` with nothing pushed, and the watch closed it through the runtime close. Its `lane-closed` line with the archive line comes first. The fleet-log `close` row names the send's result, the CLI's words and the credit reading from `directive_send`.

The watch asks a close once per lane, by a marker `lane-close.[ITEM]` under its own state directory. A marker that stands beside a lane whose record still reads open is a close the watch cannot confirm: it says `lane-close-unconfirmed item=[ITEM] marker=[PATH]` on the duty's failure line each pass. Close that lane yourself, then remove the marker at the path the line names.

1. Archive nothing yourself: report the session id to the owner, who archives it.
2. Relaunch the item as a hosted lane on its branch. Choose the host under [oversee.md § 3](../workflows/oversee.md#3-launch) Placement, never `claude-cloud`, and run [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) with the request's `host` naming it. The relaunch starts fresh on the `start` brief, which runs the standard cycle on the branch the cloud lane left.
3. Name the fleet-log cause in the relaunch's `ruling` row.

### `lane-long`

`EVENT lane-long [ITEM] age=[SECONDS] review_rounds=[N] fix_receipts=[N] validation_runs=[N] restacks=[N] repeated_class_rounds=[N] stage=[STEP]`: a `running` or `parked` lane is `ORCH_WATCH_LANE_AGE_SECS` past its record's `launched_at`, which a relaunch keeps. The line repeats once per further `ORCH_WATCH_LANE_AGE_SECS`.

`stage=` is the `Step:` line of the lane's status file; `parked` for a parked lane, `unread` where the read failed, `none` where the lane writes no file or names no step. Each count is a string of digits, or `unread`; all five read `unread` for a parked lane or one whose state did not read. [design-review.md](design-review.md) reads the counts.

1. For any `stage=` but `parked`, read the lane: its status file per [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads), its workflow state, and its pull request's `.agents/skills/github/scripts/github.sh pr-timeline`.
2. For `parked`, read none of its files: read the lane record's `parked` and `pauses`, and that pull request's `pr-timeline`. A park happens only in `merge-pr.md` § 5 step 1's queue wait, so the cause is the merge queue or the time before the park.
3. Apply [design-review.md](design-review.md) when its trigger holds.
4. Name the cause: long tests, a stuck state or wait, a review loop, scope growth, or the merge queue. If no design review starts, record the cause as a fleet-log `ruling` whose text starts `long-reason`.
5. Where the cause is in the system, not in this item, file its fix under § Fix the source.

### `usage-limit`

`EVENT usage-limit [LANE] [ACCOUNT] [resets=[UTC]] [wall_kind=auth]`: the lane's harness drew a usage-limit banner, or a Pi lane's turn ended on one; the banner and the screen around it follow. The watch left the wall to the overseer: `ORCH_WALL_RELAUNCH=ask`, no account qualified, or a refusal. The lines under it:

- `pick lane=[DIR]`, `pick none` or `pick unjudged [CAUSE]`: the account judge's answer for the record's model, the spent account excluded.
- `wall-relaunch-refused lane=[LANE] reason=[REASON]`: the step that stopped the watch's relaunch. `record-unnamed` is a record naming no harness or model; `account-unknown` one naming no account; `spent-account` a pick that named the spent account; `context-unavailable cause=[CAUSE]` a record the relaunch cannot compose its requests from; `stop-failed exit=[RC]` or `stop-unanswered` a hosted stop the provider did not confirm, so the harness may still run and nothing starts beside it; `marker-unwritten` or `launch-failed` a relaunch that could not start.
- `account-wall: record-unwritten config_dir=[DIR] cause=[CAUSE]`: the wall's record for that account did not write. Until it writes, launch nothing on that account before the reset.

1. Read the banner and the screen around it. Confirm the banner is the harness's own, not a limit phrase the lane printed. Leave a lane that is still working alone.
2. Before any stop by hand, apply [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch).
3. With `pick lane=[DIR]` under `ask`, for a lane that section admits: on a hosted lane, run `.agents/skills/orch/scripts/orch-runtime host stop --item [ITEM] --harness [HARNESS]` and require its `stopped item=[ITEM] processes=[N]` line; keep the window, which the relaunch's runtime close closes. Then relaunch with `[DIR]` as the request's `account`.
4. With no account of that harness qualifying, pick another harness and relaunch with the one-sentence continuation brief from [handoff.md § 2](../workflows/handoff.md#2-launch), naming the matching path from the prior harness's transcript store.
5. With none qualifying and `resets=` on the line, keep the window and wait for the reset: § `usage-limit-passed` follows. A `resets=` read from a clock time or weekday is an upper bound. Never launch onto the spent account before its reset, and never park a lane on an estimate of your own when `resets=` states the time.
6. With none qualifying and no `resets=`, tell the owner the recovery is blocked and keep the window until an account qualifies. The spent account's `account` line or heartbeat roster line says which case it is.

`wall_kind=auth` is a login failure: a wall with no reset. The account judge never picks an account whose credential no longer answers. Relaunch on another account, never the walled one; with none qualifying, tell the owner and ask the operator to sign in.

A wall forced on a scratch lane by removing its account's login, with another account qualifying, takes § `lane-relaunched`; that line and the lane record naming the new account are the evidence a check needs.

### `lane-relaunched`

`EVENT lane-relaunched [ITEM] lane=[DIR] from=[DIR]`, then `log=[PATH]`: under `ORCH_WALL_RELAUNCH=auto` the watch ran the wall route itself. The account judge qualified `lane=` for the record's model with the spent `from=` excluded. A hosted lane's harness was stopped through its provider first. The watch started the record's own relaunch detached, its output at `log=`. Nothing is owed. While that launch runs, inside `ORCH_WATCH_PREPARE_SECS`, its missing window is no `window-gone`. Its failure is § `lane-prepare-failed`, its overrun § `lane-prepare-stuck`.

### `usage-limit-passed`

`EVENT usage-limit-passed [LANE] [ACCOUNT] resets=[UTC]`: the reset the wall named passed, and the lane still sits at the banner. The line under it says what follows:

- `resume wake`: the wake duty types the lane's resume once the account reads room; the `wake-*` lines with `resume=usage-limit` report it. Nothing is owed until one of those lines asks.
- `resume unreached`: the wake does not reach this lane. Read the banner and the screen as for § `usage-limit`; a lane that is working is left alone. Otherwise send it a one-line continuation directive. Do not move the item and do not launch onto that account.
- `resume walled`: the account walled again. Handle it as § `usage-limit`.

### `account`

`EVENT account [FIELDS] change=[KINDS] was=[STATUS]/[VERDICT]`: an account the fleet launches on changed since the last compared reading. `[FIELDS]` is the roster row's text, the same the heartbeat's `account-roster` lines print. An unmeasured reading moves no comparison, unless its status is `expired` or `retired`. `change=reset` is context, never a route of its own.

An `account-end-contradicted [ALIAS] ...` line under the roster is a retired account whose credential still answers: correct the retire statement its `source=` names, or take the account out of the fleet. Nothing launches on it meanwhile.

Take the first arm that matches the new reading:

1. `status=expired`: no reset brings the account back. Tell the operator to log in to it once, in the shape [communication-modes.md § Status report](communication-modes.md#status-report) gives. Never park a lane on it.
2. `status=plan_ended`: its plan ended or its organization disabled access. Tell the operator that only the owner can restore it, or take the account out of the fleet. Never park a lane on it.
3. `verdict=unmeasured`: nothing measured the account. Launch nothing new on it; handle its status per [lane-directive.md § No lane has room](lane-directive.md#no-lane-has-room).
4. `verdict=walled`: launch nothing on it before `binding_resets_at`. Where `binding_bucket=credits`, the account is a grant at or below its credit floor that no reset reopens: launch nothing on it, and direct each live lane on it to write its handoff record.
5. `verdict=room`: resume any launch the judge refused for want of an account. Wake a lane parked on this account only where its `usage-limit` carried no `resets=`.

[agent-runtime's accounts judge](../../agent-runtime/runtime/src/accounts/mod.rs) owns the verdict rules, the buckets and the credit floors.

### `overseer-dead`, `overseer-walled`, `overseer-reserve`, `overseer-context-unmeasured`, `overseer-context-stale`, `overseer-mark`

The overseer's own session: [overseer-session-events.md](overseer-session-events.md).

### `lane-question`

`EVENT lane-question [ITEM] [ID]`, then the question: the lane's own question. The lane is blocked in `lane-mail wait` on it, so every question is answered.

1. Answer it where the evidence at hand decides it: repository state, the issue body, a stated convention, a scope-narrowing call under [design-review.md § Inputs and actions](design-review.md#inputs-and-actions), or the lane's own well-argued recommendation. A pure cut back to main's behaviour, or a cut of surface the Done-when does not need, takes no table.
2. Relay any other question to the owner only where [communication-modes.md § Ask set](communication-modes.md#ask-set) puts it, in the question format that section links. A merge question under `ORCH_MERGE_AUTONOMY=ask` always goes to the owner, per § Held merges.
3. Record the ruling in the fleet log and send the answer per [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane).

An answer that accepts a step the lane's workflow would otherwise ask about carries that acceptance in its envelope; the lane's round close names its id as the overseer's act. The `stages[].authorization` row of [workflow-state.md § Field Definitions](../schemas/workflow-state.md#field-definitions) says which ids that field admits.

An overseer resuming a fleet reads what it still owes with `lane-mail pending --item [ISSUE_ID]`, adding `--root [MAIL_ROOT] --host` for a lane whose record puts it on another host.

### `lane-notice`

`EVENT lane-notice [ITEM] [ID]`, then the notice: the lane reports something it is not waiting on. Act on it where it needs acting on; it needs no reply.

- A `copilot-*` notice takes [copilot-head-notices.md](copilot-head-notices.md). A `copilot-fallback` notice whose first line carries `cause=` comes from the lane's review call and can arrive twice; one with no `cause=` is the lane's own, from its triage's `timeout` row ([review-pr-comments.md § 7.2](../workflows/review-pr-comments.md#72-copilot-head-route)).
- A notice naming a merge-group ejection that `queue-watch` read as `reach: outside`, with the failed checks, their reach, the run links and the head: red checks the item's change does not select, a defect outside the item. Apply [design-review.md](design-review.md)'s filing row, then file it once through § File one item alone, naming the failed checks and the run links. A notice that row matches to an earlier filing is recorded against that filing in the fleet log.

### `directive-read`

`EVENT directive-read [ITEM] [ID]`: the lane's mailbox cursor passed the directive. This line alone confirms a sent directive.

### `directive-unread`

`EVENT directive-unread [ITEM] [ID] age=[SECONDS]`: the directive has waited `ORCH_DIRECTIVE_UNREAD_SECS` with the lane's cursor short of it. The directives still unread print again once `ORCH_OVERSEER_MARK_REPEAT` mail turns pass with no such line for that mailbox. Reach the lane by its state, under its row in [lane-reach.md § Lane states](lane-reach.md#lane-states). `directive-read` follows once it reads it.

### `owner-note`

`EVENT owner-note [ID]`, then the note: a note to the overseer mailbox from the owner or a delegate. `from=owner` is routing, not authorship: a record names the stated speaker per [communication-modes.md § Recording](communication-modes.md#recording).

1. Act on it, or record it in the fleet log as a ruling. A standing instruction follows [communication-modes.md § Recording](communication-modes.md#recording).
2. Where a reply is owed, send it with `lane-mail notice --item overseer --to owner --ref [ID] --file [PATH]`, so the owner reads it on the channel the note came from ([oversee-takeover.md § 1](../workflows/oversee-takeover.md#1-read-the-mailbox-and-handoff)). Route it per [communication-modes.md § Owner delivery](communication-modes.md#owner-delivery). A question back is an owner ask.

An identical send within the minute appends nothing and refuses `duplicate id=[FIRST_ID]`. A notice text the owner received within 24 hours refuses `owner-notice-repeated` naming that notice's id, so a second reply takes its own words.

The watch prints each message line at least once. A stop between the print and its cursor commit prints it again: an id already seen is a repeat.

### `owner-ask-resolved`

`EVENT owner-ask-resolved [ASK_ID] by=[text|default] id=[ANSWER_ID]`, then the answer: an answer to an owner ask. The owner can answer more than once, each answer with its own id. `by=default` is the recommendation standing for an unanswered deadline.

1. Record the ruling per [communication-modes.md § Recording](communication-modes.md#recording).
2. Once you have the ruling, close the ask with `lane-mail resolve --item overseer --id [ASK_ID]`, and send a notice with `--ref [ASK_ID]` naming what stood.

What a reply after the close reaches, on each channel: [communication-modes.md § Owner asks](communication-modes.md#owner-asks).

### `owner-ask-closed`

`EVENT owner-ask-closed [ASK_ID] by=[explicit|text|default]`: the ask's close record. An answered deadline closes with no default answer; the owner's words stand.

### `owner-ask-unmarked`

`EVENT owner-ask-unmarked [ASK_ID] issue=[ITEM] step=[STEP] cause=[KEY]`: a tracker mark of an owner ask did not land on the item. `step` is `ruling` or `item` for the close's ruling comment and item write, `line` for the action line kept while the ask is open, `delivery` for the reply marking an answer delivered. The line prints once per cause. Correct what the key names.

### `peer-note`

`EVENT peer-note [REPOSITORY] [ID] kind=[KIND] [re=[ASK_ID]]`, then the note: a peer repository's overseer wrote to this one. Answer `kind=ask` alone, per [peer-mail.md](peer-mail.md). Record `kind=answer` against the ask its `re=` names. `kind=directive` needs no reply. Record the exchange in the fleet log.

### `idle-unread`

`EVENT idle-unread [TARGET]`: the wake duty found `[TARGET]`, `overseer` or a lane's item, idle with mail it has not read. The duty types one line into an idle session that reads its inbox; the lines in § `wake-delivered`, `wake-unconfirmed`, `wake-limit` report it. The line repeats only once the target's unread state changes.

For the overseer, this session: run `.agents/skills/mailbox/scripts/lane-mail inbox --item overseer` and act on every envelope it prints.

### `wake-delivered`, `wake-unconfirmed`, `wake-limit`

`EVENT wake-delivered [TARGET] [resume=[CAUSE]]`, `EVENT wake-unconfirmed [TARGET] cause=[C] [resume=[CAUSE]]`, `EVENT wake-limit [TARGET] harness=[H] cause=[C] [resume=[CAUSE]]`: the wake duty's outcome for one unread state. `resume=` names the turn end the wake resumed (`usage-limit` or `api-error`); a mail wake carries none.

- `wake-delivered`: the line was typed, and a new user turn in the session's own file or a hosted prompt row with its digest confirmed it. Nothing is owed.
- `wake-unconfirmed`: no matching user turn or hosted prompt digest confirmed the typed line within the bound. `cause=turn-pending` means no later prompt, `cause=turn-unmatched` means other text, and `cause=rows-host-unread` means the provider rows read failed. Hosted marks with these causes are read once per later wake pass without resending; a failed cursor read before the send is final. `cause=session-hosted` is final: the host cannot serve prompt evidence, the harness is Pi, or a prompt row lacks a digest. `cause=outcome-lost` is a send whose watch pass stopped before its answer and whose next pass found no matching local turn or hosted prompt row. Other causes are the delivering verb's word. Nothing is typed again for that unread state.
- `wake-limit`: nothing was typed; `cause` says why the harness has no confirmable route.

On a lane's `wake-unconfirmed` or `wake-limit`, deliver the mail per [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver).

For the overseer, the watch tells the owner through the overseer mailbox's owner channel on its next pass, once per unread state, with the notice file `overseer-wake-unread.txt`. The owner types into this session the line that notice names.

`[TARGET]` `overseer-follow` is the follow wake: the overseer was idle, the watch log held lines past its last follow, and no follow ran. The watch typed it a line to handle each numbered line from its next unhandled line and re-arm its follow. A confirmed follow wake prints no line. On `wake-limit overseer-follow` or `wake-unconfirmed overseer-follow`, the watch tells the owner once with the notice file `overseer-wake-follow.txt`, and the owner types that line into this session.

### `report-due`

`EVENT report-due reason=[minutes|issues] since=[UTC] [landed=[N]]`: the status report is due. The watch prints the line again each `ORCH_REPORT_EVERY_MINUTES` while the same due stands with no report sent; with `ORCH_REPORT_EVERY_MINUTES=0`, once.

1. Run `.agents/skills/orch/scripts/orch-runtime report render --state [OVERSEE_STATE] --repo [REPO]`, one `--repo` per watch `--repo` value; it reads the `ORCH_CONNECTED_REPOS` repositories after them. The rendered body is the report's whole read of the fleet: read a record from its home by item only where a row needs explaining, and print no state file.
2. Write the work's outcomes with the communication skill's [summary template](../../communication/references/reports.md#summary-template) to `[PATH]`.
3. Run `.agents/skills/orch/scripts/orch-runtime report write --state [OVERSEE_STATE] --repo [REPO] --summary-file [PATH]` with the same values.
4. Paste the reply's `result.body` into the chat unchanged: it is the content of the file `result.path` names. `write` sends the summary to the owner as the report's notice, `result.notice_id` its id. Never send the summary as a separate notice.

During `ORCH_REPORT_QUIET_HOURS`, in `ORCH_OWNER_TIME_ZONE`, `write` writes the file and sends no notice; empty quiet hours turn this off. The first due report after the window is the morning brief: its summary covers the work since the last report sent to the owner, overnight merges included. Decisions needed and critical notices go out at any hour.

A refused `write`:

- A notice send that failed: `write` wrote the report file and kept its attempt beside it. Fix the cause, then run the same `write` with the same summary within the same UTC minute, which sends the notice once ([communication-modes.md § Status report](communication-modes.md#status-report)).
- `report-unjudged cause=report-exists`: past that minute, or with another summary. Send the notice by hand: `lane-mail notice --item overseer --to owner --attach [FILE] --file [SUMMARY_PATH]`, `[FILE]` the report's path. A refusal `owner-notice-repeated` means the first send landed, and the id it names is the receipt.
- `report-unjudged cause=summary-stale ask=[ID]`: the summary cites an owner ask that has closed. Summarize again against `lane-mail pending --item overseer --to owner` and run the same `write`.
- Any other refusal names its cause on its first stderr line: fix it and run the report again. Where it stands, tell the owner the report is blocked and why.

### `heartbeat`

`EVENT heartbeat loops=[N] interval=[N]s since=[UTC|none]`, then its body. Take the body's lines in order.

1. The open pull request lines carry repository, number, branch and title, with no arm or queue state. A parked record's pull request the list shows open, with no reducer line on it, stays parked; its dequeue reads as a `disarmed` line under § `pr-watch`, never from this list.
2. For each hosted `running` lane whose pull request the list shows open and whose reducer lines name nothing, run the park verb as [oversee-lanes.md § Parking a merge wait](oversee-lanes.md#parking-a-merge-wait) says, on a fleet whose provider implements the `stop-sandbox` and `start` pair (the shipped `lane-host-ssh` does not). The verb's own read judges queued, armed and clean; its refusal is the answer where the lane is not ready.
3. The `account-roster` lines are the fleet's capacity as the account judge reads it, routed per § `account`. `account-roster unread` means no account was read, never that none has room.
4. Each `owed [ITEM] state=[STATE] priority=[N] lane=[LANE] verdict=[VERDICT]` line is an item the tracker holds as owed work, with no running, preparing or parked record, that `launch_queue` lacks. `priority=-` ranks after every number. A parked item with work left over its merged pull request takes its `parked-merged` line instead.
   - `verdict=queue`: gate it as [oversee.md § 2](../workflows/oversee.md#2-select-work) does. One that passes joins `launch_queue` at its priority's position, relaunched per [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) where `lane=` names a record. Tell the owner of one that fails, with the reason it cannot run, in the chat and in the next report's summary.
   - `verdict=merged [DELIVERY]`: the record carries the cycle of that merge while the tracker still holds the item open. Where the merge finished the item, complete it in the tracker; where the item went back to work after it, queue it as for `queue`.
   - `verdict=dated harness=[H] until=[UTC]`: every account for the record's harness and model is walled. Launch and queue nothing; name the item with its `until=` in the chat when first judged so, and in that summary. Each heartbeat judges it again.
   - `verdict=unjudged harness=[H]`: the host's account listing or the judge failed, named on the watch's stderr as `heartbeat-accounts-unread` or `heartbeat-pick-unread`. The next heartbeat judges it again.
5. Run § Heartbeat backstop for lane proposals, § Heartbeat backlog audit and § Heartbeat design review.
6. Run the triage pass: run [oversee.md § Bounded issue reads](../workflows/oversee.md#bounded-issue-reads), drop the IDs the fleet state's `triaged` already records, and send the rest through § `triage`. Judge only issues a fleet lane filed: each lane item's created-issue records in its workflow state (`audit_issues_created`, `pr_comment_review.issues_created`) and each lane pull request body's Created Issues section; the created-since listing backstops a tracker with no such state. Leave every other issue alone.

### `triage`

`EVENT triage [ID]`: an issue the triage pass owes a verdict. The watch prints it every pass until the fleet state's `triaged` list records one.

1. Run [oversee.md § Bounded issue reads](../workflows/oversee.md#bounded-issue-reads) and set `[ISSUES]` to the identifiers it prints. Take out each Linear mirror [oversee.md § Outside contributions](../workflows/oversee.md#outside-contributions) judges on GitHub, recorded as it says.
2. Cross-check `gh issue list --repo [REPO] --state open` for the first repository. An open GitHub issue whose Linear mirror is Done is residue: close it on GitHub naming the pull request that fixed it. One with no mirror and no `outside-contribution` line means the GitHub-to-Linear sync broke: send the owner one notice naming the issue.
3. Read each issue team's whole live project inventory once, and reuse it for project selection and validation. Stop without writing `triaged` where a project read fails or comes back incomplete.
4. Launch one fresh canonical `maintainer` verifier on the source repository, on the lowest-cost model the surface offers, by the surface's generated-agent call ([SKILL.md § Runtime Notes](../SKILL.md#runtime-notes)). On Codex, run `.agents/skills/agent-runtime/scripts/agent-runtime subagent spawn --harness codex maintainer` for the spawn parameters. On the terminal surface, call it from the overseer session; on the managed-session surface, use that surface's own call; in sequential mode, make the same call and wait for it.
5. Send it the team project inventories and this task: `Verify only these Linear issues: [ISSUES]. For each issue, read its full body and source and apply the filing bar regardless of lane authorship. Follow the Verifier returns contract in .agents/skills/orch/references/skill-rules.md under Coordination for evidence, project and agent selection, and the final return.` That contract ([skill-rules.md § Coordination](skill-rules.md#coordination)) governs the task and its acceptance.
6. Capture only its single final return ([skill-rules.md § Single Return Message](skill-rules.md#single-return-message)). Once it is captured, or on any failure after the launch, retire the verifier through the surface's own shut-down call before any further launch: a finished subagent can keep holding a thread slot ([skill-rules.md § Reviewer persistence is budget-conditional](skill-rules.md#reviewer-persistence-is-budget-conditional)).
7. Validate the return against that contract. On a launch, capture, parse or validation failure, stop without writing `triaged`.
8. For each valid kept item, read its project and labels with `linear.sh issues get [ID]`. Set only what is missing in one `linear.sh issues update [ID]`: `--project` only where the team inventory is nonempty and the item has none; `--labels` only where `LINEAR_AGENT_LABELS` is nonempty and the item has no agent label, merging the chosen agent label with every current label under the linear skill's `--labels` rule. Leave an existing project and agent label alone. With an empty `LINEAR_AGENT_LABELS`, keep every current label. Where the read or update fails, write no `triaged` record for that item.
9. Route each valid kept item or cancel it. Then record its verdict: write `{"issue":"[ID]","verdict":"[kept|canceled]","reason":"[ONE_LINE]"}` to `tmp/triage-verdict-[ID].json` with the harness file-write tool, and run `.agents/skills/orch/scripts/orch-runtime op --fleet --request-json '{"op":"record-overseer-ledger","entry":"triage","file":"tmp/triage-verdict-[ID].json"}'`. A row with other keys or another verdict refuses `triaged-record-invalid`. The watch rebuilds its triage keys from `triaged` ([workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)).

### `outside-contribution`

`EVENT outside-contribution [OWNER/REPO]#[N] kind=[KIND] author=[LOGIN] [head=[SHA]]`: [oversee.md § Outside contributions](../workflows/oversee.md#outside-contributions).

### `pr-watch`

`EVENT pr-watch rc=[N]`, then the reducer's attention lines and its stderr: the GitHub duty's reducer found a new attention key, `rc` the highest status any repository's reducer returned. What each kind means is `.agents/skills/github/scripts/pr-watch.sh --help`; below is what the overseer does about it. A detail ending in `(QUEUED: dequeue before pushing)` outranks its kind: the lane dequeues before it can push anything.

- A `refresh-ready` line takes [copilot-head-notices.md § Consumer refresh approval](copilot-head-notices.md#consumer-refresh-approval) at once, with no owning lane and no quiet period required. That route owns the proof, review and same-head approval.
- Any other line on a pull request no `lanes[]` record or triaged item owns is no wake. An approved, green `kendex/refresh` pull request in a fleet repository is the exception: the refresh workflow arms every class itself, and the overseer arms one a dequeue or a failed arm left unarmed, by the queue route of [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 1.
- A line on a pull request a parked record's `parked.pr` names is a resume, whatever its kind: relaunch through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch), which starts the harness fresh on the kept disk. A `disarmed` line on a parked pull request is also how a dequeue reads, and under `ORCH_MERGE_AUTONOMY=ask` it is still a resume.

Per kind:

- `ci-failed`: for a pull request no lane owns, the refresh pull request among them, read the failed run with `.agents/skills/github/scripts/github.sh ci-logs [PR]` and route the cause through § File one item alone. Approve nothing and re-run nothing until the cause is known. A running lane's pull request is no wake while its merge wait holds it.
- `threads-open`: check the count against the API, then wake the owning lane with it.
- `changes-requested`: wake the owning lane. A standing objection is the lane's to answer, never the overseer's to dismiss.
- `disarmed`:
  - A `running` record whose kind declares `land=handoff` in [lane-host.md § Host kinds](../schemas/lane-host.md#host-kinds), a `claude-cloud` record, never merges and has no mailbox to ask through. Under either `ORCH_MERGE_AUTONOMY` its line launches the item's landing lane: choose the host under [oversee.md § 3](../workflows/oversee.md#3-launch) Placement, then run [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) with `/orch merge-pr [PR_NUMBER]` in its `brief_file` and `host` naming that host. That lane merges by `merge-pr.md` § 5 and completes the item; under `ask` it asks its merge question through lane mail, and § Held merges applies.
  - A `land=lane` record under `auto`: a pull request whose `running` lane owns it is no wake; the lane owns its merge by its own direct attempt in `merge-pr.md` § 5 step 1. For a record no lane runs, relaunch the lane into that step through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch).
  - A `land=lane` record under `ask`: no wake. The lane holds the pull request for § Held merges.
- `awaiting-stale`: no approval reached the head within the quiet period: Copilot is down, out of credit, or gave no verdict. Apply [copilot-head-notices.md § Fallback approval](copilot-head-notices.md#fallback-approval).
- `head-moved`: the reduction describes the earlier head. Do nothing; the next pass reads the new head.
- `error`: each line's detail carries its remedy: follow it. A pull request nothing evaluated is never healthy.

The merge route stays the lane's; the overseer never adopts it as its own step.

### `refresh-failing`

`EVENT refresh-failing [OWNER/REPO] runs=2 last=[RUN] since=[UTC] report=[initial|repeat] cause=[CAUSE]`: a consumer refresh workflow failed twice in a row. On `report=initial`, send the owner one notice naming the repository, the failed-run count and the cause, even when the cause matches an earlier incident. On `report=repeat`, notify only where the cause changed. A consumer fleet's overseer applies this to its own repository too.

### `main-push-failing`

`EVENT main-push-failing [OWNER/REPO] workflow=[FILE] event=[push|schedule] run=[RUN] [head=[SHA] since=[SHA|none]] jobs=[JOBS] cause=[CAUSE]`: a push run or a scheduled run on the default branch is red. On a push run, `head=` is its head and `since=` the head of the last green push run before it, `none` where the watch knows of none: the merges between the two are the ones that can have turned it red.

1. Link an open item that covers the failed jobs and suite, or file one item at Urgent priority in the repository's tracker through § File one item alone. Name the run link (`https://github.com/[OWNER/REPO]/actions/runs/[RUN]`), the failed jobs, the cause and the merges between `since=` and `head=`.
2. Send the owner a notice with that item and the run link.

### `main-push-budget`

`EVENT main-push-budget [OWNER/REPO] workflow=skill-tests.yml run=[RUN] warnings=[JSON]`: a completed Skill Tests run carries budget warnings. The line prints once per run. Link an open maintenance item that covers the named suites or jobs, or file one through § File one item alone, naming the run link and each distinct warning.

### `main-workflow-absent`

`EVENT main-workflow-absent [OWNER/REPO] workflow=[FILE] cause=[branch|unwatched]`: a workflow `ORCH_MAIN_WORKFLOWS` names is read by nothing, so its red runs reach no one.

1. With `cause=branch`, read the repository's `.github/workflows/` for the renamed or removed file. With `cause=unwatched`, check the entry's `OWNER/REPO` against the watch's `--repo` values and `ORCH_CONNECTED_REPOS`.
2. Where the repository has its own overseer, ask it which workflow holds its nightly run: `lane-mail peer ask --repo [OWNER/REPO] --file [PATH]` ([peer-mail.md](peer-mail.md)).
3. Correct the entry, or the connected list, in the overseer repository's settings in a reviewed change. Restart the watch after it merges.

### `security-alert`, `security-alerts-unread`, and a `heartbeat` line on a Dependabot pull request

[security-alerts.md](security-alerts.md).

### `verifying-deadline`

`EVENT verifying-deadline [ITEM] [ROW]`: a due or overdue box of a Verifying item changed its key, `[ROW]` its `box=[N] trigger=[JSON] status=[due|overdue] deadline=[UTC|null] [read=[KIND]]`. `[ROW]` `boxes=0` is the first read of the item with no open box. Run [verify.md](../workflows/verify.md) with the item and its box lines, and apply § Verification to that box even where reconciliation omits it.

### `verifying-invalid`

`EVENT verifying-invalid [ITEM]`: the item's checklist cannot be judged: a branch-provable box still open on a Verifying item, or post-merge metadata the parser refuses. The watch's stderr carries the parser's rule and the box under `verifying-invalid issue=[ITEM]` every pass; the event prints once while the item stays invalid. Correct the checklist in the tracker; the next pass judges it again.

### Verification

Each `verifying [ITEM] box=[N] trigger=[JSON] status=[STATUS] deadline=[UTC|-] [merged=[UTC]] blocked_by=[IDS|-] reading=[JSON] where=[JSON] why=[JSON] [read=[KIND] ...]` line names an open post-merge box on a merged item, or an unproved box beside a container's "Every child Done or cancelled" box. A container's line has `trigger="outcome"`, `deadline=-` and no merge time.

`status` is `blocked` where an open blocker stands, else `overdue` at or past the deadline, else `waiting` for an unfired trigger, else `due`. A due or overdue box ends with `read=[KIND]`: `met` or `failed` with `observed=[FIGURE]`, `missing`, or `inconclusive` or `unread` with `cause=[WORD]`. A new reading is a new key, so it prints once.

`verifying-deadline` prints a box only when its due or overdue key changes; the heartbeat prints every box. `orch-runtime reconcile-items` returns the same lines in `result.lines`, their counts in `result.counts`, and each item with an overdue box as a `verifying-overdue` finding in `result.findings`.

The watch completes a box that reads `met` itself, with its Evidence line, and comments once on a box that reads `failed` or `inconclusive`. For each due or overdue box the watch leaves open, run [verify.md](../workflows/verify.md). Acceptance follows [SKILL.md § The Cycle](../SKILL.md#the-cycle). A failed check takes that section's route; evidence still unreadable at its deadline takes [verify.md § 2](../workflows/verify.md#2-resolve-missing-evidence); the reader and the message for a person's reading are [communication-modes.md § Owner-only verification](communication-modes.md#owner-only-verification).

For each proved box:

1. Post an evidence comment on the item.
2. Write one `N: text` line per proved box to `[EVIDENCE_FILE]` under the checkout's `tmp/`, the text citing the evidence comment. Include an already-ticked box whose Evidence line is missing, citing the comment already posted for it.
3. A merged item: read `[MERGED_AT]` from the item's linked merged pull request with `env -u GH_REPO -u GITHUB_REPOSITORY gh pr view [MERGED_PR_URL] --json mergedAt --jq .mergedAt`; an absent or unreadable time is a completion failure. Then run `.agents/skills/linear/scripts/linear.sh issues complete [ITEM] --post-merge-at [MERGED_AT] --done-when-met [N] --evidence-file [EVIDENCE_FILE]`. It keeps Verifying while another box stays open and sets Done after the last. A merged item's `verifying [ITEM] boxes=0` line completes the same way, with the same pull request's time. Leave both evidence flags out only where every checked box already carries its Evidence line.
4. A container is due once every child is Done or Canceled. Its `boxes=0` line runs `env -u GH_REPO -u GITHUB_REPOSITORY [MAIN_REPO_ROOT]/.agents/skills/orch/scripts/orch-runtime container-close [MAIN_REPO_ROOT] [ITEM]`, which ticks the parent's child box with each child's state as Evidence and completes the parent, Canceled where every child was canceled. A container uses no `--post-merge-at`. Its answer is one line: `closed [ITEM]`; `deferred [CHILD_IDS...]`, open until those children complete, or a bare `deferred` where the lock wait expired; `held [ITEM] [RESET]`, a quota hold per the linear skill's `patterns/workflow-actions.md` § Quota Holds. A refusal is its `container-close: [KEY] ...` line on stderr at exit 1, or exit 2 for a malformed parent id: keep the stderr, and run the same close again once the named cause is resolved.
5. A container `box=[N] trigger="outcome"` line names an outcome the parent still holds: move it into its own child item, a leaf blocked by the siblings it measures, whose holder completes it with `linear.sh issues complete [CHILD] --summary-file [SUMMARY_FILE] --done-when-met [N] --evidence-file [EVIDENCE_FILE]`, and remove the box from the parent. The open child keeps the parent open.
6. After either route sets the item Done, close its parent through [merge-pr.md § 5](../workflows/merge-pr.md#5-execute-the-merge) step 2, repeating for container ancestors. Record the closures and diagnostics in the evidence comment.
