# Orchestration

Primary-agent, single work-item orchestration for Linear and GitHub issues.

## Commands

Invoke via your AI coding harness (e.g., `/orch <command>` or `/skill:orch <command>`).

| Command | Description |
|---------|-------------|
| `start [ISSUE_ID]` | Prepare/start one Linear issue |
| `start github OWNER/REPO#N` | Prepare/start one GitHub issue |
| `start new linear\|github ...` | Create one issue, then start it |
| `handoff linear\|github ...` | Launch independent work item sessions; no monitoring |
| `plan-issues PLAN_PATH linear\|github` | Convert plan items into tracker issues |
| `dev-start [ISSUE_ID]` | Delegate implementation to specialist agents |
| `dev-fix [ISSUE_ID]` | Delegate review fix items |
| `ci-fix PR_NUMBER \| queue` | Fix CI failures |
| `review [all \| last N \| HASH]` | On-demand code review |
| `review-codebase [PATH]` | Whole-codebase reviewer fanout |
| `review-pr [PR_NUMBER]` | Pre-submission review |
| `review-pr-comments PR_NUMBER` | Triage PR review comments |
| `submit-pr [PR_NUMBER]` | Local review, push, create PR, async triage, approval gate, CI verify, merge gates |
| `merge-pr PR_NUMBER \| all` | Verify and merge PR(s) |
| `parallel-check [ISSUE_IDS]` | Verify parallel work safety |

## Skill Dependencies

| Skill | Purpose |
|-------|---------|
| `linear` | Linear issue tracking (CRUD, cache, comments) |
| `github` | PR operations, CI status |
| `worktree` | Git worktree management |
| `project-management` | TPM audit/cycle/roadmap workflows |
| `decider` | Architectural decision documents |

## Setup

1. Install dependency skills: `github`, `worktree`, `decider`, `project-management`; add `linear` for Linear workflows.
2. Set non-sensitive runtime defaults in `vstack.settings.toml`; keep secrets in `.env.local`.
3. Verify each skill works from the project root before invoking a workflow.

## Configuration

Set non-sensitive values in `vstack.settings.toml` under `[env]`. Existing `.env` and `.env.local` files still work; load order is `.env`, then `vstack.settings.toml`, then `.env.local`.

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORCH_STATE_DIR` | State file directory (env fallback for the `--state-dir` flag, which wins) | `tmp` |
| `ORCH_CACHE_DIR` | Parallel-group safety cache | `.cache/orch` |
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved GitHub token from the parent process | current `gh` auth |
| `GH_BOT_TOKEN` | Bot GitHub token for worktree auth | `GH_TOKEN` / `GITHUB_TOKEN`, then current `gh` auth |
| `GH_ISSUE_PATTERN` | Issue ID regex for branch names | `[A-Z]+-[0-9]+` |
| `CI_WAIT_NO_CHECKS_GRACE` | Seconds `ci-wait` keeps polling before failing when no CI checks have registered yet (covers approval-gated CI dispatch latency) | `180` |
| `PR_APPROVAL_GATE` | Approval merge gate policy: `on` requires a GitHub-native approval verdict; `off` for repos with no review bots/reviewers — submit-pr skips the approval wait and merge-pr treats `not_approved` as informational. Explicit config only; never auto-detected | `on` |
| `CI_FIX_MAX_CYCLES` | Max automated ci-fix cycles per PR submission (`submit-pr`) or merge recovery (`merge-pr`) before the workflow reports the persistent CI failure — failing checks, last error, per-cycle attempts — back to the user | `6` |

Bot reviews are asynchronous: no orch workflow blocks PR submission on bot-specific signals — emoji reactions, sticky comments, and checklist prose are never parsed as gates. Merges gate on internal review, green CI, zero unresolved review comments (every bot comment replied to and resolved), and a GitHub-native approval verdict from any reviewer — human or bot — polled by `approval-wait` via `reviewDecision`, with a latest-review-per-reviewer fallback when no required-review protection exists. If no approval verdict arrives within 15 minutes, the workflow prompts the user to force merge, keep waiting, or stop. The approval gate runs before CI verification, so repos that start CI only after an approval (approval-gated jobs or a merge queue) never deadlock; `ci-wait` keeps an old pre-approval aggregate failure pending while the current-head approved run is active, even if a later review-comment dispatch is an all-skipped no-op. On always-on repos the post-approval CI verify simply returns quickly.

See [`DEVELOPMENT.md`](./DEVELOPMENT.md) for GitHub auth fallback details and the test runner.

GitHub auth helpers are env-first. If launch-time configuration already provides a resolved `GH_TOKEN`, `GITHUB_TOKEN`, or `GH_BOT_TOKEN`, orch keeps it and does not re-read `op://` references from `.env.local` for GitHub auth. Auth preflight validates selected env tokens with `gh api user`; `gh auth status` is only authoritative for keyring auth when no env token is selected. Service-account setup for the `op` CLI remains local environment configuration.

Git workflow helpers use targeted `origin` operations for PR closure. When a
repo remote is SSH-backed but `gh` auth is valid, `skills/github/scripts/git-https-auth`
adds per-command HTTPS rewrite and `gh auth git-credential` config so Codex and
other non-SSH sessions can fetch, pull, or push without mutating remotes.
Optional secondary remotes are not fetched during merge sync.

## Helper Scripts

Use `skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]` to print the base branch for a worktree. It honors `WORKTREE_DEFAULT_BRANCH`, then `origin/HEAD`, and falls back to `main`.

Use `skills/orch/scripts/git-context branch|head|issue-from-branch|repo-root|common-root|timestamp [WORKTREE_PATH]` when workflow guidance needs git-derived values without inline command substitution, pipelines, or `cd && ...` chains.

Use `skills/orch/scripts/workflow-state exists --json ISSUE_ID` when a workflow needs structured existence status without relying on shell exit-code capture.

Use `skills/orch/scripts/workflow-state set-git-head ISSUE_ID FIELD [WORKTREE_PATH]` and `set-now ISSUE_ID FIELD` for common state writes that would otherwise require nested `$(git ...)` or `$(date ...)` snippets.

To target a canonical state directory from a worktree, pass the global `skills/orch/scripts/workflow-state --state-dir PATH SUBCOMMAND ...` flag before the subcommand rather than an `ORCH_STATE_DIR=… workflow-state …` env prefix. The env-assignment prefix is rejected under Codex `approval=never` (a flagged command shape); the plain flag is classifier-safe. `--state-dir` takes precedence over the `ORCH_STATE_DIR` environment fallback, which stays supported.

Use `skills/orch/scripts/pr-view-json WORKTREE_PATH --json number,state` when a workflow needs to inspect the current branch's PR. It prints the structured `status=no_pr` JSON with exit code 0 so `submit-pr` can route to PR creation without shell fallback expressions.

Use `skills/orch/scripts/review-init` to initialize standalone review context and print branch, worktree, issue ID, state path, and whether state was created as JSON.

Use `skills/orch/scripts/review-artifact-check WORKTREE_PATH AGENT_NAME DELEGATED_AT_EPOCH` to deterministically validate a reviewer's on-disk JSON artifact (existence, `mtime >=` delegation epoch, `jq -e '.verdict'`). It prints `{ok, path, reason}`; review-pr accepts a reviewer completion only when `ok == true`. `review-artifact-check --file <json_path> [delegated_at_epoch]` validates one explicit artifact (such as an external second-opinion review output); when the optional `delegated_at_epoch` is supplied it applies the same freshness gate, so a stale or misdated file is rejected instead of accepted on existence + verdict alone.

Use `skills/orch/scripts/tracker-for-issue ISSUE_ID` when workflow docs need tracker branching without inline shell conditionals.

Use `skills/orch/scripts/orch-env VAR_NAME DEFAULT` to print the effective value of a vstack `[env]` setting (process env > `vstack.settings.toml` > default) when a workflow step needs a configurable value without inline shell fallbacks. With a numeric default, a non-numeric effective value falls back to the default — e.g. `orch-env CI_FIX_MAX_CYCLES 6` for the ci-fix cycle budget.

## System Dependencies

- `jq`, `bash` 4+, `flock` (util-linux)

## Codex Desktop Threads

For app-visible handoff, use `handoff ... --harness codex-app` from the orch workflow while running inside Codex Desktop. This path uses `codex_app` thread tools, not the Codex CLI.

For multi-issue handoff, `handoff ISSUE_ID ISSUE_ID` defaults to Codex app threads when those tools are exposed. Before creating threads, run `skills/orch/scripts/codex-app-agent-preflight .`. If it reports `ok: true`, continue normally. If it reports a warning, show the message and continue only after the user explicitly accepts the risk that child sessions may fall back to `worker`; stop only on `severity: "error"` or if the user declines. Create one Codex app thread per issue. Start each thread with exactly `$orch start ISSUE_ID` for Linear or `$orch start github OWNER/REPO#N` for GitHub. Target a worktree environment with `startingState: {type: "branch", branchName: "[BASE_BRANCH]"}`, where `BASE_BRANCH` comes from `skills/orch/scripts/resolve-base-branch .`. Do not use `startingState: {type: "working-tree"}` for normal orch handoff; app-created worktrees can otherwise start before ignored generated Codex agent files are visible, forcing generated dev/reviewer agents through `worker` fallback. If the runtime separates thread creation from prompting, call `codex_app.send_message_to_thread` once for the returned thread ID with that same start prompt.

Codex Desktop may create those child sessions as detached app worktrees under `~/.codex/worktrees`. Generated Codex agents must be tracked under `.codex/agents/*.toml` in the saved project branch for app-created worktrees to expose them before subagent discovery; setup hooks and worktree symlinks run too late to affect that discovery. The preflight is a warning gate for missing or ignored agent TOMLs, not a hard launch blocker after user acceptance. The child `start` workflow still runs the normal worktree lifecycle: `session-init --json github OWNER/REPO#N` normalizes the branch to `issue-N`, then the session proceeds through implementation, review, PR submission, CI, and merge offer. A dirty or detached worktree is a hard preflight failure before review or PR submission.

The Codex CLI does not expose these thread tools. Do not automate app-visible handoff with terminal launch helpers, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.
