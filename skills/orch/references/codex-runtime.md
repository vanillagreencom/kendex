# Codex runtime reference

Read when orch runs on Codex: a shell refusal, a wait inside a turn, a process-owned reviewer, a lane's mail, a collaboration agent or an app handoff.

## Shell approval by launch mode

Codex refuses a command for one of three causes: an execpolicy rule match, its built-in `rm -f` check, or the sandbox. It refuses no shell form. A redirect, a pipeline, a `;` list, `$(...)`, a heredoc, a `for` loop, an environment-assignment prefix, a literal backtick and `git rebase` each ran in every mode, as far as the sandbox let it write (measured, `codex-cli 0.157.1`, § Check).

| Mode | Where kendex launches it | Probe flags | Sandbox | `rm -f` |
|---|---|---|---|---|
| Bypass | A lane under the `bypass` posture: `--dangerously-bypass-approvals-and-sandbox` (agent-runtime `harness.rs` `Harness::permission_spellings`) | `--dangerously-bypass-approvals-and-sandbox` | None | Refused |
| `never`, full access | A user config holding `approval_policy = "never"` and `sandbox_mode = "danger-full-access"`; `-a never` on that config | None, on that config | None | Refused |
| `never`, workspace-write | `-a never` on a config whose sandbox is `workspace-write` | `-c approval_policy='"never"' -s workspace-write` | A write outside the working directory fails `Read-only file system` | Refused |
| Approve for me | A lane whose line carries `--approve-for-me` | `--approve-for-me` | workspace-write; a write outside the working directory failed, then its reviewed escalation ran | Reviewed, then ran |
| Read-only | second-opinion: `codex exec -s read-only` | `-s read-only` | Every write fails `Read-only file system` | Refused |

### Refusals

| Cause | Text the tool returns | Action |
|---|---|---|
| An execpolicy rule with `decision="prompt"` matched; seen in bypass and `never`, full access | `approval required by policy, but AskForApproval is set to Never` | Do not retry and do not wait: no approval can arrive. The rule matches a command prefix, not a shell form. Rules live in `$CODEX_HOME/rules/*.rules` and the project's `.codex/rules/*.rules`; `codex execpolicy check --rules <file> <command words>` prints the matching rule. Run the replacement the rule's owner names, or report a blocker. |
| The built-in `rm -f` check, in every mode but approve for me | `rm -f style commands are not permitted. Use a safer approach` | Drop `-f`: `rm <path>` passed the check in every mode. |
| The sandbox, in the workspace-write and read-only modes | `Read-only file system` | Read-only writes nothing. Workspace-write writes inside the working directory; a write outside it is a blocker. |
| A kendex PreToolUse hook, in every mode | `Command blocked by PreToolUse hook: <hook>: ...` | Use the accepted form the hook names. The project's `.codex/hooks.json` lists the hooks; each refuses a named command, and none refuses a shell form. |

### Check

Each mode ran one `codex exec` whose prompt listed these commands, one shell tool call each, in a scratch directory under `tmp/` holding a one-commit git repository `repo`:

| Shape | Command | Result |
|---|---|---|
| Redirect | `echo probe > redirect.txt` | Ran; read-only failed `Read-only file system` |
| Pipeline | `printf 'a\nb\n' \| wc -l` | Ran |
| `;` list | `echo one; echo two` | Ran |
| Substitution | `echo "$(printf sub)"` | Ran |
| Heredoc | `cat <<'EOF' > heredoc.txt`, one body line, `EOF` | Ran; read-only failed |
| Loop | `for i in 1 2; do echo "$i"; done` | Ran |
| Env prefix | `PROBE_VAR=1 printenv PROBE_VAR` | Ran |
| Backtick | ``grep -c '`' prompt-copy.txt`` | Ran |
| Rebase | `git -C repo rebase HEAD` | Ran; read-only failed on the ref lock |
| `rm -f` | `rm -f redirect.txt heredoc.txt` | Refused, except in approve for me |
| Rule match | `git -C repo rebase HEAD`, with `.codex/rules/probe.rules` in the scratch directory holding `prefix_rule(pattern=["git", "-C", "repo", "rebase"], decision="prompt")` | Refused in bypass and `never`, full access |
| Hook | `pkill -f ken1894-no-such-process`, run with `--dangerously-bypass-hook-trust` | Refused by `block-argv-kill` in bypass and read-only |

```bash
codex exec --json --ephemeral --skip-git-repo-check -C <scratch-dir> <probe-flags> - < <prompt-file>
```

A `command_execution` item with `"status":"completed"` in the `--json` output is a command that ran. Rerun the check after a Codex upgrade, and update these tables when a result changes.

### Substitutes

A kendex hook reads a literal backtick in a command as command substitution. In a search pattern, write a backtick as the regex hex escape `\x60` (`[\x60]` inside a bracket expression) in regex mode; `rg -F` has no escapes:

```bash
rg -n '\x60kendex refresh\x60' skills/
```

- A derived value comes from a helper (`git-context`, `orch-runtime state`), never from substitution.
- Related state reads are one `orch-runtime state get` held in a variable, then one jq filter over its `.result.value` once the read exits 0. Related writes are the one command the step names; `orch-runtime state set-git-head` and `orch-runtime state set-now` compute their own value.
- For an optional environment variable that affects a command, omit the option and let the script detect it, or read it with `printenv VAR` and run a second command with the literal value. Never put an unset-variable expansion in a required command.

### Rule-refused rebase

Where an execpolicy rule refuses top-level `git rebase`, no user authorization or delegation lifts the refusal. For a clean linear issue branch, take the worktree skill's replay route, [worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback)](../../worktree/SKILL.md#policy-blocked-rebase-cherry-pick-replay-fallback), never an improvised force-push. A dirty tree or a merge commit in range is outside that route: report a blocker.

## Confinement

On Linux a local Codex lane runs inside agent-runtime's `bwrap` wrapper: the whole tree read-only except the paths its launch grants, a private `/tmp`, and the user's runtime folder hidden. On any other host it runs unconfined under the cause `macos-profile-unbuilt` (agent-runtime `confine.rs` `answer`). `orch-runtime ready --duty launch` names the lacking wrapper on Linux, and prints `confinement=off harness=codex cause=macos-profile-unbuilt` elsewhere. A job launched from inside the wrapper runs under `setsid` ([job-units.md](job-units.md)).

## Standing watch

Codex starts no turn for output that arrives after a turn ended, from a detached process or from a running exec session (agent-runtime `harness.rs` `starts_turn_on_output`). A Codex overseer holds the oversee watch ([watch-delivery.md](watch-delivery.md)) inside its turn with the unified exec tools. The limits are the Codex CLI tool descriptions (0.156.1):

| Step | Call | Limit |
|---|---|---|
| Arm | `exec_command`, `cmd` the numbered follow command of [watch-delivery.md](watch-delivery.md), `yield_time_ms` 30000 | `yield_time_ms` takes 250 to 30000 ms. The call returns the first output and a `session_id` while the follow runs. |
| Wait | `write_stdin` on that `session_id`, empty `chars`, `yield_time_ms` 300000 | An empty poll waits 5000 to 300000 ms; `background_terminal_max_timeout` sets the ceiling, 300000 by default. It returns the output written since the previous call. |
| Re-arm | The same `write_stdin` again, in the same turn, once every returned line is handled | Every poll return, empty, with output or with an `exit_code`, is an expiry: run the watch-delivery.md checks before the next poll. An `exit_code` ended the follow: arm again from the line after the last number handled. |

Never end the turn between polls while a lane record is `running`. A turn end while the follow runs outside the turn is held once with `lane-mail-check: wake=unwatched`: the follow cannot wake the session (orch `turnend/wake.rs` `check`). Poll again in the same turn; the continued turn end passes and says the session is unwatched.

## Validation wait

A dev agent holds its validation run inside its turn with the same tools: Codex starts no turn when the run ends, and the run's end notice reaches the lane's mailbox, never the dev agent. The dev skill's [long-running-validation.md](../../dev/workflows/long-running-validation.md) owns the route; these are its Codex calls.

Start and Resume each return an `exit_code` once the command ended inside their yield, or a `session_id` while it still runs. A return that carries an `exit_code` ended the command: read its lines and do not poll. Only a return that carries a `session_id` takes the Wait step, repeated until a return carries an `exit_code`.

| Step | Call | Return |
|---|---|---|
| Start | `exec_command`, `cmd` `.agents/skills/orch/scripts/orch-runtime validate entry --worktree [WORKTREE_PATH] --run-id [RUN_ID]`, `yield_time_ms` 30000 | The output so far. The start prints its `state=started` line once it has launched the run, which can come on a Wait return. Keep its `run-dir=` value. The start follows the run for up to 540 seconds, then exits 3 with `state=running`. |
| Wait | `write_stdin` on the `session_id` a Start or Resume returned, empty `chars`, `yield_time_ms` 300000, repeated in the same turn | The output since the previous return. |
| Resume | `exec_command`, `cmd` `.agents/skills/orch/scripts/orch-runtime validate entry --wait --run-dir [RUN_DIR]`, `yield_time_ms` 30000 | Taken only for a run whose `state=started` line was read: when a call exits 3 with `state=running`, or when its session ended with no verdict line and no refusal line. |

A call that exits 2 with a `validate: [REASON]` line on stderr was refused and is never resumed: `run-live` routes as its line names, and any other reason is a validation failure, both by the dev skill's [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate). Once a `state=started` line is read, never end the turn before the run prints `state=done` or `state=lost`. What each line means is the dev skill's [SKILL.md § Long-Running Validation](../../dev/SKILL.md#long-running-validation).

## Delegated round wait

Codex starts no turn when a collaboration agent returns after its caller ended the turn. For a dev round that writes a dev-return artifact, the round's watchdog decides the round: an artifact verdict or the round deadline. The round token, deadline, acceptance and escalation stay in [skill-rules.md § Round Closure](skill-rules.md#round-closure).

Launch the one watchdog through [waiter-launch.md § Launch](waiter-launch.md#launch). In a lane, `--owner` names the lane's item:

```bash
.agents/skills/orch/scripts/orch-runtime launch-job --name wait-[RUN_ID] --run [RUN_DIR]/wait --owner [ISSUE_ID] -- .agents/skills/orch/scripts/orch-runtime dev-return --text check --wait 600 --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID] < /dev/null
```

A fix round appends `--expect-items-from-round`. Launch one watchdog per round; it replaces any background watchdog. A lane then ends its turn: the `job-end` mail reaches it through the wake ([waiter-launch.md § Completion](waiter-launch.md#completion)). A session that is no lane launches without `--owner` and holds the completion inside the turn with `exec_command` and empty `write_stdin` polls, as § Validation wait does. An agent's return message does not release the wait.

Once `wait.exit` is nonempty, read it and `wait.log`. Where the watchdog returned no verdict, apply Round Closure's refusal and replacement rules. Otherwise run the delegating workflow's acceptance table on the artifact verdict or the deadline result.

## Reviewer round wait

For each incomplete reviewer, launch its one watchdog through [waiter-launch.md § Launch](waiter-launch.md#launch):

```bash
.agents/skills/orch/scripts/orch-runtime launch-job --name wait-[RUN_ID] --run [RUN_DIR]/wait --owner [ISSUE_ID] -- .agents/skills/orch/scripts/orch-runtime review-artifact --text check --worktree [WORKTREE_PATH] --agent [AGENT] --delegated-at [REVIEW_DELEGATED_AT] --wait [SECS] --issue [ISSUE_ID] < /dev/null
```

Take `[SECS]`, re-arming and the required-measurement allowance from [review-pr.md § 3.2](../workflows/review-pr.md#32-watchdog). Each watchdog replaces a background one. A lane ends its turn and handles each `job-end` mail as it arrives; a session that is no lane omits `--owner` and holds every completion inside the turn as § Delegated round wait does. After each completion, sweep all run directories for nonempty `wait.exit` files and run § 3.2's filesystem sweep and due actions. Read each completed run's `wait.exit` and `wait.log`; § 3.2 owns refusal replacement and § 3.1 owns artifact acceptance. An agent message alone never releases a watchdog wait.

## Process-owned reviewers

Read when [review-pr.md § 2](../workflows/review-pr.md#2-prepare-reviewers) receives `alternate-review` from `orch-runtime admission --item [ITEM] --attached-launch`. This route runs each mandatory canonical review domain as a separate Codex session. Every required domain not yet launched starts in the same wave, each through its own admission (step 4). Panel selection, original-batch provenance, deadlines, the one re-delegation and artifact acceptance stay with that workflow. An advisory external reviewer cannot replace a required domain.

1. Read the lane's own model and effort with `.agents/skills/orch/scripts/orch-runtime session`. It prints `model=[MODEL] source=...`, `effort=[EFFORT] source=...` and `agent=... source=...`. Bind `[MODEL_AND_EFFORT_FLAGS]` as `-m [MODEL] -c model_reasoning_effort=[EFFORT]` (agent-runtime `harness.rs` `Harness::model_words`). A `session-<member>-unrecorded` line, a `session-unnamed` line or another refusal key stops this route: report that word to the caller.
2. Bind `[PERMISSION_FLAG]` to the permission word of the lane's own launch line: `--dangerously-bypass-approvals-and-sandbox` under the `bypass` posture, `--approve-for-me` where the lane carries it, nothing under `native`. Keep the lane's launch home and account in the inherited environment, a private `CODEX_HOME` included. Select no other model, effort, account, provider or executable. A missing `codex` stops this route and is reported to the caller.
3. Make a fresh `[JOB_DIR]` as [waiter-launch.md § Launch](waiter-launch.md#launch) makes `[RUN_DIR]`. Save the complete `DELEGATION:` prompt as `[JOB_DIR]/delegation.md` with the harness file-write tool: the installed canonical role's full instructions and workflow, then review-pr's complete delegation with its minted artifact path, range, decisions and re-review context. A role name or a shortened request is not enough.
4. Run [review-pr.md § Process launch admission](../workflows/review-pr.md#process-launch-admission) immediately before every launch, a replacement included. An earlier `alternate-review` verdict is no fresh reading.
5. Launch from the owned worktree:

```bash
.agents/skills/orch/scripts/orch-runtime launch-job --name review-[RUN_ID] --run [JOB_DIR]/review --owner [ISSUE_ID] -- sh -c 'exec codex exec --ephemeral [MODEL_AND_EFFORT_FLAGS] [PERMISSION_FLAG] --disable hooks --output-last-message "$1/last-message.md" - < "$1/delegation.md"' sh "[JOB_DIR]" < /dev/null
```

The turn end hands lane mail only to the session the lane record binds, so the reviewer session reads none of its parent's mail; `--disable hooks` keeps its hooks off before that binding stands. `--ephemeral` controls persistence alone. Keep the override after the selection flags, and change no stored configuration, trust, account or home.

The job's files are `review.runner`, `review.log`, `review.exit` and `review.err` under `[JOB_DIR]`, beside `last-message.md` and the assigned artifact path ([job-units.md](job-units.md)). The job has no agent ID, thread, chat channel or child-wait target. Hold its completion through [waiter-launch.md § Completion](waiter-launch.md#completion), reading `review` for `wait`, and keep § Reviewer round wait's artifact watchdog running. The process's end and the measurement evidence in its log supply liveness; review-pr § 3 owns acceptance, failure and deadline actions, and neither a launch nor a last message is acceptance.

For review-pr § 3.1's process collection, run the assigned-file check only after a zero exit. `[CHECK_BOUNDARY]` is the original batch's evidence boundary, or its stricter rejection boundary under § 3.2. Read the log beside the result. A failed exit read or a nonzero exit supplies no artifact verdict and leaves the required evidence unread under that workflow's failure route:

```bash
sh -c 'code=$(cat "$1/review.exit") || exit 2; case "$code" in 0) ;; *) printf "codex-review: execution-exit=%s\n" "$code" >&2; exit 1 ;; esac; exec .agents/skills/orch/scripts/orch-runtime review-artifact --text check --file "$2" --worktree "$3" --delegated-at "$4" --issue "$5"' sh "[JOB_DIR]" "[ASSIGNED_ARTIFACT_PATH]" "[WORKTREE_PATH]" "[CHECK_BOUNDARY]" "[ISSUE_ID]"
```

## Lane mailbox

A Codex lane arms no mailbox monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)): its launch brief carries no arm line, since Codex starts no turn for a monitor's output. Mail reaches it at its turn ends and through the watch's wake duty, which types the inbox line into an idle local Codex lane and confirms it by a user turn in the session's rollout ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)). A Codex lane that waits on an answer or a job ends its turn after the ask or the launch; the answer or the completion reaches it as mail. `wake-limit` is the wake's own limit: a session no record binds, a home unknown, a session file absent. Mail that cannot wait for those takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver).

## Spawning Codex collaboration agents

Spawn a generated agent without a full-history fork, which would carry the parent's runtime settings into the child. Resolve the spawn with `.agents/skills/agent-runtime/scripts/agent-runtime subagent spawn --harness codex [CANONICAL_AGENT_NAME]`. The answer's `spawn` holds `agent_type`, `task_name` and `fork_turns: "none"`; hand those to `spawn_agent`. The canonical hyphenated name is the identity everywhere orch records anything; the runtime spelling stays in `record.runtime_metadata`. `--fallback-reason [REASON]` spawns the generic `worker` for a deliberate fallback, never for a name the schema rejected. Prepare the complete `DELEGATION:` message under [skill-rules.md § Codex thread reuse](skill-rules.md#codex-thread-reuse), the target agent's full instructions and workflow included, and give it to `spawn_agent` as `message`. Use `followup_task` for a new task on a finished thread and `send_message` for guidance to a running one.

`.agents/skills/agent-runtime/scripts/agent-runtime subagent room --harness codex` prints the thread cap the home's `config.toml` sets under `[features.multi_agent_v2]` `max_concurrent_threads_per_session`, or the default 4, with its source. A running session keeps its cap until restarted. The verb cannot read the threads in use: count them with `list_agents` before each spawn under [skill-rules.md § Codex thread reuse](skill-rules.md#codex-thread-reuse). Finished threads still hold slots and `interrupt_agent` releases none. Reuse an eligible finished thread through `followup_task` before reporting a cap blocker.

## Codex Desktop app handoff

[handoff.md](../workflows/handoff.md) with `harness=codex-app` is the default for a multi-issue handoff when the runtime exposes `codex_app` thread tools. Create exactly one thread per issue with `codex_app.create_thread`, targeting a worktree environment whose `startingState` is `{type: "branch", branchName: "[BASE_BRANCH]"}`, the branch `.agents/skills/orch/scripts/resolve-base-branch` prints. Start it with `$orch start [ISSUE_ID]` or `$orch start github [OWNER/REPO]#[N]`, and record the returned thread ID. Where the runtime separates creation from prompting, call `codex_app.send_message_to_thread` once with that prompt.

Use a `working-tree` starting state only when the user asks for a dirty local snapshot: it can start the child before generated Codex agents are visible, which forces a `worker` fallback. Generated agents are discoverable only when tracked under `.codex/agents/*.toml` in the saved project branch; setup hooks and worktree links run too late.

The Codex CLI has no app tools. Do not emulate an app handoff with a terminal launch, `codex debug app-server`, raw `codex app-server` or manual app-thread instructions.
