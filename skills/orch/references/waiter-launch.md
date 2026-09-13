# Waiter launch

Load from `submit-pr.md` or `merge-pr.md` before running `approval-wait`, `ci-wait` or `queue-wait`. Run each long waiter under `setsid`. Keep the lane active until its completion file arrives. Never start the waiter as a harness background command.

## Launch

Run `command -v setsid`. If it fails, report the missing dependency. Create a fresh directory under the current worktree's `tmp/` with `mktemp -d tmp/waiter.XXXXXX`. Use its absolute path as `[RUN_DIR]`. Each invocation, including a workflow-authorized retry, uses a fresh directory.

Use the harness file-write tool to save this script as `[RUN_DIR]/launch.sh`:

```sh
run_path=$1
shift
setsid sh -c '"$@" > "$0.log" 2>&1; printf "%s\n" "$?" > "$0.exit"' "$run_path" "$@" > /dev/null 2>&1 < /dev/null &
```

Invoke it as one foreground shell-tool command. Replace `[WAITER_COMMAND_AND_ARGS]` with the workflow's complete command, including any `env -u` prefixes. Preserve its polling interval, budget and output flags:

```bash
sh "[RUN_DIR]/launch.sh" "[RUN_DIR]/wait" [WAITER_COMMAND_AND_ARGS]
```

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

The completion file contains the waiter's exit code. Route that code and the log's final result through the calling workflow. A nonzero code stays nonzero. A confirmed stopped process with no completion file has no verdict; report the interruption and confirm that no waiter for this PR remains before any workflow-authorized retry. Never replace the waiter with manual GitHub polls or short foreground slices.
