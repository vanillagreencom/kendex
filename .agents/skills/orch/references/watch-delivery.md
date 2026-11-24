# Watch delivery

Read when an overseer starts, follows or stops the fleet watch, and when a lane arms its mailbox monitor. Read § Stop only at [oversee.md § 5](../workflows/oversee.md#5-stop). A lane reads § Lane mailbox monitor from [skill-rules.md § Lane mail](skill-rules.md#lane-mail).

Oversight stands from the watch's first launch until [oversee.md § 5](../workflows/oversee.md#5-stop). Every watch line reaches this session as the watch writes it. Where the harness has no asynchronous wake, the turn is the wait:

- Hold a blocking follow of the log.
- Re-arm it on every return.
- Never end the turn while any lane record is `running`.

## The watch

The watch is the runtime's standing scheduler, `orch-runtime watch run`.

- A controller that `start-controller` opens has its watch from the start: the request carries the watch's words.
- A session that `orch-runtime register --fleet` recorded, with no live claim, starts the watch once from its own pane with the block [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) states.
- The watch outlives the session that started it, a succession, and a death or wall recovery.
- It also outlives an update to its own code: it replaces its program in place, keeping its claim and log ([oversee-events.md § `watch-replaced`](oversee-events.md#watch-replaced)).
- Nothing hands it over; a successor follows the same log.

Follow the watch's log. Never start a second watch on the same fleet state.

- A harness that delivers log lines as they arrive, or holds a blocking follow inside its turn, uses § Repeat watch.
- A harness whose only wake is a background command's exit uses § Single passes.

## Reader directory

The log is `oversee-watch.log` beside the fleet state. `oversee-watch.err` beside it holds the runner's stderr, including each duty failure's cause under its `watch-step-failed` words.

1. From the watch claim's working directory, create a fresh reader directory with `mktemp -d tmp/waiter.XXXXXX`. Use its absolute path as `[RUN_DIR]`. The turn-end check and the wake duty find the follow by this path.
2. Link `[RUN_DIR]/watch.log` to the log.
3. Save the follow of § Repeat watch or § Single passes as `[RUN_DIR]/follow.sh`.
4. Follow with `sh "[RUN_DIR]/follow.sh" "[RUN_DIR]/watch.log" [NEXT_LINE]`, starting after the last numbered line handled.

The retention duty removes a reader folder once nothing uses it, as [workflow-state.md § Scratch](../schemas/workflow-state.md#scratch) states. The newest one on the watch's log stays as the live follow's.

A fleet's first start, a `start-controller` with no `resume`, empties the log an earlier fleet left. After it the reader starts at 1, whatever a standing handoff names. A succession, a resume, a takeover and a hand `watch start` keep the log, so a successor keeps the cursor its handoff names. Never launch a second follow merely to receive events.

## Claim

The runtime is the one reader of the claim. Run this after each delivery and each expiry:

```bash
.agents/skills/orch/scripts/orch-runtime watch status --fleet
```

Read `result.claim.standing`:

- `live` is the watch.
- `gone`, or no claim, is no live watch. A session the fleet state records as its overseer then starts the watch as [takeover § 2](../workflows/oversee-takeover.md#watch-reader) states.
- `unreadable` is a failed read, its `cause` in the reply. A refusal with a keyed line is a failed read too. Report either and start nothing.
- A live claim from another pane belongs to that pane: read the fleet's current controller record before any recovery.

Do not replace a watch because a follow ended.

## Repeat watch

The bound controller's turn end checks that its follow can wake it, and refuses once when it cannot (`lane-mail-check: wake=unarmed` or `wake=unwatched`). Then re-arm with `sh "[RUN_DIR]/follow.sh" "[RUN_DIR]/watch.log" [NEXT_LINE]` from the next unhandled line.

On every harness, the watch types the follow's start command into an idle overseer whose follow has ended with log lines unhandled: the `overseer-follow` target of [oversee-events.md § `wake-delivered`, `wake-unconfirmed`, `wake-limit`](oversee-events.md#wake-delivered-wake-unconfirmed-wake-limit).

```sh
n=$2
tail -n "+$n" -F "$1" | while IFS= read -r line; do printf '%s: %s\n' "$n" "$line"; n=$((n + 1)); done
```

The shell `read` loop numbers each line as it arrives. Do not use `awk`: `mawk` fills its input buffer before it acts on a line, and holds back lines already written.

| Harness | Wake | Re-arm |
|---|---|---|
| Claude Code | `Monitor` on the numbered follow, `timeout_ms` at its maximum. | At each expiry or stop, from the line after the last number delivered. |
| Codex | `write_stdin` polls on a follow: [codex-runtime.md § Standing watch](codex-runtime.md#standing-watch). | Poll again once each poll's output is handled. |
| Pi | `bg_task` output wakes on a follow: [pi-runtime.md § Standing watch (Pi)](pi-runtime.md#standing-watch-pi). | Respawn in the cases its Re-arm and Exit rows name. |
| Copilot CLI | § Single passes, run as the list below says. | Start the next pass after each pass exits. |

Copilot CLI runs § Single passes as its standing follow:

- Run each pass as a sync-mode shell call with `initial_wait` 520 seconds, never in async mode: only an async call can take `detach: true`.
- The CLI can return the call before its wait. A call that returns with no line leaves its pass running, attached, and the pass's quiet expiry, longer than the wait, keeps it running. Start no second pass.
- While Autopilot runs, it waits on the attached pass, and the pass's exit starts a new turn.
- After Autopilot stops, a pass's exit starts no turn: the CLI holds its result for the next typed message.
- Autopilot stops at `Task complete`, and at its continuation limit when no attached pass runs, as when the pass is detached. So never call `Task complete` while overseeing; the watch's typed line delivers a held result.
- Measured on Copilot CLI 1.0.114 with autopilot on 2026-11-21: attached async passes and sync passes that outlived their wait each started a turn within 4 seconds of their exit; a detached async pass, and async and sync passes running at `Task complete`, had their exit held; a 520-second wait returned after 266 to 267 seconds.

## Single passes

Use single passes on a harness that wakes only when a background command exits. Each pass reads new log lines and starts no watch. Use the reader directory, link and cursor of § Reader directory, and save this follow as `[RUN_DIR]/follow.sh`:

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

1. Run the follow as the harness's background command, in the mode its § Repeat watch row names. Its exit wakes the session.
2. Handle each numbered line, then start the next pass after the last line handled.
3. A quiet expiry is rare: it means the watch missed its heartbeat. Read the claim and `oversee-watch.err` as § Claim directs before any recovery. Keep the next unhandled line unchanged, and start the next pass.

## Stop

Run this from the overseer's checkout. It asks the claimed runner to stop and waits for the claim's release.

Where the claimed runner is already dead, the stop removes its claim and any stop request, and replies `"claim": "removed"`. No later start reads that claim as a watch to bring back. A claim that a new runner wrote after the stop read the dead one stays.

- Report a refusal with its keyed line.
- Then start no further follow or pass.

```bash
.agents/skills/orch/scripts/orch-runtime watch stop --fleet
```

After a stop, the [oversee.md § 5](../workflows/oversee.md#5-stop) handoff's Watch line ([communication-modes.md § Handoff](communication-modes.md#handoff)) names the watch `stopped` with its `[RUN_DIR]`. No later session resumes or relaunches that watch.

## Lane mailbox monitor

A lane whose harness has an Arm in the table below arms one standing monitor on its own mailbox as its first step. It arms it from its worktree on its own host; a hosted lane arms it inside its sandbox. The launch closes every brief of such a lane with the line that tells it to ([lane-directive.md § Brief file](lane-directive.md#brief-file)).

- The monitor runs `.agents/skills/mailbox/scripts/lane-mail watch --item [ISSUE_ID]`. It announces unread mail, including answers no wait has read, on lines opening `lane-mail: mail=[ISSUE_ID]`. `lane-mail --help` owns when it announces.
- Each announcement wakes an idle lane. The woken turn runs the `lane-mail inbox` command printed under it, and acts on every envelope it prints, answers and directives alike.
- The ask gate's `lane-mail wait` hands earlier unread envelopes to the lane on stderr before it advances the read cursor past the answer it prints on stdout. Act on those envelopes; the watch and the inbox do not hand them over again.
- A watch that exits with status 2 refused, its keyed `lane-mail:` line on stderr. Never re-arm a refused watch blind:
  1. Run `lane-mail inbox --item [ISSUE_ID]` once.
  2. Send that keyed line to the overseer with `lane-mail notice`.
  3. Re-arm once the cause it names is fixed.

The overseer wakes no lane on a `lane-mail send` receipt's `monitor=` word: the watch's wake duty types a running lane read idle with mail unread ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)).

| Harness | Arm | Re-arm |
|---|---|---|
| Claude Code | `Monitor` on the watch command, `timeout_ms` at its maximum. | At its expiry, or after the lane stopped it. Status 2 is a refusal. |
| Codex | None: [codex-runtime.md § Lane mailbox](codex-runtime.md#lane-mailbox). | None. |
| Pi | None: the `pi-hooks` mail wake starts a turn in the idle lane when unread mail lands ([pi-runtime.md § Lane mailbox wake (Pi)](pi-runtime.md#lane-mailbox-wake-pi)). | None. |
| Copilot CLI | The watch command with `--once`, run as a background shell command. It exits 0 at its first announcement, and that exit starts a new turn in the idle session (measured on Copilot CLI 1.0.88). The lane also reads mail at its hook points and its `lane-mail inbox` wait points ([copilot-runtime.md § Wake and lane mail](copilot-runtime.md#wake-and-lane-mail)). | After each exit 0, once the `lane-mail inbox` command it printed has run; the fresh watch announces what still stands unread. Status 2 is a refusal. |

The prompt hook hands Claude Code, Codex and Copilot CLI lanes unread mail, and opens their local turn row.

- Claude Code and Codex acknowledge written context.
- Copilot CLI leaves it unread, and there a typed prompt can show context that the next delivery repeats.
- Beside its watch, a Copilot CLI lane's hooks hand it mail, only in a recorded lead session. [copilot-runtime.md § Wake and lane mail](copilot-runtime.md#wake-and-lane-mail) names each hook point. [copilot-runtime.md § Unproved behaviour](copilot-runtime.md#unproved-behaviour) holds the pending proof for a built-in subagent's calls.
- A custom subagent's halt refusal names no command: the lead's turn end names the read that clears it.
- Copilot also runs the `hooks` entries of `.claude/settings.json`. The lane-mail registrations kendex writes there exit 0 before their script in a Copilot hook process (measured on Copilot CLI 1.0.88; kendex's `docs/adapters/claude.md` § Cross-reads). The `.github/hooks` copies stay the one reader. A copy registered there by hand runs, reads the payload's `timestamp` as a Copilot call, and passes it silently (the turn-end check's payload reading, `skills/orch/runtime/src/turnend/payload.rs`).
