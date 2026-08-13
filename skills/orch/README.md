# Orchestration

Primary-agent orchestration for one Linear or GitHub work item at a time. It picks up an issue, delegates the implementation to a specialist agent, runs a reviewer fan-out, routes the fixes back, opens the PR, and shepherds it through the review gate and CI to merge. It never writes code itself — every implementation, review, and QA task goes to a sub-agent.

## How it works

A session runs one cycle: get the issue → dev implements → review → dev fixes blockers → re-review the fix diff → push the PR → review gate → merge. Loops are bounded — minor suggestions never trigger another review round, and a finding that cannot affect real usage is declined rather than fixed or filed. Progress is accepted from on-disk artifacts plus git and tracker state, never from an agent's chat message, so a session survives compaction and an agent going quiet mid-run.

You are asked about product and experience decisions. Technical choices are settled by rule or by the specialist who owns them. Merge, expanding scope beyond the issue, and revisiting a recorded decision always ask.

## Commands

Invoke through your AI coding harness (`/orch <command>`, `/skill:orch <command>`).

| Command | Description |
|---------|-------------|
| `start [ISSUE_ID]` \| `start github OWNER/REPO#N` | Prepare and run one issue |
| `start new linear\|github ...` | Create one issue, then start it |
| `handoff linear\|github ...` | Launch independent sessions; no monitoring |
| `plan-issues PLAN_PATH linear\|github` | Convert a plan into tracker issues |
| `dev-start [ISSUE_ID]` / `dev-fix [ISSUE_ID]` | Delegate implementation / fix items |
| `ci-fix PR_NUMBER \| queue` | Fix CI failures |
| `review [all \| last N \| HASH]` | On-demand review of local changes |
| `review-codebase [PATH]` | Whole-codebase reviewer fanout |
| `review-pr [PR_NUMBER]` | Pre-submission review cycle |
| `review-pr-comments PR_NUMBER` | Triage PR review comments |
| `submit-pr [PR_NUMBER]` | Push, open the PR, gate it, verify CI |
| `merge-pr PR_NUMBER \| all` | Verify and merge |

## Setup

1. Install the required skills: `github`, `worktree`, `dev`, `reviewer`, `decider`, `project-management`. Add `linear` for Linear workflows. `second-opinion` (pre-PR local review) and `review-gate` (multi-PR watching) are optional — orch checks for them and works without them.
2. Install `jq`, `bash` 4+, and `flock`.
3. Put non-secret settings in `vstack.settings.toml` under `[env]` and secrets in `.env.local`. `vstack.settings.toml.example` ships every orch key with its default and a comment explaining it.

## Bundles

A parent issue with children is a **container**: it is never orchestrated or merged as one PR. Each child is its own PR unit, and the container closes automatically when its last child merges. To keep a bundle as a single session and PR, add `(one PR)` to the parent's title — that marker always wins, including over the `agent:multi` label.

Maintainer notes, including the test entry point: [`DEVELOPMENT.md`](./DEVELOPMENT.md).
