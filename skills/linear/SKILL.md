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

`cache issues list --all-projects` enumerates every project in one command (each row carries its `project` name); `--no-project` returns only unassigned issues. Both are mutually exclusive with `--project`. Use `--all-projects`; never loop per project. An unrecognized filter flag is rejected. Repeated `--label` flags (and `--labels a,b`) require ALL named labels.

Both `issues list` and `cache issues list` return the first 75 rows by default and warn on stderr when that truncated the result; `--max` fetches everything. `--limit N` caps a CACHE listing's total; on the live path it is the per-page size (`--max --limit N` pages at N under a 200-page cap that warns when it truncates). An audit that must see the whole backlog passes `--max`.

The cache lives at `.cache/linear` under the physical worktree root from `git rev-parse --show-toplevel`, or under `LINEAR_CACHE_ROOT` when the caller sets it, and a value naming no directory is refused rather than falling back. That redirect moves the cache and the attachment store only; the API key and other project settings still come from the repository the command runs in. A missing-cache error names the `cache_dir` and `meta_path` it checked. A cache file that exists but does not parse is reported as corrupt, never as an empty result.

In a linked worktree whose `.cache` should be a `WORKTREE_SYMLINKS`-managed symlink but is a real directory, `sync` refuses before touching the API and names the repair (`worktree fix-links <PATH>` from the main checkout). Repos whose `WORKTREE_SYMLINKS` deliberately excludes `.cache` are exempt.

## Team Target

`LINEAR_TEAM` has no default. With it unset every write refuses before any API call; reads drop the team filter. `--team <name>` overrides per call only on `issues create`, `projects create`, `cycles create`, and `labels create`. Run `auth-check --strict` before the first mutation in a project.

| Variable | Purpose | Default |
|----------|---------|---------|
| `LINEAR_API_KEY` | Required for live commands and sync; not for cache reads | — |
| `LINEAR_API_KEY_OVERRIDE` | Inline/test key that beats project files | — |
| `LINEAR_TEAM` | Team every write targets | — (unset refuses writes) |
| `LINEAR_FORMAT` | Default output format | `safe` |
| `LINEAR_TEAM_PREFIX` | Issue identifier prefix | `PROJ` |
| `LINEAR_AGENT_LABELS` | Declared `agent:*` taxonomy; non-empty makes `issues create` refuse unrouted creates | — (unset = off) |
| `LINEAR_REQUIRE_REACH` | Non-empty makes `issues create` refuse a body with no `Reached by:` line | — (unset = off) |

`LINEAR_API_KEY` belongs in `.env.local`; non-secret defaults in committed `kendex.settings.toml` `[env]`. A key from project files beats one inherited from the environment, and `auth-check` warns (fingerprints only) when it shadows a differing inherited key.

## Issue Creation Routing

Never create a tracked issue directly from an orchestration or review session — route it through the TPM pipeline (project-management skill), which owns labels, project, priority, estimate, and relations.

Where `LINEAR_AGENT_LABELS` declares a taxonomy, `issues create` refuses — before any API call — a create carrying no agent label from that set, including a typoed `agent:*` name. `--no-agent-label` permits a deliberate bare create.

Where `LINEAR_REQUIRE_REACH` is set, `issues create` refuses — before any API call — a description with no `Reached by:` line and, with `--review-born`, a `--priority 2` description with no `Symptom:` line. An unsubstituted placeholder (`[REACH]`) or a null token (`TBD`, `n/a`, `none`, `-`) counts as no line, so a refusal naming a missing line is what an author who typed one of those reads. What the lines say is the author's to judge; the guard checks that they are there. Each refusal states the rule it enforces; the rule itself is the project-management skill's SKILL.md § Disposition, **Name what reaches it**, which is also where a create decides whether it is review-born.

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

Blocking relations must connect peers of one bundle: same direct parent, or both top-level. The two issues need not share a project. An issue cannot block its own ancestor or descendant; use `--related` for traceability. The check reads each issue's own direct parent in one query.

A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata** — Linear itself already treats the dependent issue as unblocked. The relation stays for provenance; never remove or "fix" it, and audits must never classify it as stale. The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule").

Normalized issue lists, gets, bulk gets, bundles, recursive children, relation reads, and session status keep each blocking relation in `blocked_by` and list only nonterminal blockers in `blocked_by_open`.

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

Where a **name** selects one project — `issues create` / `update` / `bulk-update --project`, `projects get`, `projects list-dependencies`, `milestones --project`, `initiatives add-project` / `remove-project` — a canceled project sharing that name loses to the live one, and a name with no live match is refused, naming each match and its state; pass a UUID to reach a canceled project. Name **filters** never resolve: `issues list --project`, `cache issues list --project` and `documents list --project` match on the name alone, so their results can mix a live project with its canceled twin.

`--labels` REPLACES the whole issue-label set. Fetch current labels, compute the final set, validate it against `cache labels list --format=safe` (which reports `is_group` so parent/group labels can be rejected), then pass the complete set. A name that does not resolve fails the update; `--clear-labels` is the only way to empty the set.

- `agent:*` labels are mutually exclusive, one per issue; `issues activate` applies them with the "In Progress" transition (semantics: `issues --help`).
- `issues bulk-update` is non-atomic: on partial failure it emits `partial: true` with per-issue results and exits non-zero.
- `issues block` applies the `blocked` label, creates the blocking relation, and comments. A rejected relation fails the command.

## validate-completion

The pre-merge check on state plus summary comment, live only — `issues validate-completion`, with no `cache` spelling. The expected-state matrix — session root vs bundle children vs `--container` parents, and the fail-closed flag pairing — is in `issues --help` § Validate-Completion.

A "labelIds not exclusive child labels" error means two labels from one exclusive group. Requires Bash 4.0+ (macOS system Bash 3.2 is unsupported), `curl`, and `jq`.
