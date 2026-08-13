# Codex runtime reference

Deep halves of the Codex notes in [../SKILL.md](../SKILL.md). Everything here is Codex-specific.

## Shell-shape classifier (`approval_policy = never`)

The CLI classifies shell CONTROL SYNTAX as approval-required however harmless the inner commands are. Rejected shapes: `for`/`while` loops; multi-command blocks (`;`- or newline-separated — the shape alone triggers it); `VAR=x cmd` env-assignment prefixes; `$(...)` substitution, including a literal backtick anywhere in the command, even inside a quoted search pattern; and redirection. Write search patterns with the regex hex escape `\x60` (`[\x60]` inside a bracket expression) in regex mode — `rg -F` has no escapes and would need the literal character. Canonical safe search shape:

```bash
rg -n '\x60vstack refresh\x60' skills/
```

`approval required by policy, but AskForApproval is set to Never` means the shape was flagged, not access. Do not retry the shape and do not wait for approval — none can arrive.

Rewrites:

- Polling loops → the orch waiters `ci-wait`, `approval-wait`, `queue-wait`.
- Multi-item sweeps → one simple command per item.
- Derived values → helper scripts (`git-context`, `workflow-state`), never substitution.
- File writes → harness file tools or `apply_patch`, never redirection.
- Related `workflow-state` operations → one `get '{...}'` or one `update '... | ...'`. Split what cannot collapse — `set-git-head`/`set-now` (they compute their own value), a read mixed with a write, a `// empty` default that would collapse a combined object, a per-item loop — into separate one-command calls.
- Several file reads → separate read commands or the harness file-read tool.
- An optional environment variable affecting a command → omit the option and let the script auto-detect, or read it with `printenv VAR` and run a second command with a literal value. Never put an unset-variable expansion in a required command.

### Env-assignment prefixes

The prefix is an environment precondition, not part of the required command — normalize it where the command is accepted into the workflow, before any agent is asked to run it, however authoritative its source. `printenv VAR` confirms ordinary variables; `locale` confirms locale variables by their effective `LC_*` lines (an unset `LC_ALL` with an effective `C` locale satisfies `LC_ALL=C`). `env VAR=value cmd args` merely relocates the assignment: the classifier is not documented to accept it, and a shape that *might* pass cannot carry a required verification step. If the ambient environment does not satisfy the precondition, report a blocker instead of running under the wrong environment.

### Policy-rejected porcelain

The classifier rejects some porcelain verbs outright, top-level `git rebase` among them. The classification is harness-side: no user authorization or delegation lifts it, and an "explicitly authorized" rebase fails identically. The replacement for a clean linear issue branch is the worktree skill's guarded `create <ID> --reuse --replay` (or `--restack --replay` to pause on conflicts) with `worktree restack continue|skip|abort` — worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback) — never an improvised force-push. A dirty tree or merge commits in range put the branch outside that recipe: report a blocker.

## Codex Desktop app handoff

`workflows/handoff.md` with `harness=codex-app`, the default for multi-issue handoff when the runtime exposes `codex_app` thread tools. Create exactly one thread per issue with `codex_app.create_thread`, targeting a worktree environment whose `startingState` is `{type: "branch", branchName: "[BASE_BRANCH]"}` from `resolve-base-branch`. Start it with exactly `$orch start [ISSUE_ID]` or `$orch start github [OWNER/REPO]#[N]`, and record the returned thread ID. If the runtime separates creation from prompting, call `codex_app.send_message_to_thread` once with that same prompt.

A `working-tree` starting state can begin the child before generated Codex agents are visible, forcing a `worker` fallback — use it only when the user explicitly asks for a dirty local snapshot. Generated agents must be tracked under `.codex/agents/*.toml` in the saved project branch to be discoverable at all: setup hooks and worktree symlinks run too late.

The Codex CLI does not expose these tools. Do not emulate app handoff with terminal launch, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.
