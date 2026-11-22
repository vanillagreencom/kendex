# Workflow Actions

Multi-step procedures built from the `linear` skill's commands. Command syntax is in `SKILL.md`.

Every state change that reflects a decision (cancel, absorb, rescope, reparent, reprioritize) gets a comment recording why in the same step.

## State Transitions

```bash
scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT]
scripts/linear.sh issues block [ISSUE_ID] --by [BLOCKER_ID] --reason "[REASON]"
scripts/linear.sh issues unblock [ISSUE_ID]
scripts/linear.sh issues complete [ISSUE_ID] --summary-file [SUMMARY_PATH]
```

Cancel, duplicate, and absorb first disposition every open descendant, including open work below a closed child:

1. Read `issues get [ISSUE_ID]` and its `children` rows, which report up to three levels with `depth`.
2. Repeat from every deepest row until no new descendants appear.
   - Deduplicate identifiers.
3. Keep closed children in this walk.
4. Act on the open descendants.
5. Comment the reason for each disposition.
6. Detach a child to keep it with `issues update [CHILD_ID] --remove-parent`.
7. Cancel a child only with independent authorization for that child.
   - Record its reason.
   - Resolve its descendants first.
8. After the descendants are detached or terminal, use `comments create` + `issues update --state "Canceled"` on the parent.
9. Name the surviving issue in the comment on both sides of an absorb.

## Quota Holds

A command Linear rate-limits exits nonzero with one JSON stderr line carrying `code:"RATELIMITED"`. Its `quota` receipt contains these fields:

- `status`: `future`, `elapsed`, `missing` or `invalid`.
- `reset`: the UTC deadline, or `unavailable`.
- `reset_epoch`: whole seconds, or null.
- `limit`: `requests`, `complexity`, `endpoint` or `unknown`.

The request code selects the reset:

- It selects the reset for the limit the refusal names.
- With no named limit, it selects the latest usable future request, complexity or endpoint reset.
- It rounds fractional epochs up.
- `requests_reset` keeps the raw request-reset header's UTC time or `unavailable`. It can be earlier than the selected deadline.

Future holds persist privately per credential binding on this host:

- Same-binding GraphQL calls refuse before HTTP or credential renewal.
- App-pair bindings survive token renewal.
- Personal keys and pre-minted app tokens have separate bindings.
- This does not coordinate other hosts, users or token aliases.
- A local refusal has `source:"local"` and adds no HTTP journal row.
- Missing storage means no learned hold.
- Malformed or unreadable required storage returns `code:"LINEAR_HOLD_UNAVAILABLE"`.
- A failed save retains the refusal with `hold_storage:"unavailable"`.

A usable future deadline ends the current GraphQL attempt without retry HTTP. Missing, invalid or elapsed resets keep the existing bounded retry. Attachment downloads keep their separate retry loop and do not consult the GraphQL hold.

An `activate` or `complete` that answers with a quota refusal is held:

1. Keep the held command and its `--summary-file` or body file under `tmp/`. The held command is:
   - After `complete` reports structured `error: supersession-incomplete`: `retry.action` with `retry.options`. Its stdout preserves the successful transition, and its stderr states `already_done: true` with `retry.resource`, `retry.action`, `retry.issue`, and `retry.options`. Those options preserve checklist evidence and merge time but omit summary flags. Required effects remain unfinished even though the replacement is Done.
   - After a `complete` whose stderr also carries a `State transition to Done failed after the summary comment was posted` line: the `issues complete` rerun that line names, without summary flags and keeping any `--done-when-met`. The summary is already posted, so rerunning with summary flags would post it twice.
   - Otherwise: the original command.
2. For `quota.status:"future"`, wait until `quota.reset` through the job runner.
3. After that wait, or at once for an `elapsed` deadline, run the held command once more.
   - A reset does not prove a full allowance.
4. A second rate limit, or a `missing` or `invalid` reset, returns the held command and its file to the caller.
   - None authorizes another try or an indefinite wait.
   - A hold-storage failure also returns its diagnostic to the caller.

## Descriptions

- Write multiline or markdown bodies to a file and pass `--description-file` / `--body-file`.
- Inline `--description`/`--body` is for short plain strings only; never use heredocs.

After adding, removing, or reordering children, rebuild the parent's description from its actual `children[]` (read it with `issues get [PARENT_ID]`), preserving sections that are still valid.

## Hierarchy and Relations

```bash
scripts/linear.sh issues update [CHILD_ID] --parent [PARENT_ID]
scripts/linear.sh issues update [CHILD_ID] --remove-parent
scripts/linear.sh issues add-relation [ISSUE_ID] --blocks|--blocked-by|--related [OTHER_ID]
scripts/linear.sh issues remove-relation [ISSUE_ID] --blocks|--blocked-by [OTHER_ID]
```

- Blocking-relation shape: SKILL.md § Blocked Label vs Issue Relations.
- A removal whose reason opens `Violation:` adds `--peer-rule-violation`.
- Never drop a valid dependency.
- Use `--related` when the dependency is informational rather than blocking.

## Labels

Before any create or label update from a workflow:

1. Run `scripts/linear.sh labels list --max --format=safe`.
2. Build the full final set from the project's taxonomy.
   - Reject unknown labels, parent/group labels (`is_group: true`), missing required categories, and exclusive-category conflicts.
3. Ask for explicit authorization before creating any missing label.
   - Never create labels automatically.

Project labels are a separate resource and must not be used for issue-label preflight.

## Shared label maintenance

`LINEAR_TEAM` requires a target before writes that do not address an issue. It does not restrict an API key or check a label's owning team. `auth-check` verifies authentication and the local target, not the key's permission mask.

- Inspect key permissions in Linear settings; report fingerprints only.

Before changing a label definition:

1. Read its ID, team, parent and group status. An empty team means workspace scope.
2. Read issue use across affected teams.
3. Check references in their manifests, scripts, gates and generated instructions.

A team-restricted key cannot establish workspace-wide issue use.

- The workspace owner coordinates shared label changes with affected repository maintainers. A repository taxonomy names that owner.
- Keep generic labels shared and project-specific labels team-scoped.
- Obtain approval for the concrete affected set and the exact proposed change before any shared-label definition change, replacement or deletion.
- Issue-label assignment authority does not authorize changing a shared label definition.

To make the change:

1. Prepare dependent repository corrections before the label change.
2. After an authorized change, refresh each affected inventory.
3. Render instructions from their source.
4. Run each inventory's taxonomy and repository checks.
5. Record the label IDs, issue assignments and repository commits together.
6. If the API cannot change scope, prepare a replacement plan with history and recovery limits before requesting migration approval.

## Bulk and Cycle Assignment

```bash
scripts/linear.sh issues bulk-update [ID_1] [ID_2] --cycle [CYCLE_ID] --state "Todo"
```

When a child's state or cycle changes:

- Fetch the parent.
- Promote it when a child advances into active work.
- Never demote it.

## Projects and Initiatives

```bash
scripts/linear.sh projects update [PROJECT_ID] --state started|completed
scripts/linear.sh projects add-dependency [PROJECT_ID] --blocked-by [OTHER_PROJECT_ID]
scripts/linear.sh projects set-sort-order [PROJECT_ID] --after|--before [OTHER_ID]
scripts/linear.sh initiatives add-project [INITIATIVE_ID] --project [PROJECT_ID]
scripts/linear.sh initiatives update [INITIATIVE_ID] --status Active
```

## Creating Follow-up Issues

```bash
scripts/linear.sh issues create \
  --state "Backlog" \
  --title "[TITLE]" --project "[TARGET_PROJECT]" --labels "[VALIDATED_LABELS]" \
  --priority [PRIORITY] --estimate [ESTIMATE] --description-file [PATH]
```

- `[PATH]` holds a body built from project-management's `templates/issue-description-template.md`, including the `Reached by:` and `Supersession:` lines.
- `[VALIDATED_LABELS]` is the full set project-management's `references/labels.md` § Creates Carry the Full Set selects, validated by step 2 of § Labels, not a bare agent label.
- Add any blocking relations the new issue should impose after it exists.

## Resolve a cited artifact

- Read a cited repository path when it exists.
- When it is absent, list the issue's attachments.
- A failed list is a read failure to report, not a missing attachment.

```bash
linear.sh attachments list [ISSUE_ID]
linear.sh attachments fetch [URL] --output tmp/[FILENAME]
```

1. Read the issue description's `**Artifacts**` list first. Its `[repository path](url)` links name the current copy, on this issue or another. The link whose label is the cited path selects the entry with that `url`, whatever its `context`.
2. With no such link, match the original cited repository path against `repo_path`, scoped to that issue or the research/source issue its brief explicitly names.
3. For attachments with no `repo_path` and no such link, accept a filename match only when it is unique within that issue.
4. Use an attachment URL in the brief to select the matching `url` when references collide.
5. Fetch the match into `tmp/`.
6. Read that file.
7. Keep the repository path as the tracker reference.
8. Resolve companion files, such as a plan's JSON or research metadata, the same way.
9. Do not write a machine's `tmp/` path into an issue or delegation for another checkout.

- No match leaves the calling workflow's missing-file behavior unchanged.
- Multiple matches without a distinguishing reference require clarification.
- A failed fetch is a download failure. Report it instead of treating the research as absent.
- Consumers without attachments keep reading repository files as before.

## Task discovery

- Read a managed task project's complete issue set without a state or recency filter.
- Select unresolved work from the returned states, descriptions and current decisions.
- Use the selected project's UUID to avoid mixing same-name projects.

```bash
scripts/linear.sh issues list --project-id [PROJECT_UUID] --max
scripts/linear.sh issues list --search [REQUEST_OR_OUTCOME_TERMS] --include-archived --max
scripts/linear.sh issues get [ISSUE_ID]
scripts/linear.sh comments bulk-list [ISSUE_ID_1] [ISSUE_ID_2]
```

At adoption or scope change:

1. Also run the project list with `--include-archived`.
2. Include terminal rows in that migration review.
3. Read matching items and complete comments before deciding reuse or restoration.
4. Read closure history from native issue Activity when the reason for a terminal transition matters.
5. Use the team's native Archives to restore an archived item before editing it. The installed CLI has no unarchive action.
6. Follow the existing state-transition procedure above when reopening an editable item.
7. Read changed items through `issues bulk-get` to confirm retention.

A failed or truncated read establishes no complete discovery.

## Task-scope automation

Read [Linear's Auto-close documentation](https://linear.app/docs/delete-archive-issues#auto-close) before setting up a managed task scope. The native interface is **Team settings > Workflows & automations > Auto-close**. The setting affects the team, including work outside the selected project. A project selection does not narrow that authority.

1. Confirm the selected project's actual team and the operator's authority over this team-wide setting.
   - Open that team's native settings.
   - Inspect Auto-close's current enabled state, inactivity period and destination status when present.
   - Record the actual team and project ids with the observed values on the caller's setup item.
2. Disable Auto-close for that team through the native setting.
   - If the caller lacks authority, retain the exact setting change as unresolved for its authorized owner.
   - Neither an unfinished project nor periodic issue updates substitutes for disabling the setting.
3. Reopen that same team's settings after saving.
   - Read back the actual disabled state.
   - Record it, its scope and evidence reference on the setup item.
   - An unavailable setting or readback leaves setup unresolved.
   - The CLI's `teams get` does not expose this setting, and a successful credential check proves no automation configuration.
4. Inspect existing terminal and archived task outcomes through Task discovery before relying on open-task discovery.
   - A setting change restores no previously closed item.
   - Keep Auto-archive separate.
   - Use the native Archives restoration route for any archived item that still owes an outcome.
