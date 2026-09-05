# Second Opinion

Cross-model code review and consultation through an external AI CLI. The model your session runs is never asked to review its own work: Claude Code gets Codex, Codex gets Claude, and the run refuses, stating why, when nothing else is eligible. For a project that wants a second model's findings on a diff or a plan before the PR opens.

## Install

```bash
kendex add vanillagreencom/kendex --skill second-opinion
```

Needs `jq` and at least one external CLI, `claude` or `codex`, logged in.

## What it does

- `review`: code review of a diff range, returned as review-finding JSON in the same schema the internal review agents use.
- `challenge`: adversarial analysis of an approach, returned as text.
- `audit`: examination of existing code, returned as review-finding JSON.
- `quick`: a question to the other model, returned as text.
- `detect`: prints which target a review would run.
- Reviews with several models at once when `SECOND_OPINION_COUNT` is raised, unioning the findings.

## How it works

```
/second-opinion review                     # the branch diff
/second-opinion review last 3 commits
/second-opinion challenge my refactor plan
/second-opinion audit src/auth/
/second-opinion quick is this pattern safe?
```

```bash
./scripts/second-opinion review --cwd .
./scripts/second-opinion review --target claude --range HEAD~3..HEAD --cwd .
```

Every mode picks the first roster entry that is available and runs a different model from the session. The review prompt reviews through fixed lenses (correctness, security and fail-open, adversarial inputs, portability, repo-rule adherence, docs-versus-code drift, test adequacy) and appends the repository's own instruction files, the same inputs the GitHub review bots read. The orch skill runs `review` as a local pre-PR review during `submit-pr` and can offer one during `review-pr`.

Flags, exit codes and the artifact contract: `second-opinion --help`.

## Customise

Set shared values in `kendex.settings.toml` under `[env]` and personal overrides in `.env.local`; nothing is marked required, so an install writes no settings. Every key, its default and the built-in `claude` and `codex` command lines: `second-opinion --help`. The ones most projects touch:

- `SECOND_OPINION_MODELS`: the priority-ordered roster, default `claude codex`.
- `SECOND_OPINION_COUNT`: opinions a `review` collects, default `1`.
- `SECOND_OPINION_<NAME>_CMD`: the full command a roster entry runs; another model CLI is a settings entry, not new code. Keep the sandbox read-only so a second opinion can never write to your worktree.
- `SECOND_OPINION_TIMEOUT`: seconds per CLI invocation, default `1080`.
- `SECOND_OPINION_CURRENT_MODEL`: the session model, required in Pi, OpenCode, Cursor or an undetected shell; never store it in a project file.
