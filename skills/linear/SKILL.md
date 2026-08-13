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

```bash
.agents/skills/linear/scripts/linear.sh <resource> <action> [options]
```

Reads go through `cache`; writes go through the live commands, which write through to the cache. `linear.sh <resource> --help` prints per-resource options.

## Commands

| Resource | Actions |
|----------|---------|
| `issues` | list, get, bulk-get, create, update, bulk-update, archive, trash/delete, children, list-relations, add-relation, remove-relation, activate, block, unblock, complete, validate-completion |
| `comments` | list, create, update, delete |
| `projects` | list, get, create, update, delete, list-dependencies, add-dependency, remove-dependency, post-update, list-updates, reorder, set-sort-order |
| `initiatives` | list, get, create, update, delete, add-project, remove-project |
| `milestones` | list, get, create, update, delete |
| `labels` / `project-labels` | list, create, update, delete |
| `teams` / `users` / `statuses` / `documents` | list, get (`users` also has `me`) |
| `cycles` | list, create, update |
| `sync` | Refresh the local cache (`--full`, `--reconcile`, `--if-stale N`, `--stats`) |
| `cache` | Cache-only reads: issues, projects, comments, labels, initiatives, cycles, attachments, status |
| `auth-check` | Report the resolved key/team and `writes_enabled` (`--strict` exits non-zero when writes would refuse) |
| `session-status` | Aggregated status for the `/start` workflow |

Aliases: `issues relations` → `list-relations`, `projects dependencies` → `list-dependencies`. Singular resource names (`issue`, `project`, …) route to the plural.

There is no `view`/`show`. Single-issue lookups are `issues get <ID>` (live) or `cache issues get <ID>`; multi-issue lookups are `issues bulk-get <ID1> <ID2> ...`, which is also the post-mutation verification path.

Schema reference over ctx7: `/websites/studio_apollographql_public_linear-api_variant_current` (API), `/linear/linear` (SDK), `/websites/linear_app_developers` (guides). [patterns/workflow-actions.md](patterns/workflow-actions.md) covers multi-step state changes.

## Cache

```bash
linear.sh cache issues list --project "Phase 2" --state "Todo,In Progress"
linear.sh cache issues get ABC-100 --with-bundle
linear.sh sync --reconcile
```

`cache issues list --all-projects` enumerates every project in one command (each row carries its `project` name); `--no-project` returns only unassigned issues. Both are mutually exclusive with `--project`. Use `--all-projects` rather than looping per project — restricted harness policies reject loop-shaped commands. An unrecognized filter flag is rejected rather than ignored. Repeated `--label` flags (and `--labels a,b`) require ALL named labels.

The cache lives at `.cache/linear` under the physical worktree root from `git rev-parse --show-toplevel`, so symlinked checkout spellings resolve to one cache. A missing-cache error names the `cache_dir` and `meta_path` it checked. A cache file that exists but does not parse is reported as corrupt — never as an empty result.

In a linked worktree whose `.cache` should be a `WORKTREE_SYMLINKS`-managed symlink but is a real directory, `sync` refuses before touching the API and names the repair (`worktree fix-links <PATH>` from the main checkout). Repos whose `WORKTREE_SYMLINKS` deliberately excludes `.cache` are exempt.

## Team Target

`LINEAR_TEAM` has no default: a team name resolves inside whatever workspace the API key reaches, so an unset team means no target. Every write refuses before any API call; reads drop the team filter. `--team <name>` overrides per call only on `issues create`, `projects create`, `cycles create`, and `labels create`. Run `auth-check --strict` before the first mutation in a project.

| Variable | Purpose | Default |
|----------|---------|---------|
| `LINEAR_API_KEY` | Required for live commands and sync; not for cache reads | — |
| `LINEAR_API_KEY_OVERRIDE` | Inline/test key that beats project files | — |
| `LINEAR_TEAM` | Team every write targets | — (unset refuses writes) |
| `LINEAR_FORMAT` | Default output format | `safe` |
| `LINEAR_TEAM_PREFIX` | Issue identifier prefix | `PROJ` |
| `LINEAR_AGENT_LABELS` | Declared `agent:*` taxonomy; non-empty makes `issues create` refuse unrouted creates | — (unset = off) |

`LINEAR_API_KEY` belongs in `.env.local`; non-secret defaults in committed `vstack.settings.toml` `[env]`. A key from project files beats one inherited from the environment, and `auth-check` warns (fingerprints only) when it shadows a differing inherited key.

## Issue Creation Routing

Never create a tracked issue directly from an orchestration or review session — route it through the TPM pipeline (project-management skill), which owns labels, project, priority, estimate, and relations. A direct `issues create` prints a URL and looks like success even when the issue landed with none of those, invisible to agent routing.

Where `LINEAR_AGENT_LABELS` declares a taxonomy, `issues create` refuses — before any API call — a create carrying no agent label from that set, including a typoed `agent:*` name. `--no-agent-label` permits a deliberate bare create.

## Attachments

`issues create`, `issues update`, and `comments create` take a repeatable `--attach <path>`. Images embed as markdown in the description/body — on `issues update` without `--description`, the embed appends to the existing description rather than replacing it. Other files become Linear attachments on issues, or markdown links on comments (comments have no attachment surface). An unreadable path refuses before any API call; an attachment failure after a successful issue write reports `partial: true` and exits non-zero.

## Output Formats

| Format | Description |
|--------|-------------|
| `safe` | DEFAULT. Flat, null-safe JSON |
| `compact` | `safe` minus descriptions and other large text |
| `ids` | Newline-separated identifiers |
| `table` | Human-readable table |
| `raw` | Original GraphQL nesting — do not assume top-level jq paths |

`safe` renames fields: `identifier`→`id`, `id`→`uuid`, `state.name`→`state`, `state.type`→`state_type`, `sortOrder`→`sort_order`.

## Blocked Label vs Issue Relations

| Scenario | Use |
|----------|-----|
| Issue A blocked by Issue B (both in Linear) | Relation: `--blocked-by` |
| Issue blocked by an external factor (vendor, license) | `blocked` label + comment |

Blocking relations must connect peers of one bundle: same direct parent, or both top-level. The two issues need not share a project — a dependency is a property of the work, not of how it is filed. An issue cannot block its own ancestor or descendant; the hierarchy already encodes that dependency, so use `--related` for traceability. Rejections for cross-subtree pairs prescribe the valid pair at the level where the subtrees separate. Before acceptance or remediation, the guard proves each parent chain reaches an explicit null root through well-formed unique-ID edges; incomplete, cyclic, or malformed hierarchy data is rejected before mutation.

A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata** — Linear itself already treats the dependent issue as unblocked. The relation stays for provenance; never remove or "fix" it, and audits must never classify it as stale. The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule").

## Option Behavior

| Option | Accepts | On failure |
|--------|---------|-----------|
| `--project` / `--milestone` | Name or UUID | Fail with "not found" |
| `--state` | Exact name, case-sensitive and team-specific | Fail, listing available states |
| `--parent` | Issue identifier or UUID | Fail; create also fails if the link cannot be verified or repaired |
| `--assignee` | Name or `me` | Fail with "not found" |
| `--labels` | Comma-separated issue-label names | Fail; nothing is written |
| `--cycle` | Cycle UUID | Fail before the mutation |
| `--priority` / `--estimate` / `--sort-order` | Numbers (`--priority` 0-4) | Fail naming the flag |

Available states: Backlog, Todo, In Progress, In Review, Done, Canceled (not "Cancelled"). Verify with `statuses list`.

`--labels` REPLACES the whole issue-label set. Fetch current labels, compute the final set, validate it against `cache labels list --format=safe` (which reports `is_group` so parent/group labels can be rejected), then pass the complete set. A name that does not resolve fails the update rather than silently dropping that label; `--clear-labels` is the only way to empty the set.

- `agent:*` labels are mutually exclusive, one per issue. `issues activate ISSUE --agent NAME` applies `agent:NAME` in the same update as the "In Progress" transition and fails without changing state when the label does not exist.
- `issues complete ISSUE --summary-file PATH` posts the completion comment first, then transitions to Done; a failed post leaves the state unchanged.
- `issues bulk-update` is non-atomic: on partial failure it emits `partial: true` with per-issue results and exits non-zero.
- `issues block` applies the `blocked` label, creates the blocking relation, and comments. A rejected relation fails the command — the label alone never reports a blocked issue.

## validate-completion

A pre-merge check. Session-root targets are expected in "In Progress"/"In Review" (Done fails `state_ok`: managed roots stay pre-merge until PR merge). `--include-children-of` expands a bundle and validates each child as Done — completed children pass, a pending child fails, canceled children are excluded from the expansion.

`--container` marks the target a container parent whose children each ship as their own PR and which closes LAST. The container's own state passes for any live state (canceled fails closed) and needs no pre-posted summary; the expanded children still gate on Done, so `all_ok` answers "may this container complete now?". It fails closed: exactly one target, a paired `--include-children-of` naming that same issue, and at least one non-canceled child. A child of a container validates alone as its own session root. Without `--container`, the children-Done-before-root default is the explicit single-PR bundle contract (the "(one PR)" title marker).

A "labelIds not exclusive child labels" error means two labels from one exclusive group. Requires Bash 4.0+ (macOS system Bash 3.2 is unsupported), `curl`, and `jq`.
