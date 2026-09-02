# Codex runtime reference

Deep halves of the Codex notes in [../SKILL.md](../SKILL.md). Everything here is Codex-specific.

## Shell-shape classifier (`approval_policy = never`)

The CLI classifies shell CONTROL SYNTAX as approval-required however harmless the inner commands are. Rejected shapes: `for`/`while` loops; multi-command blocks (`;`- or newline-separated); `VAR=x cmd` env-assignment prefixes; `$(...)` substitution, including a literal backtick anywhere in the command, even inside a quoted search pattern; array building; heredocs; value-plumbing pipelines; and redirection. Write search patterns with the regex hex escape `\x60` (`[\x60]` inside a bracket expression) in regex mode — `rg -F` has no escapes. Canonical safe search shape:

```bash
rg -n '\x60kendex refresh\x60' skills/
```

`approval required by policy, but AskForApproval is set to Never` means the shape was flagged, not access. Do not retry the shape and do not wait for approval — none can arrive.

Rewrites:

- Polling loops → the orch waiters `ci-wait`, `approval-wait`, `queue-wait`. Launch all three once as blocking commands and stay on them until they return — merge-pr's queue wait included. Never re-run a waiter merely because the harness yielded early or slice it into short polls.
- Multi-item sweeps → one simple command per item.
- Derived values → helper scripts (`git-context`, `workflow-state`), never substitution.
- File writes → harness file tools or `apply_patch`, never redirection.
- Related `workflow-state` operations → one `get '{...}'` or one `update '... | ...'`. Split what cannot collapse — `set-git-head`/`set-now` (they compute their own value), a read mixed with a write, a `// empty` default that would collapse a combined object, a per-item loop — into separate one-command calls.
- Several file reads → separate read commands or the harness file-read tool.
- An optional environment variable affecting a command → omit the option and let the script auto-detect, or read it with `printenv VAR` and run a second command with a literal value. Never put an unset-variable expansion in a required command.

### Env-assignment prefixes

The prefix is an environment precondition, not part of the required command — normalize it where the command is accepted into the workflow, before any agent is asked to run it. `printenv VAR` confirms ordinary variables; `locale` confirms locale variables by their effective `LC_*` lines (an unset `LC_ALL` with an effective `C` locale satisfies `LC_ALL=C`). `env VAR=value cmd args` is not an accepted shape. If the ambient environment does not satisfy the precondition, report a blocker instead of running under the wrong environment.

### Policy-rejected porcelain

The classifier rejects some porcelain verbs outright, top-level `git rebase` among them; no user authorization or delegation lifts it. The replacement for a clean linear issue branch is the worktree skill's guarded `create <ID> --reuse --replay` (or `--restack --replay` to pause on conflicts) with `worktree restack continue|skip|abort` — worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback) — never an improvised force-push. A dirty tree or merge commits in range put the branch outside that recipe: report a blocker.

## Spawning Codex collaboration agents

Spawn generated agents with `fork_context: false` — a full-history fork inherits the parent agent type and the runtime rejects the spawn. Resolve parameters with `scripts/spawn-adapter spawn <canonical-agent-name>`: the canonical hyphenated name is the identity everywhere orch records anything, and the adapter confines the runtime spelling to `record.runtime_metadata`. `--fallback-reason` is for a deliberate generic-worker fallback, never one a name-schema rejection caused. After the spawn, `send_input` a `DELEGATION:`-prefixed `<delegation_format>`.

`scripts/spawn-adapter slots` prints the effective thread cap and the `REVIEWER_SLOT_BUDGET` it implies, warning when only the legacy key is set (it is ignored); a running session keeps its old cap until restarted. Set the reported budget in `kendex.settings.toml` `[env]`.

## Codex Desktop app handoff

`workflows/handoff.md` with `harness=codex-app`, the default for multi-issue handoff when the runtime exposes `codex_app` thread tools. Create exactly one thread per issue with `codex_app.create_thread`, targeting a worktree environment whose `startingState` is `{type: "branch", branchName: "[BASE_BRANCH]"}` from `resolve-base-branch`. Start it with `$orch start [ISSUE_ID]` or `$orch start github [OWNER/REPO]#[N]`, and record the returned thread ID. If the runtime separates creation from prompting, call `codex_app.send_message_to_thread` once with that same prompt.

Use a `working-tree` starting state only when the user explicitly asks for a dirty local snapshot (it can start the child before generated Codex agents are visible, forcing a `worker` fallback). Generated agents must be tracked under `.codex/agents/*.toml` in the saved project branch to be discoverable: setup hooks and worktree symlinks run too late.

The Codex CLI does not expose these tools. Do not emulate app handoff with terminal launch, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.
