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
| `submit-pr [PR_NUMBER]` | Push, create PR, bot review, CI |
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
| `ORCH_STATE_DIR` | State file directory | `tmp` |
| `ORCH_CACHE_DIR` | Parallel-group safety cache | `.cache/orch` |
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved GitHub token from the parent process | current `gh` auth |
| `GH_BOT_TOKEN` | Bot GitHub token for worktree auth | `GH_TOKEN` / `GITHUB_TOKEN`, then current `gh` auth |
| `GH_ISSUE_PATTERN` | Issue ID regex for branch names | `[A-Z]+-[0-9]+` |
| `BOT_REVIEWERS` | Comma-separated review bot usernames | auto-detect |
| `BOT_CHECK_NAME` | CI check name for early review detection and PR-level approved fallback gating | — |
| `BOT_REVIEW_SETTLE_SECONDS` | Re-check window after Codex-style approval signals to catch late inline review threads | `180` |
| `BOT_REVIEW_SETTLE_INTERVAL` | Poll interval during the terminal settle window | `15` |

`bot-review-wait` also handles stale pending bot prose: when GitHub reports `reviewDecision=APPROVED`, the configured bot check has passed if one is set, and no unresolved review threads remain, it can return a terminal approved result instead of continuing to poll the stale status comment or checklist. Codex-style reaction or PR-decision approvals get a short settle/re-check window first so late inline review threads can still flip the verdict to changes.

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

Use `skills/orch/scripts/pr-view-json WORKTREE_PATH --json number,state` when a workflow needs to inspect the current branch's PR. It prints the structured `status=no_pr` JSON with exit code 0 so `submit-pr` can route to PR creation without shell fallback expressions.

Use `skills/orch/scripts/review-init` to initialize standalone review context and print branch, worktree, issue ID, state path, and whether state was created as JSON.

Use `skills/orch/scripts/tracker-for-issue ISSUE_ID` when workflow docs need tracker branching without inline shell conditionals.

## System Dependencies

- `jq`, `bash` 4+, `flock` (util-linux)

## Codex Desktop Threads

For app-visible handoff, use `handoff ... --harness codex-app` from the orch workflow while running inside Codex Desktop. This path uses `codex_app` thread tools, not the Codex CLI.

For multi-issue handoff, `handoff ISSUE_ID ISSUE_ID` defaults to Codex app threads when those tools are exposed. Before creating threads, run `skills/orch/scripts/codex-app-agent-preflight .`. If it reports `ok: true`, continue normally. If it reports a warning, show the message and continue only after the user explicitly accepts the risk that child sessions may fall back to `worker`; stop only on `severity: "error"` or if the user declines. Create one Codex app thread per issue. Start each thread with exactly `$orch start ISSUE_ID` for Linear or `$orch start github OWNER/REPO#N` for GitHub. Target a worktree environment with `startingState: {type: "branch", branchName: "[BASE_BRANCH]"}`, where `BASE_BRANCH` comes from `skills/orch/scripts/resolve-base-branch .`. Do not use `startingState: {type: "working-tree"}` for normal orch handoff; app-created worktrees can otherwise start before ignored generated Codex agent files are visible, forcing generated dev/reviewer agents through `worker` fallback. If the runtime separates thread creation from prompting, call `codex_app.send_message_to_thread` once for the returned thread ID with that same start prompt.

Codex Desktop may create those child sessions as detached app worktrees under `~/.codex/worktrees`. Generated Codex agents must be tracked under `.codex/agents/*.toml` in the saved project branch for app-created worktrees to expose them before subagent discovery; setup hooks and worktree symlinks run too late to affect that discovery. The preflight is a warning gate for missing or ignored agent TOMLs, not a hard launch blocker after user acceptance. The child `start` workflow still runs the normal worktree lifecycle: `session-init --json github OWNER/REPO#N` normalizes the branch to `issue-N`, then the session proceeds through implementation, review, PR submission, CI, and merge offer. A dirty or detached worktree is a hard preflight failure before review or PR submission.

The Codex CLI does not expose these thread tools. Do not automate app-visible handoff with terminal launch helpers, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.
