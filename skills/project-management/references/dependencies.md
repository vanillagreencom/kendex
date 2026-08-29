# Dependencies Reference

## Blocking Relations

A `blocks`/`blocked-by` relation records a real dependency between two issues. Record it directly whatever projects the two issues sit in. Use `related` only for an informational link with no dependency.

**Never derive a project relation from issue relations.** Project `blocked-by` comes from project-order scope analysis (`tpm-audit` project-order mode), not bottom-up from one or two issue crossings.

| Scenario | Record as |
|----------|-----------|
| Issue A must finish before issue B | Issue relation `A blocks B` |
| A whole project must finish before another starts | Project relation `B blocked-by A` |
| Blocked by something outside the tracker (vendor, license, approval) | `blocked` label + a comment naming the blocker |

### Level

A parent with children is a **container**: cross-bundle dependencies go on the parents, and dependent children are sequenced by sibling child-blocks-child relations within one parent. A relation between an ancestor and its own descendant is never valid.

When an audit finds a relation at the wrong level, **lift it, never delete it**: add the parent-level relation, remove the child-level one, and add `related` between the original children.

The Linear CLI rejects malformed relations at mutation time (peers of one bundle only, no ancestor/descendant edges).

### Completed Blockers Are Satisfied History

A blocking relation pointing at a Done or Canceled issue is **auto-satisfied**: the relation stays as provenance.

- Never remove or "fix" a relation whose blocker is Done/Canceled, and never list one under a stale-metadata heading.
- The only legitimate finding for an active issue whose blockers have all completed is a scheduling signal: `ready_to_schedule[]` where the audit reports findings per project, or "gates cleared, ready to schedule" in the issue's `reason` where it reports per issue.

### Reading a Full Subtree

`cache issues children [ISSUE_ID] --recursive` returns three levels, flattened, every row carrying its own `depth`. A deeper tree is not truncated to one branch: every row at the maximum depth returned is a frontier, and a branching tree has as many frontier rows as it has branches.

Repeat the call rooted at **every** frontier row, deduplicate identifiers across calls, and stop when a round returns nothing new. Continuing from one frontier row drops every subtree under the rest.

## Parent-Child Placement

**A sub-issue must be in the same project as its parent.**

When an audit finds a cross-project parent-child: detach the child (`--remove-parent`), then either move it into the parent's project or leave it standalone with a `blocks`/`related` relation. Do not relocate an issue merely to record a dependency.
