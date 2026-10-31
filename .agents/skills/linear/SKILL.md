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

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

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
| `projects` | list, get, create, update, delete, list-dependencies, add-dependency, remove-dependency, post-update, list-updates, reorder, set-sort-order, audit; create/update take `--lead EMAIL\|ID` and repeatable `--link LABEL=URL` |
| `initiatives` / `milestones` | list, get, create, update, delete (`initiatives` also add-project, remove-project; create/update take `--owner EMAIL\|ID`, `--lead-team KEY\|NAME`, `--labels A,B`, and repeatable `--link LABEL=URL`) |
| `teams` / `users` / `statuses` / `documents` | list, get (`users` also has `me`; `teams keys` reads `{urlKey, keys}` for outbound tracker links without changing `teams list`'s array) |
| `cycles` | list, create, update |
| `attachments` | list (every file an issue references), fetch (download one) |
| `auth-check` | Report the selected credential, actor, team and `writes_enabled` for writes that need a configured team (`--strict` exits non-zero when no team is configured) |
| `auth-mint` | Mint application token JSON from the client pair without writing files |
| `journal` | Start, stop or read a bounded local request-attempt journal; off by default |
| `session-status` | Aggregated status for the `/start` workflow |

Aliases: `issues relations` → `list-relations`, `projects dependencies` → `list-dependencies`. Singular resource names (`issue`, `project`, …) route to the plural. There is no `view`/`show`: single-issue lookups are `issues get <ID>`; only `issues get <ID>`, without `--with-bundle` and in the default `safe` format, carries `github_sync`, the GitHub issues Linear's GitHub sync links the issue to, each as `owner/repo#N` lowercased. Safe `issues get` and `issues list` rows carry `in_pr_bundle`, true when the description holds `**In-PR bundle**: yes`. Multi-issue lookups are `issues bulk-get <ID1> <ID2> ...`, which is also the post-mutation verification path. Comments for several issues are one `comments bulk-list <ID1> <ID2> ...` call (`--stdin` takes one identifier per line), never a loop or parallel `comments list` readers.

The removed `cache` and `sync` verbs refuse with one `linear: removed=` line (`linear.sh --help`).

Schema reference over ctx7: `/websites/studio_apollographql_public_linear-api_variant_current` (API), `/linear/linear` (SDK), `/websites/linear_app_developers` (guides). [patterns/workflow-actions.md](patterns/workflow-actions.md) covers multi-step state changes.

## Reads

Read the time an issue entered a state from its history: the matching `toState` row's `createdAt`. Read every history page needed to identify the latest transition into that state. `updated_at` records the issue's latest update, which can be a different change. Use Linear's API or activity history; `issues get` exposes no history field. If the transition is unavailable, report its time as unread.

```bash
linear.sh issues list --project "Phase 2" --state "Todo,In Progress" --max
linear.sh issues get ABC-100 --with-bundle
linear.sh labels list --max --format=safe
```

`issues list --all-projects` enumerates every project in one command (each row carries its `project` name); `--no-project` returns only unassigned issues. Both are mutually exclusive with `--project`. Use `--all-projects`; never loop per project. An unrecognized filter flag is rejected. Repeated `--label` flags (and `--labels a,b`) require ALL named labels.

A list of issues, projects, labels, project labels, teams, users, cycles, documents or initiatives returns its first `--limit` rows (75 by default, a positive whole number) and prints a `linear-list: truncated` line on stderr when rows were left unread; `--max` reads every page. `milestones list`, `statuses list`, `comments list` and `attachments list` always read every row and take neither. A read follows each nested collection (labels, relations, children, comments) to its end. A read that cannot finish its chain (a failed later page, a missing or repeated cursor, or a chain still open after 400 pages) exits nonzero with no output, never a partial result. An audit that must see the whole backlog passes `--max`. A text search over issues uses `issues list --search TERMS`, which Linear filters by title and description server-side, never a `--max` list piped to a local filter.

A quota refusal exits nonzero with JSON stderr `code:"RATELIMITED"`. Its `quota` receipt supplies the selected deadline; `requests_reset` keeps the raw request-header time. Same-binding GraphQL calls share a private hold on this host. Receipt fields, storage failures and held writes: [Quota Holds](patterns/workflow-actions.md#quota-holds).

The transport retries a rate refusal, a 5xx query/download or an unanswered query/download at most twice. A known hold can stop a GraphQL retry before HTTP. A 5xx or unanswered mutation is sent once with `linear-http: write=unconfirmed`: read its result before resending. Waits double, or use a longer `Retry-After`. A `Retry-After` over 60 seconds or any other HTTP error fails immediately.

## Request journal

Set `LINEAR_JOURNAL_DIR` to an absolute new directory in every process that participates. The installed interface is:

```bash
linear.sh journal start --max-bytes BYTES --actor-id UUID
linear.sh journal stop
linear.sh journal read
```

Start accepts a positive byte limit of at most nine digits and a supplied actor UUID. It creates the directory exclusively and binds that identity to the selected credential. It sends no API request and mints no token. Read and stop need no credential lookup. A changed credential leaves actor identity unread. The supplied identity is an operator assertion, not an independent API check. A client pair keeps its binding through token renewal.

The journal is `attempts.jsonl` in that directory. It records completed HTTP attempts for GraphQL, token mint and renewal, attachment downloads and storage PUTs. Each attempt carries the raw HTTP status, safe operation name, attempt within its authorization phase, actor provenance and caller repository/script/item. `LINEAR_JOURNAL_CALLER` supplies a script identifier without arguments. `LINEAR_JOURNAL_ITEM` supplies a carrying issue identifier or `owner/repo#number`. Missing labels stay unread or use the actual Linear command script. No request or response body, variables, authorization, credential value or signed URL is retained.

Collection stops after one hour, before an append would exceed the byte limit, on explicit stop, or on a journal failure. Each new session needs a new directory. The byte limit covers the journal file; small fixed session, stop and writer-lock metadata are additional. A journal failure reports unavailable or incomplete evidence without changing the HTTP result. A lock is never reclaimed by signalling a saved process number.

Read reports the session state, per-caller attempt counts, the top five callers by attempts, separate transport counts and identity/label/complexity coverage. It sums only returned valid `X-Complexity` values. Missing values stay unread. Shared remaining-quota changes are never request costs. A rate-limit refusal does not establish which caller spent the shared quota.

Only participating installed transport processes on this host are covered. The window uses the host clock and records completed attempts. An attempt completed after expiry, or killed before its record, can be absent. A collection stopped before expiry, capped or failed is not a complete hour. Storage attempts need not consume GraphQL quota.

## Team Target

`LINEAR_TEAM` has no default. Existing-issue writes, including `comments create`, route by the issue identifier and need no configured team. Other writes refuse when it is unset; reads drop the team filter. `--team <key-or-name>` overrides `LINEAR_TEAM` per call only on `issues create`, `projects create`, `cycles create`, `labels create`, `labels audit`, `projects audit`, `cycles list`, `statuses list` and `statuses get`; the `--team` filter of `issues list`, `projects list` and `labels list` takes a key or name too. On these reads and `statuses list|get`, an empty or dash-led `--team` value refuses before any request rather than reading every team. Run `auth-check --strict` before the first mutation that needs a configured team in a project.

Every lane writes with one app token, and Linear lets that token write in every team, so `linear.sh` keeps writes in `LINEAR_TEAM` itself. Before any write it refuses `issues create` whose `--team` is another team, and `issues update`, `bulk-update`, `activate`, `block`, `unblock`, `complete`, `archive` and `trash` (or its alias `delete`) on an issue outside `LINEAR_TEAM`, judged by reading the issue's current team for each identifier or UUID, once per distinct reference per invocation. A failed team read refuses as `refused=cross-team-unread` before any write. Reads, `comments create`, `add-relation` and `remove-relation` run in any team. The refusal line is `linear: refused=cross-team action=<verb> issue=<ID> team=<KEY> own-team=<KEY> route=peer-mail`: give cross-team work to the overseer of that team's repository with `lane-mail peer send --repo [REPO]`. No setting turns the guard off. With no `LINEAR_TEAM`, an existing-issue write runs unchecked and prints `linear: cross-team-guard=inactive`.

Set `LINEAR_APP_TOKEN` or the client pair in the project's private env file (`.env.local` unless `KENDEX_ENV_FILE` names another); `op://` references are supported. Use `auth-mint` on the host with the real pair to publish a token to the fleet. Credential precedence, expiry, caching and attribution: [authentication](references/authentication.md).

`LINEAR_API_KEY` and `KENDEX_USER_EMAIL`, the operator's email, also belong in the private env file. Non-secret defaults belong in committed `kendex.settings.toml` `[env]`. The kendex app's Customize tab writes the key, team and email. A `LINEAR_API_KEY` from project files beats an inherited key. When the personal key is selected, `auth-check` warns with fingerprints if it shadows a different inherited key. Every other key uses process environment precedence over the private env file.

## Shared label maintenance

`LINEAR_TEAM` requires a target before writes that do not address an issue; it does not restrict an API key or check a label's owning team. `auth-check` verifies authentication and the local target, not the key's permission mask. Inspect key permissions in Linear settings; report fingerprints only.

Before changing a label definition, read its ID, team, parent and group status. An empty team means workspace scope. Read issue use across affected teams and check references in their manifests, scripts, gates and generated instructions. A team-restricted key cannot establish workspace-wide issue use.

The workspace owner coordinates shared label changes with affected repository maintainers. A repository taxonomy names that owner. Keep generic labels shared and project-specific labels team-scoped. Obtain approval for the concrete affected set and the exact proposed change before any shared-label definition change, replacement or deletion. Issue-label assignment authority does not authorize changing a shared label definition.

Prepare dependent repository corrections before the label change. After an authorized change, refresh each affected inventory, render instructions from their source, and run its taxonomy and repository checks. Record the label IDs, issue assignments and repository commits together. If the API cannot change scope, prepare a replacement plan with history and recovery limits before requesting migration approval.

## Issue Creation Routing

Never create a tracked issue directly from an orchestration or review session. Route it through the TPM pipeline (project-management skill), which owns labels, project, priority, estimate, and relations.

`issues create` needs a `LINEAR_AGENT_LABELS` label before API calls when set; `--no-agent-label` allows bare creates. Unless `LINEAR_REQUIRE_REACH` is set empty, create needs `Reached by:` and, with `--review-born --priority 2`, `Symptom:`; placeholders and null tokens are absent. Authored create/update/bulk-update bodies then need nonempty quoted `> **Story:**` then `> **Why this matters:**` blocks after any owner action line. Quote block text; put unquoted blank lines between blocks and before any first heading. Unfilled opening placeholders are empty. Headers over 500 characters refuse with line and length. Updates only placing, replacing or removing a stored body's leading owner action line check its length alone; other empty changed bodies refuse. Other guards have separate settings. Authors and reviewers judge prose; software checks structure. Filing-line and review-born rules: project-management SKILL.md § Disposition, **Name what reaches it**.

Under a declared label taxonomy (project-management references/labels.md § Project Taxonomy Contract), `issues create`, `issues update --labels`, `issues bulk-update --labels`, `issues activate` and `issues block` refuse before any write a label it does not declare, naming the label and the taxonomy file. The taxonomy check does not refuse an undeclared label the issue already carries. `issues create` refuses declared labels absent from Linear. `labels create` and `labels update --name` refuse an undeclared name, and a name a workspace label already uses (on create, only a `--team` label). `labels audit` lists the undeclared labels on the team's open issues and the same-name team/workspace pairs. With no taxonomy declared, none of this applies.

Under a declared project map, `issues create`, `issues update --project` and `issues bulk-update --project` refuse a project off it, and `projects audit` lists what lies outside it: the project-management skill's references/project-map.md § Routing and § Audit.

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

For a cross-team relation, select a minted app token through `LINEAR_APP_TOKEN` ([credential selection](references/authentication.md)). Confirm `credential: "app-token"` with `auth-check` and check that the actor can access both teams.

A blocker that is itself a Linear issue is a relation (`--blocked-by`); an external one (vendor, license) is the `blocked` label plus a comment.

Blocking relations may connect issues with the same direct parent, two top-level issues, or a blocked leaf to an issue outside its ancestors. An ancestor/descendant pair is refused at any depth; use `--related` for traceability. The two issues need not share a project. One query reads child status and parent chains. An incomplete chain refuses.

A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata**. The relation stays for provenance; never remove or "fix" it, and audits must never classify it as stale. The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule"). `issues remove-relation` refuses such a relation before any write, with one `linear: refused=completed-blocker` line. Its `--peer-rule-violation` route, the project-management skill's tpm-audit structural repair, removes one only when the pair breaks the blocking-level rule above.

Normalized issue lists, gets, bulk gets, bundles, recursive children, relation reads, and session status keep each blocking relation in `blocked_by` and list only nonterminal blockers in `blocked_by_open`.

## Option Behavior

What each option accepts: `issues --help`. Refused before any write, on create and update: `--cycle` on a non-UUID, `--project`/`--milestone`/`--assignee` on a reference that matches nothing, and `--priority` on an out-of-range value. Resolve state names from `statuses list` for the issue's team. Verifying is a started state after In Review. The verification pass reads its post-merge checks.

A **name** selects one project on `issues create` / `update` / `bulk-update --project`, `projects get`, `projects list-dependencies`, `milestones --project`, and `initiatives add-project` / `remove-project`. Issue creation resolves the name within `LINEAR_TEAM` or `--team`. Updates and bulk updates resolve it within each issue's recorded team. Multiple live matches in that team refuse with each project's UUID and team name. A canceled project sharing the name loses to the live one, and a name with no live match is refused, naming each match and its state; pass a UUID to reach a canceled project. Name **filters** never resolve: `issues list --project` and `documents list --project` match on the name alone, so their results can mix a live project with its canceled twin.

`--labels` REPLACES the whole issue-label set. Fetch current labels, compute the final set, validate it against `labels list --max --format=safe` (which reports `is_group` so parent/group labels can be rejected), then pass the complete set. `issues update --labels` and `issues activate --agent` resolve names live against the issue's own team and workspace labels. An unresolved name refuses before mutation and names the team and label. `--clear-labels` is the only way to empty the set.

- `agent:*` labels are mutually exclusive, one per issue; `issues activate` applies them with the "In Progress" transition (semantics: `issues --help`). Its default output is JSON; `--format ids` or `--format=ids` prints only the identifier.
- `issues activate` assigns an issue nobody is assigned to the user whose email is `KENDEX_USER_EMAIL`, in the same mutation, and never replaces an assignee. It says which happened in one stderr line, `assignee-set`, `assignee-kept` or `assignee-skipped` with its `cause=`, and in the result's `assignee` field; a skip still activates, and a failed issue read, users lookup or update fails the activation with no line (lines: `issues --help`). `--assignee` on create and update takes the same address form: a value containing `@` matches a user's whole email, case-insensitively; a user id is sent as given.
- `issues update` and `bulk-update` refuse completed-type states if the new description has open Done-when boxes or checked boxes without indented, nonblank `Evidence:` directly below. Refusals list the issue, boxes and `fix=issues complete`. Bulk lists each refusal before writes. Partial failures emit per-issue results, `partial: true`, and exit nonzero.
- `issues block` applies the `blocked` label, creates the blocking relation, and comments. A rejected relation fails the command.
- `issues complete` posts an optional summary before setting Done. Use `--done-when-met all` or a comma-separated list of box numbers to tick verified Done-when boxes in the same update that sets the state. With `--post-merge-at`, it validates the checklist against the merged PR's `mergedAt` and sets Verifying while a post-merge box remains open. It requires every branch-provable box to be checked. Each post-merge box uses the project-management skill's Done-when form and trigger deadline window. Every call parses the Done-when checklist. An open branch box refuses before any summary or state write. Without `--post-merge-at`, an open post-merge box keeps the current started state; other states refuse. Every checked box needs a nonblank `Evidence:` line indented directly below it. `--done-when-met` takes `--evidence-file PATH`, with one `N: text` line per box, and writes evidence with the tick and state. Select already-ticked boxes to add evidence from their existing evidence comments. An item with no Done-when section, a container among them, completes as Done. orch's container-close ticks a container's one box, "Every child Done or cancelled", as it sets it Done; an all-canceled container is set Canceled, its box open. container-close owns child validation, the bundle summary and the Done transition, and needs no merge time. Its default output is JSON; `--format ids` or `--format=ids` prints only the identifier. A failed state update after a posted summary exits nonzero and reports on stderr in either format.

## validate-completion

The pre-merge check on state plus summary comment: `issues validate-completion`. The expected-state matrix is in `issues --help` § Validate-Completion: session root vs bundle children vs `--container` parents, and the fail-closed flag pairing.

A "labelIds not exclusive child labels" error means two labels from one exclusive group. Requires Bash 4.0+ (macOS system Bash 3.2 is unsupported), `curl`, and `jq`.
