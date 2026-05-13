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

`bot-review-wait --json` fails fast with JSON `status: "error"` when GitHub auth/API reads are not reliable. Both `bot-review-wait` and `ci-wait` source `scripts/lib/gh-auth.sh`: if an invalid `GH_TOKEN`/`GITHUB_TOKEN` masks working `gh` keyring auth, the wait process unsets those variables and continues with a warning so a stale inherited token does not 401 every API call.

## System Dependencies

- `jq`, `bash` 4+, `flock` (util-linux)

## Setup

1. Install dependency skills: `linear`, `github`, `worktree`, `decider`, `project-management`.
2. Set runtime config in `.env` or `.env.local` (`LINEAR_API_KEY`, `ORCH_STATE_DIR`, etc.).
3. Verify each dependency skill works from the project root before invoking a workflow.
