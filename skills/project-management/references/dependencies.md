# Dependencies Reference

## Blocking Relations

A `blocks`/`blocked-by` relation records a real dependency between two issues. Record it directly whatever projects the two issues sit in — a dependency is a property of the work, not of how the work is filed. Use `related` only for an informational link with no dependency.

**Never derive a project relation from issue relations.** Project `blocked-by` comes from project-order scope analysis (`tpm-audit` project-order mode), not bottom-up from one or two issue crossings.

| Scenario | Record as |
|----------|-----------|
| Issue A must finish before issue B | Issue relation `A blocks B` |
| A whole project must finish before another starts | Project relation `B blocked-by A` |
| Blocked by something outside the tracker (vendor, license, approval) | `blocked` label + a comment naming the blocker |

### Level

A parent with children is a **container**: cross-bundle dependencies go on the parents, and dependent children are sequenced by sibling child-blocks-child relations within one parent. A relation between an ancestor and its own descendant is never valid — a child blocking its parent is meaningless (the container closes last anyway) and a parent blocking its child deadlocks every child in the bundle.

When an audit finds a relation at the wrong level, **lift it, never delete it**: add the parent-level relation, remove the child-level one, and add `related` between the original children so the reasoning survives. A blocking relation is evidence about the work; fix the structure it hangs on.

The Linear CLI rejects malformed relations at mutation time (peers of one bundle only, no ancestor/descendant edges), so a workflow states the design rule and lets the CLI enforce the shape.

### Completed Blockers Are Satisfied History

A blocking relation pointing at a Done or Canceled issue is **auto-satisfied**: the tracker already treats the dependent issue as unblocked, and the relation stays as provenance for why the work was sequenced.

- Never remove or "fix" a relation because its blocker is Done/Canceled, and never list one under a stale-metadata heading. That framing invites destructive cleanup of valid history.
- The only legitimate finding for an active issue whose blockers have all completed is a scheduling signal: `ready_to_schedule[]` (project mode) or "gates cleared, ready to schedule" in the issue's `reason` (issue mode).

## Parent-Child Placement

**A sub-issue must be in the same project as its parent.** Children in another project break project-level progress tracking and leave the parent permanently incomplete.

When an audit finds a cross-project parent-child: detach the child (`--remove-parent`), then either move it into the parent's project or leave it standalone with a `blocks`/`related` relation. Do not relocate an issue merely to record a dependency — dependencies cross projects freely.
