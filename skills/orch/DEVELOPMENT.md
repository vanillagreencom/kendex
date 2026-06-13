# Orchestration — Development Notes

Implementation details and contributor notes. End-user setup: [`README.md`](./README.md). Agent-facing instructions: [`SKILL.md`](./SKILL.md).

## GitHub Auth Fallback

`bot-review-wait` and `ci-wait` share `scripts/lib/gh-auth.sh::orch_sanitize_gh_env`. Four-step ladder:

1. **Sanitize.** Env tokens set but `gh auth status` fails → try `env -u GH_TOKEN -u GITHUB_TOKEN gh auth status`. If that succeeds, warn on stderr and unset.
2. **Bot-token load.** `GH_TOKEN` empty → load `GH_BOT_TOKEN` from `.env`, `vstack.settings.toml`, then `.env.local`. `op://` references resolve via `op read`.
3. **Fallback retry.** Auth still fails → drop env tokens, retry bot-token load. Recovers when project config/secrets have a valid token despite broken keyring.
4. **Hard fail.** No path works → exit `3` with diagnostic. Callers do not poll against empty output.

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
