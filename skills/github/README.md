# GitHub Queries

CLI wrapper for GitHub API operations used in PR workflows.

## Structure

- `scripts/github.sh` — Entry point (command router)
- `scripts/git-diff-summary` — Standalone changed-file domain/scope and risk-flag summary helper
- `scripts/commands/` — Individual command scripts
- `scripts/lib/github-api.sh` — Shared library (auth, GraphQL, REST, error handling)
- `SKILL.md` — Agent-facing skill definition

## Setup

1. Authenticate: `gh auth login`
2. Optionally set `GH_BOT_TOKEN` in `.env.local` for bot account operations
3. Optionally set non-secret defaults such as `GH_ISSUE_PATTERN`, `GH_BOT_USERNAME`, and `GH_VERIFY_CMD` in committed `vstack.settings.toml`

```bash
./scripts/github.sh pr-view 123 --json number,title,state
./scripts/github.sh bot-token
```

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `GH_TOKEN` / `GITHUB_TOKEN` | Pre-resolved GitHub token from the parent process | Falls back to `gh` auth |
| `GH_BOT_TOKEN` | Bot account GitHub token | Falls back to `GH_TOKEN` / `GITHUB_TOKEN` for helper auth, then `gh` auth |
| `GH_BOT_USERNAME` | Bot username for filtering | `review-bot[bot]` |
| `GH_ISSUE_PATTERN` | Regex for branch issue extraction | `[A-Z]+-[0-9]+` |
| `VSTACK_GITHUB_OP_TIMEOUT` | Seconds to wait for `op read` token resolution | `10` |
| `VSTACK_GITHUB_AUTH_TIMEOUT` | Seconds to wait for `pr-view` auth preflight | `10` |
| `VSTACK_GITHUB_PR_VIEW_TIMEOUT` | Seconds to wait for `gh pr view` | `30` |

Keep tokens in `.env.local` unless the parent process injects already-resolved secrets at launch. Token loaders are env-first: resolved `GH_TOKEN`, `GITHUB_TOKEN`, or `GH_BOT_TOKEN` values are used before project files are read, and `op read` is only called when the final selected value is an `op://` reference. Bot-token operations still prefer an explicit `GH_BOT_TOKEN` over user-token variables. Shared non-secret defaults can live in `vstack.settings.toml` under `[env]`; `.env.local` still wins for local overrides.

`pr-view --json ...` emits normal `gh pr view` JSON on success. On failure it
emits structured JSON on stdout with `status` (`no_pr`, `auth_error`,
`token_resolution_failed`, `token_resolution_timeout`,
`token_resolution_unavailable`, `auth_timeout`, `gh_timeout`, or `gh_error`),
`error`, `detail`, `exit_code`, and `number:null`, then exits nonzero. Stderr
keeps the raw `gh`/`op` detail for logs.

## Adding a Command

1. Create `scripts/commands/<command-name>.sh`
2. Source `../lib/github-api.sh` for shared functions
3. Add a `show_help()` function
4. Add the command to the case statement in `scripts/github.sh`
5. Update the Commands table in `SKILL.md`

## Diff Summary Risk Flags

`git-diff-summary` emits JSON for review routing. Rust-specific risk flags
(`unsafe_code_added`, `repr_c_struct_changed`, `extern_c_changed`,
`atomics_modified`) scan added lines from `.rs` diffs only. Non-Rust scripts,
docs, and config can mention `unsafe`, `#[repr(C)]`, `extern "C"`, or
`Atomic` without triggering Rust risk flags.

## Verification (pr-cross-check --verify)

`verify-lib.sh` auto-detects the build system. Override order:
1. `GH_VERIFY_CMD` env var
2. `verify.sh` in project root
3. Auto-detect from `Cargo.toml`, `package.json`, `go.mod`, `pyproject.toml`, `Makefile`

## Dependencies

- `gh` CLI authenticated
- `jq`
- `op` CLI (optional, for 1Password token references)
