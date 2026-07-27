# github skill development

## Structure

- `scripts/github.sh` — Entry point (command router)
- `scripts/git-https-auth` — Git wrapper for per-command GitHub SSH→HTTPS fallback through `gh` auth
- `scripts/git-diff-summary` — Standalone changed-file domain/scope and risk-flag summary helper
- `scripts/commands/` — Individual command scripts
- `scripts/lib/gh-auth.sh` — Shared GitHub token resolution and keyring fallback helpers
- `scripts/lib/github-api.sh` — Shared library (auth, GraphQL, REST, error handling)
- `SKILL.md` — Agent-facing skill definition

## Adding a Command

1. Create `scripts/commands/<command-name>.sh`
2. Source `../lib/github-api.sh` for shared functions
3. Add a `show_help()` function
4. Add the command to the case statement in `scripts/github.sh`
5. Update the Commands table in `SKILL.md`
