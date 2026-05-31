---
name: linear
description: "Use for ANY Linear interaction: read, view, list, search, create, edit, update, comment on, label, block, unblock, or activate any Linear issue, project, cycle, milestone, initiative, or label. Bash CLI over Linear's GraphQL API with local cache and mutation syncing."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  version: "1.0.0"
---

# Linear CLI

CLI wrapper for Linear's GraphQL API with local cache, bulk operations, and structured output.

```bash
.agents/skills/linear/scripts/linear.sh <resource> <action> [options]
```

## Resources

### ctx7 CLI

| Library | ctx7 ID | Use For |
|---------|---------|---------|
| Linear API | `/websites/studio_apollographql_public_linear-api_variant_current` | GraphQL schema reference |
| Linear SDK | `/linear/linear` | SDK docs with examples |
| Linear Guides | `/websites/linear_app_developers` | Developer guides |

## Workflow Patterns

| Pattern | Use For |
|---------|---------|
| [patterns/workflow-actions.md](patterns/workflow-actions.md) | Multi-step issue/project state changes used by linear-orch and TPM workflows |

## Commands

| Resource | Actions |
|----------|---------|
| `issues` | list, get, create, update, children, relations, bulk-get |
| `comments` | list, create |
| `projects` | list, get, create, update, dependencies, updates |
| `initiatives` | list, get, create, add-project |
| `milestones` | list, get, create |
| `labels` | list, create |
| `project-labels` | list, create |
| `teams` | list, get |
| `users` | list, get |
| `cycles` | list |
| `statuses` | list, get |
| `documents` | list, get |
| `sync` | Sync Linear data to local cache |
| `cache` | Query local cache (issues, projects, cycles, initiatives, comments, labels, attachments) |
| `auth-check` | Validate API key |

## Hierarchy

```
INITIATIVE (Strategic goal — months)
  └── PROJECT (2-6 week deliverable)
        ├── MILESTONE (stage: Alpha, Beta, Release)
        │     └── ISSUE (1-5 day work item)
        └── ISSUE (work item without milestone)
              └── SUB-ISSUE (breakdown for parallel work)
```

## Cache Pattern

Reads go through `cache`. Writes go through live commands (auto-update cache via write-through). Sync at session start or when cache is stale.

```bash
# READS → cache (fast, no API calls)
linear.sh cache issues list --project "Phase 2" --state "Todo,In Progress"
linear.sh cache issues get ABC-100 --with-bundle

# WRITES → live (hit API, auto-update cache)
linear.sh issues create --title "New task" --project "Phase 2"
linear.sh issues update ABC-100 --state "Done"

# SYNC → refresh cache
linear.sh sync --reconcile      # Incremental + reconcile archived
linear.sh sync --full           # Full re-sync
```

## Output Formats

| Format | Description |
|--------|-------------|
| `safe` | DEFAULT. Flat, null-safe JSON |
| `ids` | Newline-separated identifiers |
| `table` | Human-readable table |
| `raw` | Original GraphQL structure |

`compact` omits description and other large text fields. `raw` nests fields under GraphQL structure — do not assume top-level jq paths. Use `safe` (default) when you need issue descriptions or full field access.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `LINEAR_API_KEY` | API key (required for live API commands and sync; not required for cache reads) | — |
| `LINEAR_TEAM` | Default team name | `Claude` |
| `LINEAR_FORMAT` | Default output format | `safe` |
| `LINEAR_TEAM_PREFIX` | Issue identifier prefix | `CC` |

## Safe Format Field Mapping

```
identifier → id         # ABC-XXX issue ID
id → uuid              # GraphQL UUID
state.name → state     # State name
state.type → state_type
sortOrder → sort_order  # Manual sort position
```

## Blocked Label vs Issue Relations

| Scenario | Use |
|----------|-----|
| Issue A blocked by Issue B (both in Linear) | Relation: `--blocked-by` |
| Issue blocked by external factor (vendor, license) | `blocked` label + comment |

## Common Pitfalls

| Option | Accepts | On failure |
|--------|---------|-----------|
| `--project` | Name or UUID | Fail with "not found" |
| `--state` | Exact name (case-sensitive) | Fail, lists available states |
| `--milestone` | Name or UUID | Fail with "not found" |
| `--labels` | Comma-separated issue-label names | Warn + skip invalid, continue (workflow callers must preflight strictly) |
| `--assignee` | Name or `me` | Silent fail |

- State names are case-sensitive and team-specific — verify with `linear.sh statuses list`
- Available states: Backlog, Todo, In Progress, In Review, Done, Canceled (not "Cancelled")
- `agent:*` labels are mutually exclusive (only one per issue)
- `--labels` replaces the full issue-label set on update. Workflow callers must fetch current labels, compute the final set, validate against `cache labels list --format=safe`, then call update with the full final set.
- `cache labels list --format=safe` returns issue labels with `id`, `name`, `team`, `parent`, and `is_group` so workflows can reject parent/group labels before mutation.

## Troubleshooting

- **"labelIds not exclusive child labels" error**: Using multiple labels from the same exclusive group. Only one `agent:*` label and one `platform:*` label per issue.
- **Need raw GraphQL output?**: Use `--format=raw`
- **Script help**: `linear.sh <resource> --help`

## Dependencies

- `curl`
- `jq`
