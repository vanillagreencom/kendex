# Long-running validation

Read [Long-Running Validation](../SKILL.md#long-running-validation) before starting, polling or resuming validation.

`.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] --run-id [RUN_ID]` starts the run the round's admission named, `[RUN_ID]` being the id the admission step of [validation.md § Admission](../references/validation.md#admission) minted. It starts the admitted directory as `orch-runtime validate start` does: it resolves the mode from the project's declaration, records the run's mode and job on the round's admitted `validate` entry, launches the run's job and prints the `state=started` line. When the run ends, the runtime closes that entry with the run's verdict and sends this lane its end notice, mail on the lane's channel.

The bare start without `--run-id`, `.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH]`, is the ad-hoc route for a delegation that carries no admission: the runtime mints the id and records the run files.

Both routes:

- bound no command's length;
- detach the command so the run outlives the shell that launched it;
- print the run directory first and the verdict last;
- resume through the same `--wait --run-dir` poll.

The validation command contract is in orch's `references/artifact-checks.md` § Validation command output. The executor ends a run as stalled only after the start's `quiet-secs` with no output, no new process and no CPU work, and one call waits for its budget, 540 seconds by default. Never choose either number yourself. Full contract: `orch-runtime validate entry --help`.

Every harness row below plans without a spawned harness child, a harness process a tool starts in this session: no row names such a child's sign-in as proven, so a lane that needs a second agent takes the harness's own subagent route, which runs in the lane's session.

- **Claude Code.**
  - Run the BARE command `.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] --run-id [RUN_ID]` in the foreground, never piped or chained, under the harness's maximum command timeout. It starts the run detached and then blocks until the verdict.
  - A run that outlasts that timeout comes back cut off or moved to the background. For such a run:
    - Read the `run-dir=` value off the `state=started` line in the output it returned or in the output file the harness names.
    - Take the foreground poll `.agents/skills/orch/scripts/orch-runtime validate entry --wait --run-dir [RUN_DIR]` as the turn's next step, under the same timeout because one call runs for up to nine minutes. Repeat it for as long as it exits 3 and prints `state=running`.
  - Never end the turn while the run is still running and never wait for a completion notice. A subagent whose turn has ended is not woken when the run ends, the runtime's end notice reaches the lane's mailbox and never that subagent, and the harness can kill a background shell on a low-memory heuristic that fires with free memory to spare. Neither loses the verdict, because the sentinel is on disk.
  - Read the verdict, then resume the tail:
    - The verdict is the `validate=` value on the `state=done` line: `pass`, `FAILING`, or `no-verdict` for a command's exit 3 or an unavailable host check, which [validation.md § No-verdict](../references/validation.md#no-verdict) routes. The log holds command output and never an exit status.
    - `state=lost` is a failed validation.
  - A tool-started `claude -p` is the spawned child this workflow forbids: its sign-in is unproven.
- **Codex.**
  - Start `.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] --run-id [RUN_ID]` with `exec_command`.
  - While a call returns a `session_id`, hold it inside the turn with empty `write_stdin` polls on it. A return that carries an `exit_code` ended the command.
  - A session that printed `state=started` and then ended without a verdict line or an exit-2 refusal resumes with `.agents/skills/orch/scripts/orch-runtime validate entry --wait --run-dir [RUN_DIR]` the same way, repeated while it exits 3 and prints `state=running`.
  - A refusal routes by [validation.md](../references/validation.md) and is never resumed.
  - The calls and their limits are [codex-runtime.md § Validation wait](../../orch/references/codex-runtime.md#validation-wait).
  - Once the run has started, hold the turn until you read the verdict. The validation's end starts no Codex turn by itself.
  - The watch confirms a hosted wake when the provider returns a matching prompt row. A `wake-unconfirmed` event leaves receipt unknown.
  - Read the verdict as Claude Code does, then resume the tail.
  - A tool-started `codex exec` is the spawned child this workflow forbids: its sign-in is unproven.
  - For every other long command, hold its job-runner completion inside the turn through the Codex row in [waiter-launch.md § Completion](../../orch/references/waiter-launch.md#completion).
- **Pi.**
  - Pi sets no default foreground timeout. A foreground ceiling comes from the host or an explicit tool timeout.
  - Start `.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] --run-id [RUN_ID]` through `bg_task action: "spawn"` with `notifyOnExit: true`.
  - Keep the task id and the `run-dir=` value from the task log's `state=started` line.
  - Read the task log on its exit wake and interpret the verdict as Claude Code does.
  - If the task ends without a verdict, resume `.agents/skills/orch/scripts/orch-runtime validate entry --wait --run-dir [RUN_DIR]` through the same background mechanism, repeating while it prints `state=running` and exits 3.
  - Resume the completion tail after reading the verdict.
  - A Pi background child that starts this run needs a `bgTaskTimeoutMs` deadline that covers its work before the run plus one `--wait` call's budget, because the deadline counts from the child's launch. Otherwise the deadline kills it before its completion tail.
  - A Pi process a tool starts is the spawned child this workflow forbids: its sign-in is unproven.
  - For other long commands, follow the [Long-Running Validation](../SKILL.md#long-running-validation) command-routing rule.
- **A host whose agent warden kills detached jobs**, on any harness:
  - Add `--attached` to the start command and run it in the foreground, under the harness's maximum command timeout.
  - A foreground run has no cap to fit under, so the route fits only a harness with no call limit or one it can raise past the run's length.
  - The run then stays inside the agent's own process tree and writes the same run directory, sentinel and record, which `orch-runtime dev-return --text write` takes as it takes a detached run.
  - A harness that cuts the call off kills only the parent, and the warden then reaps the child before its verdict: the run ends as `state=lost`, a failed validation.
  - The `--wait --run-dir` resume above holds only on a host without such a warden.
  - An `--attached` run is held to its start's memory bound by its executor, `memory-held=reader bound=<bytes>` in its log.

## A run another seat starts

When another seat starts the admitted run, such as the overseer for a confined lane, the round runs no start. It follows the run with `.agents/skills/orch/scripts/orch-runtime validate entry --wait --worktree [WORKTREE_PATH] --run-id [RUN_ID]`.

- The call reads the run as queued until the run's start record stands, then follows it as the `--wait --run-dir` poll does, under one budget.
- A budget that ends before the start prints `state=queued` and exits 3.
- An id no round admitted is refused `run-unadmitted`.
- An admission that closed with no start record, such as one whose start was refused after it, is refused `run-ended-unstarted` with the admission's outcome. Its cause is the key of the refusal that kept the run from starting, such as `run-exists` or `memory-short`, where one stood, else the close's word.
- A start the other seat ran that was refused before it recorded the run, such as `memory-short`, is refused `start-refused` with that start's key as its cause. The admission stays open, so that seat can start again under the same id.
- A start the other seat ran that answers `refusal-unrecorded` left no refusal on the run's record, so the call still ends `state=queued`. That seat relays the refusal to its lane or closes the admission.
- Each refusal exits 2 and routes as a refused start does.
- Each harness holds the call as its row above holds the start:
  - Claude Code runs the bare command in the foreground under the maximum command timeout.
  - Codex takes the Follow step of [codex-runtime.md § Validation wait](../../orch/references/codex-runtime.md#validation-wait).
  - Pi spawns it through `bg_task` with `notifyOnExit: true`.
- Run the same command again when a call ends with no `state=done`, `state=lost` or refusal line: an exit 3 with `state=queued` or `state=running`, or a call cut off, moved to the background or ended with no verdict. Never poll the run directory between calls.
- Read the verdict as the Claude Code row reads it.
