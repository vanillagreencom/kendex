# Orchestration — Development Notes

Implementation details and contributor notes. End-user setup: [`README.md`](./README.md). Agent-facing instructions: [`SKILL.md`](./SKILL.md).

## GitHub Auth Fallback

`approval-wait` and `ci-wait` use `scripts/lib/gh-auth.sh`, which wraps the GitHub skill's shared `scripts/lib/gh-auth.sh` helpers. Each candidate source is probed at most once during startup:

1. **Selected env token.** If `GH_TOKEN` or `GITHUB_TOKEN` is set, validate it with bounded `gh api user`.
2. **Keyring fallback.** If that env token fails, try `env -u GH_TOKEN -u GITHUB_TOKEN gh auth status` once. If it succeeds, warn on stderr and unset the stale env token.
3. **Bot-token load.** If keyring does not recover, unset stale `GH_TOKEN`/`GITHUB_TOKEN` before loading a `GH_BOT_TOKEN` candidate from process env or project config/secrets. `op://` references resolve via `op read` only after the final token source is selected. The `github.sh` router separately prefers resolved `GH_BOT_TOKEN` before resolved `GITHUB_TOKEN` so bot access is not blocked by a user token.
4. **No-env keyring.** If no env token was present at startup and no bot token loads, probe keyring auth once.
5. **Hard fail.** No path works → exit `3` with diagnostic. Callers do not poll against empty output.

The `op` CLI service-account/token setup is intentionally outside orch. Launchers may inject resolved secrets before starting Codex, Claude, or Pi; orch preserves those values instead of clobbering them with local `op://` references.

## Git HTTPS Fallback

Merge and submit workflows should use targeted `origin` git operations through
the GitHub skill's `scripts/git-https-auth` helper instead of broad remote
enumeration. The helper is a per-command fallback for SSH-backed GitHub remotes:
it validates selected env-token or keyring `gh` auth, then supplies temporary
`credential.helper=!gh auth git-credential` and `url.https://github.com/.insteadOf`
config so GitHub SSH URLs work over HTTPS. It does not persist config.

Do not use `git fetch --all --prune` for current-PR closure. Secondary remotes
may be useful for a project but optional for syncing `origin` after merge, and
their SSH failures should not block branch cleanup or tracker closure.

## Approval Wait

`approval-wait` replaced `bot-review-wait` in #538. The old waiter parsed bot-specific signals — sticky-comment verdicts, checklist state, emoji reactions — which coupled the merge path to each bot's signaling dialect and provider quota. The new poller reads only GitHub-native review state:

- `gh pr view --json reviewDecision,latestReviews` — approved when `reviewDecision == "APPROVED"`, or, when `reviewDecision` is empty because no required-review branch protection exists, when at least one reviewer's latest review is APPROVED and none is CHANGES_REQUESTED. `REVIEW_REQUIRED` never falls back to `latestReviews` — branch protection is still waiting on required approvals. COMMENTED and DISMISSED latest reviews neither approve nor block. Any reviewer counts — human or bot — as long as it posts a formal GitHub review.
- A `reviewThreads` GraphQL count of unresolved threads, emitted with every result and used for a `status: "comments"` early return so callers triage new feedback instead of idling to the deadline.

Statuses: `approved` (exit 0); `changes_requested`, `comments`, `timeout` (exit 1); `error` (exit 1, or 3 on auth failure — same auth contract as `ci-wait`). Every exit path emits a final stdout result; `--json` always prints one well-formed object.

## CI Triggering Patterns

The `defer-ci` label pattern is retired — orch never defers, queues, or labels CI. The workflow contract that replaces it: `submit-pr.md` orders the approval gate (§ 4) before CI verification (§ 5), universally and with no repo detection, so CI that only starts after an approval can never deadlock the workflow. Two portable repo-side patterns build on that contract:

- **Approval-gated jobs** (any GitHub plan): trigger the workflow on `pull_request` plus `pull_request_review: types: [submitted]`. A cheap gate job checks the PR's `reviewDecision` (or latest-review approval when no required-review protection exists); heavy jobs declare `needs:` on the gate. Cheap lint/unit jobs can still run unconditionally on `pull_request`.
- **Merge queue** (GitHub Enterprise / public repos): run heavy CI on `merge_group`, minimal CI on `pull_request`, and require the approval for queue entry via branch protection. `merge-pr.md` § 5 handles the queued merge portably with `pr-merge --auto` (exit 75 = queued/armed), watches queue membership, and on ejection (failed merge-group run) routes back into ci-fix automatically — bounded, per-PR, with no cross-session coordination.

Always-on CI (everything on `pull_request`) needs no change — § 5 just verifies checks that already ran. `ci-wait` tolerates post-approval dispatch latency via `CI_WAIT_NO_CHECKS_GRACE` (default 180s) before reporting "no checks registered". It scopes the current-head check rollup to the latest substantive run per workflow, so a later all-skipped `COMMENTED` review dispatch cannot hide an active approved run. A custom aggregate status still pointing at the pre-approval run stays pending while a newer non-failing substantive run exists; the newer run must publish its own status before the waiter can pass, and a failed run or missing replacement remains fail-closed. This section is guidance for consuming repos; vstack's own CI is unaffected.

## Tests

```bash
bash skills/orch/tests/run-all.sh
# Filter:
bash skills/orch/tests/run-all.sh session_init
```

Tests stage isolated repos/worktrees with parametrized CLI stubs on `PATH`. Each `tests/*.sh` is self-contained and prints `pass: N fail: M`. Suites:

- `approval_wait.sh` — GitHub-native approval verdict detection + output contract.
- `ci_wait.sh` — CI-wait state machine + auth ladder.
- `session_init.sh` — worktree Linear auth diagnostic preservation.
- `review_artifact_check.sh` — deterministic reviewer artifact acceptance (`review-artifact-check`), including `--file` freshness with an optional delegated-at boundary, plus review-pr and submit-pr `--file` wiring assertions.

All tests discovered by `run-all.sh` are part of the installed orch skill and
must pass in downstream projects without access to the vstack source checkout.
The source-only CLI/generator regression runs through
`cli/scripts/integration-check.sh`; it validates install/refresh byte identity,
markdownlint, idempotence, the refreshed downstream `run-all.sh` suite, and the
installed dev work-item cache-preflight contract.

## Codex App Worktree Routing

Codex Desktop handoff starts each child thread in an app-managed worktree, often on detached `HEAD`. App handoff must first run `codex-app-agent-preflight`; generated Codex agent TOMLs must be tracked under `.codex/agents/*.toml` in the saved project branch for generated agent types to be visible before child creation. Local ignored/generated files are not enough: setup hooks, `WORKTREE_SYMLINKS`, and `codex-setup` run too late for subagent type discovery. Missing or ignored agent TOMLs are a warning gate, not a hard blocker: show the warning and continue only after explicit user acceptance of the `worker` fallback risk.

When preflight passes, create the app worktree from the resolved base branch (`startingState: {type: "branch", branchName: "[BASE_BRANCH]"}`), not from the controller `working-tree` snapshot. The branch path avoids dirty controller state; the tracked-agent preflight documents whether generated Codex agent types should be available before first delegation.

`session-init --json github OWNER/REPO#N` is the normalization boundary: it converts the GitHub ref to `issue-N`, calls the worktree skill's `codex-branch` helper when the cwd is under `~/.codex/worktrees`, and returns the normalized issue context to `start-worktree.md`.

The managed lifecycle relies on committed branch diffs. `dev-start.md`, `review-pr.md`, and `submit-pr.md` must reject dirty or detached worktrees before review/submission so uncommitted edits cannot be treated as "no changes".
