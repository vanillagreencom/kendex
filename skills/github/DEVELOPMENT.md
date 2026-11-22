# github skill development

## Adding a command

1. Create `scripts/commands/<command-name>.sh`, sourcing `../lib/github-api.sh` for auth, GraphQL, REST and error handling.
2. Give it a `show_help()`.
3. Add the command to the case statement in `scripts/github.sh` and to the Commands table in `SKILL.md`.

- Parse arguments with an explicit `while`/`shift` loop that rejects unknown flags and surplus positionals.
- Emit JSON with `jq -n`, never string interpolation: API error text routinely contains quotes.
- Send a `{error}` refusal on stderr through `github_error` in `scripts/lib/json-error.sh`, which `github-api.sh` sources.
- `tests/json-error.test.sh` drives each refusal that echoes a caller's argument, path or `GH_REPO` value with a double quote in it.
- `tests/edit-comment.test.sh` holds edit-comment's non-numeric id.
- Subprocess time bounds go through `scripts/lib/bounded.sh`, the one portable wall-clock bound.
- Token resolution and the keyring fallback are `scripts/lib/gh-auth.sh`, shared with `scripts/gh-auth-ladder`, which the orch runtime runs for its GitHub reads.
- Check-rollup run scoping and the required set are `scripts/lib/ci-run-correlation.sh`, sourced by `pr-merge`, `ci-classify-refusal`, `ci-rerun` and `pr-timeline`. Orch's `approve-head` request, which runs the overseer's approvals, reads Copilot's check runs in the runtime.
- The process-group leader prefix every bounded child forks through is `scripts/lib/group-leader.sh`. The second-opinion runtime, reviewer's `mutation-stability` and the orch runtime's attached validation run share it.
- Second-opinion, reviewer and orch require `github`.
- Jarvis and worktree declare `github` optional.
- Jarvis needs `group-leader.sh` for detached sessions without `setsid`.
- Worktree needs `group-leader.sh` for configured setup commands.

## Pull-request watcher

- `scripts/pr-watch.sh` stands outside the router: the orch runtime's watch and its lane close run it by path, and `OVERSEE_WATCH_PR_WATCH` names a replacement for both.
- It reads `PR_REVIEW_WAIT_SECS` through `scripts/lib/kendex-env.sh` in a subshell, so the project files set nothing else in the watcher.
- Its stdout lines are the protocol those callers parse. `pr-watch.sh --help` states it.

## Tests

- `tests/` holds one self-contained suite per file. CI runs each as `bash <file>`.
- The watcher suites share `tests/lib/pr-watch-fixture.sh`. `tests/pr-watch-process.test.sh` also sources orch's `tests/lib/process-count.sh`.
- `tests/corpus/` is the contract for the decline grammar in `scripts/commands/check-review-replies.sh`. A new label goes into a corpus file first, and the word list widens until `tests/check-review-replies-threads.test.sh` passes.
