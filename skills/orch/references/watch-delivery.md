# Watch delivery

Read when an overseer starts, follows or stops the fleet watch, and when a lane arms its mailbox monitor. At [overseer takeover § 2](../workflows/oversee-takeover.md#2-claim-and-follow-the-watch), read § The watch, § Reader directory, § Claim and the section and table row for this harness. Read § Stop only at [oversee.md § 5](../workflows/oversee.md#5-stop). A lane reads § Lane mailbox monitor from [skill-rules.md § Lane mail](skill-rules.md#lane-mail).

Oversight stands from the watch's first launch until [oversee.md § 5](../workflows/oversee.md#5-stop), and every watch line reaches this session as it is written. Where the harness has no asynchronous wake, the turn is the wait: hold a blocking follow of the log, re-arm it on every return, and never end the turn while any lane record is `running`.

## The watch

The watch is the runtime's standing scheduler, `orch-runtime watch run`, claimed by its process identity in `oversee-watch.pid` beside the fleet state. A controller `start-controller` opens has its watch from the start: the request carries the watch's words, and the runtime launches them detached before it publishes the controller; a watch that refuses or never claims leaves the start `unconfirmed`. A session `orch-runtime register --fleet` recorded, with no live claim, starts the watch once from its own pane with the block [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) states; `oversee-watch.runner` and `oversee-watch.err` land beside the fleet state. The watch outlives the session that started it, a succession and a death or wall recovery; nothing hands it over, and a successor follows the same log.

Follow the watch's log; never start a second watch on the same fleet state. A harness that delivers log lines as they arrive, or holds a blocking follow inside its turn, uses § Repeat watch. A harness whose only wake is a background command's exit uses § Single passes.

## Reader directory

The log is `oversee-watch.log` beside the fleet state, and `oversee-watch.err` beside it holds the runner's stderr, each duty failure's cause under its `watch-step-failed` words.

1. From the watch claim's working directory, create a fresh reader directory with `mktemp -d tmp/waiter.XXXXXX`, and use its absolute path as `[RUN_DIR]`. The turn-end check and the wake duty find the follow by this path.
2. Link `[RUN_DIR]/watch.log` to the log.
3. Save the follow of § Repeat watch or § Single passes as `[RUN_DIR]/follow.sh`.
4. Follow with `sh "[RUN_DIR]/follow.sh" "[RUN_DIR]/watch.log" [NEXT_LINE]`, starting after the last numbered line handled.

A fleet's first start, a `start-controller` with no `resume`, empties the log an earlier fleet left: after it the reader starts at 1, whatever a standing handoff names. A succession, a resume, a takeover and a hand `watch start` keep the log, so a successor keeps the cursor its handoff names. Never launch a second follow merely to receive events.

## Claim

The runtime is the one reader of the claim. Run this after each delivery and each expiry:

```bash
.agents/skills/orch/scripts/orch-runtime watch status --fleet
```

`result.claim` carries the claim's `pid`, `start`, `pane`, `origin`, `cwd` and `standing`; `result.due` each duty's next due time; `result.log` the log's path; and `result.events` the last line's number.

- `standing` `live` is the watch.
- `gone`, or no claim, is no live watch. A session the fleet state records as its overseer then starts the watch as [takeover § 2](../workflows/oversee-takeover.md#watch-reader) states.
- `unreadable` is a failed read, its `cause` in the reply; a refusal with a keyed line is a failed read too. Report either and start nothing.
- A live claim from another pane belongs to that pane: read the fleet's current controller record before any recovery.

Do not replace a watch because a follow ended.

## Repeat watch

The bound controller's turn end checks that its follow can wake it. It refuses once with `lane-mail-check: wake=unarmed`, naming the start command, when a live watch's follow does not run on a reader whose `watch.log` links to the watch's log, and once with `lane-mail-check: wake=unwatched` when the follow runs on a harness that starts no turn on background output; the continued turn is told and passes. Re-arm with `sh "[RUN_DIR]/follow.sh" "[RUN_DIR]/watch.log" [NEXT_LINE]` from the next unhandled line. The check reads the claim through the runtime and starts no process; what it cannot judge it says under its own key, and the turn goes on.

Whatever the harness, the watch types one line naming the follow's start command into an idle overseer whose follow has ended while the log holds lines at or past its start, confirmed by a new user turn.

```sh
n=$2
tail -n "+$n" -F "$1" | while IFS= read -r line; do printf '%s: %s\n' "$n" "$line"; n=$((n + 1)); done
```

The shell `read` loop numbers each line as it arrives. `awk` is not used: `mawk` fills its input buffer before it acts on a line, holding back lines already written.

| Harness | Wake | Re-arm |
|---|---|---|
| Claude Code | `Monitor` on the numbered follow, `timeout_ms` at its maximum. | At each expiry or stop, from the line after the last number delivered. |
| Codex | `write_stdin` polls on a follow: [codex-runtime.md § Standing watch](codex-runtime.md#standing-watch). | Poll again once each poll's output is handled. |
| Pi | `bg_task` output wakes on a follow: [pi-runtime.md § Standing watch (Pi)](pi-runtime.md#standing-watch-pi). | Respawn in the cases its Re-arm and Exit rows name. |
| Copilot CLI | § Single passes is this harness's standing follow. Run each pass as a sync-mode shell call with `initial_wait` 520 seconds, never in async mode. On Copilot CLI 1.0.114, an async pass's exit woke no turn once Autopilot ended, and a sync pass that outlived its wait woke the session at its exit (measured by the kendex Jarvis session on 2026-11-18). A call that returns at its wait with no line leaves its pass running: start no second pass, because that pass's exit wakes the session. A background follow's exit starts a new turn only after a turn that ended without `Task complete`, so never end a turn with `Task complete` while overseeing; the watch's typed line is the net under it. Measured on Copilot CLI 1.0.112 with autopilot. | Start the next pass after each pass exits. |

## Single passes

Use single passes on a harness that wakes only when a background command exits. Each pass reads new log lines; it starts no watch. Use the reader directory, link and cursor of § Reader directory, and save this follow as `[RUN_DIR]/follow.sh`:

```sh
n=$2
remaining=6300
while :; do
  lines="$(
    sed -n "${n},\$p" "$1" | while IFS= read -r line; do
      printf '%s: %s\n' "$n" "$line"; n=$((n + 1))
    done
  )" || exit 2
  if [ -n "$lines" ]; then printf '%s\n' "$lines"; exit 0; fi
  [ "$remaining" -gt 0 ] || exit 0
  sleep 1 || exit 2
  remaining=$((remaining - 1))
done
```

The quiet bound, 6300 seconds, is above the watch's default heartbeat of 6000 seconds (`--max-loops` 25 × `--interval` 240), so while the watch lives a pass ends on a line. The bound is also above a Copilot CLI call's 520-second wait, so a quiet call returns at its wait's end, never earlier.

1. Run the follow as the harness's background command, in the mode its § Repeat watch row names. Its exit wakes the session.
2. Handle each numbered line, then start the next pass after the last line handled.
3. A quiet expiry is rare: it means the watch missed its heartbeat. Read the claim and `oversee-watch.err` as § Claim directs before any recovery, keep the next unhandled line unchanged, and start the next pass.

Between deliveries the detached watch keeps judging the overseer's pane for death and wall.

## Stop

Run this from the overseer's checkout. It asks the claimed runner to stop and waits for the claim's release, answering `released` with the runner's identity, or `none` where no live claim stands. Report a refusal (`watch-stop-timeout`, `watch-claim-unreadable`) with its keyed line. Then start no further follow or pass.

```bash
.agents/skills/orch/scripts/orch-runtime watch stop --fleet
```

The [oversee.md § 5](../workflows/oversee.md#5-stop) handoff names the follow in force, its re-arm rule, `[RUN_DIR]` and the next log line. After a stop it names the watch `stopped` with its `[RUN_DIR]`, and no later session resumes or relaunches that watch.

## Lane mailbox monitor

A lane whose harness has an Arm in the table below arms one standing monitor on its own mailbox as its first step, from its worktree and on its own host, a hosted lane inside its sandbox. The launch closes every brief of such a lane with the line that tells it to; the overseer writes none.

- The monitor runs `.agents/skills/mailbox/scripts/lane-mail watch --item [ISSUE_ID]`, which announces unread mail, answers no wait has read included, on lines opening `lane-mail: mail=[ISSUE_ID]`; `lane-mail --help` owns when it announces.
- Each announcement wakes an idle lane. The woken turn runs the `lane-mail inbox` command printed under it and acts on every envelope it prints, answers and directives alike.
- The ask gate's `lane-mail wait` hands earlier unread envelopes to the lane on stderr before it advances the read cursor past the answer it prints on stdout. Act on those envelopes; the watch and the inbox do not hand them over again.
- A watch that exits with status 2 refused, its keyed `lane-mail:` line on stderr. Never re-arm a refused watch blind: run `lane-mail inbox --item [ISSUE_ID]` once, send that keyed line to the overseer with `lane-mail notice`, and re-arm once the cause it names is fixed.

Every poll rewrites the mailbox's `to-lane.watch`, and a `lane-mail send` receipt reads it as `monitor=live` or `monitor=none`. The overseer wakes no lane on the receipt: the watch's wake duty types a running lane read idle with mail unread ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)). A Claude Code lane reads `none` while its monitor is not running. A Copilot CLI lane's `none` is a `--once` watch that announced and is not yet re-armed, or one never armed; the re-armed watch announces what still stands unread. A Pi lane runs no watch, so its receipt always reads `none`. A directive the watch reports `directive-unread` on a lane the wake does not reach takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver).

| Harness | Arm | Re-arm |
|---|---|---|
| Claude Code | `Monitor` on the watch command, `timeout_ms` at its maximum. | At its expiry, or after the lane stopped it. Status 2 is a refusal. |
| Codex | None: Codex starts no turn for output that arrives after its turn ended. The wake duty types the lane; otherwise its mail waits for its next turn ([codex-runtime.md § Lane mailbox](codex-runtime.md#lane-mailbox)). | None. |
| Pi | None: the `pi-hooks` mail wake starts a turn in the idle lane when unread mail lands ([pi-runtime.md § Lane mailbox wake (Pi)](pi-runtime.md#lane-mailbox-wake-pi)). | None. |
| Copilot CLI | The watch command with `--once`, run as a background shell command: it exits 0 at its first announcement, and that exit starts a new turn in the idle session (measured on Copilot CLI 1.0.88 by the kendex Jarvis session on 2026-09-29). The lane also reads mail at the hook points below and at its `lane-mail inbox` wait points ([copilot-runtime.md § Wake and lane mail](copilot-runtime.md#wake-and-lane-mail)). | After each exit 0, once the `lane-mail inbox` command it printed has run; the fresh watch announces what still stands unread. Status 2 is a refusal. |

The prompt hook hands Claude Code, Codex and Copilot CLI lanes unread mail and opens their local turn row. Claude Code and Codex acknowledge written context; Copilot CLI leaves it unread. Beside its watch, a Copilot CLI lane is handed mail by its hooks: at its session start and at each prompt it is handed (`lane-mail-start`, `lane-mail-prompt`), after each tool call (`lane-mail-deliver`), at its turn end (`lane-mail-check`), and at its next tool call while a halt stands.

- A Copilot tool call names no agent, so mail is handed after one, and marked read, only where the call's session is a lead session the hook recorded at its session start or at a turn end its own transcript proved. A custom subagent's call, measured on Copilot CLI 1.0.88 carrying its own session id, which nothing recorded, is handed nothing, and its halt refusal names no command: the lead's turn end names the read that clears it.
- Whether a built-in task-tool subagent's calls carry their own session id or the lead's is a pending live-lane proof. One whose calls carry the lead's is read as the lead: it is handed the lead's mail after its calls, which marks it read, and under a halt it is shown the read that clears it.
- `tools/harness-smoke --only copilot --copilot-interactive` measured session-start context, typed print and interactive prompt context, and turn-end continuation on Copilot CLI 1.0.91 against silent-hook controls. That version can also run userPromptSubmitted on a background-command completion and discard its context, so the prompt hook leaves mail unread for the inbox or another delivery point. A typed prompt can show context that the next delivery repeats.
- Copilot also runs the `hooks` entries of `.claude/settings.json`. The lane-mail registrations kendex writes there exit 0 before their script in a Copilot hook process, as measured on Copilot CLI 1.0.88 (kendex's `docs/adapters/claude.md` § Cross-reads), leaving the `.github/hooks` copies the one reader. A copy registered there by hand runs, reads the payload's `timestamp` as a Copilot call and passes it silently (the turn-end check's payload reading, `skills/orch/runtime/src/turnend/payload.rs`).
- The lead's turn end is the agentStop naming a transcript in the session's own `session-state/<session-id>/` directory. Copilot CLI 1.0.88 also fires agentStop at a custom subagent's end, with the subagent's own session id and the lead's transcript, which that rule reads as a subagent's.
