# Codex runtime reference

Deep halves of the Codex runtime notes in [../SKILL.md](../SKILL.md). Everything here is Codex-specific.

## Shell-shape classifier (`approval_policy = never`)

The Codex CLI classifies shell CONTROL SYNTAX as approval-required no matter how harmless the inner commands are. Rejected shapes: `for`/`while` loops; multi-command blocks (`;`- or newline-separated — the multi-command shape alone triggers the block, even with no substitution or redirection); `VAR=x cmd` env-assignment prefixes; `$(...)` substitution — a literal backtick anywhere in the command counts, even inside a quoted search pattern (write the regex hex escape `\x60` instead, `[\x60]` inside a bracket expression, in regex mode — `rg -F` has no escapes and would need the literal character); and redirection. The rejection `approval required by policy, but AskForApproval is set to Never` means the command shape was flagged, not access: do not retry the same shape and do not wait for approval — none can arrive.

Rewrites:

- Polling loops → the orch waiters `ci-wait`, `approval-wait`, `queue-wait`.
- Multi-item sweeps (e.g. per-worktree `git status`) → a separate single command per item.
- Derived values → helper scripts (`git-context`, `workflow-state`), never substitution.
- File writes → harness file tools or `apply_patch`, never redirection.
- Related `workflow-state` operations → one `get '{...}'` (a jq object returning every field) or one `update '... | ...'` (a piped jq expression applying every mutation atomically). Split what genuinely cannot collapse into one expression — `set-git-head`/`set-now` (they compute their value internally), a read mixed with a write, a `// empty` default that would collapse a combined object, or a per-item loop — into separate one-command calls.
- Several file reads → separate read commands or the harness file-read tool, never a shell loop.
- An optional environment variable affecting a command → omit the option and let the script auto-detect, or read it first with `printenv VAR` and run a second command with a literal value. Never include unset-variable expansions such as `"$OPTIONAL_OVERRIDES"` in required command examples.

### Env-assignment prefixes (Codex)

The prefix is an environment precondition, not part of the required command — normalize it where the command is accepted into the workflow (issue preparation, delegation assembly), before any agent is asked to run it, however authoritative its source. `printenv VAR` confirms ordinary variables; `locale` confirms locale variables by the effective `LC_*` lines (an unset `LC_ALL` with an effective `C`/`POSIX` locale satisfies `LC_ALL=C`). `env VAR=value cmd args` merely relocates the assignment: the classifier is not documented to accept it, and a shape that might pass cannot carry a required verification step — if an `env` form is rejected, that rejection is final; never retry it. If the ambient environment does not satisfy the precondition, report the mismatch as a blocker instead of running under the wrong environment.

### Policy-rejected porcelain (Codex)

The classifier rejects some porcelain verbs outright — top-level `git rebase` among them. The classification is harness-side: no user authorization or delegation can lift it, and an "explicitly authorized" rebase fails identically. The documented replacement for a clean, linear issue branch is the worktree skill's guarded `create <ID> --reuse --replay` (or `--restack --replay` to pause on conflicts) with `worktree restack continue|skip|abort` controls — worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback) — never an improvised force-push. A dirty tree or merge commits in the range put the branch outside that recipe: report a blocker.

## Codex Desktop app handoff

Invoked as `workflows/handoff.md` with `harness=codex-app`. When `handoff` receives multiple issues and the runtime exposes Codex app thread tools, default to `harness=codex-app` unless the user explicitly selected another harness.

Before creating child threads, run the Codex app agent preflight (`scripts/codex-app-agent-preflight`) to check whether tracked `.codex/agents/*.toml` files are present in the saved project branch — setup hooks run too late for subagent type discovery. If preflight reports a warning, present the exact message and continue only after explicit user acceptance of the risk that child sessions may fall back to `worker`; stop on a preflight `severity=error` or if the user declines. Do not silently create degraded child threads.

Create one Codex app thread per issue with `codex_app.create_thread`, target a worktree environment whose `startingState` is `type="branch"` with `branchName` set to the resolved base branch, start it with exactly `$orch start [ISSUE_ID]` or `$orch start github [OWNER/REPO]#[N]`, and record the returned thread ID. Do not use a `working-tree` starting state unless the user explicitly requests a dirty local snapshot — that path can start the child before generated Codex agents are visible and force `worker` fallback. If the runtime separates thread creation from prompting, call `codex_app.send_message_to_thread` once with that same start prompt. The Codex CLI does not expose these tools; do not emulate app handoff with terminal launch, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.
