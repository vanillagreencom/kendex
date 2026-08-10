---
name: linear
description: "Use for ANY Linear interaction: read, view, list, search, create, edit, update, comment on, label, block, unblock, or activate any Linear issue, project, cycle, milestone, initiative, or label. Bash CLI over Linear's GraphQL API with local cache and mutation syncing."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.0.0"
---

# Linear CLI

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

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
| [patterns/workflow-actions.md](patterns/workflow-actions.md) | Multi-step issue/project state changes used by orch and TPM workflows |

## Commands

| Resource | Actions |
|----------|---------|
| `issues` | list, get, create, update (create and update take a repeatable `--attach <path>` file upload — see [Attachment Uploads](#attachment-uploads)), children, list-relations, add-relation, remove-relation, bulk-get, bulk-update, activate (`--agent <name>` applies the exclusive `agent:<name>` label), block, unblock, complete (`--summary <text>` / `--summary-file <path>` post the completion comment before the Done transition), validate-completion |
| `comments` | list, create (`--body`, `--body-file`, repeatable `--attach <path>`) |
| `projects` | list, get, create, update, list-dependencies, add-dependency, remove-dependency, post-update, list-updates |
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
| `auth-check` | Validate API key and report the resolved team target (`--strict` also fails when no team is configured) |

Compatibility aliases: `issues relations` maps to `issues list-relations`, and `projects dependencies` maps to `projects list-dependencies`. Prefer the explicit action names in new workflows.

There is no `view` or `show` action. Single-issue lookups are `issues get <ID>` (live) or `cache issues get <ID>` (cache); multi-issue lookups are `issues bulk-get <ID1> <ID2> ...`. For post-mutation verification, use live `issues bulk-get` — it returns fresh state for every mutated issue in one command.

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
linear.sh cache issues list --all-projects --state "Backlog,Todo" --max --format=compact
linear.sh cache issues get ABC-100 --with-bundle

# WRITES → live (hit API, auto-update cache)
# (agent:* label required when LINEAR_AGENT_LABELS declares a taxonomy — see Issue Creation Routing)
linear.sh issues create --title "New task" --project "Phase 2" --labels "agent:generalist"
linear.sh issues update ABC-100 --state "Done"

# SYNC → refresh cache
linear.sh sync --reconcile      # Incremental + reconcile archived
linear.sh sync --full           # Full re-sync
```

`cache issues list --all-projects` enumerates every project in ONE command — each row carries its `project` name, and other filters (`--state`, `--max`, `--format`) compose. Use it for cross-project comparison sets instead of looping `--project` per project; restricted harness approval policies reject loop-shaped commands. Mutually exclusive with `--project`.

Cache and attachment files live under `.cache/linear` in the physical git worktree root reported by `git rev-parse --show-toplevel`, not under the path used to reach the skill script. This keeps `sync`, `cache`, and attachment reads consistent across symlinked checkout spellings, worktrees, and canonical source-path invocation. A missing-cache error includes the checked `cache_dir` and `meta_path`; inspect those fields before assuming a sync wrote somewhere else.

In a linked git worktree whose `.cache` should be a `WORKTREE_SYMLINKS`-managed symlink into the main checkout but is a real directory (a git operation re-materialized it), any full or reconciling `sync` refuses before touching the API — a full re-sync into a worktree-local dir would silently re-pull the entire history and burn the shared API budget. The refusal names the worktree, the expected symlink, and the repair: run `worktree fix-links <PATH>` from the main checkout, then re-run `sync`. Repos whose configured `WORKTREE_SYMLINKS` deliberately excludes `.cache` are exempt.

## Attachment Uploads

`issues create`, `issues update`, and `comments create` take a repeatable `--attach <path>`. Each file is uploaded through Linear's `fileUpload` flow: the mutation returns `uploadUrl`, `assetUrl`, and the exact headers the storage PUT must carry — the CLI PUTs the bytes with those headers verbatim (plus Content-Type from the file extension; unknown extensions upload as `application/octet-stream`).

- Images (`image/*`) embed into the description/body being written as `![<filename>](<assetUrl>)`. On `issues update` without `--description`/`--description-file`, the embed appends to the issue's existing description.
- Non-image files on issues become real Linear attachments (`attachmentCreate`) after the issue write; `issues update --attach` alone (no other fields) is valid and skips the `issueUpdate` mutation. On comments they append a `[<filename>](<assetUrl>)` markdown link instead — comments have no attachment surface.
- `--attach` composes with `--description-file`/`--body-file`. A missing or unreadable path refuses before any API call. If the issue write succeeded but an attachment step failed, the command reports the issue identifier with `partial: true` on stderr and exits non-zero — never a zero exit with a silent gap.
- Embedded assetUrls point at `uploads.linear.app`, so the attachment cache downloads them on write-through and picks them up on sync like any other attachment.

## Issue Creation Routing

Never create a tracked issue directly from an orchestration or review session — route it through the TPM pipeline (project-management skill), which owns labels, project, priority, estimate, and relations. A direct `issues create` prints a URL and looks like success even when the issue landed with none of those, invisible to agent routing.

When the project declares its agent-label taxonomy (`LINEAR_AGENT_LABELS` in `vstack.settings.toml` `[env]`, comma- or space-separated `agent:*` names), `issues create` enforces this: it refuses — before any API call — a create that carries no agent label from the declared set, including an unknown/typoed `agent:*` name that label resolution would otherwise silently skip. `--no-agent-label` permits a deliberate bare create (e.g. mirroring intake from another tracker). Projects with no declaration are unaffected.

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
| `LINEAR_API_KEY_OVERRIDE` | Explicit key override that beats project files; the inline/test channel | — |
| `LINEAR_TEAM` | Team every write targets | — (unset refuses writes) |
| `LINEAR_FORMAT` | Default output format | `safe` |
| `LINEAR_TEAM_PREFIX` | Issue identifier prefix | `PROJ` |
| `LINEAR_AGENT_LABELS` | Declared agent-routing label set; non-empty makes `issues create` refuse creates with no agent label from the set (see [Issue Creation Routing](#issue-creation-routing)) | — (unset = guard off) |

Put `LINEAR_API_KEY` in `.env.local`. Put non-secret defaults in committed `vstack.settings.toml` under `[env]`; `.env.local` still wins for local overrides. For the API key specifically, a key set by project files (`.env` → settings `[env]` → `.env.local`) wins over a plain `LINEAR_API_KEY` inherited from the environment — per-repo workspaces make a box-global export wrong for every other repo, and `auth-check` warns (key fingerprints only) when a differing inherited key is being shadowed. `LINEAR_API_KEY_OVERRIDE` always wins; use it for one-off/inline keys and tests.

`LINEAR_TEAM` has no default. A team name resolves inside whatever workspace the API key reaches, so an unset team means no target: every write (create, update, comment, archive, relation, state change) refuses with an actionable error before any API call, and reads run without a team filter. `--team <name>` overrides it per call only on the actions that take a team — `issues create`, `projects create`, `cycles create`, `labels create`; every other write requires the configured value. `linear.sh auth-check` reports the resolved team, where it came from, and `writes_enabled`; `linear.sh auth-check --strict` exits non-zero when writes would refuse — run it before the first mutation in a project.

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

Blocking relations must connect peers of one bundle: same direct parent, or both top-level (and same project). An issue cannot block its own ancestor or descendant — the parent-child hierarchy already encodes that dependency; use `--related` for traceability. Rejections for cross-subtree pairs prescribe the valid pair at the level where the subtrees separate. Before either acceptance or remediation, the guard proves each parent chain reaches an explicit null root through well-formed edges with unique IDs/identifiers. It also requires an explicit null or well-formed project value; incomplete, cyclic, or malformed hierarchy data is rejected before mutation.

A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata** — Linear itself already treats the dependent issue as unblocked. The relation stays for provenance and traceability; never remove or "fix" it, and audits must never classify it as stale. The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule").

## Common Pitfalls

| Option | Accepts | On failure |
|--------|---------|-----------|
| `--project` | Name or UUID | Fail with "not found" |
| `--state` | Exact name (case-sensitive) | Fail, lists available states |
| `--milestone` | Name or UUID | Fail with "not found" |
| `--parent` | Issue identifier or UUID | Fail if the parent cannot be resolved; create also fails if the link cannot be verified or repaired |
| `--labels` | Comma-separated issue-label names | Warn + skip invalid, continue (workflow callers must preflight strictly) |
| `--assignee` | Name or `me` | Silent fail |

- State names are case-sensitive and team-specific — verify with `linear.sh statuses list`
- Available states: Backlog, Todo, In Progress, In Review, Done, Canceled (not "Cancelled")
- `agent:*` labels are mutually exclusive (only one per issue)
- `issues activate ISSUE --agent NAME` applies `agent:NAME` in the same update as the "In Progress" transition, replacing any existing `agent:*` label; it fails without changing state when the label does not exist
- `issues complete ISSUE --summary-file PATH` posts the completion summary comment first and only then transitions to "Done"; a failed post leaves the state unchanged
- `issues validate-completion` is a pre-merge check: session-root targets are expected in "In Progress"/"In Review" (Done fails `state_ok` — managed roots stay pre-merge until PR merge; this pre-merge rule applies to the session root only). `--include-children-of` expands the bundle and validates each child as "Done": every completed child IS included and passes, a still-pending child fails, and canceled children are excluded from the expansion (abandoned work is never "Done")
- `--container` (with `validate-completion`) marks the target as a container parent — a bundle whose children each ship as their own PR, with the container closing LAST. The container's own state passes for any live state (canceled fails closed) and needs no pre-posted summary (`issues complete --summary` posts it at completion time); the expanded children still gate on "Done", so `all_ok` answers "may this container complete now?". A child of a container validates alone as its own session root — plain `validate-completion CHILD`, no sibling or parent state involved. The children-Done-before-root default above is the explicit single-PR bundle contract ("(one PR)" title marker)
- `--labels` replaces the full issue-label set on update. Workflow callers must fetch current labels, compute the final set, validate against `cache labels list --format=safe`, then call update with the full final set.
- `cache labels list --format=safe` returns issue labels with `id`, `name`, `team`, `parent`, and `is_group` so workflows can reject parent/group labels before mutation.
- `issues bulk-update` is non-atomic. If one item fails after earlier updates succeeded, it emits a JSON summary with `partial: true`, per-issue results, and exits nonzero.

## Troubleshooting

- **"labelIds not exclusive child labels" error**: Using multiple labels from the same exclusive group. Only one `agent:*` label and one `platform:*` label per issue.
- **Need raw GraphQL output?**: Use `--format=raw`
- **Script help**: `linear.sh <resource> --help`

## Dependencies

- Bash 4.0 or newer (macOS system Bash 3.2 is unsupported; install a newer Bash and invoke `linear.sh` with it)
- `curl`
- `jq`
