# Watch delivery

Load from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) before launching the repeat watch.

Oversight stands from the first watch launch until oversee.md § 5 Stop, and every watch line reaches this session as it is written, through the runtime's own event mechanism. Where the runtime has no asynchronous wake, the turn is the wait: hold a blocking follow of the watch log, re-arm it on every return, and never end the turn while any lane record is `running`.

Launch the repeat command once from the overseer's own pane by [Waiter launch](waiter-launch.md) § Launch, run path `[RUN_DIR]/watch`: output in `[RUN_DIR]/watch.log`, status in `[RUN_DIR]/watch.exit`. `[NEXT_LINE]` starts at 1 in each fresh `[RUN_DIR]`. Save the numbered follow below as `[RUN_DIR]/follow.sh` with the harness file-write tool. Every harness follows the log with `sh "[RUN_DIR]/follow.sh" "[RUN_DIR]/watch.log" [NEXT_LINE]`, one simple command that prefixes each line with its number. Arm every follow from the line after the last number handled. The watch is the launch shell, whose argv carries the run path as its own word, and that shell leads the process group of everything the watch started. One read finds it, `pgrep -f 'waiter[.][RUN_ID]/watc[h] '`, `[RUN_ID]` being the letters and digits `mktemp` put after `waiter.` in `[RUN_DIR]`, whatever spelling launched the command: the name holds no regex character where the checkout path may, the bracket keeps the read from matching the shell that runs it, the trailing space keeps it off `watch.log`, and a pid it prints is that group. Exit 0 is a live watch and exit 1 is no watch. Any other status is a failed read: report it with pgrep's stderr, and launch, stop or relaunch nothing on it. A pid file would stay behind after its process ended, and a reused pid could then name some other process group.

After each delivery and expiry, run that read first, then `test -s "[RUN_DIR]/watch.exit"`. A printed pid is a live watch. With no pid, a nonempty file ends the watch: `stopped` is the mark the stop below writes and ends oversight with no restart, and any other value follows the stop and restart rules of [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance). With no pid and an empty file, the watch died without writing its status, killed together with its launch shell: report it and launch a new one in a fresh `[RUN_DIR]` under the same restart rule, then end the current follow and arm a new one on the new `[RUN_DIR]/watch.log` from line 1 (on Pi, stop the kept task and keep the new id). A follow is re-armed only while these checks read a live watch.

To stop the watch, write `stopped` into `[RUN_DIR]/watch.exit` with the harness file-write tool, then run the read, send `kill -TERM -- -[PID]` to the group it proved, and run the read again until it exits 1. The kill ends the launch shell before it writes a status, so the mark written first is what every later check reads. When the first read exits 1, there is no watch to signal.

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
