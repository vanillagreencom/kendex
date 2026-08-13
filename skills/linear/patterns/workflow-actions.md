# Workflow Actions

Multi-step issue/project transitions built from the `linear` skill's commands. Use the command reference in `SKILL.md` for syntax; this file carries only the rules that the commands themselves do not enforce.

Every state change that reflects a decision (cancel, absorb, rescope, reparent, reprioritize) gets a comment recording the reason in the same step. The comment is the audit trail; the state change alone loses why.

## State Transitions

```bash
scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT]
scripts/linear.sh issues block [ISSUE_ID] --by [BLOCKER_ID] --reason "[REASON]"
scripts/linear.sh issues unblock [ISSUE_ID]
scripts/linear.sh issues complete [ISSUE_ID] --summary-file [SUMMARY_PATH]
```

`activate --agent` applies the exclusive `agent:*` label with the "In Progress" transition and fails without changing state when the label does not exist. `complete` posts the summary comment before transitioning to Done, so a failed post leaves the state unchanged.

Cancel, duplicate, and absorb are all `comments create` + `issues update --state "Canceled"`; name the surviving issue in the comment on both sides of an absorb.

## Descriptions

Write multiline or markdown bodies to a file and pass `--description-file` / `--body-file`. Inline `--description`/`--body` is for short plain strings, and heredocs are blocked under `never` approval.

After adding, removing, or reordering children, rebuild the parent's description from its actual `children[]` (read it with `cache issues get [PARENT_ID] --with-bundle`), preserving sections that are still valid.

## Hierarchy and Relations

```bash
scripts/linear.sh issues update [CHILD_ID] --parent [PARENT_ID]
scripts/linear.sh issues update [CHILD_ID] --remove-parent
scripts/linear.sh issues add-relation [ISSUE_ID] --blocks|--blocked-by|--related [OTHER_ID]
scripts/linear.sh issues remove-relation [ISSUE_ID] --blocks|--blocked-by [OTHER_ID]
```

A `make_parent` action carrying `retitle` applies the retitle alongside the reparenting; skipping it leaves the promoted parent reading as a container and splits a bundle the audit decided to keep whole.

`--blocks`/`--blocked-by` are guarded: a blocking relation must connect peers of one bundle — same direct parent, or both top-level. The two issues need not share a project. An issue never blocks its own ancestor or descendant, since the hierarchy already encodes that dependency. A rejected cross-subtree pair comes back with the one valid replacement pair, at the level where the subtrees separate, already validated against the same rule.

Never drop a valid dependency because the current structure cannot express it cleanly. Lift child-level dependencies to the parent level when bundles are involved, and use `--related` when the dependency is informational rather than blocking.

## Labels

`--labels` replaces the entire issue-label set, so every update passes the full intended final set — never just the changed label. An unresolvable name now fails the update rather than dropping that label, and `--clear-labels` is the only way to empty the set.

Before any create or label update from a workflow:

1. `scripts/linear.sh sync --reconcile` when the cache is missing or stale, then `scripts/linear.sh cache labels list --format=safe`.
2. Build the full final set from the project's taxonomy.
3. Reject unknown labels, parent/group labels (`is_group: true`), missing required categories, and exclusive-category conflicts. Agent labels are exclusive: replace the old `agent:*` rather than adding to it.
4. Ask for explicit authorization before creating any missing label; never create labels automatically.

Project labels are a separate resource and must not be used for issue-label preflight.

## Bulk and Cycle Assignment

```bash
scripts/linear.sh issues bulk-update [ID_1] [ID_2] --cycle [CYCLE_ID] --state "Todo"
```

`bulk-update` is non-atomic. On a nonzero exit read its JSON before retrying: `partial: true` means some issues already changed, and `results` identifies which.

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
  --title "[TITLE]" --project "[TARGET_PROJECT]" --labels "[VALIDATED_LABELS]" \
  --priority [PRIORITY] --estimate [ESTIMATE] --description-file [PATH]
```

`[VALIDATED_LABELS]` is the full preflighted label set including the project's required agent/domain/workflow categories, not a bare agent label. Add any blocking relations the new issue should impose after it exists.
