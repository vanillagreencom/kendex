# Lane directive

Read the matching section when [lane-launch.md § Lane directive](lane-launch.md#lane-directive) cannot choose an account or launch a lane. Read § Recovery relaunch when [oversee.md § Recovery relaunch](../workflows/oversee.md#recovery-relaunch) brings back a dead, walled or handed-off lane. A refusal prints `orch-runtime: KEY field=value ...` on stderr. A launch that failed after it was recorded carries the key as its observation's `cause`. [settings.md](settings.md) holds the settings named here.

## No lane has room

The account judge is `.agents/skills/orch/scripts/orch-runtime lane pick --fleet --harness [HARNESS] --native-model [MODEL]`; `--lane [CONFIG_DIR]` judges one named account. A request with `judge_account: true` checks its named account through the same judge.

Read `.result.answer`:

- `lane` names the account in `.result.record.config_dir`.
- `unjudged` is never a verdict: repair what `.result.record.cause` names.
- `cloud-repo-unset` is a cloud-session account with no access to this checkout's repository under `ORCH_LANE_CLOUD_REPOS`.
- Any other answer refuses; on a walled one, read the roster.

The 5-hour window is no wall for a running lane. For a start, on any account, the harness's own session-limit report on a lane holds the account's 5-hour window spent until its reset. A refusal on the 5-hour window names the `session` bucket and its `resets_at` in `projected_window`. An account a lane-host provider row measures is otherwise judged on its plan windows' figures, whatever their age. On an account this machine's listing measures, a start is judged on the 5-hour window as on the plan windows:

- One lane's hour of burn must leave the 5-hour window under the bound.
- A reading older than one lane at its burn takes to spend the room a window shows below the bound admits no start until a fresh reading. An account that would otherwise read `room` reads `unmeasured`, its `detail` starting `usage-stale`; a refused account keeps its own verdict.

```bash
.agents/skills/orch/scripts/orch-runtime lane roster
```

Wait only for an account over the threshold whose `status` is `ok`. Answer any other status as the table says, and report it to the operator:

| Status | Remedy |
|---|---|
| `expired` | Log in again, or run the command `detail` names. |
| `plan_ended` | Never wait on it: it has no reset. |
| `rate_limited` | Where `headroom_pct` is null, launch on another account. Never log in again. |
| `unreachable`, `refused` | Launch on another account. Never log in again. |
| `no_credentials`, `no_usage_data` | Report it; launch on another account. |
| `error` | Repair the step `detail` names. |

- Only the owner brings a `plan_ended` account back, by restoring the plan or the access, or by taking the account out of the fleet.
- A Claude account's `error` for a missing OAuth client id needs `AGENT_RUNTIME_CLAUDE_CLIENT_ID`, set once per host.

The judge can still refuse an account with roster room on its `projected_headroom_pct`, which charges each fleet lane live on the account. Wait for a lane on that account to close, or launch on another account.

A Codex account past its plan windows can still have room on its credits. A walled one reopens at `binding_resets_at`.

### Pi picks

The judge reads a Pi pick on a `github-copilot/` model on the Copilot pool, from the lane host's `accounts` row for the Pi root ([lane-host.md § Accounts rows](../schemas/lane-host.md#accounts-rows)). Run `orch-runtime lane pick --fleet --harness pi --native-model [MODEL] --lane [PI_ROOT]`.

- An `unmeasured` answer whose `refusal.cause` is `provider-unmeasured` means no reading measured the pool. Never wait it out. Repair the provider's read, whose row `orch-runtime lane roster` shows, or state the pool in `AGENT_RUNTIME_COPILOT_POOL`.
- A walled pool reopens at its `binding_resets_at`. A walled stated pool moves only when the owner restates it: report it to the operator.

For a Pi pick on another model:

- A Pi pick on a `pi-claude/` model is a Claude pick on the Claude seats.
- A Pi pick on an `anthropic/` model spends an API-credit grant; a refused grant (`cause=api-credit`) has no retry time, and a local host reads no API credit.
- An `unmeasured` answer with no `refusal` is a model whose provider nothing bills: launch on a model of a billed provider.

## Lane preference

`ORCH_LANE_PREFERENCE` lists `harness[@host]:model:effort` entries in order, under the grammar of [kendex.settings.toml.example](../kendex.settings.toml.example). The walk, `.agents/skills/orch/scripts/orch-runtime lane walk --fleet`, judges each entry's account and takes the first entry the judge gives an account. An entry with `@host` is judged on that host; one without it on `ORCH_LANE_HOST`.

| Option | Use |
|---|---|
| `--lane [DIR]` | Judge every entry on one account, a directory or a listed alias. |
| `--replaces [ITEM_KEY]` | On a relaunch: leave that lane's charge out, take no cloud session, and judge an account whose usage read is refused (`rate_limited`) and whose kept figure would leave room `unmeasured`. |
| `--source-harness [HARNESS]`, `--source-flags [WORDS]` | Pass over an entry whose harness cannot carry the asking session's permission posture. |

Read `.result.answer`:

- `lane`: the launch request takes `.result.chosen`.
- `none`: every entry was passed over. No reset answers the entries `.result.unread` names: repair the readings they name.
- `held`: the final, `:last` entry is a last choice, and an earlier entry had room or was unread (`.result.room`). Wait as § No lane has room says.

The request carries the chosen `harness`, `model`, `effort` and `account`, the `class` with its `class_reason`, and the entry's `host` where it is not `local`. A request naming neither `account` nor `model` runs the harness's default.

## Launch gate

The runtime judges a launch request in one transition before it writes anything; the transition's effect then prepares and opens the lane.

### Before anything is written

A transition refusal exits 1 with `ok: false` and records nothing. Fix what the key and its fields name, then send the request again. These keys need more:

- `obligation-conflict`: report the contradiction to root (§ Obligation lineage). Never rewrite the binding.
- `lane-live`, `harness-live`, `harness-unreadable`: end the lane first (§ Recovery relaunch). A launch never starts a second session beside one.
- `launch-blocked`, `launch-blocked-unread`, `overseer-unjudged`, `cap-unreadable`: never launch around it. A lane whose brief changes no repository file launches `read_only` beside its item's launch blockers ([§ A read-only launch](#a-read-only-launch)).
- `overseer-foreign`: launch from that repository's fleet, or list it in `ORCH_CONNECTED_REPOS`, as `route` says.
- `item-foreign`: file it in its own tracker and follow `route` and [peer-mail.md](peer-mail.md#addressing).
- `item-ineligible`: the item is a container; launch its unblocked children.
- `launch-overlap`: launch once that lane stops, or name the file in `in_scope` where the brief adds to it append-only.
- `join-unreachable`: the holder is hosted or a cloud session, which no join reaches. Launch once that lane stops.
  - A hosted lane that carries the launch's blockers refuses with no branch read, naming them as `blockers`.
  - A hosted lane that holds a shared path always refuses, naming the held path as `file`. The refusal says whether its head commit, read on its host and compared by GitHub with the repository's default branch, changes a shared path.
  - A head that changes a shared path refuses with `item`, `file`, `holder` and `route`.
  - Any other refusal adds `branch`, `unknown` where the head itself was unread, and `cause`. `worktree-unproved` is a head that changes none of the launch's paths. A cloud session's head is never read.
- `read-only-unconfined`: nothing can hold the lane to changing no file, as `cause` names: a cloud session (`cloud`), or a harness this machine cannot confine. Launch it here on a harness the confinement holds, or on an ssh host. A first launch, or one over a `done` record, may instead leave out `read_only`; a relaunch keeps the record's (§ Recovery relaunch).
- `join-confined`: the holder's confinement bars the join. For a shared-file tie, retry once the holder stops. For a launch-blocker tie, retry a standalone launch once Linear clears the launch blockers. Retry the join if the holder becomes eligible under [§ A joined launch](#a-joined-launch). For `confinement-unproved`, wait for the holder's launch to report its confinement before retrying the join.
- `join-unsent`, `join-tier-narrower`: repair the mailbox, or launch once the holder stops.
- `tier-narrower`: brief the judged cycle.
- `lane-repo-conflict`: leave `repo` out of the `admit-paths` request; the lane's own is judged.
- `launch-class-missing`: name both `class` and `class_reason`, under [skill-rules.md § Model class](skill-rules.md#model-class). A relaunch naming neither keeps the record's.
- `launch-class-missed`: launch at `standard` or above.
- `launch-model-missing`, `launch-effort-missing`: name the model and effort the account was judged on.
- `permission-unrepresentable`: name a spelling the harness takes, or leave `permission` out to run the `AGENT_RUNTIME_LAUNCH_PERMISSION` posture.
- `account-spent`, `account-walled`, `account-reserved`, `account-retired`, `account-unmeasured`, `account-unjudged`: read the answer as § No lane has room does. Then choose another account, never the same one, through [lane-launch.md § Lane directive](lane-launch.md#lane-directive) step 3.
- `cap-reached`: § Caps.

### A joined launch

A first launch can join a live lane of the same repository before that lane's review, through a shared path or the launch blockers that lane carries. Across worktrees the holder must be unconfined. The reply's `op` is `joined`. Nothing is launched and no slot is charged. The brief reaches the holder's mailbox after the holder's widened `Admitted paths:` line, and the holder ships both items.

### A read-only launch

A request naming `read_only: true` launches a lane that ships no repository change. Name it for a lane whose brief changes no repository file, such as a plan or a tracker-comment lane.

- On this machine, its confinement binds its checkout and its common git folder read-only, the checkout's `tmp` alone writable.
- On an ssh host, the launch puts a read-only record (`lane-read-only`) holding the worktree path in the worktree's git directory, and `record-push` refuses `push-read-only` from that worktree in every mode that pushes.
  - A writing launch on that host puts the record empty, which holds nothing.
  - A put that fails or never answers refuses the launch before the harness starts.
  - The hold is advisory: it stops neither a direct `git push` nor the `record-push` of a consumer whose committed orch render reads no record.
- A cloud session refuses `read-only-unconfined`.
- Its first launch is not judged on its item's launch blockers, or a container ancestor's: it starts beside them. The item's writing launch still waits for them.
- Its first launch judges an empty touched set: it meets no holder, and its record holds no path.
- The tier is still judged over the paths a writing lane's touched set would hold ([lane-launch.md § Shared files](lane-launch.md#shared-files)).
- A read-only lane takes no join on either side. A launch sharing a path with it passes it, and one whose launch blockers it alone carries refuses `launch-blocked`. A read-only launch opens its own lane beside a lane carrying its blockers.
- `read_only` is decided where the launch is judged. A relaunch keeps the record's `read_only` and touched set whatever it names (§ Recovery relaunch): one naming `read_only: true` over a writing record launches a writing lane. A launch over a `done` record is judged, and takes its request's.

### After the lane is recorded `preparing`

The effect's refusal settles the launch intent `failed` and records the lane `stopped`, with the key as the observation's `cause`. Under `--effect-exit` the reply's `settled` intent carries that observation; `.agents/skills/orch/scripts/orch-runtime state inspect --fleet` shows it.

1. Fix what it names before retrying.
2. If a failed cloud launch leaves an item worktree claim, resolve that claim with its owner before sending the request again.

These causes need more:

- `bypass-refused`: the account's owner removes the recorded `skipDangerousModePermissionPrompt: false`, or the lane launches without the bypass word.
- `harness-binary-missing`: install the harness, or name it in `AGENT_RUNTIME_HARNESS_BINARIES` as `harness=/absolute/path`.
- `permission-mismatch`: drop the bypass word, or name a narrower one.
- `home-relative`, `no-context-reader`: [copilot-runtime.md § Account setup](copilot-runtime.md#account-setup). Repair what `file` names.
- `tmux-session-unresolved`, `tmux-session-missing`, `tmux-server-absent`, `tmux-server-unstarted`, `tmux-socket-dir-unsafe`, `tmux-socket-dir-unmade`: § Tmux session.
- `session-owned-elsewhere`, `session-store-unreadable`: the same request meets the same refusal. Repair the store, or report the session to the operator.
- `read-only-unconfined`: a Codex seat linked outside its grants (`linked-seat`) cannot hold a read-only lane. Repair the seat, or launch on another account.

### Harness gate

The harness gate (agent-runtime `effects/prepare/gate.rs`) admits only a lane whose compaction is off and whose turns its hooks record. A `cause` from it is repaired as the lane's harness says; a hosted Pi or Copilot lane meets the gate on the host's own files:

- Pi: [pi-runtime.md § Lane mailbox wake (Pi)](pi-runtime.md#lane-mailbox-wake-pi).
  - Pi needs automatic compaction off in its settings, no project setting turning it on, and an installed pi-hooks carrier that supplies `context_window` and wakes on mail.
  - Its causes are `compaction-on`, `pi-settings-unreadable`, `pi-carrier-unreadable`, `pi-carrier-unresolved`, `pi-selection-unresolved`, `pi-mail-wake-missing`, `pi-mail-wake-off` and `unsupported-for-oversee harness=pi`.
  - After the repair, send the item's `launch-lane` request again, as `retry=launch-lane` says.
- Copilot: [copilot-runtime.md § Account setup](copilot-runtime.md#account-setup). Install the three lane-mail hooks through kendex, switch them back on, or repair kendex.
- `host-pi-claude-seat`: launch the Pi lane locally, or on a `github-copilot/` or `anthropic/` model.
- `home-unresolved`: name the account.

### Hosted launch

A launch record that the provider's `create` did not leave whole (`marker-failed`, `host-gitfile-unread`, `host-gitfile-invalid`, `host-runtime-unbuilt`): report it to the provider's owner.

A provider step that gave no answer holds the launch open, with a `note` ending `-unknown`. The provider may hold the item's worktree.

- A repeated launch request reconciles the open launch.
- To start a fresh one, close the held launch through [lane-reach.md § Lane close](lane-reach.md#lane-close) and confirm the sandbox is gone.
- A sandbox the provider acknowledged stays charged to the cap until a close confirms it gone.
- If create refuses before acknowledging the sandbox, check its ownership with the provider before retrying.

### Cloud launch

A cloud launch held as `cloud-create-unknown`, `worktree-create-unknown` or `worktree-push-unknown` has no process left to answer it, and its intent stays open.

- Read it with `orch-runtime state inspect --fleet`.
- Where its observation or `CloudCreate` phase carries `answer_by`, wait until that time, then check claude.ai/code for a session on the item's branch.
- Check again immediately before relaunching the item.
- A close that answers `intent-open` leaves the launch standing: wait for its owner to end and reconcile it, and do not launch beside it.
- Settle the lane with the runtime close, which supersedes the held launch:

  ```json
  {"op": "close-owned-resources", "item": "[ITEM_KEY]", "terminal": {"verdict": "[completed|canceled]", "source": "[SOURCE]"}}
  ```

  Use `terminal` where the item is finished. To relaunch it, use the `no_landing` ground of § Recovery relaunch.

## Brief file

- Write the brief with the harness's file tool under the checkout's `tmp/`, and name its absolute path as the request's `brief_file`.
- Keep the file until the launch settles.
- A launch with no `brief_file` starts the lane on the start workflow for its item, which continues from the item's handoff record.

The brief opens the lane's workflow, `/orch start [ITEM]` or the tier's verb, in the form its harness takes ([lane-launch.md § Lane directive](lane-launch.md#lane-directive)). A first launch reads the tier the brief states, by its verb or its one `item-tier` line; a relaunch keeps the record's.

The launch closes a local or hosted lane's brief with these, in order:

1. The `Admitted paths:` line, the lane record's `touched` as a JSON array, where the record holds a non-empty set and the lane is not `read_only` ([lane-launch.md § Shared files](lane-launch.md#shared-files)).
2. The unattended words.
3. The lane mailbox monitor's arm line, for Claude Code and Copilot CLI ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)).
4. The output-mode sentence of [skill-rules.md § Lane Output](skill-rules.md#lane-output).

A cloud launch's brief takes the cloud session words in place of the unattended words.

## Obligation lineage

The root launch or continuity directive supplies the item's original obligation and its accepted parent mapping: the object of [workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state) `lanes[].obligation`. Carry it as the `launch-lane` request's `obligation`.

- A record that binds none takes the stated object. A request naming none keeps the record's binding.
- A first launch naming `repo` and no `obligation` records the item as its own parent: a fresh item.
- A record with no accepted mapping stays unknown. Never reconstruct one from a title, a current parent or the checkout's repository.
- A surface-2 record carries the binding as [lane-launch.md § Lane record](lane-launch.md#lane-record) writes it.

Keep the binding through same-item launches, retries, relaunches, park and resume, account or model recovery, and context handoff. Reparenting does not rewrite the original parent. A replacement item names its predecessor's complete object as its launch request's `obligation`, or in its surface-2 record; its own item key stays separate. A cross-fleet transfer carries its accepted mapping where no retained record reaches the successor. Report a contradiction to root; never rewrite a known binding. A separate obligation needs a new tracker item or an explicit root disposition.

## Caps

The transition counts its cap before it writes anything. A `claude-cloud` request counts against `ORCH_OVERSEER_CLOUD_LANES`; every other kind, a cloud session's landing lane included, counts against `ORCH_OVERSEER_LANES`. No cap bounds the lanes on one account. The reply's `admission` lists each charge with its `reason`. A relaunch leaves its own record's charge out, so it replaces the lane it holds.

- `cap-reached`: send the request again once a lane that cap counts closes. Write no counting loop.
- `cap-unreadable`: fix the source it names; never launch around it.

A request's `over_cap` admits one deliberate launch past its cap; the record keeps the word.

## Tmux session

Every lane window opens in one session on the fleet's tmux server. The launch uses `AGENT_RUNTIME_TMUX_SESSION` when set, then falls back to the fleet state's `tmux.session`. A confirmed controller start or lane launch fills an absent `tmux.session` and preserves an existing value.

- If no tmux server answers on the controller record's `server_socket`, as after a restart, the launch starts one there and makes that session in it. It first makes the socket's directory, mode `0700`, where it is gone.
- On any other socket, such as a caller's own `$TMUX`, a launch where no server listens refuses `tmux-server-absent`.
- The server runs as its own job, a user unit or a `setsid` group, recorded in `tmux-server.runner` beside the fleet state, with its stderr in `tmux-server.err`. Stopping the caller does not end it, and an OOM kill in one pane does not end the unit. It ends with its last session.
- A socket directory that is not this user's, or that group or others may write in, refuses `tmux-socket-dir-unsafe`. One it cannot make refuses `tmux-socket-dir-unmade`.
- A launch that resolves no session refuses `tmux-session-unresolved`.
- A server that stands without the session refuses `tmux-session-missing`: set `AGENT_RUNTIME_TMUX_SESSION`, or create that session.
- A stderr file the start cannot empty, a start the launcher refused, a server that exits, or one that never answers within `AGENT_RUNTIME_TMUX_VERIFY_SECS` refuses `tmux-server-unstarted`.
  - `launch` is the launcher's answer (`refused`, `started` or `unanswered`), `exited` where the server ended before it answered, or `unrun` where the stderr file could not be written.
  - `runner` is the launcher's line, or its cause where it refused or did not answer.
  - `cause` is the server's last stderr line, else the last tmux error, else `unanswered`.
  - A lane's observation has `cause: tmux-server-unstarted`, with the refusal's own cause in `detail`.
  - A controller start's observation has `note: tmux-server-unstarted`, with `launch`, `runner` and `cause` under `fields`. `controller-resume-failed` prints that `cause`.

## Recovery relaunch

For a local lane whose session has ended, run the relaunch from the checkout with the item alone:

```bash
.agents/skills/orch/scripts/orch-runtime lane relaunch --fleet [ITEM_KEY]
```

- It runs steps 2 and 3 below from the record: the close, then the launch on the record's own account and the start brief.
  - Where no handoff record stands for the item, the start brief closes with one sentence: the last session ended without a handoff, so before the next step the worker reads its worktree's Git state and the branch's remote head, settles the last command it saw no result for, and restarts any wait it held.
  - A standing handoff record leaves the sentence out.
- Before the close, it judges the record's account with the launch's own judge, with the lane's own charge left out, and admits the launch as the launch would be admitted.
- It reaches the controller record's `server_socket`, not the caller's `$TMUX`, and starts a gone server as § Tmux session states.
- Exit 0 prints `resumed item=[ITEM_KEY] route=resume|fresh account=[DIR|-]`.
- A failed close prints `close-failed` on stderr at exit 3, and an open one `close-unconfirmed` at exit 75. Nothing is launched after either.
- A failed launch prints `launch-failed` at exit 3, and an open one `launch-unconfirmed` at exit 75. Both name the close's intent as `close=[ID]`. A launch refused after the close is `launch-failed` with `refusal=[KEY] ...`.
- Every refusal at exit 1 closes nothing. The keys are `server-socket-unrecorded`, `lane-missing`, `lane-hosted`, `lane-live` where the lane's session still runs, `handoff-unreadable` where a place the item's handoff is read from cannot be read, `harness-unreadable`, `harness-unrecorded`, `relaunch-unprepared cause=[CAUSE]`, the account refusals [§ Before anything is written](#before-anything-is-written) lists, and the launch's admission refusals.

Compose the steps below by hand to change the harness, account or brief, to supply an explicit close reason, for a lane whose session still runs, which step 2's `no_landing` close ends, or for a hosted lane. A relaunch sends the item's `launch-lane` request again over its standing record, from the checkout the launch ran from.

1. End the lane. The record must not be in flight, and no recorded harness or detached turn may still run. End it through its own close-out, [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver), or the runtime close in step 2.
2. Where the lane still stands, run the runtime close. It retires the attempt and keeps the item's work, the worktree and its validation runs among it, and a hosted lane's sandbox stands after it (§ Resume or fresh). Write the request with the harness file tool:

   ```json
   {"op": "close-owned-resources", "item": "[ITEM_KEY]", "no_landing": {"reason": "[REASON]", "source": "overseer"}}
   ```

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --fleet --effect-exit --request [REQUEST_FILE]
   ```

   - Exit 0 is a confirmed stop.
   - Exit 3 is a failed close, its cause in the observation.
   - Exit 75 is a close still open; a repeat of the same request settles it.
   - The close stops the harness only on proof that it is idle or gone: a working lane fails `not-idle`.
   - A lane holding an unanswered ask fails `ask-unanswered` while its harness runs: answer the ask ([lane-reach.md § Asks and mailboxes](lane-reach.md#asks-and-mailboxes)).
   - Add `"interrupt": true` inside `no_landing` only for an unusable session, as after a model switch; it waives only the idle proof.
   - An open close lists what still stands in its observation's `remaining`.
   - A `pane` row marked `unaddressable: true` names a pane with no tmux server: find it with `tmux list-panes -a`, end what it runs by hand, and report the open intent to the operator.

3. Compose the relaunch request from the record, and send it as § Launch gate's request is sent:

| Field | Value |
|---|---|
| `item`, `harness`, `tracker`, `repo`, `model`, `effort`, `permission` | The record's, or the replacement's choice. |
| `mail_root` | The record's; a hosted record's `checkout`. |
| `host`, `kind` | Together, where the replacement runs where the record's lane ran. |
| `account` | The account `lane walk --fleet --replaces [ITEM_KEY]` or `lane pick --fleet --replaces [ITEM_KEY]` chose. |
| `class`, `class_reason` | Both, or neither to keep the record's. |
| `refresh` | `true` for a refresh lane. |
| `brief_file` | The continuation (§ Brief file). |

- A request naming neither `host` nor `kind` opens a window on this machine and records a local lane.
- A relaunch without `refresh` drops the record's `refresh`.
- The confirmed launch writes `harness`, `account`, `model` and `effort` from the request, each null where the request names none: carry each one the replacement keeps.
- Left out, `tracker`, `repo`, `over_cap`, `permission` and `obligation` keep the record's value.
- A recorded `desktop` stands whatever the request names, and so does the record's `read_only`, set or not.
- A relaunch naming no `permission` runs the `AGENT_RUNTIME_LAUNCH_PERMISSION` posture: carry the record's word.
- A relaunch is not judged by the [Ancestor gate](skill-rules.md#ancestor-gate) or the file-overlap hold; it keeps the record's touched sets and tier.
- A record that reads `done` takes the request as the item's next phase, judged as a first launch, its tier read from the new brief.

### Resume or fresh

- A local relaunch on the same harness and account resumes the session the record binds, with the brief as its next prompt.
- A local Claude Code relaunch on another account resumes that session too, where the request's account's home holds it.
- A switched harness, any other switched account, a Pi lane, a session the destination home lacks, or a standing handoff record with `relaunch` `fresh` or none starts the harness fresh instead; the observation names the reason as `route_cause`.
- A hosted relaunch always starts the harness fresh.

Outside § Parked record, a host whose capability line declares `park=none` ([lane-host.md § Host kinds](../schemas/lane-host.md#host-kinds)) is asked neither `list` nor `start`: the launch goes straight to `create --relaunch`. A `park=verb` host is asked its `list`, which tells its sandbox's two states apart:

- Standing, as the `no_landing` close of § Recovery relaunch step 2 keeps it: the launch asks the provider's `start`, then `create --relaunch`.
- Gone: the launch asks no `start` and goes straight to `create --relaunch`.

A list that fails refuses the launch `host-list-failed`. A hosted relaunch whose provider's `start` answers it holds no sandbox for the item gets a fresh sandbox, with no kept worktree, session or mailbox: its observation reads `host_start: item-unknown` and `route_cause` `sandbox-absent`.

A fresh start continues through the handoff record:

- Its brief is the `start` brief ([start.md § 0](../workflows/start.md#0-resume-from-a-handoff)).
- A harness switch's brief also carries the transcript sentence of [handoff.md § 2](../workflows/handoff.md#2-launch).

The brief carries the continuation either way, so paste nothing into the pane after a relaunch.

### Parked record

A `parked` record ([oversee-lanes.md § Parking a merge wait](oversee-lanes.md#parking-a-merge-wait)) is relaunched with the same request.

- The launch asks the provider's `start` for the stopped sandbox before its `create`, with no `list` read.
- The relaunch moves the parked pull request into `pending_pr` ([workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), so an OPEN pull request still prevents the terminal close.
- A parked record holds no slot without a live identity or a reservation, so its relaunch can meet `cap-reached`.
