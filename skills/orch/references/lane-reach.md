# Lane reach

Read from [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane) when a lane's state decides how to reach it, the wake does not reach it, or it shows a harness dialog, and from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) when a lane closes. § Per harness says who sends a dialog's keys.

## Lane states

`.agents/skills/orch/scripts/orch-runtime lane status --item [ITEM]` reads the item's one in-flight lane record and prints its state as `result.state`, with `result.cause` where the state carries one. It refuses `lane-missing` where no record is in flight, `lane-ambiguous` where two are, and `fleet-missing` with no fleet state.

Beside the state, the reply carries `item`, `window`, `pane_key` and `identity`, and the `lane-long` line's five counts, each a string holding a number or `unread`: `review_rounds`, `fix_receipts`, `validation_runs`, `restacks` and `repeated_class_rounds`. `counts_cause` names a count read that failed. `stage` and `stage_start` name the stage the item state holds open in the lane's current session, `none` where it holds none and `unread` where it cannot be read; `post_pr_stop` is the session's post-PR stop. The counts and the stage come from the item's workflow state and the worktree's validation run index, never from the lane status file: on this disk for a local lane, through the provider's `cat` for a hosted lane whose host declares `files=verb`, and `unread` for a `files=none` kind, a cloud session, or a host whose capability line cannot be read.

The read asks the host first. Where the lane's host kind declares `status=verb`, the provider's status decides: `exited` is the lane exited, a failed read leaves it `unjudged` with the cause, and `running` proves the harness up. A host kind with no status verb leaves a hosted lane `unjudged` with `status-none`. On a `pane=verb` host the provider's capture is the screen. Otherwise the read takes the recorded pane, the pane's foreground process and its screen. A Pi lane is judged by the session rows its turn end writes in its mailbox; a Pi lane with no rows, or rows that cannot be read, is `unjudged`, never idle off its screen.

| State | What the read found | How the lane is reached |
|---|---|---|
| `idle` | The harness is at its prompt. | The wake types the mail line; a directive reaches the lane at once. |
| `working` | A turn is in flight. | Send mail; the lane reads it at its next tool call or turn end. Mail that cannot wait takes § Mail the wake cannot deliver. |
| `asking` | A dialog waits on an answer. | Answer it by the lane's harness in § Per harness. |
| `rate-limit-switch` | The rate-limit model-switch dialog. | Apply [oversee-events.md § lane-asking](oversee-events.md#lane-asking). |
| `walled` | A usage or authentication wall, on the screen or in a Pi row. | Follow the wall's cause under [oversee-events.md § usage-limit](oversee-events.md#usage-limit). |
| `exited` | The provider read the harness exited, or only shells run under the pane. | It reads no mail. Relaunch it under [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). |
| `gone` | The recorded pane is absent. | Relaunch it under [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). |
| `unreadable` | A pane, process or capture read failed. | Resolve `result.cause` first. An unreadable read proves no exit. |
| `unjudged` | The read settles nothing: an unrecorded pane or harness, missing or unreadable Pi rows, another foreground process, a screen with no marker, an unreadable host capability line, a failed provider status read, or `status-none`. | Resolve `result.cause`, read beside the recorded identity, before deciding to relaunch. |

The watch's wake duty types a positively idle lane one line and confirms it by a new user turn in that session's own file. It reaches a running lane whose window is on this machine, and a hosted lane on a `launch=ssh` host whose line reads `pane=local` with `status=verb` (typed through its window) or `pane=verb` (sent through the provider's `send`). A hosted paste is reported `wake-unconfirmed cause=session-hosted`, and the lane's own mailbox read confirms it. A record that is not `running` is never woken: it is relaunched. A lane the wake cannot confirm is reported `wake-limit` with its harness and cause.

## Mail the wake cannot deliver

Every running lane the wake does not reach takes this route, whatever its harness: a `working` or `unjudged` lane, a lane the duty reports `wake-limit`, and a lane on a host the wake does not reach. The mail waits by default. The lane reads it at the next point the Lane mail rule names ([skill-rules.md § Lane mail](skill-rules.md#lane-mail)), a waiter's return among them; a lane idle at its prompt reads nothing until its next turn starts.

The lane's turn end says on its first line, `lane-mail-check: KEY=VALUE`, why its mail did not reach it:

| Line | Meaning | Remedy |
|---|---|---|
| `lane-record=unread` | The fleet record that names the lane's session could not be read, with its cause. Mail waiting at a turn end is handed to nobody and none is marked read. | Repair the fleet state the cause names. |
| `lane-process=unread cause=` | Whether the call runs under the lane's own harness process could not be read; the turn end judges it the lane's lead and goes on. | None: the turn goes on as the lead's. |
| `lane-session=unbound` | A session started in the lane's harness process in place of the one the record names, and the record could not be bound to it. The watch reads the lane's context as another session's until a later start or a relaunch binds it. | Relaunch the lane where its context matters. |

Stop a lane for mail that cannot wait only where [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) can relaunch it; otherwise keep the session, window, record and pending mail. The stop interrupts any turn in flight, so it is never the default. For a lane it can relaunch:

1. Stop the lane through the runtime close on the `no_landing` ground with `interrupt`, run from the fleet's checkout. It stops the harness by the record's `launch` identity, else the pane's foreground, a hosted harness through its provider, and the detached turn the record's `wake` names. It releases the window, records the lane `stopped`, and keeps the worktree, its validation runs and a hosted lane's sandbox:

   ```bash
   .agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] op --fleet --effect-exit --request-json '{"op": "close-owned-resources", "item": "[ITEM]", "no_landing": {"reason": "[REASON]", "source": "overseer", "interrupt": true}}'
   ```

   Exit 0 is the stop confirmed. Exit 3 is a stop that failed, its cause in the observation; exit 75 a stop still open, which its reconcile settles. A lane holding an unanswered ask fails `ask-unanswered`: answer the ask (§ Lane close, Asks and mailboxes) and run the stop again.

2. Relaunch under [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). The relaunch's brief carries the continuation, so nothing is pasted after it.

## Lane close

The runtime's close is the `close-lane` request. Write it with the harness file tool, then run it:

```json
{"op":"close-lane","item":"[ITEM_KEY]"}
```

```bash
.agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] op --fleet --request [REQUEST_FILE]
```

`[ITEM_KEY]` is the lane record's `item`, `[REQUEST_FILE]` the request's path and `[OVERSEE_STATE_DIR]` the fleet state's directory. The request takes these members:

| Member | Value |
|---|---|
| `mode` | `close`, the default: end the lane and record it `done`. `keep-sandbox`: end its harness and record it `stopped`, keeping its worktree, its validation runs and a hosted lane's sandbox, which then reads `sandbox: standing` and holds its slot. `{"park": {...}}`: park a hosted lane's merge wait ([oversee-lanes.md § Parking a merge wait](oversee-lanes.md#parking-a-merge-wait)). `terminal-state`: print the tracker's verdict alone, `completed`, `canceled` or `open`, in `result.state`. `if-terminal`: close only where that verdict is terminal, refusing `item-open` otherwise. |
| `delivery` | The merge the lane delivered: `{"pr": {"pr": [N], "repo": "[OWNER/REPO]"}}`, or a direct push's `{"commit": {"commit": "[SHA]"}}`. The close records that merge cycle on the lane when it confirms ([oversee-events.md § Direct-push cycle records](oversee-events.md#direct-push-cycle-records)). |
| `landing` | `{"disposed": {"by": "overseer", "id": "[ID]", "reason": "[REASON]", "of": "record"}}`, with `of` `record`, `boxes` or `both`: gives up a merge cycle the close could not record, or merged boxes it could not settle, under that authority. The close writes it once as the fleet log's `landing-disposed` row. |
| `tracker`, `repo`, `harness` | The identity a record written without it needs (§ Records with no identity). |

### The answer

`result.word` says how far the close got:

| Word | Meaning |
|---|---|
| `closed` | The record reads `done`. A record already `done` answers `closed` with nothing done. |
| `stopped` | The harness ended and the sandbox was kept. A stopped record closed with `keep-sandbox` answers `stopped` with nothing done, unless it holds an unanswered ask (§ Asks and mailboxes). |
| `parked` | The sandbox stopped with its disk kept. |
| `state` | The `terminal-state` verdict, in `result.state`. |
| `unconfirmed` | The close's intent stays open, with what still stands in `result.observation`. End what it names, then close again. |
| `failed` | Nothing moved; the cause is in `result.observation`. |

`result.notes` carries what a step left: `stop-skipped`, `item-files-kept cause=`, `host-absent mail-status=`, `host-kept kind= session=` for a Claude cloud session, which the close never stops, `merged-unjudged`, `boxes-ticked`, `boxes-unread cause=direct-delivery`, `base-follow refused cause=`, and under a `landing` disposal `cycle-unrecorded cause=` and the open boxes' note with `boxes-comment=`.

A refusal exits 1 with `ok: false`, its key in `refusal.key`, and the line `orch-runtime: KEY field=value ...` first on stderr. Nothing past the read it names has changed. The close reads before it acts: the lane record (`lane-missing`, `lane-duplicate`, `record-invalid field=mail_root`), the identity, the tracker's verdict (`tracker-read-failed`), the lane's state as the watch judges it, and the host's capability line (`host-capabilities-unread`).

### How a running lane is judged

| The lane reads | The close |
|---|---|
| `exited` | Closes. The item's files stay where its tracker holds it open (`item-files-kept cause=open`). |
| `idle`, `rate-limit-switch` | Closes where its tracker ended the item, or where its merge stands and its work is over. Otherwise refuses `lane-live state=idle`. |
| `gone`, or no recorded pane | Closes on the same two grounds, its harness ended by the provider or its launch identity. Otherwise refuses `pane-missing`. |
| `working`, `asking`, `walled`, `unjudged`, `unreadable` | Closes where its merge stands and its work is over, whatever the screen reads. A hosted lane whose provider says it holds no lane of the item closes as an exited one. Otherwise refuses `lane-live state=working`, `asking` or `unjudged`, the wall refusal below, or `pane-read-failed`. |

A merge stands where the record's `cycle` or the request's `delivery` names one. The work is over where the item's state was closed out or its worktree is gone, read on this disk, or on the host through the provider for a hosted lane. A recorded merge alone is no proof: a lane relaunched on a merged item works on with its `cycle` kept, so it still refuses `lane-live`. A read that fails refuses as `state-unreadable`, `worktree-read-failed`, or `host-busy` at the provider's call cap.

A usage banner on the screen is passed over only where the account judge, read for the record's `account` under the record's `host`, finds room for the record's `model`, over the whole account where it names none, and the banner names no reset still ahead. Every other reading keeps the lane walled: `lane-live state=walled` names the reading as `account=` (`room`, `walled`, `unlisted`, `unmeasured`, `read-failed` or `none`) and a reset still ahead as `resets=`.

Before it acts, a close on the merged ground or on an item its tracker completed completes a Linear item's branch-provable Done-when boxes from the merged pull request's evidence, through the linear package. Boxes it cannot settle refuse the close as `boxes-unsettled` (`item`, `state`, `cause`); a merge cycle it cannot record refuses as `cycle-unrecorded` (`item`, `cause`). A merged pull request whose repository neither the `delivery` nor the record names refuses as `boxes-unsettled state=unticked cause=repo-missing`: name the `repo` in the `delivery`. Fix the cause, or give that part up with the request's `landing` disposal.

### Hosted harness

A hosted lane's harness is stopped through its provider before the close transition, except a Copilot lane in a window of this machine (`pane=local`), which § What the close does stops after it. A Copilot lane on a provider that captures its pane first gets `C-c` and `/exit` through the provider's input, so it writes its session totals. Otherwise the provider's `stop` runs, then the close waits up to `ORCH_LANE_CLOSE_SECS` for the pane to read exited.

| Refusal or note | Meaning |
|---|---|
| `stop-failed` (`harness`, `cause`, `status`) | The provider's stop failed or gave no answer. |
| `host-busy step=stop` | The provider's call cap stayed full. Ask again. |
| `harness-unsupported harness=unknown` | The record names no harness: pass `harness` (§ Records with no identity). |
| `exit-timeout` (`harness`, `pane`, `processes`) | The pane outlived the stop. |
| note `stop-skipped ... cause=worktree-removed` or `cause=unowned` | The item's worktree is gone, or the host holds no lane of the item: a full close skips the stop and the provider's close ends it. A `keep-sandbox` close or a park refuses it as `stop-failed`. |

An exited lane needs no stop before the transition.

### What the close does

The close transition's effect ends a local lane's harness by the record's `launch` identity, else by the harness the pane's foreground shows; a local Copilot lane gets `C-c` and `/exit` first. A hosted Copilot lane in a `pane=local` window gets them in that window, then the provider's `stop` and its `status` read exited within `ORCH_LANE_CLOSE_SECS`, on every mode but a host-absent close. Nothing else is typed into the pane. It stops the detached turn the record's `wake` names. On every mode but `keep-sandbox` it ends the validation runs the lane's local worktree holds. On the tracker's terminal verdict it archives and removes the item's files. It closes a hosted lane's sandbox through the provider's `close`, releases the window, releases the worktree or keeps it with its reason, and moves the record.

A step that does not settle answers `unconfirmed`, the window and record standing, with the step in `result.observation`: `validate: stop-failed` with the run's cause, `item_files: failed`, `host_close: refused`, `failed` or `unanswered` from the provider's close, `host_close: standing` where its list still names the sandbox or `unconfirmed` where the list failed, `host_stop` with a refusal of § Hosted harness and its fields (`stop-failed`, `host-busy`, `exit-timeout`, or `pane-read-failed` with the status read's `cause`), reported after the harness has exited, `wake: live`, or a harness that outlived its grace (`timeout_pid`). End what the observation names, then close again.

The provider's `close` runs on every mode but `keep-sandbox` and a host-absent close, with `--merged` for an item its tracker completed whose merge the record's cycle or `worktree merged` shows. It answers `host_close: refused` with `path`, its exit 3 `close-refused path=`, where the clone or the item's worktree on the host holds a dirty path it cannot set aside, as [lane-host.md § Provider protocol](../schemas/lane-host.md#provider-protocol) states for `close`. Clean or commit what that checkout holds, then close again.

### Asks and mailboxes

A lane holding an ask nobody answered refuses the close as `ask-unanswered` (`item`, `ask`); a local lane's close answers `failed` with that cause. Answer the ask, then close again:

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ITEM] --re [ASK_ID] --file [PATH]
```

A lane whose record carries `host` takes `--root [MAIL_ROOT] --host`, under the mailbox rule of [oversee.md § Lane record](../workflows/oversee.md#lane-record). A mailbox the close cannot read refuses as `mail-read-failed`, or `host-busy step=mail-read`. On a full close of a hosted record on a terminal item, a mailbox read that failed is asked of the provider's list: where it names no sandbox for the item, the close notes `host-absent mail-status=` and records `done` with no provider stop or close. An exited lane takes neither refusal. A `keep-sandbox` close refuses `ask-unanswered` on a running hosted lane and on a `stopped` record, whatever the item's verdict, since the kept sandbox can be relaunched into a session that reads the reply. A full close of a `stopped` record reads its mailbox only while the tracker holds the item open. A park on the lane's own ask passes.

### Records with no identity

A record written without the lane's tracker, repository or harness carries none of them. The close takes each from the record, else from the request: a tracker-identifier item key reads as `linear`, and an `issue-N` key answers no tracker, so such a record refuses as `tracker-read-failed cause=key-ambiguous` unless the lane's landing and the end of its work prove it over. `tracker-read-failed` names `tracker`, `source` and `cause`: `source=given` where the record or the request named the tracker, `source=derived` where the close read it off the item key. A `github` lane with no repository on the record or the request refuses with `cause=repo-missing`. Pass `"tracker": "linear"` or `"github"` for an `issue-N` record, `"repo": "[OWNER/REPO]"` for a GitHub lane, and `"harness"` for a hosted lane whose record names none. Each fills only a field the record leaves empty, and refuses as `record-invalid` where it contradicts one the record carries.

### Closes the watch makes

The watch closes a merged hosted lane with its merge as the `delivery`, and a parked or stopped record whose tracker item is terminal through the same close, after it records the merge's cycle. A parked item with unfinished work, a Done item with an unchecked box among them, is not closed on the `merged` of its pull request: the watch prints `parked-merged`, the overseer relaunches the lane, and the resumed lane is closed as a merged hosted item is. Its retained pull request identity follows [workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state), so an OPEN pull request prevents the terminal close.

Before each close the watch writes its marker, `lane-close.[ITEM]` under its own state directory. A close that ended reports `lane-closed`, and a refused one `lane-close-refused` ([oversee-events.md § Event kinds](oversee-events.md#event-kinds)); any other answer is the `watch-step-failed` line's `lane-close-failed item=[ITEM]`, and the next pass asks again until the cause the refusal names is fixed. A close that started and gave no answer is `lane-close-unanswered`, and its marker stands. While the record still reads in flight, a later pass reports `lane-close-unconfirmed` and leaves the lane to the operator: read the lane record, then close the lane by hand.

On the surfaces of [oversee.md § 1](../workflows/oversee.md#1-resolve-the-launch-surface), surface 2 uses its native close and then sets its lane record `done`, because the runtime's close stops only a harness its own launch recorded, by its identity, its pane or its provider. Surface 3 continues in the overseer session and has no separate session or lane record to close.

## Per harness

What stays per harness is launching, resuming and the harness's own dialogs. Every lane launches through the runtime's `launch-lane` into a tmux window ([oversee.md § 3](../workflows/oversee.md#3-launch)), and its state is read through [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads). The keys the table names reach a dialog by one of two routes:

- A hosted lane whose host declares `pane=verb` takes each key through its provider, one key per call:

  ```bash
  .agents/skills/orch/scripts/orch-runtime host --host [HOST] send --item [ITEM] --key [KEY]
  ```

- Any other lane, local or hosted on `pane=local`, takes each key in its recorded window, one key per call:

  ```bash
  .agents/skills/orch/scripts/orch-runtime lane key --item [ITEM] --key [KEY]
  ```

  The key is `Enter`, `Up`, `Down`, `C-c` or a digit. It is pressed only while the lane reads `asking` or `rate-limit-switch`, through agent-runtime's `deliver --key`, whose refusal the verb prints: `deliver-refused` with the `state` it read, `process-mismatch` where the window's foreground is neither the harness nor a hosted lane's ssh client, `pane-self` for the overseer's own pane, `key-invalid` for any other key. `lane-unreachable` names a lane with no window here to press into, and `route=provider` a `pane=verb` lane, which takes the command above.

The Pi commands are the pi-session-bridge CLI, documented in its [README](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-session-bridge/README.md) and `pi-bridge --help`; every Pi call selects the lane by `--name` or `--cwd`.

| Harness | Launch | Answer a harness dialog |
|---|---|---|
| Claude Code | A first launch in a folder the wrapper has not trusted shows a trust prompt with "No, exit" selected: press `Down`, then `Enter`, then relaunch. A bypass launch sets `CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT=1`, `CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1` and `CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS=1` in the launching environment, which settings `env` blocks cannot set. The first two remove the inline-shell and substitution-only removal prompts; the third turns the critical-path removal prompt off in bypassPermissions mode. The launch disables `AskUserQuestion` and `EnterPlanMode`. | Press `Up` or `Down`, then `Enter`; the recorded choice line confirms it. Where a `PermissionRequest` hook such as `critical-path-deny` is installed, the third switch has no effect, and the [critical-path checks](https://code.claude.com/docs/en/permission-modes#critical-paths) still prompt for variable and positional-parameter targets, home, root, the working directory and its parents. `critical-path-deny` denies that prompt at once in a launched lane, with the [permission-modes page](https://code.claude.com/docs/en/permission-modes.md#rewrite-a-flagged-command)'s rewrite for each flagged form, and the lane does not wait. Explicit ask rules, MCP tools marked `requiresUserInteraction` and cross-session messaging safeguards can still prompt. Elsewhere, read the command, and press `Enter` on Yes only when it stays inside the lane's own worktree. |
| Codex | No dialog at launch. | Press the number the dialog shows, at the idle prompt. |
| Copilot CLI | [copilot-runtime.md](copilot-runtime.md) holds its launch environment and recovery. The launch sets `COPILOT_ALLOW_ALL=true` where the lane runs a full bypass, the `bypass` posture with no narrower `permission` word, which trusts the folder, and sets it empty otherwise; the record's `allow_all` says which. A lane without that grant, in a folder its account has not trusted, opens on "Confirm folder trust", which the watch reports as `lane-asking`: press `Enter` on "1. Yes", and relaunch the lane if its composer then sits empty with no turn started. | Press `Up` or `Down`, then `Enter`. |
| Pi | No dialog at launch. Use `pi-bridge state` only when the event carries no pane payload; never `history` or `stream`. | `pi-bridge questions` lists a pending dialog with its request id; `pi-bridge answer` answers it with that id and the option label, never through the pane, where a typed number lands on the default option. |
| App or other | The session or thread launcher the harness or an app-specific skill exposes ([oversee.md § 1](../workflows/oversee.md#1-resolve-the-launch-surface)). Read only the bounded state that explains the event, through its API or tooling. | The API or tooling that surface exposes; a pane at its idle prompt only when nothing else exists. |
