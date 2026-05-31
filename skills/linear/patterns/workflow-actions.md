# Workflow Actions

Portable multi-step issue-tracker CLI patterns for workflows that need more than basic CRUD.

Use this reference when linear-orch or TPM workflows need to:
- change issue/project state
- move or regroup issues
- repair relations
- create gap or research follow-up issues
- update project dependencies, initiative membership, or ordering

For the underlying command syntax, use the main `linear` skill command docs first.

## State Transitions

```bash
scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT]
scripts/linear.sh issues block [ISSUE_ID] --by [BLOCKER_ID] --reason "[REASON]"
scripts/linear.sh issues unblock [ISSUE_ID]
scripts/linear.sh issues update [ISSUE_ID] --state "Done"
```

## Cancel / Merge / Combine

```bash
scripts/linear.sh comments create [ISSUE_ID] --body "[REASON]"
scripts/linear.sh issues update [ISSUE_ID] --state "Canceled"

scripts/linear.sh comments create [REMOVE_ID] --body "Duplicate of [KEEP_ID]. [REASON]"
scripts/linear.sh issues update [REMOVE_ID] --state "Canceled"

scripts/linear.sh comments create [TARGET_ID] --body "Absorbing [REMOVE_ID]: [REASON]"
scripts/linear.sh comments create [REMOVE_ID] --body "Absorbed into [TARGET_ID]: [REASON]"
scripts/linear.sh issues update [REMOVE_ID] --state "Canceled"
```

## Cancel Obsolete Issues

```bash
scripts/linear.sh comments create [ISSUE_ID] --body "Obsolete: [REASON]"
scripts/linear.sh issues update [ISSUE_ID] --state "Canceled"
```

## Scope Changes

```bash
scripts/linear.sh issues update [ISSUE_ID] --description "[UPDATED_DESCRIPTION]"
scripts/linear.sh comments create [ISSUE_ID] --body "Scope updated: [WHAT_CHANGED]"

scripts/linear.sh issues update [ISSUE_ID] --project "[TARGET_PROJECT]"
scripts/linear.sh comments create [ISSUE_ID] --body "Moved from [OLD_PROJECT] to [TARGET_PROJECT]: [REASON]"
```

## Hierarchy Changes

After every hierarchy change, sync the parent description. See [Sync Parent Description](#sync-parent-description).

```bash
scripts/linear.sh issues update [CHILD_ID] --parent [PARENT_ID]
scripts/linear.sh comments create [CHILD_ID] --body "Made sub-issue of [PARENT_ID]: [REASON]"

scripts/linear.sh issues update [CHILD_ID] --remove-parent
```

## Sync Parent Description

After adding/removing/reordering children:

1. Read the parent with bundle context.
2. Rebuild the parent's child list from actual `children[]`.
3. Preserve sections that are still valid.
4. Update summary/acceptance criteria only if your project expects parent descriptions to reflect child scope.

Portable minimum:

```bash
scripts/linear.sh cache issues get [PARENT_ID] --with-bundle
scripts/linear.sh issues update [PARENT_ID] --description "[REGENERATED_DESCRIPTION]"
```

## Fix Relation Violations

Do not drop a valid dependency just because the current structure cannot express it cleanly.

Preferred order:
1. relocate the issue to the correct project when the dependency is real
2. lift child-level dependencies to the parent level when bundles are involved
3. use `related` for cross-project informational links

## Relations

```bash
scripts/linear.sh issues add-relation [ISSUE_ID] --blocks [OTHER_ID]
scripts/linear.sh issues add-relation [ISSUE_ID] --blocked-by [OTHER_ID]
scripts/linear.sh issues add-relation [ISSUE_ID] --related [OTHER_ID]

scripts/linear.sh issues remove-relation [ISSUE_ID] --blocks [OTHER_ID]
scripts/linear.sh issues remove-relation [ISSUE_ID] --blocked-by [OTHER_ID]

scripts/linear.sh cache issues list-relations [ISSUE_ID]
```

## Priority Updates

```bash
scripts/linear.sh issues update [ISSUE_ID] --priority 1
scripts/linear.sh comments create [ISSUE_ID] --body "Priority updated: [REASON]"
```

## Label Preflight

Before any issue create or label update from a workflow:

1. Refresh/load issue-label inventory: `scripts/linear.sh sync --reconcile` when the cache is missing or stale, then `scripts/linear.sh cache labels list --format=safe`.
2. Load project taxonomy/application rules from the calling project.
3. Build the full final issue-label set.
4. Reject unknown labels, parent/group labels (`is_group: true` or names used as parents), missing required categories, and exclusive-category conflicts.
5. Ask for explicit user authorization before creating any missing issue label; never create labels automatically.

Project labels are separate resources and must not be used for issue-label preflight.

## Agent Label Updates

Agent labels are exclusive. Replace the old taxonomy `agent` category label with the new one, preserve all unrelated labels, and update with the full validated final set.

```bash
scripts/linear.sh cache issues get [ISSUE_ID]
# FINAL_LABELS = current labels - current agent-category labels + agent:[NAME]
# Preflight FINAL_LABELS against live issue-label inventory + project taxonomy.
scripts/linear.sh issues update [ISSUE_ID] --labels "[FINAL_LABELS]"
scripts/linear.sh comments create [ISSUE_ID] --body "Agent label updated: [REASON]"
```

## Label Co-occurrence Fixes

```bash
scripts/linear.sh cache issues get [ISSUE_ID]
# FINAL_LABELS = current labels + [MISSING_LABEL]
# Preflight FINAL_LABELS against live issue-label inventory + project taxonomy.
scripts/linear.sh issues update [ISSUE_ID] --labels "[FINAL_LABELS]"
scripts/linear.sh comments create [ISSUE_ID] --body "Added [MISSING_LABEL]: [REASON]"
```

Remember that `--labels` replaces the full label set. Never pass only the changed label unless the intended final label set is exactly that one label.

## Cycle Assignment

```bash
scripts/linear.sh issues update [ISSUE_ID] --cycle [CYCLE_ID] --state "Todo"
scripts/linear.sh issues bulk-update [ISSUE_ID_1] [ISSUE_ID_2] --cycle [CYCLE_ID] --state "Todo"
```

## Parent State Sync

When changing a child's state or cycle:

1. fetch the parent
2. do not demote parent state
3. promote the parent when a child advances into active work
4. optionally propagate cycle assignment to pending siblings if your project expects bundle-level movement

Portable minimum:

```bash
scripts/linear.sh cache issues get [PARENT_ID] --with-bundle
scripts/linear.sh issues update [PARENT_ID] --state "[CHILD_STATE]" --cycle [CYCLE_ID]
```

## Estimate & Label Updates

```bash
scripts/linear.sh issues update [ISSUE_ID] --estimate 3
# For labels: compute FINAL_LABELS from current labels + intended add/replace, preflight, then update.
scripts/linear.sh issues update [ISSUE_ID] --labels "[FINAL_LABELS]"
```

## Create Gap Issues

```bash
scripts/linear.sh issues create \
  --title "[TITLE]" \
  --project "[TARGET_PROJECT]" \
  --labels "[LABELS]" \
  --priority [PRIORITY] \
  --estimate [ESTIMATE] \
  --description "[DESCRIPTION]"
```

Then add any blocking relations that the new gap issue should impose.

`[LABELS]` must be the full validated issue-label set, not a partial agent label.

## Create Research Gap

```bash
scripts/linear.sh issues create \
  --title "Research: [TOPIC]" \
  --project "[TARGET_PROJECT]" \
  --labels "[VALIDATED_RESEARCH_LABELS]" \
  --priority 3 \
  --estimate 1 \
  --description "[RESEARCH_BRIEF]"
```

`[VALIDATED_RESEARCH_LABELS]` must include the project-required agent/domain/workflow categories and must pass issue-label preflight.

## Project State Changes

```bash
scripts/linear.sh projects create --name "[NAME]" --description "[DESCRIPTION]"
scripts/linear.sh projects update [PROJECT_ID] --state started
scripts/linear.sh projects update [PROJECT_ID] --state completed
```

## Project Relations

```bash
scripts/linear.sh projects add-dependency [PROJECT_ID] --blocked-by [OTHER_PROJECT_ID]
scripts/linear.sh cache projects list-dependencies [PROJECT_ID]
```

## Initiative Management

```bash
scripts/linear.sh initiatives create --name "[NAME]" --description "[DESCRIPTION]"
scripts/linear.sh initiatives add-project [INITIATIVE_ID] --project [PROJECT_ID]
scripts/linear.sh cache initiatives list --status Active
```

## Initiative & Project Status

```bash
scripts/linear.sh initiatives update [INITIATIVE_ID] --status Active
scripts/linear.sh projects update [PROJECT_ID] --state started
scripts/linear.sh projects update [PROJECT_ID] --state completed
```

## Project Reorder

```bash
scripts/linear.sh projects set-sort-order [PROJECT_ID] --after [OTHER_PROJECT_ID]
scripts/linear.sh projects set-sort-order [PROJECT_ID] --before [OTHER_PROJECT_ID]
scripts/linear.sh projects set-sort-order [PROJECT_ID] --position [SORT_ORDER]
```
