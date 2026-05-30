# GitHub Queries

CLI wrapper for GitHub API operations used in PR workflows.

## Structure

- `scripts/github.sh` — Entry point (command router)
- `scripts/commands/` — Individual command scripts
- `scripts/lib/github-api.sh` — Shared library (auth, GraphQL, REST, error handling)
- `SKILL.md` — Agent-facing skill definition

## Setup

1. Authenticate: `gh auth login`
2. Optionally set `GH_BOT_TOKEN` in `.env.local` for bot account operations
3. Optionally set `GH_ISSUE_PATTERN` if branches don't use `ABC-123` style IDs

```bash
./scripts/github.sh pr-view 123 --json number,title,state
./scripts/github.sh bot-token
```

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `GH_BOT_TOKEN` | Bot account GitHub token | Falls back to `gh` auth |
| `GH_BOT_USERNAME` | Bot username for filtering | `review-bot[bot]` |
| `GH_ISSUE_PATTERN` | Regex for branch issue extraction | `[A-Z]+-[0-9]+` |

## Adding a Command

1. Create `scripts/commands/<command-name>.sh`
2. Source `../lib/github-api.sh` for shared functions
3. Add a `show_help()` function
4. Add the command to the case statement in `scripts/github.sh`
5. Update the Commands table in `SKILL.md`

## Verification (pr-cross-check --verify)

`verify-lib.sh` auto-detects the build system. Override order:
1. `GH_VERIFY_CMD` env var
2. `verify.sh` in project root
3. Auto-detect from `Cargo.toml`, `package.json`, `go.mod`, `pyproject.toml`, `Makefile`

## Flightdeck Activity

GitHub wrappers emit Flightdeck activity rows only when `FLIGHTDECK_MANAGED=1`
or `FLIGHTDECK_ACTIVITY_FILE` is set. Emission is best-effort: if the shared
Flightdeck helper is unavailable, wrappers continue and print one clear
non-blocking warning instead of raw shell diagnostics. Standalone use outside
Flightdeck stays silent.

## Dependencies

- `gh` CLI authenticated
- `jq`
- `op` CLI (optional, for 1Password token references)
