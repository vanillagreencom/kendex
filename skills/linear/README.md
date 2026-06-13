# Linear CLI

CLI wrapper for Linear's GraphQL API with local cache, bulk operations, and structured output.

## Structure

```
skills/linear/
├── SKILL.md                    # Agent-facing skill definition
├── scripts/
│   ├── linear.sh               # Entry point (resource router)
│   ├── commands/               # Individual resource scripts
│   └── lib/
│       ├── common.sh           # Auth, GraphQL, formatting
│       ├── cache.sh            # Cache management
│       ├── formatters.sh       # Output formatters (safe, table, ids, raw)
│       ├── attachments.sh      # Attachment download and caching
│       └── issue-validation.sh # Issue state validation
└── patterns/
    └── workflow-actions.md     # Multi-step issue/project state transitions
```

## Setup

1. Add `LINEAR_API_KEY` to `.env.local` for live API commands and sync
2. Optionally set non-secret defaults such as `LINEAR_TEAM`, `LINEAR_FORMAT`, and `LINEAR_TEAM_PREFIX` in committed `vstack.settings.toml`

```bash
./scripts/linear.sh auth-check
./scripts/linear.sh sync --reconcile
```

Read-only cache queries (`./scripts/linear.sh cache ...` except `cache attachments fetch`) use existing `.cache/linear` data and do not require API auth.

`cache labels list --format=safe` returns issue-label metadata (`id`, `name`, `team`, `parent`, `is_group`) so workflow callers can preflight labels and reject parent/group labels before issue mutation.

Use `comments create ISSUE --body-file tmp/comment.md` for Markdown or multi-line comments. Inline `--body` is intended for short plain strings.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `LINEAR_API_KEY` | API key (required for live API commands and sync; not required for cache reads) | — |
| `LINEAR_TEAM` | Default team name | `Claude` |
| `LINEAR_FORMAT` | Default output format | `safe` |
| `LINEAR_TEAM_PREFIX` | Issue identifier prefix | `CC` |

Keep `LINEAR_API_KEY` in `.env.local`. Shared non-secret defaults can live in `vstack.settings.toml` under `[env]`; `.env.local` still wins for local overrides.

## Adding a Resource

1. Create `scripts/commands/<resource>.sh`
2. Source `../lib/common.sh`
3. Add `show_help()` function
4. Add to case statement in `scripts/linear.sh`
5. Update Commands table in `SKILL.md`

## Dependencies

- `curl`
- `jq`
