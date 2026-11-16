# Waiter launch

Read when a workflow or reference launches a waiter: [submit-pr.md](../workflows/submit-pr.md), [ci-fix.md](../workflows/ci-fix.md), [merge-pr.md](../workflows/merge-pr.md), [merge-attempt.md](merge-attempt.md), [review-pr-comments.md](../workflows/review-pr-comments.md), [skill-rules.md](skill-rules.md) or [codex-runtime.md](codex-runtime.md), before a review wait or a `verify-pr` call (`orch-runtime op`), `queue-watch`, `copilot-wait`, or a Codex watchdog or reviewer. Start each waiter through `orch-runtime launch-job` ([job-units.md](job-units.md)), never as a harness background command. A lane waits on mail through the wake, never on a waiter.

## Launch

1. From the worktree root, make a fresh directory with `mktemp -d tmp/waiter.XXXXXX`. Use its absolute path as `[RUN_DIR]`, and the letters and digits after `waiter.` as `[RUN_ID]`. Every invocation, a workflow-authorized retry included, takes a fresh directory.
2. Run the launch below as one foreground shell-tool command. Replace `[WAITER_COMMAND_AND_ARGS]` with the workflow's complete command, its `env -u` prefixes included, and keep its polling interval, budget and output flags. In a lane, `--owner` names the lane's item. A session that is no lane, and a subagent, leaves `--owner` out. No launch caps the waiter's time: a `verify-pr` or review call ends when the operation answers, `queue-watch` at its `--max-wait`, and `copilot-wait` at the bound [review-pr-comments.md § 1](../workflows/review-pr-comments.md#1-fetch-and-parse) states.
3. Read the exit. 0: the waiter started; the JSON reply carries its runner line and record. 75: it may have started; keep `[RUN_DIR]`, wait on its completion as § Completion says, and launch no second waiter for it. 1: `job-launch-failed` with its `cause`; nothing started, so report the cause and launch nothing on it.
4. Record `[RUN_DIR]/wait.exit` and `[RUN_DIR]/wait.log` in the lane's status. Launch once: a shell-tool return or timeout authorizes no other waiter.

```bash
.agents/skills/orch/scripts/orch-runtime launch-job --name wait-[RUN_ID] --run [RUN_DIR]/wait --owner [ISSUE_ID] -- [WAITER_COMMAND_AND_ARGS] < /dev/null
```

### Run files

The launch writes `[RUN_DIR]/[WORD].runner`, the launcher's record. The job, `orch-runtime run-job`, runs the command and writes beside it:

| File | Holds |
|---|---|
| `[WORD].log` | The runner line, then the command's output. A job launched with `--owner` ends it with `job-end-notice=sent`, `unsent:[CAUSE]` or `held`, how the notice went. |
| `[WORD].exit` | The command's exit code, written before the notice. A signalled command reads 128 plus the signal, a command not found 127. |
| `[WORD].err` | The job's own standard error. |

`[WORD]` is `wait`, or `review` for a [process-owned Codex reviewer](codex-runtime.md#process-owned-reviewers).

## Completion

A lane launched with `--owner` ends its turn after the launch. When the waiter ends, the job sends the lane one notice, `job-end name=wait-[RUN_ID] exit=[CODE] log=[PATH] exit-file=[PATH]`, and the wake or the turn-end hand-over delivers it as mail. Read the files then. A notice that was not sent loses no result: the exit file stands, so read it at the lane's next turn.

A session with no owner holds the wait inside its turn with the bounded foreground poll of [reviewer mutation-stability.md § 3. Await completion](../../reviewer/workflows/mutation-stability.md#3-await-completion), run again for as long as it exits 124. On Codex it takes the `exec_command` and `write_stdin` calls of [codex-runtime.md § Validation wait](codex-runtime.md#validation-wait).

A missing or empty `wait.exit` means the waiter has no recorded exit. Keep waiting; never read that state as a verdict or start a duplicate waiter. When it is nonempty, read it and the log:

```bash
cat "[RUN_DIR]/wait.exit"
```

```bash
cat "[RUN_DIR]/wait.log"
```

Route the exit code and the log's result through the calling workflow. The log of a `verify-pr` or review call, or of `queue-watch` or `copilot-wait`, holds the runtime's JSON reply between the runner line and, for an owned job, the `job-end-notice=` line; route it by its `result.status`. A nonzero code stays nonzero. A confirmed stopped process with no exit file has no verdict: report the interruption, and confirm no waiter for this pull request remains before any workflow-authorized retry. Never replace the waiter with manual GitHub polls or short foreground slices.
