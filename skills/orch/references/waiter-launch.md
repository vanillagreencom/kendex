# Waiter launch

Load from the workflow or reference that launches a waiter: `submit-pr.md`, `ci-fix.md`, `merge-pr.md`, `merge-attempt.md`, `review-pr-comments.md`, `skill-rules.md` or `codex-runtime.md`, before a review wait or a `verify-pr` call (`orch-runtime op`), `queue-watch`, `copilot-wait`, `lane-mail wait`, or a Codex artifact watchdog or reviewer. Start each long waiter through the orch job runner, `.agents/skills/orch/scripts/lib/job-unit.sh` ([job-units.md](job-units.md)). Keep the lane active until its completion file arrives. Never start the waiter as a harness background command.

## Launch

Run from the worktree root. Create a fresh directory under the current worktree's `tmp/` with `mktemp -d tmp/waiter.XXXXXX`. Use its absolute path as `[RUN_DIR]`, and the letters and digits `mktemp` put after `waiter.` as `[RUN_ID]`. Each invocation, including a workflow-authorized retry, uses a fresh directory.

Use the harness file-write tool to save this script as `[RUN_DIR]/launch.sh`:

The job is the launch shell, whose argv carries the run path as its own word and which leads the process group of everything the job starts. `[WORD]` is the run path's last word: `wait`, or `review` for a [process-owned Codex reviewer](codex-runtime.md#process-owned-reviewers). The job's name, job-units.md's `NAME`, is `[WORD]-[RUN_ID]`, so every launch names a unit no other launch has. The launch passes no `--cap`: each waiter ends on its own budget, a `verify-pr` or review call ends when the operation answers, `queue-watch` ends at its `--max-wait`, and `copilot-wait` at the bound [review-pr-comments.md § 1](../workflows/review-pr-comments.md#1-fetch-and-parse) states. The runner records how the job runs in `[RUN_DIR]/[WORD].runner`, and the launch shell writes that record's runner line as the first line of `[RUN_DIR]/[WORD].log`.

The runner adds no signal ignore of its own, where a job a non-interactive shell starts with `&` ignores INT and QUIT, which leaves a detached guard or waiter uninterruptible and makes its signal rows report false failures. Under `setsid` a signal the calling process already ignores stays ignored; a unit starts from the manager's dispositions, with SIGPIPE at its default.

Invoke it as one foreground shell-tool command. Replace `[WAITER_COMMAND_AND_ARGS]` with the workflow's complete command, including any `env -u` prefixes. Preserve its polling interval, budget and output flags:

```bash
.agents/skills/orch/scripts/orch-runtime launch-job --name wait-[RUN_ID] --run [RUN_DIR]/wait --owner [ISSUE_ID] -- [WAITER_COMMAND_AND_ARGS] < /dev/null
```

It prints the runner line and exits 0 once the job is started. Exit `6`, `launch-unconfirmed`, may have started the job: keep `[RUN_DIR]`, wait on its completion file as § Completion says, and launch no second waiter for it. Any other exit started nothing: report its `job-unit:` line, which names the cause (`missing-command commands=setsid` on a host with neither runner), and launch nothing on it.

Record `[RUN_DIR]/wait.exit` and `[RUN_DIR]/wait.log` in the lane's status. Launch once. A shell-tool return or timeout does not authorize another waiter.

## Completion

Use the completion route for the current harness:

| Harness | Completion route |
|---------|------------------|
| Codex | Run the foreground poll and its timeout retry route from [reviewer SKILL.md § Mutation-Stability Pairing](../../reviewer/SKILL.md#mutation-stability-pairing) with `exec_command` and empty `write_stdin` polls in the same turn, under [codex-runtime.md § Standing watch](codex-runtime.md#standing-watch). Follow [§ Validation wait](codex-runtime.md#validation-wait) for `session_id` and `exit_code` handling. Keep the turn active until `wait.exit` is nonempty; Codex starts no turn when the waiter ends. |
| Other harnesses | Use the harness's monitor or wait mechanism to check `test -s "[RUN_DIR]/wait.exit"` every 30 seconds. |

A missing or empty file means the waiter has no recorded exit. Keep waiting; never read that state as a verdict or start a duplicate waiter.

When the file is nonempty, read it and the log:

```bash
cat "[RUN_DIR]/wait.exit"
```

```bash
cat "[RUN_DIR]/wait.log"
```

The completion file contains the waiter's exit code. Route that code and the log's final result through the calling workflow; the log of a `verify-pr` or review call, or of `queue-watch` or `copilot-wait`, holds the runtime's JSON reply under its runner line, routed by its `result.status`. A nonzero code stays nonzero. A confirmed stopped process with no completion file has no verdict; report the interruption and confirm that no waiter for this PR remains before any workflow-authorized retry. Never replace the waiter with manual GitHub polls or short foreground slices.
