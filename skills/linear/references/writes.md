# Issue writes

Read when attaching a file, recording a relation, setting an option on an issue write, or checking completion before merge.

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

1. Select a minted app token through `LINEAR_APP_TOKEN` ([credential selection](authentication.md)).
2. Confirm `credential: "app-token"` with `auth-check`.
3. Check that the actor can access both teams.

For a blocker tracked in Linear, `issues block --by ITEM` requires the blocking relation and attempts to post a comment. The command can succeed if the comment fails. For an external blocker such as a vendor or license, use the `blocked` label and a comment.

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

Safe gets and their `children` rows, safe lists and the `owed` selection also carry `blocked_by_launch`, the blockers that hold a launch: it leaves out a Verifying blocker too.

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
- A "labelIds not exclusive child labels" error means two labels from one exclusive group.

`issues activate` and `--assignee`: `issues --help` § Activate Options, Workflow Actions and Create Options.

On a nonzero `bulk-update` exit, read its JSON before retrying. `partial: true` means some issues already changed, and `results` identifies which.

`issues complete`: `issues --help` § Complete Options.

## validate-completion

The pre-merge check on state plus summary comment: `issues validate-completion`. The expected-state matrix is in `issues --help` § Validate-Completion: session root vs bundle children vs `--container` parents, and the fail-closed flag pairing.
