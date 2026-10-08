# Watch delivery

Load from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) before launching the watch, and from [skill-rules.md § Coordination](skill-rules.md#coordination), Lane mail, before a lane arms its mailbox monitor.

Oversight stands from the first watch launch until oversee.md § 5 Stop, and every watch line reaches this session as it is written, through the runtime's own event mechanism. Where the runtime has no asynchronous wake, the turn is the wait: hold a blocking follow of the watch log, re-arm it on every return, and never end the turn while any lane record is `running`.

`oversee launch` and `oversee-succeed` start the repeat watch through the orch job runner. The watch serves the new pane and survives the session's exit. A failed runner launch refuses the overseer launch. A running watch is handed to the new pane by the succession helper. The retained command includes its script, directory and watch arguments after the old claim ends. Automatic death and wall recovery leave a watch for the successor.

Read that watch's log without starting another watch on the same fleet state. A harness that delivers log lines as they arrive, or holds a blocking follow inside the turn, uses § Repeat watch. A harness whose only wake is a background command's exit uses § Single passes.

## Repeat watch

The registered overseer's lead turn end refuses with `lane-mail-check: wake=unarmed` when the repeat watch is live but its follow is not running on the watch claim's cwd. Re-arm with `sh "[RUN_DIR]/follow.sh" "[RUN_DIR]/watch.log" [NEXT_LINE]` from the next unhandled line. The hook starts no process.

Read the `log` field of the launch's `watch-started` line. After a handover, the stdout log is `oversee-watch.log` beside the fleet state. Read `oversee-watch.err` beside it for restart failures. Create a fresh reader directory with `mktemp -d tmp/waiter.XXXXXX` from the watch claim's cwd. Use its absolute path as `[RUN_DIR]`. Link `[RUN_DIR]/watch.log` to that stdout log. Save the numbered follow below as `[RUN_DIR]/follow.sh`. The reader directory uses the path the turn-end wake check recognizes. It owns no watch claim.

Every harness follows with `sh "[RUN_DIR]/follow.sh" "[RUN_DIR]/watch.log" [NEXT_LINE]`. `[NEXT_LINE]` starts at 1 in each fresh reader. A fresh overseer launch with no live watch clears both retained logs before starting its watch. Each follow starts after the last numbered line handled. The detached watch appends to the same log across succession and recovery, so the successor keeps the cursor from the handoff. Read the runner record and the live watch claim beside the fleet state through `scripts/lib/watch-pid.sh` and `scripts/lib/job-unit.sh`. Never launch a second repeat command merely to receive events.

For a hand-opened session with no live watch claim, launch the workflow's repeat command once by [Waiter launch](waiter-launch.md) § Launch. That launch uses `[RUN_DIR]/watch`, `[RUN_DIR]/watch.log`, `[RUN_DIR]/watch.exit` and `[RUN_DIR]/watch.runner`, as the steps below specify.

For a watch the overseer launcher started, run this claim read after each delivery and expiry. It prints the live watch's `[PID]`, also used by the stop command below.

```bash
bash -c '. "$1" || exit 3; watch_pid_live "$2" && printf "%s\n" "$WATCH_PID"' _ .agents/skills/orch/scripts/lib/watch-pid.sh "[OVERSEE_STATE]"
```

Exit 0 is a live claim. Exit 1 is no live claim. Any other status is a failed read: report its stderr and start nothing. A live claim from another pane belongs to that pane; read the fleet's current overseer record before taking any recovery action. With no claim, follow [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance)'s stop and restart rules. Do not replace a watch merely because the follow ended. The watch log and error log stay beside the fleet state.

To stop a launcher-owned watch, use `[PID]` from that claim read. Run `.agents/skills/orch/scripts/lib/job-unit.sh stop-job "[OVERSEE_STATE_DIR]/oversee-watch.runner" [PID] '*oversee-watch*'`. The runner stops its exact unit or its verified process group. Report any failed stop with its `job-unit:` line.

For a hand-opened session's waiter launch, find its group with `pgrep -f 'waiter[.][RUN_ID]/watc[h] '`. Exit 0 is a live watch and exit 1 is no watch. Report any other status and start nothing. Run `test -s "[RUN_DIR]/watch.exit"` after each delivery and expiry. With no pid, read that file: `stopped` ends oversight, another value follows the workflow's stop and restart rules, and an empty file means the watch died without a verdict. To stop that watch, write `stopped` into `[RUN_DIR]/watch.exit`, then stop its verified group with `.agents/skills/orch/scripts/lib/job-unit.sh stop-job "[RUN_DIR]/watch.runner" [PID] '*waiter.[RUN_ID]/watch *'`.

| Harness | Wake mechanism | Re-arm |
|---------|----------------|--------|
| Claude Code | `Monitor` on the numbered follow, `timeout_ms` at its maximum. | At each expiry or stop, from the line after the last number delivered. |
| Codex | `write_stdin` polls on a follow: [codex-runtime.md § Standing watch](codex-runtime.md#standing-watch). | Poll again once each poll's output is handled. |
| Pi | `bg_task` output wakes on a follow: [pi-runtime.md § Standing watch (Pi)](pi-runtime.md#standing-watch-pi). | Respawn in the cases its Re-arm and Exit rows name. |

```sh
n=$2
tail -n "+$n" -F "$1" | while IFS= read -r line; do printf '%s: %s\n' "$n" "$line"; n=$((n + 1)); done
```

The shell `read` loop numbers each line as it arrives; `awk` is not used because `mawk` fills its input buffer before it acts on a line, holding back lines already written.

The [oversee.md § 5](../workflows/oversee.md#5-stop) handoff names the mechanism in force, its re-arm rule, `[RUN_DIR]` and the next log line. After that Stop it names the watch `stopped` and its `[RUN_DIR]`, and no later session resumes or relaunches that watch.

## Single passes

Keep single-pass delivery for a harness that wakes only when a background command exits. When a detached repeat watch owns the fleet state, each pass reads new log lines instead of running `oversee-watch` again. Use the same reader directory, log link and numbered cursor as § Repeat watch. Save this version as `[RUN_DIR]/follow.sh`:

```sh
n=$2
remaining=30
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

Run the follow as the harness's background command. Its exit wakes the session after new complete lines or a quiet expiry. After each return, read the claim and error log as § Repeat watch directs before any recovery action. A quiet return keeps the next unhandled line unchanged. Handle each numbered line and start the next pass after the last line handled. The detached watch keeps judging the overseer's pane for death and wall between deliveries. At Stop, stop that watch through its runner record and start no further reader pass.

A hand-opened fleet with no repeat claim may still run the workflow command without `--repeat` as its background command. Its exit is the wake. This mode alone cannot report the session's death. Do not use it when a detached watch owns the state.

## Lane mailbox monitor

A lane whose harness has an Arm below arms one standing monitor on its own mailbox as its first step, from its worktree and on its own host, a hosted lane inside its sandbox. The monitor runs `.agents/skills/orch/scripts/lane-mail watch --item [ISSUE_ID]`, which announces unread mail, including answers no wait has read, on lines opening `lane-mail: mail=[ISSUE_ID]`; `lane-mail --help` owns when it announces. Each announcement wakes an idle lane, and the woken turn runs the `lane-mail inbox` command printed under it and acts on every envelope it prints, answers and directives alike, as its text directs. The ask gate's `lane-mail wait` hands preceding unread envelopes to the lane on stderr before advancing the read cursor past the answer it returns on stdout. Act on those envelopes as their text directs. The watch and inbox do not hand that mail over again. Every poll rewrites the mailbox's `to-lane.watch`, and a `lane-mail send` receipt reads it as `monitor=live` or `monitor=none`; the overseer wakes a Claude Code or Codex lane only on `monitor=none` ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)), and a lane on any other harness never. A Pi lane is sent no wake on the receipt: it runs no watch, so its receipt always reads `monitor=none` while the `pi-hooks` mail wake starts its turn, and a directive the watch reports `directive-unread` on any Pi lane takes [lane-reach.md](lane-reach.md). A Copilot CLI lane's `monitor=none` is a `--once` watch that announced and is not yet re-armed, or one never armed: the re-armed watch announces what still stands unread, so the overseer sends it no wake. That the watch's exit starts a Copilot turn, the premise of its Arm row below, is measured on Copilot CLI 1.0.88 by the kendex master session on 2026-09-29; the overseer sends a Copilot CLI lane no wake, so a directive the watch reports `directive-unread` on one takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver); a lane the wake refuses while its session runs, every hosted lane included, takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver). A lane whose harness has no Arm below never has a monitor. A Claude Code lane reads `none` while its monitor is not running.

The launch brief of a lane whose harness has an Arm below adds this line ([oversee.md § 3](../workflows/oversee.md#3-launch)): "As your first step, arm the mailbox monitor `lane-mail watch --item [ISSUE_ID]` per watch-delivery.md § Lane mailbox monitor, re-arm it at each expiry, and run the `lane-mail inbox` command each of its announcements prints." A Copilot CLI lane's line names `lane-mail watch --once --item [ISSUE_ID]` and says to re-arm it after each exit. A Pi lane's brief and relaunch line carry no monitor arm line ([pi-runtime.md § Lane mailbox wake (Pi)](pi-runtime.md#lane-mailbox-wake-pi)).

A watch that exits with status 2 refused, and its keyed `lane-mail:` line is on its stderr. The lane never re-arms a refused watch blind: it runs `lane-mail inbox --item [ISSUE_ID]` once, sends that keyed line to the overseer with `lane-mail notice`, and re-arms once the cause the line names is fixed.

| Harness | Arm | Re-arm |
|---------|-----|--------|
| Claude Code | `Monitor` on the watch command, `timeout_ms` at its maximum. | At its expiry, or after the lane stopped it. An exit with status 2 is the refusal above. |
| Codex | None. Codex starts no turn for output that arrives after a turn ended, so the overseer wakes the lane: [codex-runtime.md § Lane mailbox](codex-runtime.md#lane-mailbox). | None. |
| Pi | No monitor. The `pi-hooks` mail wake starts a turn in the idle lane when unread mail, including an answer, lands ([pi-runtime.md § Lane mailbox wake (Pi)](pi-runtime.md#lane-mailbox-wake-pi)). | None. |
| Copilot CLI | The watch command with `--once`, run as a background shell command: it exits 0 at its first announcement, and that exit is the wake ([copilot-runtime.md § Wake and lane mail](copilot-runtime.md#wake-and-lane-mail)): a background command's exit starts a new turn in an idle Copilot session with no user message, measured on Copilot CLI 1.0.88 by the kendex master session on 2026-09-29. The paragraph above names the overseer's route for mail it does not wake. Beside the watch, the lane reads mail at its `lane-mail inbox` wait points, at its session start and at each prompt it is handed through the `lane-mail-start` and `lane-mail-prompt` hooks, after each tool call through the `lane-mail-deliver` hook, at its turn end through the `lane-mail-check` hook, and at its next tool call while a halt stands. A Copilot tool call names no agent, so mail is handed after one, and marked read, only where the call's session is a lead session the hook recorded at its session start or at a turn end its own transcript proved; a custom subagent's call, measured on Copilot CLI 1.0.88 carrying its own session id, which nothing recorded, is handed nothing, and its halt refusal names no command: the lead's turn end names the read that clears it. Whether a built-in task-tool subagent's calls carry their own session id or the lead's is a pending live-lane proof, and one whose calls carry the lead's is read as the lead, handed the lead's mail after its calls, which marks it read, and under a halt shown the read that clears it. `tools/harness-smoke --only copilot --copilot-interactive` measured session-start context, print and interactive prompt context, and turn-end continuation on Copilot CLI 1.0.91 against silent-hook controls. Copilot also runs the `hooks` entries of `.claude/settings.json`; the lane-mail registrations kendex writes there exit 0 before their script in a Copilot hook process, as measured on Copilot CLI 1.0.88 (kendex's `docs/adapters/claude.md` § Cross-reads), leaving the `.github/hooks` copies the one reader. A copy registered there by hand runs, reads the payload's `timestamp` as a Copilot call and passes it silently (`CALL_HARNESS`, `hooks/lane-mail-check.sh`). The lead's turn end is the agentStop naming a transcript in the session's own `session-state/<session-id>/` directory; Copilot CLI 1.0.88 also fires agentStop at a custom subagent's end, with the subagent's own session id and the lead's transcript, which that rule reads as a subagent's. | After each exit 0, once the `lane-mail inbox` command it printed has run; the fresh watch announces what still stands unread. An exit with status 2 is the refusal above. |
| OpenCode and others | None. No background wake starts a turn, and `open-terminal --wake` does not take these harnesses: the lane reads mail at its `lane-mail inbox` wait points, and the overseer sends no wake. | None. |
