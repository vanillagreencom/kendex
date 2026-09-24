# Watch delivery

Load from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) before launching the repeat watch.

Oversight stands from the first watch launch until oversee.md § 5 Stop, and every watch line reaches this session as it is written, through the runtime's own event mechanism. Where the runtime has no asynchronous wake, the turn is the wait: hold a blocking follow of the watch log, re-arm it on every return, and never end the turn while any lane record is `running`.

Launch the repeat command once from the overseer's own pane by [Waiter launch](waiter-launch.md) § Launch, run path `[RUN_DIR]/watch`: output in `[RUN_DIR]/watch.log`, status in `[RUN_DIR]/watch.exit`. `[NEXT_LINE]` starts at 1 in each fresh `[RUN_DIR]`. Save the numbered follow below as `[RUN_DIR]/follow.sh` with the harness file-write tool. Every harness follows the log with `sh [RUN_DIR]/follow.sh [RUN_DIR]/watch.log [NEXT_LINE]`, one simple command that prefixes each line with its number. Arm every follow from the line after the last number handled. The watch is the launch shell that names its run path, and that shell leads the process group of everything the watch started. One read finds it, `pgrep -f '[RUN_DIR]/watch [.]agents/skills/orch/scripts/oversee-watch'`, with the watch command spelled as [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) launches it: the bracket keeps the read from matching the shell that runs it, and a pid it prints is that group. A pid file would stay behind after its process ended, and a reused pid could then name some other process group.

After each delivery and expiry, run that read first, then `test -s [RUN_DIR]/watch.exit`. A printed pid is a live watch. With no pid, a nonempty file ends the watch under the stop and restart rules of oversee.md § 4. With no pid and an empty file, the watch died without writing its status, killed together with its launch shell: report it and launch a new one in a fresh `[RUN_DIR]` under the same restart rule.

To stop the watch, run the read, send `kill -TERM -- -[PID]` to the group it proved, then run the read again until it prints nothing. When the first read prints nothing, there is no watch to stop.

| Harness | Wake mechanism | Re-arm |
|---------|----------------|--------|
| Claude Code | `Monitor` on the numbered follow, `timeout_ms` at its maximum. | At each expiry or stop, from the line after the last number delivered. |
| Codex | `write_stdin` polls on a follow: [codex-runtime.md § Standing watch](codex-runtime.md#standing-watch). | Poll again once each poll's output is handled. |
| Pi | `bg_task` output wakes on a follow: [pi-runtime.md § Standing watch (Pi)](pi-runtime.md#standing-watch-pi). | Respawn in the cases its Re-arm and Exit rows name. |
| Wakes only at a background command's exit | Single passes: no `--repeat`, no detach, each pass a background command. Nothing reports `overseer-dead`. | Next pass after every line is handled, with `--skip-lane [WINDOW]` per window reported `window-gone` until tmux lists it again. |

```sh
n=$2
tail -n "+$n" -F "$1" | while IFS= read -r line; do printf '%s: %s\n' "$n" "$line"; n=$((n + 1)); done
```

The shell `read` loop numbers each line as it arrives; `awk` is not used because `mawk` fills its input buffer before it acts on a line, holding back lines already written.

The [oversee.md § 5](../workflows/oversee.md#5-stop) handoff names the mechanism in force, its re-arm rule, `[RUN_DIR]` and the next log line. After that Stop it names the watch `stopped` and its `[RUN_DIR]`, and no later session resumes or relaunches that watch.
