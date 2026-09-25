# Watch delivery

Load from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) before launching the watch, and from [skill-rules.md § Coordination](skill-rules.md#coordination), Lane mail, before a lane arms its mailbox monitor.

Oversight stands from the first watch launch until oversee.md § 5 Stop, and every watch line reaches this session as it is written, through the runtime's own event mechanism. Where the runtime has no asynchronous wake, the turn is the wait: hold a blocking follow of the watch log, re-arm it on every return, and never end the turn while any lane record is `running`.

The harness picks the path before any launch. A harness that delivers a detached log's lines as they are written, or holds a blocking follow of that log inside the turn, runs § Repeat watch: the Claude Code, Codex and Pi rows below. A harness whose only wake is a background command's exit runs § Single passes, and nothing in § Repeat watch applies to it.

## Repeat watch

Launch the repeat command once from the overseer's own pane by [Waiter launch](waiter-launch.md) § Launch, run path `[RUN_DIR]/watch`: output in `[RUN_DIR]/watch.log`, status in `[RUN_DIR]/watch.exit`. `[NEXT_LINE]` starts at 1 in each fresh `[RUN_DIR]`. Save the numbered follow below as `[RUN_DIR]/follow.sh` with the harness file-write tool. Every harness follows the log with `sh "[RUN_DIR]/follow.sh" "[RUN_DIR]/watch.log" [NEXT_LINE]`, one simple command that prefixes each line with its number. Arm every follow from the line after the last number handled. The watch is the launch shell, whose argv carries the run path as its own word, and that shell leads the process group of everything the watch started. One read finds it, `pgrep -f 'waiter[.][RUN_ID]/watc[h] '`, `[RUN_ID]` being the letters and digits `mktemp` put after `waiter.` in `[RUN_DIR]`, whatever spelling launched the command: the name holds no regex character where the checkout path may, the bracket keeps the read from matching the shell that runs it, the trailing space keeps it off `watch.log`, and a pid it prints is that group. Exit 0 is a live watch and exit 1 is no watch. Any other status is a failed read: report it with pgrep's stderr, and launch, stop or relaunch nothing on it. The watch's own `oversee-watch.pid`, beside the fleet state, is its claim record for the refusals `oversee-watch --help` states, not this liveness read. After a self-succession `oversee-succeed` restarts the watch from the successor pane, and the successor's own launch here takes that watch over.

After each delivery and expiry, run that read first, then `test -s "[RUN_DIR]/watch.exit"`. A printed pid is a live watch. With no pid, a nonempty file ends the watch: `stopped` is the mark the stop below writes and ends oversight with no restart, and any other value follows the stop and restart rules of [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance). With no pid and an empty file, the watch died without writing its status, killed together with its launch shell: report it and launch a new one in a fresh `[RUN_DIR]` under the same restart rule, then end the current follow and arm a new one on the new `[RUN_DIR]/watch.log` from line 1 (on Pi, stop the kept pid's task and keep the new pid). A follow is re-armed only while these checks read a live watch.

To stop the watch, write `stopped` into `[RUN_DIR]/watch.exit` with the harness file-write tool, then run the read, send `kill -TERM -- -[PID]` to the group it proved, and run the read again until it exits 1. The kill ends the launch shell before it writes a status, so the mark written first is what every later check reads. When the first read exits 1, there is no watch to signal.

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

Run the oversee.md § 4 command without `--repeat`, as the harness's background command: no detach, no `[RUN_DIR]`, no follow, no process read. Its exit is the wake. Handle every line it printed, then start the next pass, with `--skip-lane [WINDOW]` per window reported `window-gone` until tmux lists it again. An exit the § 4 stop rules name ends the passes. Nothing reports `overseer-dead`, since no watch outlives the session. At § 5 Stop, start no further pass and stop a running one through the harness's own background-task control. The handoff's Watch row reads `single passes` alone, and a successor starts its own passes.

## Lane mailbox monitor

A lane whose harness has an Arm below arms one standing monitor on its own mailbox as its first step, from its worktree and on its own host, a hosted lane inside its sandbox. The monitor runs `.agents/skills/orch/scripts/lane-mail watch --item [ISSUE_ID]`, which announces unread mail other than answers on lines opening `lane-mail: mail=[ISSUE_ID]`; `lane-mail --help` owns when it announces. Each announcement wakes an idle lane, and the woken turn runs the `lane-mail inbox` command printed under it and acts on every directive it prints. An answer wakes nothing, so the ask gate's `lane-mail wait` keeps it. Every poll rewrites the mailbox's `to-lane.watch`, and a `lane-mail send` receipt reads it as `monitor=live` or `monitor=none`; the overseer wakes a Claude Code, Codex or Pi lane only on `monitor=none` ([oversee.md § Talking to a lane](../workflows/oversee.md#talking-to-a-lane)), and a lane on any other harness never. A lane whose harness has no Arm below never has a monitor, and a Claude Code or Pi lane reads `none` while its monitor is not running.

The launch brief of a lane whose harness has an Arm below adds this line ([oversee.md § 3](../workflows/oversee.md#3-launch)): "As your first step, arm the mailbox monitor `lane-mail watch --item [ISSUE_ID]` per watch-delivery.md § Lane mailbox monitor, re-arm it at each expiry, and run the `lane-mail inbox` command each of its announcements prints."

A watch that exits with status 2 refused, and its keyed `lane-mail:` line is on its stderr. The lane never re-arms a refused watch blind: it runs `lane-mail inbox --item [ISSUE_ID]` once, sends that keyed line to the overseer with `lane-mail notice`, and re-arms once the cause the line names is fixed.

| Harness | Arm | Re-arm |
|---------|-----|--------|
| Claude Code | `Monitor` on the watch command, `timeout_ms` at its maximum. | At its expiry, or after the lane stopped it. An exit with status 2 is the refusal above. |
| Codex | None. Codex starts no turn for output that arrives after a turn ended, so the overseer wakes the lane: [codex-runtime.md § Lane mailbox](codex-runtime.md#lane-mailbox). | None. |
| Pi | `bg_task` output wakes on the watch command: [pi-runtime.md § Lane mailbox monitor (Pi)](pi-runtime.md#lane-mailbox-monitor-pi). | Respawn in the cases its Re-arm and Exit rows name. |
| OpenCode and others | None. No background wake starts a turn, and `open-terminal --wake` does not take these harnesses: the lane reads mail at its `lane-mail inbox` wait points, and the overseer sends no wake. | None. |
