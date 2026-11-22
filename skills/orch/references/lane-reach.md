# Lane reach

Read from [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane) when a lane's state decides how to reach it, the wake does not reach it, or it shows a harness dialog. Read from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) when a lane closes. § Per harness says who sends a dialog's keys.

## Lane states

`.agents/skills/orch/scripts/orch-runtime lane status --item [ITEM]` reads the item's one in-flight lane record and prints its state as `result.state`, with `result.cause` where the state carries one. A Pi lane is judged by the session rows its turn end writes, never idle off its screen.

| State | How the lane is reached |
|---|---|
| `idle` | The wake types the mail line; a directive reaches the lane at once. |
| `working` | Send mail; the lane reads it at its next tool call or turn end. Mail that cannot wait takes § Mail the wake cannot deliver. |
| `asking` | Answer the dialog by the lane's harness in § Per harness. |
| `rate-limit-switch` | Apply [oversee-events.md § lane-asking](oversee-events.md#lane-asking). |
| `walled` | Follow the wall's cause under [oversee-events.md § usage-limit](oversee-events.md#usage-limit). |
| `exited`, `gone` | It reads no mail. Relaunch it under [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). |
| `unreadable` | Resolve `result.cause` first. An unreadable read proves no exit. |
| `unjudged` | Resolve `result.cause`, read beside the recorded identity, before deciding to relaunch. |

The watch's wake duty types one line into a positively idle running lane and confirms it ([oversee-events.md § Wake outcomes](oversee-events.md#wake-delivered-wake-unconfirmed-wake-limit)). A record that is not `running` is never woken: relaunch it.

## Mail the wake cannot deliver

Every running lane the wake does not reach takes this route, whatever its harness: a `working` or `unjudged` lane, a `wake-limit` lane, and a lane on a host the wake does not reach. The mail waits by default. The lane reads it at the next point [skill-rules.md § Lane mail](skill-rules.md#lane-mail) names. A lane idle at its prompt reads nothing until its next turn starts.

The first line of the lane's turn end, `lane-mail-check: KEY=VALUE`, says why its mail did not reach it. On `lane-record=unread`, repair the fleet state its cause names. On `lane-session=unbound`, relaunch the lane where its context matters.

Stop a lane for mail that cannot wait only where [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) can relaunch it. Otherwise keep the session, window, record and pending mail. The stop interrupts any turn in flight, so it is never the default. For a lane that can be relaunched:

1. Stop the lane through the runtime close on the `no_landing` ground with `interrupt`, run from the fleet's checkout. It keeps the worktree, its validation runs and a hosted lane's sandbox:

   ```bash
   .agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] op --fleet --effect-exit --request-json '{"op": "close-owned-resources", "item": "[ITEM]", "no_landing": {"reason": "[REASON]", "source": "overseer", "interrupt": true}}'
   ```

   Read its exits as [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) step 2 states. On `ask-unanswered`, answer the ask (§ Asks and mailboxes), then run the stop again.

2. Relaunch under [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch). The relaunch's brief carries the continuation, so paste nothing after it.

## Lane close

The runtime's close is the `close-lane` request. Write it with the harness file tool, then run it:

```json
{"op":"close-lane","item":"[ITEM_KEY]"}
```

```bash
.agents/skills/orch/scripts/orch-runtime --state-dir [OVERSEE_STATE_DIR] op --fleet --request [REQUEST_FILE]
```

`[ITEM_KEY]` is the lane record's `item`, `[REQUEST_FILE]` the request's path, and `[OVERSEE_STATE_DIR]` the fleet state's directory. Add members as the case needs:

- `mode`: `close`, the default, ends the lane and records it `done`. `keep-sandbox` ends its harness and records it `stopped`, keeping its worktree and a hosted lane's sandbox, which holds its slot. `{"park": {...}}` parks a hosted lane's merge wait ([oversee-lanes.md § Parking a merge wait](oversee-lanes.md#parking-a-merge-wait)). `terminal-state` prints only the tracker's verdict, in `result.state`. `if-terminal` closes only on a terminal verdict.
- `delivery`: the merge the lane delivered, `{"pr": {"pr": [N], "repo": "[OWNER/REPO]"}}` or a direct push's `{"commit": {"commit": "[SHA]"}}`. The close records that merge cycle on the lane ([oversee-events.md § Direct-push cycle records](oversee-events.md#direct-push-cycle-records)).
- `landing`: `{"disposed": {"by": "overseer", "id": "[ID]", "reason": "[REASON]", "of": "record"}}`, with `of` `record`, `boxes` or `both`, gives up a merge cycle the close could not record, or merged boxes it could not settle.
- `tracker`, `repo`, `harness`: § Records with no identity.

A full close that answered `unconfirmed` leaves its intent open, and a keep refuses `close-kind-differs` until it settles. Ask that close again, or record its outcome with `{"op": "record-outcome", "intent_id": "[INTENT]", "outcome": "[OUTCOME]"}`, `[INTENT]` from the refusal's `intent`.

### The answer

`result.word` says how far the close got. On `unconfirmed`, end what `result.observation` names, then close again. On `failed`, nothing moved; fix the cause in `result.observation`. A refusal exits 1 with its key in `refusal.key`; nothing past the read it names has changed.

A hosted lane's box is read from its host before the provider's close takes its sandbox. A park reads no box, and neither does a close of a parked record, of one that owes a park, or of a relaunch from a park that failed before its sandbox came back. `result.observation.mail` holds what the watch had not yet announced: `envelopes`, each with its `id`, `kind`, `text` and `options`, and the box's `count` and `first` id, which the watch's cursor moves to. Handle each envelope as its `lane-notice` or `lane-question` line ([oversee-events.md § Event kinds](oversee-events.md#event-kinds)). The watch says the mail of the closes it makes as those lines and moves its cursor past them. A close you ask moves no cursor, so asking it again can show the same envelopes. A sandbox the provider no longer lists has no box left to read.

A close held before the provider's close because the box did not read answers `unconfirmed` with `mail: "unread"` and the cause in `result.observation.cause`: `host-busy step=[STEP]`, which a retry clears, or `mail-read-failed` with the read's cause. A relaunch from a park held at its `start` over a sandbox still stopped holds its close this way until it is relaunched. A park or a close whose read of the lane's unanswered asks fails refuses with the same keys.

### How a running lane is judged

The close ends an exited lane, and a hosted lane whose provider holds no lane of the item. Any other lane closes where its merge stands and its work is over, whatever its screen reads. An `idle`, `rate-limit-switch` or `gone` lane, or one with no recorded pane, also closes where its tracker ended the item. Otherwise the close refuses `lane-live` or `pane-missing`. A merge stands where the record's `cycle` or the request's `delivery` names one. The work is over where its worktree is gone or the item's close-out ran. An unconfined lane's close-out removes the item's state record. A confined lane's stamps it `closed_out_at`, and the stamp counts where it is at or after the lane's current session began; the record then stays with the open item, and its post-merge boxes stay open for the verification pass. A recorded merge alone is no proof: a lane relaunched on a merged item works on with its `cycle` and an earlier stamp kept.

Before it acts on the merged ground, or on an item its tracker completed, the close completes a Linear item's branch-provable Done-when boxes from the merged pull request's evidence. Where neither the `delivery` nor the record names the merged pull request's repository, name the `repo` in the `delivery`. For any other box or cycle refusal, fix the cause, or give that part up with the request's `landing` disposal.

### Hosted harness

The close stops a hosted lane's harness through its provider. On `host-busy step=stop`, ask again. On `harness-unsupported harness=unknown`, pass `harness` (§ Records with no identity). An exited lane needs no stop.

### What the close does

The close ends the harness, the detached turn its `wake` names and, on every mode but `keep-sandbox`, the validation runs of its local worktree. On the tracker's terminal verdict it archives and removes the item's files. It closes a hosted lane's sandbox, releases the window, releases or keeps the worktree, and moves the record. Nothing else is typed into the pane.

Where the clone or the item's worktree on the host holds a dirty path it cannot set aside, the provider's close answers `host_close: refused` with `path` ([lane-host.md § Provider protocol](../schemas/lane-host.md#provider-protocol), `close`). Clean or commit what that checkout holds, then close again.

### Asks and mailboxes

A lane holding an unanswered ask refuses the close as `ask-unanswered`. Answer the ask, then close again:

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ITEM] --re [ASK_ID] --file [PATH]
```

For a lane whose record carries `host`, add `--root [MAIL_ROOT] --host`, under the mailbox rule of [oversee.md § Lane record](../workflows/oversee.md#lane-record). A `keep-sandbox` close refuses `ask-unanswered` on a running hosted lane and on a `stopped` record, whatever the item's verdict: the kept sandbox can be relaunched into a session that reads the reply.

### Records with no identity

A record written without the lane's tracker, repository or harness takes each from the request. An `issue-N` key names no tracker, and its close refuses `tracker-read-failed cause=key-ambiguous`. Pass `"tracker": "linear"` or `"github"` for an `issue-N` record, `"repo": "[OWNER/REPO]"` for a GitHub lane, and `"harness"` for a hosted lane whose record names none. Each fills only a field the record leaves empty.

### Closes the watch makes

The watch closes a merged hosted lane, and a parked or stopped record whose tracker item is terminal ([oversee-events.md § `merged`](oversee-events.md#merged)). A parked item with unfinished work, a Done item with an unchecked box among them, takes [oversee-events.md § `parked-merged`](oversee-events.md#parked-merged) instead. Its retained pull request identity follows [workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state), so an OPEN pull request prevents the terminal close.

[oversee-events.md § Event kinds](oversee-events.md#event-kinds) says what the overseer does on each line the watch's close prints. On `lane-close-unconfirmed`, read the lane record before closing the lane by hand.

On the surfaces of [oversee.md § 1](../workflows/oversee.md#1-resolve-the-launch-surface), surface 2 uses its native close, then sets its lane record `done`. The runtime's close stops only a harness its own launch recorded. Surface 3 continues in the overseer session and has no separate session or lane record to close.

## Per harness

Launching, resuming and the harness's own dialogs stay per harness. Every lane launches through the runtime's `launch-lane` into a tmux window ([oversee.md § 3](../workflows/oversee.md#3-launch)), and [oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads) reads its state. The table's keys reach a dialog one key per call:

- A hosted lane whose host declares `pane=verb` takes each key through its provider:

  ```bash
  .agents/skills/orch/scripts/orch-runtime host --host [HOST] send --item [ITEM] --key [KEY]
  ```

- Any other lane takes each key in its recorded window, only while it reads `asking` or `rate-limit-switch`:

  ```bash
  .agents/skills/orch/scripts/orch-runtime lane key --item [ITEM] --key [KEY]
  ```

The Pi commands are the pi-session-bridge CLI, documented in its [README](https://github.com/vanillagreencom/kendex/blob/main/pi-extensions/pi-session-bridge/README.md) and `pi-bridge --help`. Every Pi call selects the lane by `--name` or `--cwd`.

| Harness | Launch | Answer a harness dialog |
|---|---|---|
| Claude Code | A first launch in a folder the wrapper has not trusted shows a trust prompt with "No, exit" selected: press `Down`, then `Enter`, then relaunch. | Press `Up` or `Down`, then `Enter`; the recorded choice line confirms it. Where `critical-path-deny` is installed, it denies a launched lane's [critical-path](https://code.claude.com/docs/en/permission-modes#critical-paths) prompt at once, and the lane does not wait. For any other prompt, read the command, and press `Enter` on Yes only when it stays inside the lane's own worktree. |
| Codex | No dialog at launch. | Press the number the dialog shows, at the idle prompt. |
| Copilot CLI | [copilot-runtime.md § Launch environment](copilot-runtime.md#launch-environment) holds its launch environment, and § Recovery its recovery. A lane whose record's `allow_all` shows no folder-trust grant, in a folder its account has not trusted, opens on "Confirm folder trust", which the watch reports as `lane-asking`. Press `Enter` on "1. Yes". Relaunch the lane if its composer then sits empty with no turn started. | Press `Up` or `Down`, then `Enter`. |
| Pi | No dialog at launch. Use `pi-bridge state` only when the event carries no pane payload; never `history` or `stream`. | `pi-bridge questions` lists a pending dialog with its request id. `pi-bridge answer` answers it with that id and the option label. Never answer through the pane, where a typed number lands on the default option. |
| App or other | The session or thread launcher the harness or an app-specific skill exposes ([oversee.md § 1](../workflows/oversee.md#1-resolve-the-launch-surface)). Read only the bounded state that explains the event, through its API or tooling. | The API or tooling that surface exposes; a pane at its idle prompt only when nothing else exists. |
