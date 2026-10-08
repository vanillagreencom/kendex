# Codex runtime reference

Deep halves of the Codex notes in [../SKILL.md](../SKILL.md). Everything here is Codex-specific.

## Shell approval by launch mode

In the check below, Codex refused a command for one of three causes: an execpolicy rule match, its built-in `rm -f` check, or the sandbox. It refused no shell form. A redirect, a pipeline, a `;` list, `$(...)`, a heredoc, a `for` loop, an env-assignment prefix, a literal backtick and `git rebase` each ran in every mode, as far as the sandbox let it write.

| Mode | Where kendex launches it | Probe flags | Sandbox | `rm -f` |
|------|--------------------------|-------------|---------|---------|
| Bypass | Lanes: the spelling [lane-launch.sh](../scripts/lib/lane-launch.sh) writes | `--dangerously-bypass-approvals-and-sandbox` | None | Refused |
| `never`, full access | The user config default, `approval_policy = "never"` with `sandbox_mode = "danger-full-access"`; `-a never` on that config | None, on a config holding `approval_policy = "never"` and `sandbox_mode = "danger-full-access"` | None | Refused |
| `never`, workspace-write | `-a never` on a config whose sandbox is `workspace-write` | `-c approval_policy='"never"' -s workspace-write` | A write outside the working directory fails `Read-only file system` | Refused |
| Approve for me | Lanes: the accepted spelling `--approve-for-me` | `--approve-for-me` | workspace-write; a write outside the working directory failed, then its reviewed escalation ran | Reviewed, then ran |
| Read-only | second-opinion: `codex exec -s read-only` | `-s read-only` | Every write fails `Read-only file system` | Refused |

### Refusals

| Cause | Text the tool returns | Action |
|-------|-----------------------|--------|
| An execpolicy rule with `decision="prompt"` matched; observed in bypass and `never`, full access | `approval required by policy, but AskForApproval is set to Never` | Do not retry and do not wait: no approval can arrive. The rule matches a command prefix, not a shell form. Rules live in `$CODEX_HOME/rules/*.rules` and the project's `.codex/rules/*.rules`; `codex execpolicy check --rules <file> <command words>` prints the matching rule. Run the replacement the rule's owner names, or report a blocker. |
| The built-in `rm -f` check, in every mode but approve for me | `rm -f style commands are not permitted. Use a safer approach` | Drop `-f`: `rm <path>` passed the check in every mode. |
| The sandbox, in the workspace-write and read-only modes | `Read-only file system` | Read-only writes nothing. Workspace-write writes inside the working directory; a write outside it is a blocker. |
| A kendex PreToolUse hook, in every mode | `Command blocked by PreToolUse hook: <hook>: ...` | Use the accepted form the hook names. The project's `.codex/hooks.json` lists the hooks; each refuses a named command, and none refuses a shell form. |

### Check

Observed with `codex-cli 0.157.1`. Each mode ran one `codex exec` whose prompt listed these commands, one shell tool call each, in a scratch directory under `tmp/` that holds a one-commit git repository `repo`:

| Shape | Command | Result |
|-------|---------|--------|
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

orch runs one simple command per tool call in every harness ([../SKILL.md](../SKILL.md) § Harness-Safe Shell). These substitutes keep a command inside that rule; no mode above refuses the forms they replace. In a fenced command, write a backtick in a search pattern with the regex hex escape `\x60` (`[\x60]` inside a bracket expression) in regex mode; `rg -F` has no escapes:

```bash
rg -n '\x60kendex refresh\x60' skills/
```

- Polling loops → the orch waiters `ci-wait`, `approval-wait`, `queue-wait`, launched through [Waiter launch](waiter-launch.md). Save its detach command with the harness file-write tool, then invoke the saved script as one simple command. Use the harness wait mechanism to poll the completion file.
- Multi-item sweeps → one simple command per item.
- Derived values → helper scripts (`git-context`, `workflow-state`), never substitution.
- File writes → harness file tools, `apply_patch`, or a direct redirect such as `echo value > path` where the sandbox allows the write. Never wrap a write in a Python subprocess.
- Related `workflow-state` operations → one `get '{...}'` or one `update '... | ...'`. Split what cannot collapse — `set-git-head`/`set-now` (they compute their own value), a read mixed with a write, a `// empty` default that would collapse a combined object, a per-item loop — into separate one-command calls.
- Several file reads → separate read commands or the harness file-read tool.
- An optional environment variable affecting a command → omit the option and let the script auto-detect, or read it with `printenv VAR` and run a second command with a literal value. Never put an unset-variable expansion in a required command.

### Env-assignment prefixes

The prefix is an environment precondition, not part of the required command — normalize it where the command is accepted into the workflow, before any agent is asked to run it. `printenv VAR` confirms ordinary variables; `locale` confirms locale variables by their effective `LC_*` lines (an unset `LC_ALL` with an effective `C` locale satisfies `LC_ALL=C`). `env VAR=value cmd args` is not an accepted shape. If the ambient environment does not satisfy the precondition, report a blocker instead of running under the wrong environment.

### Rule-refused porcelain

Where an execpolicy rule refuses top-level `git rebase`, no user authorization or delegation lifts the refusal. The replacement for a clean linear issue branch is the worktree skill's guarded `create <ID> --reuse --replay` (or `--restack --replay` to pause on conflicts) with `worktree restack continue|skip|abort` — worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback) — never an improvised force-push. A dirty tree or merge commits in range put the branch outside that recipe: report a blocker.

## Standing watch

Codex starts no turn for output that arrives after a turn ended, from a detached process or from a running exec session. The oversee watch ([watch-delivery.md](watch-delivery.md)) is held inside the turn by the unified exec tools. The limits are the Codex CLI tool descriptions (0.156.1):

| Step | Call | Limit |
|------|------|-------|
| Arm | `exec_command`, `cmd` the numbered follow command of [watch-delivery.md](watch-delivery.md), `yield_time_ms` 30000 | `yield_time_ms` takes 250-30000 ms. The call returns the first output and a `session_id` while the follow runs. |
| Wait | `write_stdin` on that `session_id`, empty `chars`, `yield_time_ms` 300000 | An empty poll waits 5000-300000 ms; `background_terminal_max_timeout` sets the ceiling, 300000 by default. It returns the output written since the previous call. |
| Re-arm | The same `write_stdin` again, in the same turn, once every returned line is handled | Never end the turn between polls while a lane record is `running`. Every poll return, empty, with output or with an `exit_code`, is an expiry: run the watch-delivery.md checks before the next poll. An `exit_code` ended the follow: arm again from the line after the last number handled. |

Each call is one simple command, as orch's one-simple-command rule asks ([../SKILL.md](../SKILL.md) § Harness-Safe Shell).

## Validation wait

A dev agent holds its `dev-validate-run` inside the turn with the same tools, under the limits of § Standing watch. Codex starts no turn when the run ends, and the wake refuses a hosted Codex lane (§ Lane mailbox).

Start and Resume each return an `exit_code` once the command ended inside their yield, or a `session_id` while it still runs. A return that carries an `exit_code` ended the command: read its lines and do not poll. Only a return that carries a `session_id` takes the Wait step, repeated until a return carries an `exit_code`.

| Step | Call | Return |
|------|------|--------|
| Start | `exec_command`, `cmd` `.agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH]`, `yield_time_ms` 30000 | The output so far. The start prints its `state=started` line only once it has classified the change and launched the run, which nothing bounds to this call, so the line can come on a Wait return. Keep its `run-dir=` value. The start then blocks until the verdict and never exits 3. |
| Wait | `write_stdin` on the `session_id` a Start or Resume returned, empty `chars`, `yield_time_ms` 300000, repeated in the same turn | The output since the previous return. |
| Resume | `exec_command`, `cmd` `.agents/skills/orch/scripts/dev-validate-run --wait --run-dir [RUN_DIR]`, `yield_time_ms` 30000 | Taken only for a run whose `state=started` line was read: when its session ended with no verdict line and no refusal line, or when a `--wait` session exits 3 with `state=running`, which `--wait` prints once its per-call budget runs out. |

A session that exits 2 with a `dev-validate-run: [REASON]` line was refused and is never resumed: `run-live` routes as its line names, and any other reason is a validation failure, both by the dev skill's [dev-implement.md § 5. Validate](../../dev/workflows/dev-implement.md#5-validate). Once a `state=started` line is read, never end the turn while that run has printed no `state=done`, `state=timeout` or `state=lost` line. What each line means is the dev skill's SKILL.md § Long-Running Validation.

## Delegated round wait

Codex starts no turn when a collaboration agent returns after its caller ended the turn. This includes hosted lanes, whose mailbox wake is unavailable. For dev rounds that write a dev-return artifact, keep the delegation's watchdog inside the current turn until it records an artifact verdict or reaches the round deadline. The round token, deadline, acceptance and escalation stay in [skill-rules.md § Round Closure](skill-rules.md#round-closure).

Launch the single `dev-artifact-check` watchdog through [waiter-launch.md § Launch](waiter-launch.md#launch):

```bash
sh "[RUN_DIR]/launch.sh" "[RUN_DIR]/wait" .agents/skills/orch/scripts/dev-artifact-check --wait 600 --worktree [WORKTREE_PATH] --issue [ISSUE_ID] --round-id [DEV_ROUND_ID]
```

A fix round appends `--expect-items-from-round`. This replaces the background watchdog, rather than adding a second one. Hold its completion through [waiter-launch.md § Completion](waiter-launch.md#completion), using `exec_command` and empty `write_stdin` polls in this turn. A tool return with a `session_id` requires another poll; one with an `exit_code` ended that command. A poll timeout requires the completion route's retry while `wait.exit` is empty. An agent's return message does not release this wait.

Read `wait.exit` and `wait.log` once the completion file is nonempty. Apply Round Closure's refusal and replacement rules when the watchdog returned no verdict. Otherwise run the delegating workflow's acceptance table on the artifact verdict or deadline result. Continue the workflow in this turn. The generic lane-notice instruction to end a turn while waiting on an agent does not apply to this wait.

## Reviewer round wait

For each incomplete reviewer, launch its single watchdog through [waiter-launch.md § Launch](waiter-launch.md#launch):

```bash
sh "[RUN_DIR]/launch.sh" "[RUN_DIR]/wait" .agents/skills/orch/scripts/review-artifact-check [WORKTREE_PATH] [AGENT] [REVIEW_DELEGATED_AT] --wait [SECS] --issue [ISSUE_ID]
```

Take `[SECS]`, re-arming and the required-measurement allowance from [review-pr.md § 3.2](../workflows/review-pr.md#32-watchdog). This replaces each background watchdog. Start [waiter-launch.md § Completion](waiter-launch.md#completion)'s foreground poll for each run before polling their sessions. Keep all completion waits inside this turn with `exec_command` and empty `write_stdin` polls, as [§ Delegated round wait](#delegated-round-wait) requires. After every tool return, sweep all run directories for nonempty `wait.exit` files and run § 3.2's filesystem sweep and due actions before the next poll. Read each completed run's `wait.exit` and `wait.log`; § 3.2 owns refusal replacement and § 3.1 owns artifact acceptance. Continue the review workflow in this turn; an agent message alone never releases a watchdog wait.

## Lane mailbox

A Codex lane arms no mailbox monitor ([watch-delivery.md § Lane mailbox monitor](watch-delivery.md#lane-mailbox-monitor)): a lane idle at its prompt holds no turn, and Codex starts none for a monitor's output. The overseer follows each `lane-mail send` to a Codex lane with `open-terminal --wake` ([oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)), which resumes the lane's newest session in print mode with one line that runs `lane-mail inbox`. Codex publishes no idle signal, so the wake refuses a lane whose Codex process still runs, as `working` or `unjudged` ([lane-reach.md § Wake refusals](lane-reach.md#wake-refusals)). The wake refuses a hosted Codex lane as `wake-invalid`. Mail to a Codex lane the wake refuses takes [lane-reach.md § Mail the wake cannot deliver](lane-reach.md#mail-the-wake-cannot-deliver).

## Spawning Codex collaboration agents

Spawn generated agents with `fork_context: false` — a full-history fork inherits the parent agent type and the runtime rejects the spawn. Resolve parameters with `scripts/spawn-adapter spawn <canonical-agent-name>`: the canonical hyphenated name is the identity everywhere orch records anything, and the adapter confines the runtime spelling to `record.runtime_metadata`. `--fallback-reason` is for a deliberate generic-worker fallback, never one a name-schema rejection caused. After the spawn, `send_input` a `DELEGATION:`-prefixed `<delegation_format>`.

`scripts/spawn-adapter slots` prints the effective thread cap and the `REVIEWER_SLOT_BUDGET` it implies, warning when only the legacy key is set (it is ignored); a running session keeps its old cap until restarted. Set the reported budget in `kendex.settings.toml` `[env]`.

## Codex Desktop app handoff

`workflows/handoff.md` with `harness=codex-app`, the default for multi-issue handoff when the runtime exposes `codex_app` thread tools. Create exactly one thread per issue with `codex_app.create_thread`, targeting a worktree environment whose `startingState` is `{type: "branch", branchName: "[BASE_BRANCH]"}` from `resolve-base-branch`. Start it with `$orch start [ISSUE_ID]` or `$orch start github [OWNER/REPO]#[N]`, and record the returned thread ID. If the runtime separates creation from prompting, call `codex_app.send_message_to_thread` once with that same prompt.

Use a `working-tree` starting state only when the user explicitly asks for a dirty local snapshot (it can start the child before generated Codex agents are visible, forcing a `worker` fallback). Generated agents must be tracked under `.codex/agents/*.toml` in the saved project branch to be discoverable: setup hooks and worktree symlinks run too late.

The Codex CLI does not expose these tools. Do not emulate app handoff with terminal launch, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.
