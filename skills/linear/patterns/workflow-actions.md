# Workflow Actions

Multi-step issue/project transitions built from the `linear` skill's commands. Command syntax is in `SKILL.md`.

Every state change that reflects a decision (cancel, absorb, rescope, reparent, reprioritize) gets a comment recording why in the same step.

## State Transitions

```bash
scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT]
scripts/linear.sh issues block [ISSUE_ID] --by [BLOCKER_ID] --reason "[REASON]"
scripts/linear.sh issues unblock [ISSUE_ID]
scripts/linear.sh issues complete [ISSUE_ID] --summary-file [SUMMARY_PATH]
```

`activate` also assigns the issue to the person `KENDEX_USER_EMAIL` names when nobody is assigned yet; SKILL.md § Option Behavior states the outcomes.

Cancel, duplicate, and absorb first disposition every open descendant, including open work below a closed child: read `issues children [ISSUE_ID] --recursive --pending`, comment the reason for each disposition, and detach a child to keep it with `issues update [CHILD_ID] --remove-parent`. Cancel a child only with independent authorization for that child, recording its reason and resolving its descendants first. After the descendants are detached or terminal, use `comments create` + `issues update --state "Canceled"` on the parent; name the surviving issue in the comment on both sides of an absorb. The state update refuses open descendants before writing, and bulk-update checks the whole batch before writing any item.

## Quota Holds

A command Linear rate-limits exits nonzero with one JSON stderr line carrying `code:"RATELIMITED"`. Its `quota` receipt contains `status` (`future`, `elapsed`, `missing`, `invalid`), `reset` (UTC deadline or `unavailable`), `reset_epoch` (whole seconds or null), and `limit` (`requests`, `complexity`, `endpoint`, `unknown`). The request code selects the reset for the limit the refusal names. With no named limit, it selects the latest usable future request, complexity or endpoint reset. It rounds fractional epochs up. `requests_reset` keeps the raw request-reset header's UTC time or `unavailable`; it can be earlier than the selected deadline.

Future holds persist privately per credential binding on this host. Same-binding GraphQL calls refuse before HTTP or credential renewal. App-pair bindings survive token renewal. Personal keys and pre-minted app tokens have separate bindings. This does not coordinate other hosts, users or token aliases. A local refusal has `source:"local"` and adds no HTTP journal row. Missing storage means no learned hold. Malformed or unreadable required storage returns `code:"LINEAR_HOLD_UNAVAILABLE"`. A failed save retains the refusal with `hold_storage:"unavailable"`.

A usable future deadline ends the current GraphQL attempt without retry HTTP. Missing, invalid or elapsed resets keep the existing bounded retry. Attachment downloads keep their separate retry loop and do not consult the GraphQL hold.

An `activate` or `complete` that answers with a quota refusal is held:

1. Keep the held command and its `--summary-file` or body file under `tmp/`. After `complete` reports structured `error: supersession-incomplete`, its stdout preserves the successful transition and stderr states `already_done: true` with `retry.resource`, `retry.action`, `retry.issue`, and `retry.options`. Retry that action with those options, which preserve checklist evidence and merge time but omit summary flags. Required effects remain unfinished even though the replacement is Done. Otherwise the held command is the original one, except after a `complete` whose stderr also carries a `State transition to Done failed after the summary comment was posted` line: the summary is already posted, so the held command is the `issues complete` rerun that line names, without summary flags and keeping any `--done-when-met`. Rerunning with summary flags would post the summary twice.
2. For `quota.status:"future"`, wait until `quota.reset` through the job runner, then run the held command once more. An `elapsed` deadline permits that ordinary retry without a wait. A reset does not prove a full allowance.
3. A second rate limit, or a `missing` or `invalid` reset, returns the held command and its file to the caller. None authorizes another try or an indefinite wait. A hold-storage failure also returns its diagnostic to the caller.

## Descriptions

Write multiline or markdown bodies to a file and pass `--description-file` / `--body-file`. Inline `--description`/`--body` is for short plain strings only; never use heredocs.

After adding, removing, or reordering children, rebuild the parent's description from its actual `children[]` (read it with `issues get [PARENT_ID] --with-bundle`), preserving sections that are still valid.

## Hierarchy and Relations

```bash
scripts/linear.sh issues update [CHILD_ID] --parent [PARENT_ID]
scripts/linear.sh issues update [CHILD_ID] --remove-parent
scripts/linear.sh issues add-relation [ISSUE_ID] --blocks|--blocked-by|--related [OTHER_ID]
scripts/linear.sh issues remove-relation [ISSUE_ID] --blocks|--blocked-by [OTHER_ID]
```

Blocking-relation shape: SKILL.md § Blocked Label vs Issue Relations; a rejection states the rule the pair failed. A removal whose reason opens `Violation:` adds `--peer-rule-violation`.

Never drop a valid dependency. Use `--related` when the dependency is informational rather than blocking.

## Labels

`--labels` replaces the entire issue-label set: every update passes the full intended final set, never just the changed label.

Before any create or label update from a workflow:

1. `scripts/linear.sh labels list --max --format=safe`.
2. Build the full final set from the project's taxonomy, rejecting unknown labels, parent/group labels (`is_group: true`), missing required categories, and exclusive-category conflicts.
3. Ask for explicit authorization before creating any missing label; never create labels automatically.

Project labels are a separate resource and must not be used for issue-label preflight.

## Bulk and Cycle Assignment

```bash
scripts/linear.sh issues bulk-update [ID_1] [ID_2] --cycle [CYCLE_ID] --state "Todo"
```

On a nonzero `bulk-update` exit, read its JSON before retrying — `partial: true` means some issues already changed, and `results` identifies which.

When a child's state or cycle changes, fetch the parent and promote it when a child advances into active work — never demote it.

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

`[PATH]` holds a body built from project-management's `templates/issue-description-template.md`, including the `Reached by:` line. `[VALIDATED_LABELS]` is the full set project-management's `references/labels.md` § Creates Carry the Full Set selects, validated by step 2 of § Labels, not a bare agent label. Add any blocking relations the new issue should impose after it exists.

## Task discovery

Read a managed task project's complete issue set without a state or recency filter. Select unresolved work from the returned states, descriptions and current decisions. Use the selected project's UUID to avoid mixing same-name projects.

```bash
scripts/linear.sh issues list --project-id [PROJECT_UUID] --max
scripts/linear.sh issues list --search [REQUEST_OR_OUTCOME_TERMS] --include-archived --max
scripts/linear.sh issues get [ISSUE_ID]
scripts/linear.sh comments bulk-list [ISSUE_ID_1] [ISSUE_ID_2]
```

At adoption or scope change, also run the project list with `--include-archived`. Include terminal rows in that migration review. Read matching items and complete comments before deciding reuse or restoration. Read closure history from native issue Activity when the reason for a terminal transition matters. Use the team's native Archives to restore an archived item before editing it; the installed CLI has no unarchive action. Follow the existing state-transition procedure above when reopening an editable item. Read changed items through `issues bulk-get` to confirm retention. A failed or truncated read establishes no complete discovery.

## Task-scope automation

Read [Linear's Auto-close documentation](https://linear.app/docs/delete-archive-issues#auto-close) before setting up a managed task scope. The native interface is **Team settings > Workflows & automations > Auto-close**. The setting affects the team, including work outside the selected project; a project selection does not narrow that authority.

1. Confirm the selected project's actual team and the operator's authority over this team-wide setting. Open that team's native settings and inspect Auto-close's current enabled state, inactivity period and destination status when present. Record the actual team and project ids with the observed values on the caller's setup item.
2. Disable Auto-close for that team through the native setting. If the caller lacks authority, retain the exact setting change as unresolved for its authorized owner. Neither an unfinished project nor periodic issue updates substitutes for disabling the setting.
3. Reopen that same team's settings after saving. Read back the actual disabled state and record it, its scope and evidence reference on the setup item. An unavailable setting or readback leaves setup unresolved. The CLI's `teams get` does not expose this setting and a successful credential check proves no automation configuration.
4. Inspect existing terminal and archived task outcomes through Task discovery before relying on open-task discovery. A setting change restores no previously closed item. Keep Auto-archive separate; use the native Archives restoration route for any archived item that still owes an outcome.
