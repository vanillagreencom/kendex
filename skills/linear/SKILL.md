---
name: linear
description: "Load for any Linear read or write: issues, projects, cycles, milestones, initiatives, labels."
summary: "Bash CLI over Linear's GraphQL API, read live: read, search, create, or update issues, projects, cycles, milestones, initiatives, and labels."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [integration]
---

# Linear CLI

```bash
.agents/skills/linear/scripts/linear.sh <resource> <action> [options]
```

Every read and write goes to Linear's API as it runs; no tracker data is stored locally. `linear.sh <resource> --help` prints per-resource options. `--format` values: `safe` (the default, flat and null-safe), `compact` (a smaller shape for workflow routing), `ids` (identifiers only), `table`, `raw` (the GraphQL nesting, so never assume top-level jq paths). `safe` renames fields: `identifier`→`id`, `id`→`uuid`, `state.name`→`state`, `state.type`→`state_type`, `sortOrder`→`sort_order`.

## Commands

| Resource | Actions |
|----------|---------|
| `issues` | list, get, bulk-get, create, update, bulk-update, archive, trash/delete, children, list-relations, add-relation, remove-relation, activate, block, unblock, complete, validate-completion |
| `comments` / `labels` / `project-labels` | list, create, update, delete (`comments` also bulk-list, `labels` also audit) |
| `projects` | list, get, create, update, delete, list-dependencies, add-dependency, remove-dependency, post-update, list-updates, reorder, set-sort-order |
| `initiatives` / `milestones` | list, get, create, update, delete (`initiatives` also add-project, remove-project) |
| `teams` / `users` / `statuses` / `documents` | list, get (`users` also has `me`; `teams keys` reads `{urlKey, keys}` for outbound tracker links without changing `teams list`'s array) |
| `cycles` | list, create, update |
| `attachments` | list (every file an issue references), fetch (download one) |
| `auth-check` | Report the selected credential, actor, team and `writes_enabled` for writes that need a configured team (`--strict` exits non-zero when no team is configured) |
| `auth-mint` | Mint application token JSON from the client pair without writing files |
| `session-status` | Aggregated status for the `/start` workflow |

Aliases: `issues relations` → `list-relations`, `projects dependencies` → `list-dependencies`. Singular resource names (`issue`, `project`, …) route to the plural. There is no `view`/`show`: single-issue lookups are `issues get <ID>`; only `issues get <ID>`, without `--with-bundle` and in the default `safe` format, carries `github_sync`, the GitHub issues Linear's GitHub sync links the issue to, each as `owner/repo#N` lowercased. Multi-issue lookups are `issues bulk-get <ID1> <ID2> ...`, which is also the post-mutation verification path. Comments for several issues are one `comments bulk-list <ID1> <ID2> ...` call (`--stdin` takes one identifier per line), never a loop or parallel `comments list` readers.

The removed `cache` verb exits 1 with one `linear: removed=cache replacement=` line that names its arguments as a live `linear.sh` command (`cache issues get ID` names `linear.sh issues get ID`, and a projects, labels or initiatives list adds `--max`); a spelling only the cache took is named as written and refuses there too. The removed `sync` verb names none, since every read is live.

Schema reference over ctx7: `/websites/studio_apollographql_public_linear-api_variant_current` (API), `/linear/linear` (SDK), `/websites/linear_app_developers` (guides). [patterns/workflow-actions.md](patterns/workflow-actions.md) covers multi-step state changes.

## Reads

```bash
linear.sh issues list --project "Phase 2" --state "Todo,In Progress" --max
linear.sh issues get ABC-100 --with-bundle
linear.sh labels list --max --format=safe
```

`issues list --all-projects` enumerates every project in one command (each row carries its `project` name); `--no-project` returns only unassigned issues. Both are mutually exclusive with `--project`. Use `--all-projects`; never loop per project. An unrecognized filter flag is rejected. Repeated `--label` flags (and `--labels a,b`) require ALL named labels.

A list of issues, projects, labels, project labels, teams, users, cycles, documents or initiatives returns its first `--limit` rows (75 by default, a positive whole number) and prints a `linear-list: truncated` line on stderr when rows were left unread; `--max` reads every page. `milestones list`, `statuses list`, `comments list` and `attachments list` always read every row and take neither. A read follows each nested collection (labels, relations, children, comments) to its end. A read that cannot finish its chain (a failed later page, a missing or repeated cursor, or a chain still open after 400 pages) exits nonzero with no output, never a partial result. An audit that must see the whole backlog passes `--max`. A text search over issues uses `issues list --search TERMS`, which Linear filters by title and description server-side, never a `--max` list piped to a local filter.

A rate-limited request exits nonzero with one JSON line on stderr carrying `"code":"RATELIMITED"` and `requests_reset`, the UTC time the request quota refills. A rate-limited request is retried twice. A query or attachment download answered 5xx or not at all is retried twice too, but such a mutation is sent once, since Linear may already have applied it: stderr then carries a `linear-http: write=unconfirmed` line, and the write is read back before it is sent again. Each wait doubles, or is the answer's `Retry-After` when that is longer; a `Retry-After` over 60 seconds, or any other HTTP error, fails on its first answer. Holding an activation or completion until the reset: [patterns/workflow-actions.md § Quota Holds](patterns/workflow-actions.md#quota-holds).

## Team Target

`LINEAR_TEAM` has no default. Existing-issue writes, including `comments create`, route by the issue identifier and need no configured team. Other writes refuse when it is unset; reads drop the team filter. `--team <key-or-name>` overrides `LINEAR_TEAM` per call only on `issues create`, `projects create`, `cycles create`, `labels create`, `labels audit`, `cycles list`, `statuses list` and `statuses get`; the `--team` filter of `issues list`, `projects list` and `labels list` takes a key or name too. On these reads and `statuses list|get`, an empty or dash-led `--team` value refuses before any request rather than reading every team. Run `auth-check --strict` before the first mutation that needs a configured team in a project.

Every lane writes with one app token, and Linear lets that token write in every team, so `linear.sh` keeps writes in `LINEAR_TEAM` itself. Before any write it refuses `issues create` whose `--team` is another team, and `issues update`, `bulk-update`, `activate`, `block`, `unblock`, `complete`, `archive` and `trash` (or its alias `delete`) on an issue outside `LINEAR_TEAM`, judged by the identifier's prefix against the team key, or by the issue's team for a UUID. Reads, `comments create`, `add-relation` and `remove-relation` run in any team. The refusal line is `linear: refused=cross-team action=<verb> issue=<ID> team=<KEY> own-team=<KEY> route=peer-mail`: give cross-team work to the overseer of that team's repository with `lane-mail peer send --repo [REPO]`. No setting turns the guard off. With no `LINEAR_TEAM`, an existing-issue write runs unchecked and prints `linear: cross-team-guard=inactive`.

Set `LINEAR_APP_TOKEN` or the client pair in the project's private env file (`.env.local` unless `KENDEX_ENV_FILE` names another); `op://` references are supported. Use `auth-mint` on the host with the real pair to publish a token to the fleet. Credential precedence, expiry, caching and attribution: [README.md § Setup](README.md#setup).

`LINEAR_API_KEY` and `KENDEX_USER_EMAIL`, the operator's email, also belong in the private env file. Non-secret defaults belong in committed `kendex.settings.toml` `[env]`. The kendex app's Customize tab writes the key, team and email. A `LINEAR_API_KEY` from project files beats an inherited key. When the personal key is selected, `auth-check` warns with fingerprints if it shadows a different inherited key. Every other key uses process environment precedence over the private env file.

## Shared label maintenance

`LINEAR_TEAM` requires a target before writes that do not address an issue; it does not restrict an API key or check a label's owning team. `auth-check` verifies authentication and the local target, not the key's permission mask. Inspect key permissions in Linear settings; report fingerprints only.

Before changing a label definition, read its ID, team, parent and group status. An empty team means workspace scope. Read issue use across affected teams and check references in their manifests, scripts, gates and generated instructions. A team-restricted key cannot establish workspace-wide issue use.

The workspace owner coordinates shared label changes with affected repository maintainers. A repository taxonomy names that owner. Keep generic labels shared and project-specific labels team-scoped. Obtain approval for the concrete affected set and the exact proposed change before any shared-label definition change, replacement or deletion. Issue-label assignment authority does not authorize changing a shared label definition.

Prepare dependent repository corrections before the label change. After an authorized change, refresh each affected inventory, render instructions from their source, and run its taxonomy and repository checks. Record the label IDs, issue assignments and repository commits together. If the API cannot change scope, prepare a replacement plan with history and recovery limits before requesting migration approval.

## Issue Creation Routing

Never create a tracked issue directly from an orchestration or review session. Route it through the TPM pipeline (project-management skill), which owns labels, project, priority, estimate, and relations.

Where `LINEAR_AGENT_LABELS` declares a taxonomy, `issues create` refuses before any API call a create with no agent label from that set (`--no-agent-label` permits a deliberate bare create). Unless `LINEAR_REQUIRE_REACH` is set empty, it refuses a description with no `Reached by:` line and, with `--review-born` and `--priority 2`, one with no `Symptom:` line; a placeholder or null token counts as no line. Each guard is its own setting. What the lines say is the author's to judge; the rule is the project-management skill's SKILL.md § Disposition, **Name what reaches it**, which is also where a create decides whether it is review-born.

Where the repository declares a label taxonomy (the project-management skill's references/labels.md § Project Taxonomy Contract), `issues create`, `issues update --labels`, `issues bulk-update --labels`, `issues activate` and `issues block` refuse before any write a label it does not declare, naming the label and the taxonomy file; a label the issue already carries is kept, and `issues create` also refuses a declared label Linear does not have. `labels create` and `labels update --name` refuse an undeclared name, and a name a workspace label already uses (on create, only a `--team` label). `labels audit` lists the undeclared labels on the team's open issues and the same-name team/workspace pairs. With no taxonomy declared, none of this applies.

## Attachments

`issues create`, `issues update`, and `comments create` take a repeatable `--attach <path>`. Images embed as markdown in the description/body. On `issues update` without `--description`, the embed appends to the existing description rather than replacing it. Other files become Linear attachments on issues, or markdown links on comments (comments have no attachment surface). An unreadable path refuses before any API call; an attachment failure after a successful issue write reports `partial: true` and exits non-zero. Existing-issue attachments require a successful live issue lookup with a nonempty canonical ID before upload, including for UUID input.

`issues create` and attach-only `issues update` report `attachments_requested`, the number of non-image records requested, and `attachments`, one `{url, repo_path}` object per record in request order once every `attachmentCreate` succeeded. On `issues create` they appear in the default JSON response only, so a create that needs this verification takes the default output: `--format=ids` prints the identifier alone and discards both fields. Those fields are the immediate verification; `attachments list` reads the records live.

### Resolve a cited artifact

Read a cited repository path when it exists. When it is absent, list the issue's attachments; a failed list is a read failure to report, not a missing attachment.

```bash
linear.sh attachments list [ISSUE_ID]
linear.sh attachments fetch [URL] --output tmp/[FILENAME]
```

Read the issue description's `**Artifacts**` list first: its `[repository path](url)` links name the current copy, on this issue or another, so the link whose label is the cited path selects the entry with that `url`, whatever its `context`. With no such link, match the original cited repository path against `repo_path`, scoped to that issue or the research/source issue its brief explicitly names. For attachments with no `repo_path` and no such link, accept a filename match only when it is unique within that issue. Use an attachment URL in the brief to select the matching `url` when references collide. Fetch the match into `tmp/` and read that file; keep the repository path as the tracker reference. Resolve companion files, such as a plan's JSON or research metadata, the same way. Do not write a machine's `tmp/` path into an issue or delegation for another checkout.

No match leaves the calling workflow's missing-file behavior unchanged. Multiple matches without a distinguishing reference require clarification. A failed fetch is a download failure; report it instead of treating the research as absent. Consumers without attachments keep reading repository files as before.

## Blocked Label vs Issue Relations

A blocker that is itself a Linear issue is a relation (`--blocked-by`); an external one (vendor, license) is the `blocked` label plus a comment.

Blocking relations must connect peers of one bundle: same direct parent, or both top-level. The two issues need not share a project. An issue cannot block its own ancestor or descendant; use `--related` for traceability. The check reads each issue's own direct parent in one query.

A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata**. The relation stays for provenance; never remove or "fix" it, and audits must never classify it as stale. The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule"). `issues remove-relation` refuses such a relation before any write, with one `linear: refused=completed-blocker` line. Its `--peer-rule-violation` route, the project-management skill's tpm-audit structural repair, removes one only when the pair breaks the peer rule above.

Normalized issue lists, gets, bulk gets, bundles, recursive children, relation reads, and session status keep each blocking relation in `blocked_by` and list only nonterminal blockers in `blocked_by_open`.

## Option Behavior

What each option accepts: `issues --help`. Refused before any write, on the create and update paths alike: `--cycle` on a non-UUID, `--project`/`--milestone`/`--assignee` on a reference that matches nothing, and `--priority` on an out-of-range value. Resolve state names from `statuses list` for the issue's team. Verifying is a started state after In Review. It holds merged work with an open post-merge Done-when box. It is verification work for the overseer, not a development launch.

A **name** selects one project on `issues create` / `update` / `bulk-update --project`, `projects get`, `projects list-dependencies`, `milestones --project`, and `initiatives add-project` / `remove-project`. Issue creation resolves the name within `LINEAR_TEAM` or `--team`. Updates and bulk updates resolve it within each issue's recorded team. Multiple live matches in that team refuse with each project's UUID and team name. A canceled project sharing the name loses to the live one, and a name with no live match is refused, naming each match and its state; pass a UUID to reach a canceled project. Name **filters** never resolve: `issues list --project` and `documents list --project` match on the name alone, so their results can mix a live project with its canceled twin.

`--labels` REPLACES the whole issue-label set. Fetch current labels, compute the final set, validate it against `labels list --max --format=safe` (which reports `is_group` so parent/group labels can be rejected), then pass the complete set. `issues update --labels` and `issues activate --agent` resolve names live against the issue's own team and workspace labels. An unresolved name refuses before mutation and names the team and label. `--clear-labels` is the only way to empty the set.

- `agent:*` labels are mutually exclusive, one per issue; `issues activate` applies them with the "In Progress" transition (semantics: `issues --help`). Its default output is JSON; `--format ids` or `--format=ids` prints only the identifier.
- `issues activate` assigns an issue nobody is assigned to the user whose email is `KENDEX_USER_EMAIL`, in the same mutation, and never replaces an assignee. It says which happened in one stderr line, `assignee-set`, `assignee-kept` or `assignee-skipped` with its `cause=`, and in the result's `assignee` field; a skip still activates, and a failed issue read, users lookup or update fails the activation with no line (lines: `issues --help`). `--assignee` on create and update takes the same address form: a value containing `@` matches a user's whole email, case-insensitively; a user id is sent as given.
- `issues bulk-update` is non-atomic: on partial failure it emits `partial: true` with per-issue results and exits non-zero.
- `issues block` applies the `blocked` label, creates the blocking relation, and comments. A rejected relation fails the command.
- `issues complete` posts an optional summary before setting Done. With `--post-merge-at`, it validates the checklist against the merged PR's `mergedAt` and sets Verifying while a post-merge box remains open. It requires every branch-provable box to be checked. Each post-merge box uses the project-management skill's Done-when form and a deadline after merge and at most three days later. Without that option, explicit completion keeps its ordinary Done behavior. Its default output is JSON; `--format ids` or `--format=ids` prints only the identifier. A failed state update after a posted summary exits nonzero and reports on stderr in either format.

## validate-completion

The pre-merge check on state plus summary comment: `issues validate-completion`. The expected-state matrix is in `issues --help` § Validate-Completion: session root vs bundle children vs `--container` parents, and the fail-closed flag pairing.

A "labelIds not exclusive child labels" error means two labels from one exclusive group. Requires Bash 4.0+ (macOS system Bash 3.2 is unsupported), `curl`, and `jq`.
