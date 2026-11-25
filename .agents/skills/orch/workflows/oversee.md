# Oversee

Run a fleet: select unblocked items, launch one lane per item, and move each pull request to merge.

- The overseer owns launch, the watch and unblocking.
- Lanes merge their own pull requests.
- The overseer reviews only the Copilot thread reads and head approvals in [copilot-head-notices.md](../references/copilot-head-notices.md).
- It makes only the changes [lane-launch.md § Item Tier](../references/lane-launch.md#item-tier) leaves to this session.
- Read [Presentation](../references/communication-modes.md#presentation) before writing to the owner.
- Run unattended: resolve a blocked lane before the user notices it.

## 1. Resolve The Launch Surface

- Launch only this repository's items.
- File foreign work in its own tracker, then follow [peer-mail.md § Addressing](../references/peer-mail.md#addressing).

Once per session, take the first surface that applies:

1. `$TMUX` is set: tmux lanes. Launch each item with a `launch-lane` request under [lane-launch.md § Lane directive](../references/lane-launch.md#lane-directive).
2. The harness launches its own sessions or threads, such as Codex threads, Claude Code agent teams, or a desktop app's session tool or bundled skill: one managed session per item, carrying the brief [lane-launch.md § Lane directive](../references/lane-launch.md#lane-directive) builds.
3. Neither: no parallel surface.
   - Say so once.
   - Work the queue in this session, one item at a time, with the brief [lane-launch.md § Item Tier](../references/lane-launch.md#item-tier) assigns: `start [ISSUE_ID]`, `small [ISSUE_ID]`, or [micro.md](micro.md) for a `micro` item.
   - Select under § 2 between items.
   - A hosted fleet runs no tracker item in this session ([SKILL.md](../SKILL.md) § The Cycle, Item work stays in lanes).

Only a tmux lane is confined. Item work in a harness's managed session, or in the overseer's own session, runs with the operator's reach.

On every surface the watch reports a lane's questions as `lane-question` and new tracker items as `triage`. Off the tmux surface, read session banners through the harness's session tooling.

### Controller start and adoption

- Run these steps from the overseer's checkout, one command per tool call, against one fleet state.
- `[DIR]` is the absolute checkout directory.
- `[OVERSEE_STATE]` is the path `state path` prints; `[OVERSEE_STATE_DIR]` is its directory.
- A controller opens in the first tmux session of: the request's `session`, `AGENT_RUNTIME_TMUX_SESSION`, the opener's own session, the session the fleet's lanes open in.
- Where a tmux server answers on the fleet's socket, it must hold that session. Where none answers on the controller record's `server_socket`, the start starts one holding it, as [lane-directive.md § Tmux session](../references/lane-directive.md#tmux-session) states.

1. Resolve the fleet state. Initialize it where `.result.exists` is false.

   ```bash
   .agents/skills/orch/scripts/orch-runtime state exists --fleet
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime state init --fleet
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime state path --fleet
   ```

2. A session opened by hand registers itself from its own pane, so the hooks and the watch know it is the overseer.
   - The register reads the session's launch identity from the SessionStart row its harness wrote, else from its pane.
   - It then reads the account, model, effort and permission words of the running harness process, and records the controller.
   - It creates an absent fleet state first.
   - Add `--account [DIR]` where neither the rows nor the environment name the account, as for a Copilot controller whose pane hides it.
   - Before relying on the session's marks, read the reply's `notices`: the hook and context-reader coverage.

   ```bash
   .agents/skills/orch/scripts/orch-runtime register --fleet
   ```

3. Adopt a controller in another pane to record it.
   - Name the pane and its harness.
   - Add `--socket`, `--session-id`, `--home`, `--model`, `--effort`, `--cwd` or `--account` where known.
   - The runtime reads the process identity from the pane.
   - `--request [REQUEST_FILE]` replaces the flags with a file written with the harness file tool; that file can also carry `permission`, `extra_args` and `session_rows`.

   ```bash
   .agents/skills/agent-runtime/scripts/agent-runtime controller adopt --record [OVERSEE_STATE] --pane [PANE] --harness [HARNESS] --cwd [DIR]
   ```

4. For the fleet's first controller, save the walk's choice.
   - Read `.result.walk.answer` first. If it is not `lane`, stop and report the reply; no session opens.
   - `.result.successor` is the controller to open, with its typed launch fields and its `handoff`.
   - `--handoff [HANDOFF_PATH]` names another handoff.
   - The controller's harness passes the same launch gate as a lane: [lane-directive.md § Harness gate](../references/lane-directive.md#harness-gate) holds each refusal's repair.

   ```bash
   .agents/skills/orch/scripts/orch-runtime successor --fleet --cwd [DIR] > [CHOICE_FILE]
   ```

5. Synchronize the checkout.
   - `sync-base` bounds no fetch: run it under the shell tool's timeout.
   - Stop on a failure or a stall.

   ```bash
   .agents/skills/orch/scripts/sync-base [DIR]
   ```

6. Compose and submit the start.
   - `[WORDS_JSON]` is a JSON array.
   - Under the successor's `permission` `native`, it holds the caller's own permission words in the harness's spelling, such as `["--permission-mode","dontAsk"]` for Claude.
   - Under `bypass` it is `[]`, and the runtime adds the harness's bypass word.
   - Native words include no full-bypass word.
   - `[WATCH_WORDS_FILE]` holds a JSON array of the watch's words: the absolute path of `.agents/skills/orch/scripts/orch-runtime`, `watch`, `run`, `--file`, `[OVERSEE_STATE]`, `--interval`, `240`, `--since`, `[FLEET_SINCE]`, `--repo`, `[ITEMS_REPO]`, and one `--repo` pair per other watched repository, resolved under § 4.
   - The runtime adds the mailbox and server reach.
   - On a first start it empties the log an earlier fleet left.
   - A request naming no `brief_file` opens on the takeover brief, which the runtime writes under `[OVERSEE_STATE_DIR]/intents/`.

   ```bash
   jq -n --slurpfile choice [CHOICE_FILE] --argjson words '[WORDS_JSON]' --slurpfile watch [WATCH_WORDS_FILE] '{op:"start-controller",controller:($choice[0].result.successor + {extra_args:$words}),watch:$watch[0]}' > [REQUEST_FILE]
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --fleet --effect-exit --request [REQUEST_FILE]
   ```

7. Read the outcome.
   - Exit 0 is confirmed, 3 failed, 75 unconfirmed with the intent left open.
   - `.result.effect.report.intent` carries the outcome, note and cause.
   - A watch that refuses or never claims leaves the start unconfirmed.
   - Read an open intent with `orch-runtime state inspect --fleet`; its reconcile owns completion.
   - Never submit a second launch to resolve an unknown outcome.

8. A start over a recorded controller refuses while that controller may still run. On `predecessor-unproven`, adopt the session from its pane instead (step 3).

9. To resume a recorded native session after its pane ends, as after a restart, run the state check (step 1) and `sync-base` (step 5) first, then the resume from the checkout:

   ```bash
   .agents/skills/orch/scripts/orch-runtime resume-controller --fleet
   ```

   - It starts the record's own launch with `resume` set to its `session_id`, on the record's `server_socket`, with the watch flags `oversee-watch.flags` records.
   - A gone server is started again as [lane-directive.md § Tmux session](../references/lane-directive.md#tmux-session) states.
   - It prints one line: `controller-resumed ...` at exit 0, `controller-resume-failed ... note=[NOTE] cause=[CAUSE]` at exit 3, `controller-resume-unconfirmed intent=[ID]` at exit 75.
   - On `controller-resume-failed`, where the start was refused, `note` is the refusal's key and `cause` its own cause. Otherwise `note` names the failure, and `cause` is its cause, or `-` where it carries none.
   - A record with no native id refuses `session-unrecorded field=session_id`. A fleet whose watch recorded no flags refuses `watch-flags-unrecorded`.
   - A resume keeps the recorded account.

**Refusals.**

- Read the first stderr line beginning `orch-runtime: ` as `orch-runtime: <key> field=value...`; a settings notice can precede it.
- Exit 1 with `ok: false` is a refusal.
- A line naming `persisted_intent=` means the runtime recorded an intent and the effect may have acted: inspect that intent.
- An unanswered call also leaves the outcome unknown.
- At exit 69 the runtime is unbuilt. With no cargo the wrapper prints `orch-runtime: setup-required ... run=...`: run the named `scripts/setup`, then retry. With cargo its own build failed, and the setup's refusal is the last stderr line.
- A call whose stderr opens `orch-runtime: setup-building key=...` or `agent-runtime: setup-building key=...` built its program first. If it ended on a caller's time bound, the build is the cause: retry once the build ends.

### Mailbox and handoff

- Read the mailbox and handoff through [overseer takeover § 1](oversee-takeover.md#1-read-the-mailbox-and-handoff).
- At succession, takeover and after compaction, take that route instead of the launch and stop steps.
- A new fleet continues with § 2 after those reads.

## 2. Select Work

1. Select unblocked, non-terminal development items from the tracker, read live through every page.
   - For a Linear tracker, run each line below in its own tool call. The first writes the whole read to ignored scratch storage, the second prints one row per item with no description, and the last removes the read.
   - If the read exits nonzero, stop the selection with its error and leave `launch_queue` as it is.
   - `[STATES]` names the team's open states but Triage and Verifying, comma-separated, as `linear.sh statuses list --team "[TEAM]"` lists them. The verification pass owns a Verifying item's post-merge readings.
   - Keep only an item that can start, in any state. Each of these holds it out:
     - a blocker its `blocked_by_launch` names, the field the [Ancestor gate](../references/skill-rules.md#ancestor-gate) reads;
     - the `blocked` label when `blocked_by_launch` is empty, even if the item has completed blocking relations;
     - being a container, as [skill-rules.md § Containers](../references/skill-rules.md#containers) defines one, judged from the item's children of any state as [start.md § 3](start.md#3-resolve-work-item) reads them;
     - an open ancestor whose `blocked_by_launch` names a blocker;
     - an open in-PR bundle root ancestor, whose own lane works its children;
     - a last lane record that is running, preparing or parked.
   - A GitHub item labeled `blocked` is no candidate.

   ```bash
   .agents/skills/linear/scripts/linear.sh issues list --team "[TEAM]" --state "[STATES]" --select owed --max > tmp/oversee-select-source.json
   jq -r '.[] | [.id, .state, (.priority // 0), .in_pr_bundle, .parent_id, (.blocked_by_launch | join(",")), (.labels | join(","))] | @tsv' tmp/oversee-select-source.json
   rm -f tmp/oversee-select-source.json
   ```

2. Where code shows a dependency that holds an item, first record its blocking relation under the linear skill's `references/writes.md` § Blocked Label vs Issue Relations.
   - The launch's admission applies the [Ancestor gate](../references/skill-rules.md#ancestor-gate) to a `linear` item, reading the item and every container ancestor.
   - [lane-directive.md § Launch gate](../references/lane-directive.md#launch-gate) holds its refusals; a relaunch is judged as [§ Recovery relaunch](../references/lane-directive.md#recovery-relaunch) states.
3. Keep the order in the fleet state's `launch_queue`.
   - The tracker sets its membership, never the handoff.
   - Every heartbeat names each owed tracker item the queue lacks as an `owed` line ([oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds), `heartbeat`).
4. Launch only where the cap has room.
   - One oversee session runs per repository.
   - The launch enforces both caps ([lane-directive.md § Caps](../references/lane-directive.md#caps)).
   - On the other surfaces, keep the same limits yourself:

   ```bash
   .agents/skills/orch/scripts/orch-env ORCH_OVERSEER_LANES 4
   .agents/skills/orch/scripts/orch-env ORCH_OVERSEER_CLOUD_LANES 10
   ```

5. An item whose `worktree create` exits 75 belongs to another session: skip it, and launch its siblings.
   - On the tmux surface the overseer's own `worktree create` in [lane-launch.md § Lane directive](../references/lane-launch.md#lane-directive) step 4 makes that claim; a cloud lane's launch makes its own.
   - A surface that creates its own worktree environment, such as Codex app threads, records the claim in the fleet state before launch.

## 3. Launch

Foreign work follows [§ 1](#1-resolve-the-launch-surface).

Before the first launch, set the fleet's merge autonomy.

`ORCH_MERGE_AUTONOMY=ask` ([settings.md § Talking to you](../references/settings.md#talking-to-you)) makes each merge need the user's authorization. It authorizes merges, not validation.

- On the tmux surface, set it in the overseer's tmux session before the first launch, so every lane window inherits it.
- On surface 2, pass it in the launcher's environment.
- The lane's merge question then reaches the overseer as `lane-question` ([oversee-events.md § Held merges](../references/oversee-events.md#held-merges)).

```bash
tmux set-environment ORCH_MERGE_AUTONOMY ask
```

Launch each item through [lane-launch.md](../references/lane-launch.md), in this order:

1. Assign its tier under [§ Item Tier](../references/lane-launch.md#item-tier).
2. Launch it under [§ Lane directive](../references/lane-launch.md#lane-directive). A first launch judges the files the item touches under [§ Shared files](../references/lane-launch.md#shared-files).
   - Carry the answer to question 3 under the project-management skill's `references/filing.md` § Judge the approach in the launch ruling. If the item lacks that line or carries a different answer, post the current answer on the item before launch.
3. Record it under [§ Lane record](../references/lane-launch.md#lane-record).

### Recovery relaunch

Relaunch a dead or walled lane through the runtime, as [lane-directive.md § Recovery relaunch](../references/lane-directive.md#recovery-relaunch) states.

## 4. Watch And Advance

The watch is the runtime's standing scheduler over the fleet state. [watch-delivery.md § The watch](../references/watch-delivery.md#the-watch) states how a start opens it and that a succession keeps it. A hand-opened controller starts it under [takeover § 2](oversee-takeover.md#watch-reader).

1. Pass `--file [OVERSEE_STATE]`, the file [Fleet state address](oversee-takeover.md#fleet-state-address) resolves.
   - The watch's `--since` is the earliest `lanes[].launched_at`, else the launch's own time.
   - A succession keeps that floor.
2. Pass the item repository first as `--repo`, then one `--repo` per other watched repository. The first repository and `ORCH_CONNECTED_REPOS` feed pr-watch. The other `--repo` values feed only the merged, heartbeat, report and repository checks.
3. A registered session with no live claim starts the watch from its own pane, with its shell's `TMUX_PANE`, so the claim names that pane. `watch start` launches `watch run` detached through the job launcher, with its runner record and stderr beside the fleet state.

   ```bash
   .agents/skills/orch/scripts/orch-runtime watch start --file [OVERSEE_STATE] --interval 240 --since [FLEET_SINCE] --repo [ITEMS_REPO] --repo [OTHER_REPO]
   ```

4. Read its events as § Watch delivery states.
   - Each duty appends its findings to `oversee-watch.log` beside the fleet state, as `EVENT` lines with payload lines in the shapes [oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds) states.
   - Handle every line.

**Cadence.**

- The watch runs its duties on the intervals `orch-runtime watch run --help` and [settings.md § Fleet watch](../references/settings.md#fleet-watch) name, until `orch-runtime watch stop --fleet`.
- Before every pass it reads every `lanes[]` record whose status is `running`, so a launch, relaunch or close while the watch runs needs no restart.
- A failure of the runner's own records, or a duty's `unready duty= program= cause= fix=` refusal, ends the run with its cause on stderr: fix it and start the watch again.

**GitHub and the tracker.**

- Never write a monitor of your own.
- Without the github skill's watcher, the GitHub duty fails each long pass and prints none of its lines ([gates.md § Multi-PR watching](../references/gates.md#multi-pr-watching)).
- Verifying boxes and deadlines print even for queued or active lane records, and never become `owed` development work.

**The watch rule.**

- Never end a turn while the watch is stopped.
- Only the watch closes an owner ask at its deadline, where the ask's form allows, and reports it as `owner-ask-closed`.
- While the watch is down, no model recovery starts, no cleared session is bound and no reset is applied.
- Start it again before anything else.

**Confined lanes.**

- A confined lane leaves three acts to the overseer: `container-close`, `state remove` and the worktree skill's `remove`. Each prints `<act>: left cause=confined owner=overseer` in the lane.
- Its parent container closes when the overseer handles the watch's container line ([oversee-events.md § Verification](../references/oversee-events.md#verification)).
- Its `state remove` first stamps the item's record, and the overseer's close of the merged lane reads that stamp as the close-out's end ([lane-reach.md § How a running lane is judged](../references/lane-reach.md#how-a-running-lane-is-judged)).
- Its worktree leaves at that close. Its item files leave at a close that finds the item ended.

**Closing a lane.**

- The `close-lane` request is the by-hand terminal close-out.
- The watch closes a parked or stopped record whose item is terminal through the same request ([oversee-events.md § `merged`](../references/oversee-events.md#merged)).
- [lane-reach.md § Lane close](../references/lane-reach.md#lane-close) holds how a close ends a lane, what each refusal asks, and each surface's close.
- Write the request with the harness file tool, then run it:

```json
{"op":"close-lane","item":"[ITEM_KEY]"}
```

```bash
.agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] op --fleet --request [REQUEST_FILE]
```

Read the reply's `.result.word`, or a refusal's `refusal.key` at exit 1, as [lane-reach.md § Lane close](../references/lane-reach.md#lane-close) says.

### Watch delivery

Launch, follow and re-arm the watch's reader as [watch-delivery.md](../references/watch-delivery.md) states, in single passes on a harness that wakes only at a background command's exit.

### Judgement at every event

- Before reading a lane's pane, state, status file or transcript, or the watch log, for an event, read [oversee-reads.md § Bounded lane reads](../references/oversee-reads.md#bounded-lane-reads).
- Write owner summaries with communication's [reports and template](../../communication/references/reports.md).
- For an owner note marked as a voice request, apply orch's [voice requests](../references/communication-modes.md#voice-requests) before acting and communication's [voice wording](../../communication/references/voice.md) before replying.
- Judgement rules for every event: [oversee-events.md § Judgement rules](../references/oversee-events.md#judgement-rules).
- Handling per event kind: [oversee-events.md § Event kinds](../references/oversee-events.md#event-kinds).
- A direct push: the lane's close records its merge cycle from the `close-lane` request's `delivery`, `{"commit":{"commit":"[SHA]"}}`. Name the pushed commit there per [oversee-events.md § Direct-push cycle records](../references/oversee-events.md#direct-push-cycle-records).
- A lane that asks for a path outside its admitted set: [lane-launch.md § Shared files](../references/lane-launch.md#shared-files).

### Parking a merge wait

A hosted lane armed or queued for merge is parked: [oversee-lanes.md § Parking a merge wait](../references/oversee-lanes.md#parking-a-merge-wait).

### Talking to a lane

Answering, directing, typing into and resuming a lane: [oversee-lanes.md § Talking to a lane](../references/oversee-lanes.md#talking-to-a-lane).

## 5. Stop

Stop when the queue is empty or the user stops the fleet. An empty queue under a standing `idle` ruling from the [§ Opening question](../references/communication-modes.md#opening-question) is no stop: the watch keeps running, and the owner's later note arrives through it.

1. Run [verify.md](verify.md) once, keeping the watch's box lines.
   - A stop with due boxes open needs `ORCH_VERIFY_SCHEDULE` to name a scheduled reader that survives the stop and depends on neither this overseer nor its watch.
   - Name that schedule and its remaining boxes in the stop report and in the handoff.
   - Where the setting is unset, or the reader is not confirmed to survive, list each open box under Waiting on you as `verification unscheduled`, never as handed off.
2. Stop the watch, then end the follow, as [watch-delivery.md](../references/watch-delivery.md) states, so no pass reports this overseer dead and no successor resumes a stopped fleet. On a hosted fleet, stop only when `orch-runtime host list` lists no row but `available`, or name each such host.
3. Print the merge cycles.

   ```bash
   .agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] cycle rollup
   ```

4. Report from the body `orch-runtime report render --state [OVERSEE_STATE] --repo [ITEMS_REPO]` prints, with one `--repo` per watched repository, in the sections [communication-modes.md § Status report](../references/communication-modes.md#status-report) orders.
   - The rendered body is the report's read of the fleet; no report prints a state file.
   - Also write each status report given in chat that `report write` did not save, this one included, to the `result.path` of `orch-runtime state progress-report-path`.
5. Reapply the [takeover path check](oversee-takeover.md#1-read-the-mailbox-and-handoff).
   - Rewrite the handoff's State and Workarounds sections under [communication-modes.md § Handoff](../references/communication-modes.md#handoff).
   - Before the rewrite, lift each `standing[]` row whose end has come ([communication-modes.md § Recording](../references/communication-modes.md#recording)).
   - The handoff carries no tmux command.
6. Prepare the complete headerless body in an ignored scratch file under [communication-modes.md § Handoff](../references/communication-modes.md#handoff), then write the snapshot. On a failed write, stop and report its cause; that section names what waits for a successful one.

   ```bash
   .agents/skills/orch/scripts/orch-runtime handoff --fleet --body [BODY] --handoff [HANDOFF_PATH]
   ```

The watch's retention duty runs the retention [workflow-state.md § Recording policy](../schemas/workflow-state.md#recording-policy) states, the overseer mailbox's compaction and the scratch of `tmp/` included. Prune or compact nothing by hand.

### Succession

At an overseer trigger under [oversee-events.md § The overseer's own marks](../references/oversee-events.md#the-overseers-own-marks), take these steps:

1. Wait for a safe point: finish any `merged` event, answer each lane waiting on a root answer, and collect every attached child's return.
   - Wait for each inside the current turn.
   - Claude Code uses its task list, or the measured id and status fallback, and its wait or result tools.
   - Codex, Pi and Copilot track the children they launched; Pi waits through `get_subagent_result`.
   - Where the handoff cannot wait, name every unfinished child and its known output path in the handoff's State, or say that its state and path are unknown.
2. Write the progress report under the [report-due event](../references/oversee-events.md#report-due), whatever `ORCH_REPORT` says: `orch-runtime report write --state [OVERSEE_STATE] --repo [ITEMS_REPO] --summary-file [SUMMARY_FILE] --succession`.
   - Do not repeat a refused write during this handover.
     - Tell the user the handover has no report, give the cause from its first stderr line, put that line in the handoff, and go on.
3. Complete § 5 steps 5 and 6, including the snapshot write.
4. Save the successor's choice.
   - Name this controller's pane, and add `--mark [KIND]` (`context`, `headroom`, `rate` or `memory`) at a reported mark.
   - Read `.result.walk.answer` as § Controller start and adoption step 4 says.

   ```bash
   .agents/skills/orch/scripts/orch-runtime successor --fleet --cwd [DIR] --predecessor [PANE] > [CHOICE_FILE]
   ```

5. Run `sync-base`.
   - Compose the transfer from the reply's compare set and successor, and submit it.
   - A successor that keeps the predecessor's harness keeps the recorded permission words, so the transfer adds none.

   ```bash
   jq -n --slurpfile choice [CHOICE_FILE] '{op:"request-transfer",cause:"live",expected:$choice[0].result.expected,successor:$choice[0].result.successor}' > [REQUEST_FILE]
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --fleet --effect-exit --request [REQUEST_FILE]
   ```

6. Read the outcome.
   - Exit 0 is confirmed, or a recorded runner waiting for the predecessor to exit; an open `.result.settled` is not publication.
   - Exit 3 is a closed failure, its note in `.result.settled.observation.note`.
   - Exit 75 leaves the intent open: read it before anything else.
   - The predecessor retires only once the successor reads ready.
   - A readiness refusal stops the successor, leaves the predecessor in control and tells the owner once.
   - These notes hold their account out of the walk for 30 minutes, until a confirmed hand-over, or until `register --fleet` on that account: `successor-not-ready`, `successor-not-up`, `successor-unobservable`, `successor-exited`, `successor-wrong-account`, `brief-unconfirmed` and `launch-gate-refused`. Any other note holds nothing.
   - A `successor-not-signed-in` holds its account the same way only when its cause is `auth-wall`: the successor's first turn met a login wall. A refusal before any window opened holds nothing, since the walk already passes over an account holding no sign-in.
   - A `successor-not-signed-in`: sign in the account it names, or exclude it, then request the transfer again.
   - A `successor-asking`: its `step` names the first-run question on the successor's screen, `folder-trust` or `bypass-consent`. Answer that step in the account's config dir before requesting the transfer again; each request before then opens the same question. A dialog no step names fails `successor-not-ready` with the screen it read.
   - The successor follows the watch under [takeover § 2](oversee-takeover.md#watch-reader) and starts no second watch.
7. Handle a refusal by its key:
   - `succession-off`, under `AGENT_RUNTIME_CONTROLLER_SUCCESSION=off`: tell the user, under [communication-modes.md § Status report](../references/communication-modes.md#status-report), that the handoff is written and a fresh overseer session must start. At an account trigger, keep running ([oversee-events.md § Hand off a lane before it runs out](../references/oversee-events.md#hand-off-a-lane-before-it-runs-out)). At the context mark, record the handoff as the next item says.
   - A walk that answers `none`, or another refused succession: tell the user the snapshot is installed and a fresh overseer must start.
     - Record the handoff with the command the context turn-end refusal prints: a `record-overseer-ledger` `handoff` entry keeping its `handoff_file`, `session_id` and `pane_key`.
     - That record ends the context turn-end refusal for this session.
     - Read an unresolved intent before retrying.
