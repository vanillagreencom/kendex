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
│       ├── bash-version.sh      # Bash 4+ runtime preflight
│       ├── common.sh           # Auth, GraphQL, formatting
│       ├── cache.sh            # Cache management
│       ├── formatters.sh       # Output formatters (safe, table, ids, raw)
│       ├── attachments.sh      # Attachment download and caching
│       └── issue-validation.sh # Issue state validation
└── patterns/
    └── workflow-actions.md     # Multi-step issue/project state transitions
```

## Setup

1. Install Bash 4.0 or newer. macOS system Bash 3.2 is unsupported; invoke `linear.sh` with the newer Bash executable.
2. Add `LINEAR_API_KEY` to `.env.local` for live API commands and sync
3. Optionally set non-secret defaults such as `LINEAR_TEAM`, `LINEAR_FORMAT`, and `LINEAR_TEAM_PREFIX` in committed `vstack.settings.toml`

```bash
./scripts/linear.sh auth-check
./scripts/linear.sh sync --reconcile
```

Read-only cache queries (`./scripts/linear.sh cache ...` except `cache attachments fetch`) use existing `.cache/linear` data and do not require API auth. Cache and attachment paths are anchored to the physical git worktree root from `git rev-parse --show-toplevel`, so symlinked checkout spellings and canonical skill invocation paths read and write the same cache. If no cache exists, the error JSON includes the checked `cache_dir` and `meta_path`.

`cache labels list --format=safe` returns issue-label metadata (`id`, `name`, `team`, `parent`, `is_group`) so workflow callers can preflight labels and reject parent/group labels before issue mutation.

Use `comments create ISSUE --body-file tmp/comment.md` for Markdown or multi-line comments. Inline `--body` is intended for short plain strings.

Use `issues activate ISSUE --agent NAME` to claim an issue: it sets "In Progress" and applies the exclusive `agent:NAME` label in a single update (replacing any existing `agent:*` label), and fails without changing state when the label does not exist.

Use `issues complete ISSUE --summary-file tmp/summary.md` (or `--summary "text"`) to post the completion summary comment and then transition to "Done". The comment is posted first, so a failed post leaves the issue state unchanged; unknown or trailing arguments are rejected before any mutation.

Use `issues create --parent PROJ-42` to create a sub-issue. The command resolves the parent identifier to a UUID, sends `parentId` on create, and verifies the returned issue is linked. If Linear ignores the create-time parent, the command repairs the link with `issueUpdate`; if that cannot be verified, it exits nonzero.

`issues bulk-update` applies each issue update independently. If one update fails after earlier items changed, the command emits a JSON summary with `partial: true`, per-issue success/error entries, and exits nonzero.

Use explicit list actions for dependency reads: `issues list-relations ISSUE` and `projects list-dependencies PROJECT`. The older read-only aliases `issues relations` and `projects dependencies` remain accepted for compatibility, but new workflows should use the explicit names.

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

- Bash 4.0 or newer
- `curl`
- `jq`
