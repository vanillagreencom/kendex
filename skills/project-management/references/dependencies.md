# Dependency Management Reference

## Core Rules

### Same-Project Issue Blocking

**Issue blocking relations (`blocks`/`blocked-by`) must be within the same project.**

| Scenario | Correct Approach |
|----------|------------------|
| Issue A blocks Issue B, same project | Issue relation: `--blocked-by` |
| Issue in Project 1 blocks Issue in Project 2 | **Project** relation: Project 2 blocked-by Project 1 |
| Cross-project dependency needed | Move issue to same project OR use project-level blocking |

**Why**: Projects are the unit of planning and delivery. Cross-project issue blocking creates invisible dependencies that break project-level tracking.

**When you find cross-project issue blocking**:
1. **Check project ordering** — if Issue_A (Project_A) blocks Issue_B (Project_B) and Project_A already blocks Project_B at project level, the issue-level block aligns. Leave as redundant specificity.
2. **Relocate** — if the block contradicts project ordering or no project-level dep exists, move one issue to the correct project.
3. Use `related` only for informational links where no blocking dependency exists.
4. **Never infer project-level dependencies from individual issue relations.** Project deps come from project-order scope analysis (TPM audit), not bottom-up — which can create misleading or circular project dependencies.

### Same-Project Parent-Child

**Sub-issues must be in the same project as their parent.**

| Scenario | Correct Approach |
|----------|------------------|
| Child belongs in parent's project | Normal: `--parent [ISSUE_ID]` |
| Child belongs in a different project | Detach (`--remove-parent`), move to correct project as standalone or re-parent in that project |

**Why**: Children in different projects break project-level tracking and make parents appear incomplete.

**When audit finds a cross-project parent-child**: Detach child, then either move it to parent's project or keep standalone with `related` link.

### Blocking Level Rule

**Blocking relations go on bundle parents, not children.** A child issue must not block (or be blocked by) any issue outside its own parent bundle.

| Scenario | Correct Approach |
|----------|------------------|
| Child A (parent P1) should block Child B (parent P2) | P1 blocks P2; A `related` B |
| Child A (parent P1) should block Standalone B | P1 blocks B; A `related` B |
| Standalone A should block Child B (parent P2) | A blocks P2; A `related` B |
| Child A blocks sibling Child B (same parent) | Valid — intra-bundle dependency |

### Remediation During Audit

Blocking relations are valuable — always preserve them by fixing the structural issue, not removing the relation.

| Violation | Fix |
|-----------|-----|
| Cross-project A blocks B | Move one issue to the other's project. Blocking relation stays valid. |
| Cross-bundle child A→B (same project) | Remove child relation, add parent-level blocking, `related` on children. |
| Cross-bundle child A→B (cross-project) | Move one bundle's parent to correct project, then lift to parent level. |
| Child→standalone A→B (same project) | Remove child relation, add parent blocks standalone, `related` on children. |

## Issue Dependencies vs Blocked Label

| Scenario | Use |
|----------|-----|
| Issue A blocked by Issue B (same project) | Issue relation: `--blocked-by` |
| Blocked by external factor (vendor, license, approval) | `blocked` label + comment |

## Issue Relations

See issue tracker CLI skill for commands (`issues add-relation`, `issues list-relations`).

### Relation Types

| Type | Meaning |
|------|---------|
| `blocks` | This issue blocks another from proceeding |
| `blocked-by` | Cannot proceed until another completes |
| `related` | Informational link, no blocking |
| `duplicate` | Issues are duplicates (for merging) |

### Completed Blockers Are Satisfied History

A blocking relation pointing at a **Done or Canceled** issue is auto-satisfied — the tracker itself treats the dependent issue as unblocked the moment the blocker completes. The relation is satisfied history, not stale metadata:

- **Keep the relation.** It stays for provenance and traceability of why work was sequenced. Never remove or "fix" a relation because its blocker is Done/Canceled.
- **Audits must never classify completed-blocker relations as stale metadata.** The only legitimate audit output for them is a scheduling signal: "gates cleared, ready to schedule."

**Why**: during a backlog staleness audit, an audit agent produced a "STALE blocked_by METADATA" section listing issues whose blockers were Done, framing the relations themselves as defects needing cleanup. That framing invites destructive removal of valid history; the correct read was that those issues were simply ready to schedule.

### Quick Reference

```bash
# This issue blocks another
.agents/skills/linear/scripts/linear.sh issues add-relation [ISSUE_ID] --blocks [OTHER_ISSUE_ID]

# This issue is blocked by another
.agents/skills/linear/scripts/linear.sh issues add-relation [ISSUE_ID] --blocked-by [BLOCKER_ID]

# View all relations
.agents/skills/linear/scripts/linear.sh cache issues list-relations [ISSUE_ID]
```

## Project Dependencies

Use when one project must complete before another can start.

```bash
# This project depends on another
.agents/skills/linear/scripts/linear.sh projects add-dependency [PROJECT_ID] --blocked-by [OTHER_PROJECT_ID]

# View dependencies
.agents/skills/linear/scripts/linear.sh cache projects list-dependencies [PROJECT_ID]
```

**Visualization**: In issue tracker timeline view:
- **Blue line**: Dependency satisfied (blocker finishes before blocked starts)
- **Red line**: Dependency violated (blocked starts before blocker ends)

## Integration with Workflows

### Cycle Planning

When pulling issues:
1. Query blocked issues: `.agents/skills/linear/scripts/linear.sh cache issues list --label "blocked" --max`
2. Check issue relations: `.agents/skills/linear/scripts/linear.sh cache issues list-relations [ISSUE_ID]`
3. Score higher on Dependencies factor for issues that block many others

### Roadmap Review

1. Check project dependencies: `.agents/skills/linear/scripts/linear.sh cache projects list-dependencies [PROJECT_ID]`
2. Look for violated dependencies (red lines in timeline)
3. Adjust project dates or priorities accordingly

## Workflow Checklist

### Adding a Blocker

1. Identify what's blocking
2. **If tracked issue**: `.agents/skills/linear/scripts/linear.sh issues add-relation [ISSUE_ID] --blocked-by [BLOCKER_ID]`
3. **If external**: Add `blocked` label + comment explaining blocker
4. Update issue state if needed

### Resolving a Blocker

1. Complete the blocking issue (the block auto-clears; the relation itself stays as satisfied history — do not remove it)
2. **If external**: Remove `blocked` label + add resolution comment
3. Move blocked issue back to active state
