# Waiter launch

Load from `submit-pr.md` or `merge-pr.md` before running `approval-wait`, `ci-wait` or `queue-wait`, and from `watch-delivery.md` before launching the repeat watch. Start each long waiter through the orch job runner, `.agents/skills/orch/scripts/lib/job-unit.sh`: a transient systemd user unit where a user manager answers, `setsid` elsewhere ([job-units.md](job-units.md)). Keep the lane active until its completion file arrives. Never start the waiter as a harness background command.

## Launch

Run from the worktree root. Create a fresh directory under the current worktree's `tmp/` with `mktemp -d tmp/waiter.XXXXXX`. Use its absolute path as `[RUN_DIR]`, and the letters and digits `mktemp` put after `waiter.` as `[RUN_ID]`. Each invocation, including a workflow-authorized retry, uses a fresh directory.

Use the harness file-write tool to save this script as `[RUN_DIR]/launch.sh`:

```sh
run_path=$1
shift
run_dir=${run_path%/*}
.agents/skills/orch/scripts/lib/job-unit.sh launch "${run_path##*/}-${run_dir##*/waiter.}" "$run_path.runner" -- sh -c 'sed -n "s/^line=//p" "$0.runner" > "$0.log"; "$@" >> "$0.log" 2>&1; printf "%s\n" "$?" > "$0.exit"' "$run_path" "$@" < /dev/null
```

The job is the launch shell, whose argv carries the run path as its own word and which leads the process group of everything the job starts. Its unit is `orch-[NAME]-[RUN_ID]-[PID].service`, `[NAME]` being the run path's last word (`wait` or `watch`) and `[PID]` the runner's own, so every launch, a takeover's among them, names a unit no other launch has. The unit sets no `RuntimeMaxSec`: each waiter ends on its own budget and the repeat watch runs until it is stopped. The runner records how the job runs in `[RUN_DIR]/[NAME].runner`, and the launch shell writes that record's runner line as the first line of `[RUN_DIR]/[NAME].log`: `runner=systemd unit=[UNIT]`, or a `runner=setsid` line naming why no unit was used.

A unit starts the job with every signal at its default. Where no user manager answers, the runner forks with `setsid -f` and not a trailing `&`, so the launcher adds no signal ignores of its own: a job that a non-interactive shell starts with `&` ignores INT and QUIT, which leaves a detached guard or waiter uninterruptible and makes its signal rows report false failures. There a signal the calling process already ignores stays ignored.

Invoke it as one foreground shell-tool command. Replace `[WAITER_COMMAND_AND_ARGS]` with the workflow's complete command, including any `env -u` prefixes. Preserve its polling interval, budget and output flags:

```bash
sh "[RUN_DIR]/launch.sh" "[RUN_DIR]/wait" [WAITER_COMMAND_AND_ARGS]
```

It prints the runner line and exits 0 once the job is started. Any other exit started nothing: report its `job-unit:` line, which names the cause (`missing-command commands=setsid` on a host with neither runner), and launch nothing on it.

Record `[RUN_DIR]/wait.exit` and `[RUN_DIR]/wait.log` in the lane's status. Launch once. A shell-tool return or timeout does not authorize another waiter.

## Completion

Use the harness's monitor or wait mechanism to check `test -s "[RUN_DIR]/wait.exit"` every 30 seconds. A missing or empty file means the waiter has no recorded exit. Keep waiting; never read that state as a verdict or start a duplicate waiter.

When the file is nonempty, read it and the log:

```bash
cat "[RUN_DIR]/wait.exit"
```

```bash
cat "[RUN_DIR]/wait.log"
```

The completion file contains the waiter's exit code. Route that code and the log's final result through the calling workflow; exit `5` has no result and takes the workflow's exit-5 route. A nonzero code stays nonzero. A confirmed stopped process with no completion file has no verdict; report the interruption and confirm that no waiter for this PR remains before any workflow-authorized retry. Never replace the waiter with manual GitHub polls or short foreground slices.
