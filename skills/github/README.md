# GitHub Queries

A CLI over the GitHub API for pull-request work: PR data, threads and reviews; comments and replies; labels; CI failure logs; gated merges; and cross-checks of several PRs before a batch merge. Every command prints JSON, so output pipes straight into `jq`.

## Install

```bash
kendex add vanillagreencom/kendex --skill github
```

Needs `gh` (authenticated with `gh auth login`) and `jq`. `op` is needed only when a token is a 1Password reference.

## What it does

- Reads a PR with its threads, comments and files, in a null-safe shape or the raw GraphQL nesting.
- Posts, finds and edits comments; resolves review threads the GitHub UI cannot render.
- Adds and removes labels; fetches the logs of failing CI runs and names the cause of a merge refusal.
- Merges through a gate that refuses while a live review thread is unresolved.
- Compares several PRs for conflicts and dependencies, with an optional build-and-test verification of the merged result.
- `git-https-auth` runs one git command over HTTPS through `gh` auth when an SSH remote fails.

## How it works

```bash
./scripts/github.sh pr-view 123 --json number,title,state
./scripts/github.sh pr-threads 123 --unresolved
./scripts/github.sh pr-merge 123 --check
./scripts/git-https-auth -C . fetch --prune origin
```

`./scripts/github.sh --help` lists every command; `./scripts/github.sh <command> --help` is one command's full contract. Bot-account operations use `GH_BOT_TOKEN` when set and fall back to the caller's `gh` login.

The merge gate in `pr-merge` is policy, not mechanism: it binds only merges routed through `pr-merge`, so a raw `gh pr merge` or the GitHub UI still bypasses it. It is narrower than GitHub's `required_conversation_resolution`, which counts outdated threads too.

## Customise

Set non-secret defaults in `kendex.settings.toml` under `[env]`; keep tokens in `.env.local`. A value set in the parent process wins over project files.

| Variable | Purpose | Default |
|----------|---------|---------|
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved token from the parent process | `gh` auth |
| `GH_BOT_TOKEN` | Bot account token, literal or `op://vault/item/field` | `GH_TOKEN` / `GITHUB_TOKEN`, then `gh` auth |
| `GH_BOT_USERNAME` | Bot login used when filtering reviews and comments | `review-bot[bot]` |
| `GH_ISSUE_PATTERN` | Regex extracting an issue id from a branch name | `[A-Z]+-[0-9]+` |
| `GH_VERIFY_CMD` | Build and test command for `pr-cross-check --verify` | `verify.sh` in the project root, else auto-detect |
| `KENDEX_GITHUB_OP_TIMEOUT` | Seconds allowed for `op read` | `10` |
| `KENDEX_GITHUB_AUTH_TIMEOUT` | Seconds allowed for the `pr-view` auth preflight | `10` |
| `KENDEX_GITHUB_PR_VIEW_TIMEOUT` | Seconds allowed for `gh pr view` | `30` |
| `KENDEX_GITHUB_GIT_HTTPS_FALLBACK` | `auto`, `never` or `always` for `git-https-auth` | `auto` |

The three timeouts are read to one decimal place; `0` means no bound, and a finer figure is refused rather than rounded.
