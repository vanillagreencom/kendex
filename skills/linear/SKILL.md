---
name: linear
description: "Load for any Linear read or write: issues, projects, cycles, milestones, initiatives, labels."
summary: "Bash CLI over Linear's GraphQL API with a local cache: read, search, create, or update issues, projects, cycles, milestones, initiatives, and labels."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.1.0"
tags: [integration]
---

# Linear CLI

```bash
.agents/skills/linear/scripts/linear.sh <resource> <action> [options]
```

Reads go through `cache`; writes go through the live commands, which write through to the cache. `linear.sh <resource> --help` prints per-resource options. `--format` values: `safe` (the default, flat and null-safe), `compact` (a smaller shape for workflow routing), `ids` (identifiers only), `table`, `raw` (the GraphQL nesting, so never assume top-level jq paths). `safe` renames fields: `identifier`→`id`, `id`→`uuid`, `state.name`→`state`, `state.type`→`state_type`, `sortOrder`→`sort_order`.

## Commands

| Resource | Actions |
|----------|---------|
| `issues` | list, get, bulk-get, create, update, bulk-update, archive, trash/delete, children, list-relations, add-relation, remove-relation, activate, block, unblock, complete, validate-completion |
| `comments` / `labels` / `project-labels` | list, create, update, delete |
| `projects` | list, get, create, update, delete, list-dependencies, add-dependency, remove-dependency, post-update, list-updates, reorder, set-sort-order |
| `initiatives` / `milestones` | list, get, create, update, delete (`initiatives` also add-project, remove-project) |
| `teams` / `users` / `statuses` / `documents` | list, get (`users` also has `me`) |
| `cycles` | list, create, update |
| `sync` | Refresh the local cache (`--full`, `--reconcile`, `--if-stale N`, `--stats`) |
| `cache` | Cache-only reads: issues, projects, comments, labels, initiatives, cycles, attachments, status |
| `auth-check` | Report the resolved key/team and `writes_enabled` (`--strict` exits non-zero when writes would refuse) |
| `session-status` | Aggregated status for the `/start` workflow |

Aliases: `issues relations` → `list-relations`, `projects dependencies` → `list-dependencies`. Singular resource names (`issue`, `project`, …) route to the plural. There is no `view`/`show`: single-issue lookups are `issues get <ID>` (live) or `cache issues get <ID>`, and multi-issue lookups are `issues bulk-get <ID1> <ID2> ...`, which is also the post-mutation verification path.

Schema reference over ctx7: `/websites/studio_apollographql_public_linear-api_variant_current` (API), `/linear/linear` (SDK), `/websites/linear_app_developers` (guides). [patterns/workflow-actions.md](patterns/workflow-actions.md) covers multi-step state changes.

## Cache

```bash
linear.sh cache issues list --project "Phase 2" --state "Todo,In Progress"
linear.sh cache issues get ABC-100 --with-bundle
linear.sh sync --reconcile
```

`cache issues list --all-projects` enumerates every project in one command (each row carries its `project` name); `--no-project` returns only unassigned issues. Both are mutually exclusive with `--project`. Use `--all-projects`; never loop per project. An unrecognized filter flag is rejected. Repeated `--label` flags (and `--labels a,b`) require ALL named labels.

Both `issues list` and `cache issues list` return the first 75 rows by default and warn on stderr when that truncated the result; `--max` fetches everything. `--limit N` caps a CACHE listing's total; on the live path it is the per-page size (`--max --limit N` pages at N under a 200-page cap that warns when it truncates). An audit that must see the whole backlog passes `--max`.

The cache is `.cache/linear` under the physical worktree root ([README.md](README.md)); a linked worktree whose `.cache` should be a `WORKTREE_SYMLINKS`-managed symlink but is a real directory refuses `sync` and names the repair. A repo whose `WORKTREE_SYMLINKS` deliberately excludes `.cache` is exempt.

## Team Target

`LINEAR_TEAM` has no default. With it unset every write refuses before any API call; reads drop the team filter. `--team <name>` overrides per call only on `issues create`, `projects create`, `cycles create`, and `labels create`. Run `auth-check --strict` before the first mutation in a project.

`LINEAR_API_KEY` belongs in `.env.local`; non-secret defaults in committed `kendex.settings.toml` `[env]`. A key from project files beats one inherited from the environment, and `auth-check` warns (fingerprints only) when it shadows a differing inherited key.

## Issue Creation Routing

Never create a tracked issue directly from an orchestration or review session. Route it through the TPM pipeline (project-management skill), which owns labels, project, priority, estimate, and relations.

Where `LINEAR_AGENT_LABELS` declares a taxonomy, `issues create` refuses before any API call a create with no agent label from that set (`--no-agent-label` permits a deliberate bare create). Where `LINEAR_REQUIRE_REACH` is set, it refuses a description with no `Reached by:` line and, with `--review-born` and `--priority 2`, one with no `Symptom:` line; a placeholder or null token counts as no line. Each guard is its own setting. What the lines say is the author's to judge; the rule is the project-management skill's SKILL.md § Disposition, **Name what reaches it**, which is also where a create decides whether it is review-born.

## Attachments

`issues create`, `issues update`, and `comments create` take a repeatable `--attach <path>`. Images embed as markdown in the description/body. On `issues update` without `--description`, the embed appends to the existing description rather than replacing it. Other files become Linear attachments on issues, or markdown links on comments (comments have no attachment surface). An unreadable path refuses before any API call; an attachment failure after a successful issue write reports `partial: true` and exits non-zero.

## Blocked Label vs Issue Relations

A blocker that is itself a Linear issue is a relation (`--blocked-by`); an external one (vendor, license) is the `blocked` label plus a comment.

Blocking relations must connect peers of one bundle: same direct parent, or both top-level. The two issues need not share a project. An issue cannot block its own ancestor or descendant; use `--related` for traceability. The check reads each issue's own direct parent in one query.

A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata**. The relation stays for provenance; never remove or "fix" it, and audits must never classify it as stale. The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule").

Normalized issue lists, gets, bulk gets, bundles, recursive children, relation reads, and session status keep each blocking relation in `blocked_by` and list only nonterminal blockers in `blocked_by_open`.

## Option Behavior

What each option accepts: `issues --help`. Refused before any write, on the create and update paths alike: `--cycle` on a non-UUID, `--project`/`--milestone`/`--assignee` on a reference that matches nothing, and `--priority` on an out-of-range value. Available states: Backlog, Todo, In Progress, In Review, Done, Canceled (not "Cancelled"). Verify with `statuses list`.

A **name** selects one project on `issues create` / `update` / `bulk-update --project`, `projects get` / `cache projects get`, `projects list-dependencies` (the live spelling only; `cache projects list-dependencies` matches on the name alone), `milestones --project`, and `initiatives add-project` / `remove-project`. There a canceled project sharing that name loses to the live one, and a name with no live match is refused, naming each match and its state; pass a UUID to reach a canceled project. Name **filters** never resolve: `issues list --project`, `cache issues list --project` and `documents list --project` match on the name alone, so their results can mix a live project with its canceled twin.

`--labels` REPLACES the whole issue-label set. Fetch current labels, compute the final set, validate it against `cache labels list --format=safe` (which reports `is_group` so parent/group labels can be rejected), then pass the complete set. A name that does not resolve fails the update; `--clear-labels` is the only way to empty the set.

- `agent:*` labels are mutually exclusive, one per issue; `issues activate` applies them with the "In Progress" transition (semantics: `issues --help`).
- `issues bulk-update` is non-atomic: on partial failure it emits `partial: true` with per-issue results and exits non-zero.
- `issues block` applies the `blocked` label, creates the blocking relation, and comments. A rejected relation fails the command.

## validate-completion

The pre-merge check on state plus summary comment, live only: `issues validate-completion`, with no `cache` spelling. The expected-state matrix is in `issues --help` § Validate-Completion: session root vs bundle children vs `--container` parents, and the fail-closed flag pairing.

A "labelIds not exclusive child labels" error means two labels from one exclusive group. Requires Bash 4.0+ (macOS system Bash 3.2 is unsupported), `curl`, and `jq`.
