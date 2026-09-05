# Orchestration

A workflow for taking Linear or GitHub issues through implementation, review and merge. A primary agent assigns work to coding and review agents and tracks their results.

## Install

```bash
kendex add vanillagreencom/kendex --skill orch
```

Requires jq, Bash 3.2 and flock. kendex installs the required workflow skills. Add linear for Linear issues. Second-opinion and review-gate are optional.

## Features

- Assign implementation to a specialist in an isolated worktree.
- Collect review findings and route required fixes to the implementer.
- Open PRs and monitor CI and review requirements.
- Resume work from saved workflow records.
- Coordinate separate sessions for ready issues.

## How it works

The primary agent reads the selected issue and prepares a worktree. It assigns implementation to a coding agent. Review agents inspect the completed change and return findings. The primary agent routes required fixes, opens the PR and checks CI and review results. It follows your configured merge policy when the PR is ready.

## Settings

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
