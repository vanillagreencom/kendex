# Orchestration

Multi-agent session coordination — issue workflows, delegation, review pipelines, cycle planning, and research spikes.

## Commands

Invoke via your AI coding harness (e.g., `/$orchestration <command>`).

| Command | Description |
|---------|-------------|
| `start [ISSUE_ID]` | Start a session — routes by context (main repo, worktree, or new issue) |
| `start new [title]` | Create a new issue and worktree |
| `start self` | Initialize team/auth/state, then await instructions |
| `dev-start [ISSUE_ID]` | Delegate implementation to specialist agents |
| `dev-fix [ISSUE_ID]` | Delegate review fix items |
| `ci-fix PR_NUMBER` | Fix CI failures |
| `review [all \| last N \| HASH]` | On-demand code review |
| `review-pr [PR_NUMBER]` | Pre-submission review |
| `review-pr-comments PR_NUMBER` | Triage PR review comments |
| `submit-pr [PR_NUMBER]` | Push, create PR, bot review, CI |
| `merge-pr PR_NUMBER \| all` | Verify and merge PR(s) |
| `audit-issues project \| issue [IDs]` | Audit issues for relations and hierarchy |
| `cycle-plan` | Prioritized cycle plan |
| `roadmap plan [feature]` | Consult specialists, analyze roadmap |
| `roadmap create @[plan-file]` | Execute roadmap plan |
| `parallel-check [ISSUE_IDS]` | Verify parallel work safety |
| `research-spike` | Quick research exploration |

## Skill Dependencies

Install these before using orchestration workflows:

| Skill | Purpose |
|-------|---------|
| `linear` | Issue tracking (CRUD, cache, comments) |
| `github` | PR operations, CI status |
| `worktree` | Git worktree management |
| `project-management` | TPM audit/cycle/roadmap workflows |
| `decider` | Architectural decision documents |

## Configuration

Set in `.env` or `.env.local`, or export in the shell. Helper scripts source both files automatically when present, with `.env.local` taking precedence.

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORCH_STATE_DIR` | State file directory | `tmp` |
| `GH_TOKEN` | Main/user GitHub token for main-repo dashboard reads | current `gh` auth |
| `GH_BOT_TOKEN` | Bot GitHub token for worktree auth and bot operations | current `gh` auth |
| `GH_ISSUE_PATTERN` | Issue ID regex for branch names | `[A-Z]+-[0-9]+` |
| `BOT_REVIEWERS` | Comma-separated review bot usernames | auto-detect |
| `BOT_CHECK_NAME` | CI check name for early review detection | — |

`bot-review-wait --json` fails fast with JSON `status: "error"` when GitHub auth/API reads are not reliable. Both `bot-review-wait` and `ci-wait` source `scripts/lib/gh-auth.sh` for a four-step auth ladder: (1) sanitize stale `GH_TOKEN`/`GITHUB_TOKEN` that mask working `gh` keyring auth (warns on stderr and unsets); (2) if `GH_TOKEN` ends up empty, load a valid `GH_BOT_TOKEN` from `.env.local`/`.env` (`op://` references resolved via `op read`); (3) on remaining auth failure, drop env tokens and retry the bot-token load so a stale env token plus broken keyring still recovers if `.env.local` provides a valid bot token; (4) if no auth path works, exit `3` with a clear diagnostic.

## Tests

```
bash skills/orchestration/tests/run-all.sh
```

Runs every script-level regression test (`bot_review_wait.sh`, `ci_wait.sh`). Each test stages a temp repo with a parametrized `gh` stub on `PATH` and exercises every rung of the auth ladder — stale-token sanitize, keyring fallback, `.env.local` `GH_BOT_TOKEN` fallback, and the hard “no working auth path” exit (code `3`).

## System Dependencies

- `jq`, `bash` 4+, `flock` (util-linux)

## Setup

1. Install dependency skills: `linear`, `github`, `worktree`, `decider`, `project-management`.
2. Set runtime config in `.env` or `.env.local` (`LINEAR_API_KEY`, `ORCH_STATE_DIR`, etc.).
3. Verify each dependency skill works from the project root before invoking a workflow.
