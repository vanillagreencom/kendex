# Orchestration — Development Notes

Implementation details and contributor notes. End-user setup: [`README.md`](./README.md). Agent-facing instructions: [`SKILL.md`](./SKILL.md).

## GitHub Auth Fallback

`bot-review-wait` and `ci-wait` use `scripts/lib/gh-auth.sh`, which wraps the GitHub skill's shared `scripts/lib/gh-auth.sh` helpers. Each candidate source is probed at most once during startup:

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

## Bot Review Terminal Fallback

`bot-review-wait` primarily trusts per-reviewer signals from formal reviews, sticky comments, reactions, and unresolved threads. Some bot runs can leave a sticky comment looking pending after GitHub has already moved the PR to `reviewDecision=APPROVED`. In that case the waiter promotes pending/unknown reviewers to approved only when:

- no reviewer has an explicit `changes` status,
- `gh pr view --json reviewDecision` reports `APPROVED`,
- `BOT_CHECK_NAME` is unset or the matching check line is `pass`, and
- the PR has zero unresolved review threads.

The emitted reviewer signals include `pr_review_decision:approved` and `pr_threads:clear` so callers can distinguish this fallback from a direct sticky/comment verdict. Entries with this signal skip the later sticky-checklist drain wait because the fallback already verified that thread propagation is clear.

## Tests

```bash
bash skills/orch/tests/run-all.sh
# Filter:
bash skills/orch/tests/run-all.sh session_init
```

Tests stage isolated repos/worktrees with parametrized CLI stubs on `PATH`. Each `tests/*.sh` is self-contained and prints `pass: N fail: M`. Suites:

- `bot_review_wait.sh` — review-wait state machine + auth ladder.
- `ci_wait.sh` — CI-wait state machine + auth ladder.
- `session_init.sh` — worktree Linear auth diagnostic preservation.

## Codex App Worktree Routing

Codex Desktop handoff starts each child thread in an app-managed worktree, often on detached `HEAD`. App handoff must first run `codex-app-agent-preflight`; generated Codex agent TOMLs must be tracked under `.codex/agents/*.toml` in the saved project branch for generated agent types to be visible before child creation. Local ignored/generated files are not enough: setup hooks, `WORKTREE_SYMLINKS`, and `codex-setup` run too late for subagent type discovery. Missing or ignored agent TOMLs are a warning gate, not a hard blocker: show the warning and continue only after explicit user acceptance of the `worker` fallback risk.

When preflight passes, create the app worktree from the resolved base branch (`startingState: {type: "branch", branchName: "[BASE_BRANCH]"}`), not from the controller `working-tree` snapshot. The branch path avoids dirty controller state; the tracked-agent preflight documents whether generated Codex agent types should be available before first delegation.

`session-init --json github OWNER/REPO#N` is the normalization boundary: it converts the GitHub ref to `issue-N`, calls the worktree skill's `codex-branch` helper when the cwd is under `~/.codex/worktrees`, and returns the normalized issue context to `start-worktree.md`.

The managed lifecycle relies on committed branch diffs. `dev-start.md`, `review-pr.md`, and `submit-pr.md` must reject dirty or detached worktrees before review/submission so uncommitted edits cannot be treated as "no changes".
