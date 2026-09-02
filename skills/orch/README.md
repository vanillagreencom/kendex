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
| `post-summary [ISSUE_ID]` | Post summary and handoff comments |
| `oversee` | Run one session per unblocked item and shepherd every PR to merge |

## Setup

1. Install the required skills: `github`, `worktree`, `dev`, `reviewer`, `decider`, `project-management`. Add `linear` for Linear workflows. `second-opinion` (pre-PR local review) and `review-gate` (multi-PR watching) are optional — orch checks for them and works without them.
2. Install `jq`, `bash` 3.2, and `flock`.
3. Put non-secret settings in `kendex.settings.toml` under `[env]` and secrets in `.env.local`. The keys a project sets are the Configuration table below, with the lane keys' detail in `lanes --help` and `open-terminal --help`; this skill's `kendex.settings.toml.example` comments the ones worth changing first. Orch marks none of them `# required`, so installing it writes nothing into your settings file.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORCH_STATE_DIR` | State-file directory (the `--state-dir` flag wins when both are set) | `tmp` |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names (matched case-insensitively, then canonicalized: `issue-N` lowercase, Linear-style uppercase) | `([A-Z]+-[0-9]+\|issue-[0-9]+)` |
| `CI_FIX_MAX_CYCLES` | Max automated ci-fix cycles per PR submission or merge recovery | `6` |
| `REVIEW_MAX_CYCLES` | Max internal re-review cycles per issue in review-pr § 4; the `rereview_panel` write raises `rereview_cycles` and refuses at it, so the number configured is the number of re-entries allowed | `4` |
| `REVIEW_MAX_EXTERNAL_ROUNDS` | Max external review rounds on an open PR. At or past it a finding gets a disposition and no fix push, except a defect the diff introduces or arms | `4` |
| `REVIEWER_SLOT_BUDGET` | Total concurrent agent-session budget, counting the primary; `0` = unlimited. Reviews run in waves when the reviewer set exceeds the free slots. On Codex, set it to the cap `spawn-adapter slots` reports | `0` |
| `ORCH_DECISION_MODE` | `ask` presents decision points; `auto-recommended` executes the recommended option and logs `auto-selected: [option] — [reason]` in workflow-state `auto_decisions`. Review findings disposition is by rule in EVERY mode — no mode presents a selection menu over findings. The always-ask set in [SKILL.md § The Cycle](SKILL.md#the-cycle) applies in every mode | `ask` |
| `ORCH_MERGE_AUTONOMY` | `auto` merges without asking once every merge gate is green; `ask` presents the merge decision. A `MERGE_READY = false` state never auto-merges | `ask` |
| `ORCH_OVERSEER_LANES` | Max concurrent lanes `oversee` keeps in flight | `3` |
| `QA_PERF_PATHS` | Space-separated path globs whose modification adds the `needs-perf-test` QA signal in `workflows/review-pr.md` § 5. Empty means the diff scan never raises it | empty |
| `RECONCILE_STALE_HOURS` | Hours before an In Progress / In Review item counts as started-stale in `reconcile-work-items` sweeps | `24` |
| `WORKTREE_CLI` | Path to the worktree CLI `open-terminal` drives; empty resolves the installed worktree skill's `scripts/worktree` | *(resolved)* |
| Review-gate settings | `REVIEW_GATE_MODE`, `PR_REVIEW_GATE`, `PR_REVIEW_CHECK`, `PR_REVIEW_QUORUM`, `PR_REVIEW_ON_TIMEOUT`, `PR_REVIEW_NUDGE*`, `PR_REVIEW_WAIT_SECS` — [references/gates.md](references/gates.md) | — |
| Lane settings | `ORCH_LANE_DIRS`, `ORCH_LANE_ALIASES`, `ORCH_LANE_MAX_PCT`, `ORCH_TMUX_VERIFY_SECS` — `lanes --help`, `open-terminal --help` | — |

## Bundles

A parent issue with children is a **container**: it is never orchestrated or merged as one PR. Each child is its own PR unit, and the container closes automatically when its last child merges. To keep a bundle as a single session and PR, add `(one PR)` to the parent's title — that marker always wins, including over the `agent:multi` label.

Maintainer notes, including the test entry point: [`DEVELOPMENT.md`](./DEVELOPMENT.md).
