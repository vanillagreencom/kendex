# Orchestration

Primary-agent orchestration for one Linear or GitHub work item at a time: it picks up an issue, delegates the implementation to a specialist agent, runs a reviewer fan-out, routes the fixes back, opens the PR, and shepherds it through the review gate and CI to merge. It never writes code itself. For a project that wants issues taken from tracker to merged PR by agents, with a person deciding only product questions and merges.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

Needs the `github`, `worktree`, `dev`, `reviewer`, `decider` and `project-management` skills, plus `linear` for Linear workflows; `second-opinion` (a local pre-PR review) and `review-gate` (multi-PR watching) are optional and detected. System dependencies: `jq`, Bash 3.2, and `flock`.

## What it does

- Runs one cycle per session: get the issue, dev implements, review, dev fixes blockers, re-review the fix diff, push the PR, review gate, merge.
- Bounds every loop: minor suggestions never trigger another review round, and a finding that cannot affect real usage is declined rather than fixed or filed.
- Accepts progress from on-disk artifacts plus git and tracker state, never from an agent's chat message, so a session survives compaction and an agent going quiet.
- Asks you about product and experience decisions, merge, scope beyond the issue, and revisiting a recorded decision; settles technical choices by rule or by the specialist who owns them.
- `oversee` runs one session per unblocked item and shepherds every PR to merge.

Every command and its workflow: [SKILL.md](SKILL.md) § Commands. Invoke through your harness (`/orch <command>`).

## How it works

A parent issue with children is a container: it is never orchestrated or merged as one PR. Each child is its own PR unit, and the container closes when its last child merges. To keep a bundle as a single session and PR, add `(one PR)` to the parent's title; that marker wins over the `agent:multi` label.

Waiting on CI, approvals and the merge queue goes through the skill's own waiters (`ci-wait`, `approval-wait`, `queue-wait`), each with a bounded budget and one verdict. Launch lanes spread a fleet across the harness accounts on a machine by headroom.

## Customise

Non-secret settings go in committed `kendex.settings.toml` under `[env]`; secrets in `.env.local`. Nothing is marked required, so installing writes nothing into your settings file; [kendex.settings.toml.example](kendex.settings.toml.example) comments the keys worth changing first.

| Variable | Purpose | Default |
|---------|---------|---------|
| `ORCH_STATE_DIR` | Workflow state directory; the `--state-dir` flag wins where both are set | `tmp` |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names, matched case-insensitively and canonicalized | `([A-Z]+-[0-9]+\|issue-[0-9]+)` |
| `CI_FIX_MAX_CYCLES` | Automatic ci-fix cycles for one PR, counted across the heads they push; a passing CI run clears the count | `6` |
| `REVIEW_MAX_CYCLES` | Internal re-review cycles per issue; the number set is the number of re-entries allowed | `4` |
| `REVIEW_MAX_EXTERNAL_ROUNDS` | External comment-triage passes and automatic review-wait restarts on one PR head | `4` |
| `REVIEWER_SLOT_BUDGET` | Concurrent agent-session budget counting the primary; `0` is unlimited; reviews run in waves past it. On Codex, the cap `spawn-adapter slots` reports | `0` |
| `ORCH_DECISION_MODE` | `ask` presents decision points; `auto-recommended` executes the recommended option. The always-ask set in [SKILL.md § The Cycle](SKILL.md#the-cycle) holds in every mode | `auto-recommended` |
| `ORCH_MERGE_AUTONOMY` | `auto` merges once every gate is green; `ask` presents the merge decision | `auto` |
| `PR_REVIEW_ON_TIMEOUT` | `proceed` advances only when no reviewer engaged and no thread is open; `block` reports the timeout | `proceed` |
| `ORCH_OVERSEER_LANES` | Concurrent lanes `oversee` keeps in flight | `3` |
| `QA_PERF_PATHS` | Space-separated path globs whose modification adds the `needs-perf-test` QA signal | empty |
| `RECONCILE_STALE_HOURS` | Hours before an In Progress or In Review item counts as started-stale in `reconcile-work-items` sweeps | `24` |
| `WORKTREE_CLI` | Path to the worktree CLI `open-terminal` drives; empty resolves the installed worktree skill's script | resolved |
| Review-gate settings | `REVIEW_GATE_MODE`, `PR_REVIEW_GATE`, `PR_REVIEW_CHECK`, `PR_REVIEW_WAIT_SECS`: [references/gates.md](references/gates.md) | |
| Lane settings | `ORCH_LANE_DIRS`, `ORCH_LANE_ALIASES`, `ORCH_LANE_MAX_PCT`, `ORCH_TMUX_VERIFY_SECS`: `lanes --help`, `open-terminal --help` | |

Maintainer notes and the test entry point: [DEVELOPMENT.md](DEVELOPMENT.md).
