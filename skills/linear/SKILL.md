---
name: linear
description: "Load for any Linear read or write: issues, projects, cycles, milestones, initiatives, labels."
summary: "Bash CLI over Linear's GraphQL API: read, search, create, or update issues, projects, cycles, milestones, initiatives, and labels."
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

`linear.sh <resource> --help` prints the options of each resource.

`--format` takes these values:

- `safe`: the default, flat and null-safe.
- `compact`: a smaller shape for workflow routing.
- `ids`: identifiers only.
- `table`.
- `raw`: the GraphQL nesting. Never assume top-level jq paths in it.

`safe` renames fields: `identifier`→`id`, `id`→`uuid`, `state.name`→`state`, `state.type`→`state_type`, `sortOrder`→`sort_order`.

## Commands

| Resource | Actions |
|----------|---------|
| `issues` | list, get, bulk-get, create, update, bulk-update, archive, trash/delete, list-relations, add-relation, remove-relation, activate, block, unblock, complete, validate-completion |
| `comments` | list, bulk-list, create, update, delete |
| `labels` | list, create, update, delete, audit |
| `project-labels` | list, create, update, delete |
| `projects` | list, create, update, delete, list-dependencies, add-dependency, remove-dependency, post-update, list-updates, reorder, set-sort-order, audit |
| `initiatives` | list, get, create, update, delete, add-project, remove-project |
| `milestones` | list, get, create, update, delete |
| `teams` | list, get, keys |
| `users` | list, get, me |
| `statuses` | list, get |
| `documents` | list, get |
| `cycles` | list, create, update |
| `attachments` | list, fetch |
| `graphql` | One read document as written |
| `auth-check` | Report the selected credential, actor, team and `writes_enabled` |
| `auth-mint` | Mint application token JSON from the client pair, writing no files |
| `journal` | start, stop, read |
| `session-status` | Aggregated status for the `/start` workflow |

- `issues get <ID>` answers the issue with its children to three levels.
- Safe output flattens those children into `children` rows. Each row carries its `depth`, 0 for a direct child.
- `pending_count` counts the open children.
- A field `issues get` does not carry, such as the GitHub issues Linear's GitHub sync links the issue to (`syncedWith`), is a `graphql` read.
- Safe `issues get` and `issues list` rows carry `in_pr_bundle`. It is true when the description holds `**In-PR bundle**: yes`.
- Look up several issues with one `issues bulk-get <ID1> <ID2> ...`. It is also the route to verify a write.
- Read the comments of several issues with one `comments bulk-list <ID1> <ID2> ...` call. `--stdin` takes one identifier per line. Never loop or run parallel `comments list` readers.

Schema reference over ctx7: `/websites/studio_apollographql_public_linear-api_variant_current` (API), `/linear/linear` (SDK), `/websites/linear_app_developers` (guides).

## Read when

- Before a multi-step change built from these commands, such as a cancel, an absorb, a parent rebuild, a label update from a workflow or a held write: [patterns/workflow-actions.md](patterns/workflow-actions.md).
- Before changing a shared label definition: [patterns/workflow-actions.md § Shared label maintenance](patterns/workflow-actions.md#shared-label-maintenance).
- When a brief cites a repository path that does not exist: [patterns/workflow-actions.md § Resolve a cited artifact](patterns/workflow-actions.md#resolve-a-cited-artifact).
- When selecting, checking or renewing the credential a command uses, or when a write's attribution matters: [references/authentication.md](references/authentication.md).
- When starting, stopping or reading the request journal: [references/request-journal.md](references/request-journal.md).

## Reads

Read the time an issue entered a state from its history:

1. Take the matching `toState` row's `createdAt`.
2. Read every history page needed to identify the latest transition into that state.
3. Use Linear's API or activity history. `issues get` exposes no history field.
4. If the transition is unavailable, report its time as unread.

`updated_at` records the issue's latest update, which can be a different change.

- `issues list --all-projects` enumerates every project in one command. Each row carries its `project` name.
- `--no-project` returns only unassigned issues.
- Both are mutually exclusive with `--project`.
- Use `--all-projects`. Never loop per project.
- Repeated `--label` flags, and `--labels a,b`, require ALL named labels.

A list of issues, projects, labels, project labels, teams, users, cycles, documents or initiatives has these limits:

- It returns its first `--limit` rows, 75 by default, a positive whole number.
- It prints a `linear-list: truncated` line on stderr when rows were left unread.
- `--max` reads every page.
- `milestones list`, `statuses list`, `comments list` and `attachments list` always read every row and take neither option.

Every read is whole or fails:

- A read follows each nested collection (labels, relations, children, comments) to its end.
- A read that cannot finish its chain exits nonzero with no output, never a partial result. A failed later page, a missing or repeated cursor, or a chain still open after 400 pages each end the chain.
- An audit that must see the whole backlog passes `--max`.
- A text search over issues uses `issues list --search TERMS`, which Linear filters by title and description server-side. Never pipe a `--max` list to a local filter.

A quota refusal exits nonzero with JSON stderr `code:"RATELIMITED"`.

- Its `quota` receipt supplies the selected deadline.
- `requests_reset` keeps the raw request-header time.
- Same-binding GraphQL calls share a private hold on this host.
- Receipt fields, storage failures and held writes: [Quota Holds](patterns/workflow-actions.md#quota-holds).

The transport retries a rate refusal, a 5xx query or download, or an unanswered query or download, at most twice. A 5xx or unanswered mutation is sent once with `linear-http: write=unconfirmed`. Read its result before resending.

## Team Target

`LINEAR_TEAM` has no default.

- Existing-issue writes, including `comments create`, route by the issue identifier and need no configured team.
- Other writes refuse when it is unset.
- Reads drop the team filter when it is unset.
- `--team <key-or-name>` overrides `LINEAR_TEAM` for one call only on `issues create`, `projects create`, `cycles create`, `labels create`, `labels audit`, `projects audit`, `cycles list`, `statuses list` and `statuses get`.
- The `--team` filter of `issues list`, `projects list` and `labels list` takes a key or name too.
- Run `auth-check --strict` before the first mutation that needs a configured team in a project.

`linear.sh` keeps issue writes in `LINEAR_TEAM`:

- Before any write, it refuses `issues create` whose `--team` is another team.
- Before any write, it refuses `issues update`, `bulk-update`, `activate`, `block`, `unblock`, `complete`, `archive` and `trash` (or its alias `delete`) on an issue outside `LINEAR_TEAM`.
- Reads, `comments create`, `add-relation` and `remove-relation` run in any team.
- No setting turns the guard off.
- With no `LINEAR_TEAM`, an existing-issue write runs unchecked and prints `linear: cross-team-guard=inactive`.

## Issue Creation Routing

- Orchestration and review sessions file through the TPM pipeline (project-management skill), which owns labels, project, priority, estimate, and relations.
- An owner-authorized, well-specified single filing is judged in the filing session, with no analysis agent or audit JSON: project-management workflows/audit-issues.md § 4.1.

`issues create` refuses before any API call when it lacks these:

- A `LINEAR_AGENT_LABELS` label, when that key is set. `--no-agent-label` allows a bare create.
- Unless `LINEAR_REQUIRE_REACH` is set empty: `Reached by:`, a `Supersession:` record and, with `--review-born --priority 2`, `Symptom:`. Placeholders and null tokens count as absent.

Unless `LINEAR_REQUIRE_REACH` is set empty, an authored create, update or bulk-update body refuses any of these:

- A checkbox outside `## Done when`.
- An invalid `Post-merge:` trigger or Deadline.
- A missing nonempty quoted `> **Story:**` and `> **Why this matters:**` opening.

Filing-line and review-born rules: project-management references/filing.md § Name what reaches it.

Under a declared label taxonomy (project-management references/labels.md § Project Taxonomy Contract):

- `issues create`, `issues update --labels`, `issues bulk-update --labels`, `issues activate` and `issues block` refuse before any write a label it does not declare, naming the label and the taxonomy file.
- The taxonomy check does not refuse an undeclared label the issue already carries.
- `issues create` refuses declared labels absent from Linear.
- `labels create` and `labels update --name` refuse an undeclared name.
- They also refuse a name a workspace label already uses. On create, this applies only to a `--team` label.
- `labels audit` lists the undeclared labels on the team's open issues and the same-name team/workspace pairs.
- With no taxonomy declared, none of this applies.

Under a declared project map, `issues create`, `issues update --project` and `issues bulk-update --project` refuse a project off it, and `projects audit` lists what lies outside it: the project-management skill's references/project-map.md § Routing and § Audit.

## Attachments

`issues create`, `issues update`, and `comments create` take repeatable `--attach PATH`.

- Images embed as markdown appended to the description or body being written.
- An `issues update` without `--description` appends the image to the stored description.
- Other files become issue attachments or comment links.

Issue results report `attachments_requested` and ordered `{url, repo_path}` receipts in `attachments` after all bindings succeed.

- Creates and field updates need default JSON for receipts.
- A successful `--format=ids` create prints only the ID.

A failed `issues create` or `issues update` upload or binding exits nonzero with JSON naming what to resume. `issues --help` gives the resume route. A failed upload writes no issue fields. A `comments create` upload failure only exits nonzero with its stderr cause.

## Blocked Label vs Issue Relations

For a cross-team relation:

1. Select a minted app token through `LINEAR_APP_TOKEN` ([credential selection](references/authentication.md)).
2. Confirm `credential: "app-token"` with `auth-check`.
3. Check that the actor can access both teams.

A blocker that is itself a Linear issue is a relation (`--blocked-by`). An external one (vendor, license) is the `blocked` label plus a comment.

- Blocking relations may connect issues with the same direct parent, two top-level issues, or a blocked leaf to an issue outside its ancestors.
- An ancestor/descendant pair is refused at any depth. Use `--related` for traceability.
- The two issues need not share a project.

A blocking relation pointing at a Done or Canceled issue is **satisfied history, not stale metadata**.

- The relation stays for provenance. Never remove or "fix" it.
- Audits must never classify it as stale.
- The only legitimate audit output for a completed-blocker relation is a scheduling signal ("gates cleared, ready to schedule").
- `issues remove-relation` refuses such a relation before any write, with one `linear: refused=completed-blocker` line.
- Its `--peer-rule-violation` route, the project-management skill's tpm-audit structural repair, removes one only when the pair breaks the blocking-level rule above.

Normalized issue lists, gets and their `children` rows, bulk gets, relation reads, and session status keep each blocking relation in `blocked_by`. They list only nonterminal blockers in `blocked_by_open`.

## Option Behavior

What each option accepts: `issues --help`.

- Resolve state names from `statuses list` for the issue's team.
- Verifying is a started state after In Review.

A **name** selects one project on `issues create` / `update` / `bulk-update --project`, `projects list-dependencies`, `milestones --project`, and `initiatives add-project` / `remove-project`.

- Issue creation resolves the name within `LINEAR_TEAM` or `--team`.
- Updates and bulk updates resolve it within each issue's recorded team.
- A canceled project sharing the name loses to the live one. Pass a UUID to reach a canceled project.
- Name **filters** never resolve: `issues list --project` and `documents list --project` match on the name alone, so their results can mix a live project with its canceled twin.

`--labels` REPLACES the whole issue-label set:

1. Fetch the current labels.
2. Compute the final set.
3. Validate it against `labels list --max --format=safe`, which reports `is_group` so parent/group labels can be rejected.
4. Pass the complete set.

- `issues update --labels` and `issues activate --agent` resolve names live against the issue's own team and workspace labels.
- `--clear-labels` is the only way to empty the set.
- `agent:*` labels are mutually exclusive, one per issue. `issues activate` applies them with the "In Progress" transition (semantics: `issues --help`).

`issues activate` and `--assignee`:

- `issues activate` assigns an issue nobody is assigned to the user whose email is `KENDEX_USER_EMAIL`, in the same mutation. It never replaces an assignee.
- It says which happened in one stderr line, `assignee-set`, `assignee-kept` or `assignee-skipped` with its `cause=`, and in the result's `assignee` field (lines: `issues --help`).
- A skip still activates.
- A failed issue read, users lookup or update fails the activation with no line.
- `--assignee` on create and update takes the same address form. A value containing `@` matches a user's whole email, case-insensitively. A user id is sent as given.

On a nonzero `bulk-update` exit, read its JSON before retrying. `partial: true` means some issues already changed, and `results` identifies which.

`issues block` applies the `blocked` label, creates the blocking relation, and comments.

`issues complete`:

- It posts an optional summary before setting Done.
- Use `--done-when-met all`, or a comma-separated list of box numbers, to tick verified Done-when boxes in the same update that sets the state.
- With `--post-merge-at`, it validates the checklist against the merged PR's `mergedAt` and sets Verifying while a post-merge box remains open.
- Without `--post-merge-at`, an open post-merge box keeps the current started state.
- Every checked box needs a nonblank `Evidence:` line indented directly below it.
- `--done-when-met` takes `--evidence-file PATH`, with one `N: text` line per box, and writes evidence with the tick and state.
- Select already-ticked boxes to add evidence from their existing evidence comments.
- An item with no Done-when section, a container among them, completes as Done.
- A failed state update after a posted summary exits nonzero and reports on stderr in either format.

## validate-completion

The pre-merge check on state plus summary comment: `issues validate-completion`. The expected-state matrix is in `issues --help` § Validate-Completion: session root vs bundle children vs `--container` parents, and the fail-closed flag pairing.

A "labelIds not exclusive child labels" error means two labels from one exclusive group.
