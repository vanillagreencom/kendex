# Waiter launch

Read when launching a waiter for a review wait, a `verify-pr` call (`orch-runtime op`), `queue-watch`, `copilot-wait`, or a Codex watchdog or reviewer.

- Start each waiter through `orch-runtime launch-job` ([job-units.md](job-units.md)), never as a harness background command.
- A lane waits on mail through the wake, never on a waiter.

## Launch

1. From the worktree root, make a fresh directory with `mktemp -d tmp/waiter.XXXXXX`. Its absolute path is `[RUN_DIR]`, and the letters and digits after `waiter.` are `[RUN_ID]`. Every invocation takes a fresh directory, a workflow-authorized retry included.
   - The job never removes it, since its exit and log are the result read after it ends.
   - In the main checkout, the retention duty removes it once nothing uses it, as [workflow-state.md § Scratch](../schemas/workflow-state.md#scratch) states: its job has ended, nothing cites it, and its last write is past the retention.
2. Run the launch below as one foreground shell-tool command.
   - Replace `[WAITER_COMMAND_AND_ARGS]` with the workflow's complete command, its `env -u` prefixes included, and keep its polling interval, budget and output flags.
   - In a lane, `--owner` names the lane's item. A session that is no lane, and a subagent, leave `--owner` out.
   - No launch caps the waiter's time: a `verify-pr` or review call ends when the operation answers, `queue-watch` at its `--max-wait`, and `copilot-wait` at the bound [review-pr-comments.md § 1](../workflows/review-pr-comments.md#1-fetch-and-parse) states.
3. Read the exit.
   - 0: the waiter started, and the JSON reply carries its runner line and record.
   - 75: it may have started; keep `[RUN_DIR]`, wait on its completion by § Completion, and launch no second waiter for it.
   - 1: `job-launch-failed` with its `cause`; nothing started, so report the cause and launch nothing on it.
4. Record `[RUN_DIR]/wait.exit` and `[RUN_DIR]/wait.log` in the lane's status. Launch once: a shell-tool return or timeout authorizes no other waiter.

```bash
.agents/skills/orch/scripts/orch-runtime launch-job --name wait-[RUN_ID] --run [RUN_DIR]/wait --owner [ISSUE_ID] -- [WAITER_COMMAND_AND_ARGS] < /dev/null
```

### Run files

The launch writes `[RUN_DIR]/[WORD].runner`, the launcher's record. The job writes beside it `[WORD].log` (the runner line, then the command's output), `[WORD].exit` (the command's exit code) and `[WORD].err` (the job's own standard error).

`[WORD]` is `wait`, or `review` for a [process-owned Codex reviewer](codex-runtime.md#process-owned-reviewers).

## Completion

A lane launched with `--owner` ends its turn after the launch. When the waiter ends, the job sends the lane one notice, `job-end name=wait-[RUN_ID] exit=[CODE] log=[PATH] exit-file=[PATH]`, and the wake or the turn-end hand-over delivers it as mail. Read the files then. An unsent notice loses no result: the exit file stands, so read it at the lane's next turn.

A session with no owner holds the wait inside its turn with the bounded foreground poll of [reviewer mutation-stability.md § 3. Await completion](../../reviewer/workflows/mutation-stability.md#3-await-completion), run again while it exits 124. On Codex it takes the `exec_command` and `write_stdin` calls of [codex-runtime.md § Validation wait](codex-runtime.md#validation-wait).

A missing or empty `wait.exit` means the waiter has no recorded exit: keep waiting. Never read that state as a verdict or start a duplicate waiter. Once it is nonempty, read it and the log:

```bash
cat "[RUN_DIR]/wait.exit"
```

```bash
cat "[RUN_DIR]/wait.log"
```

- Route the exit code and the log's result through the calling workflow. The log of a `verify-pr` or review call, `queue-watch` or `copilot-wait` holds the runtime's JSON reply after the runner line and before an owned job's `job-end-notice=` line; route it by its `result.status`.
- A nonzero code stays nonzero.
- A process confirmed stopped with no exit file has no verdict: report the interruption.
- Before any workflow-authorized retry, confirm no waiter for this pull request remains.
- Never replace the waiter with manual GitHub polls or short foreground slices.
