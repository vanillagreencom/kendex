# Linear CLI

CLI wrapper for Linear's GraphQL API with local cache, bulk operations, and structured output. Development notes live in `DEVELOPMENT.md`.

## Setup

1. Install Bash 4.0 or newer. macOS system Bash 3.2 is unsupported; invoke `linear.sh` with the newer Bash executable.
2. Add `LINEAR_API_KEY` to `.env.local` for live API commands and sync
3. Set `LINEAR_TEAM` to this project's team in committed `vstack.settings.toml` under `[env]` — required for any write. Other non-secret defaults such as `LINEAR_FORMAT` and `LINEAR_TEAM_PREFIX` go in the same table.

```bash
./scripts/linear.sh auth-check --strict
./scripts/linear.sh sync --reconcile
```

## Team Target

`LINEAR_TEAM` has no default. A team name resolves inside whatever workspace `LINEAR_API_KEY` reaches, so with no team configured the CLI has no target of its own: writes (create, update, comment, archive, relation, state change) refuse with an actionable error before any API call, and reads run without a team filter rather than guessing one.

`--team <name>` is a per-call override only where a team is part of the request: `issues create`, `projects create`, `cycles create`, and `labels create` (plus the `issues list`, `cycles list`, and `statuses list/get` read filters). Every other write takes its target from `LINEAR_TEAM` alone, so configure it rather than relying on a flag.

`auth-check` is the preflight. It reports the resolved team, whether it came from the process environment or project config (`team_source_file` names the file only when a project file supplied the resolved value), and `writes_enabled`; it warns when a machine-wide `LINEAR_API_KEY` is paired with no project team, and when an exported `LINEAR_TEAM` — including an exported empty one — shadows the project's own value. `auth-check --strict` exits non-zero when writes would refuse.

```bash
./scripts/linear.sh auth-check --strict
{"ok":true,"team":"Platform","team_source":"project-config","team_source_file":"vstack.settings.toml","api_key_source":"environment","writes_enabled":true,"warnings":[]}
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
| `LINEAR_TEAM` | Team every write targets | — (unset refuses writes) |
| `LINEAR_FORMAT` | Default output format | `safe` |
| `LINEAR_TEAM_PREFIX` | Issue identifier prefix | `PROJ` |
| `LINEAR_AGENT_LABELS` | Declared agent-routing label set (comma- or space-separated `agent:*` names). When non-empty, `issues create` refuses a create carrying none of them — an unlabeled issue is invisible to agent routing while the CLI prints a URL that looks like success. `--no-agent-label` permits a deliberate bare create. | — (empty: guard off) |

Keep `LINEAR_API_KEY` in `.env.local`. Shared non-secret defaults can live in `vstack.settings.toml` under `[env]`; `.env.local` still wins for local overrides.

Route normal tracked-issue creation through the TPM pipeline (`project-management` skill), which owns labels, project, priority, and relations — the guard exists to catch creates that bypass it.

## Dependencies

- Bash 4.0 or newer
- `curl`
- `jq`
