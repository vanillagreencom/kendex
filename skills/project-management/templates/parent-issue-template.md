# Parent Issue Template

Format for parent/bundle issues that coordinate sub-issues across domains.

A parent with children is a **CONTAINER by default**: it is never orchestrated directly and never gets a PR — each child ships as its own PR, selection operates on the container's unblocked children, and the container closes LAST (completed by merge-pr when the final child merges). A **single-PR bundle** — one session and one PR covering all children — is the explicit opt-in exception: mark it with `(one PR)` in the parent title (or keep the work a leaf issue with an internal checklist instead of children). Wherever bundles are described, the container reading is the default and the single-PR reading must be stated as the exception.

## Template

```markdown
**Research**: [RESEARCH_REF]
**Decision [DXXX]**: [DECISION_PATH]
**Source**: [ORIGIN_CONTEXT]

[SUMMARY — 1-2 sentences describing the bundle's overall goal, synthesized from children]

## Sub-Issues

- [ISSUE_ID]: [title] (agent:X) [blocks [ISSUE_ID]]
- [ISSUE_ID]: [title] (agent:Y)

## Acceptance Criteria

- [ ] [Criterion from child [ISSUE_ID]]
- [ ] [Criterion from child [ISSUE_ID]]

## Context

- [Key constraints from decision or research, 1-3 bullets]
```

## Rules

1. **Use `## Sub-Issues`** (not `## Requirements`) — parent coordinates, children implement
2. **Same-project**: All children must be in the parent's project. See [dependencies.md](../../project-management/references/dependencies.md)
3. **Each child entry**: `- [ISSUE_ID]: [title] (agent:X) [blocks [ISSUE_ID]]` — include blocking relations
4. **Label**: `agent:multi` marks the parent as a container (apply whenever children span 2+ distinct `agent:X` domains; a parent with children and no `(one PR)` title marker reads as a container even unlabeled)
5. **Blocking relations**: sequence dependent children with sibling child-blocks-child relations (selection dispatches only unblocked children); cross-bundle dependencies go on the parents. Read [agent-sequencing.md](../../orch/workflows/agent-sequencing.md)
6. **No implementation detail** — requirements live in children, parent holds only coordination context
   - Coordination-only parents carry no estimate — clear it with `issues update [ISSUE_ID] --clear-estimate` (or `--estimate 0`). See [issues.md](../references/issues.md) § Sub-Issues.
7. **Omit empty lines** — drop Research, Decision, Source, Acceptance Criteria lines with no data
8. **Research/Decision at top** — matches convention in research-complete workflow and audit workflow
9. **Summary synthesized** — derive from children's descriptions, not repeated from a single child
10. **Acceptance Criteria** — union of children's criteria, deduplicated. Optional: omit if children lack criteria
11. **Kept in sync** — after hierarchy changes, the Sync Parent Description action regenerates Summary, Sub-Issues, and Acceptance Criteria from current children

## When to Apply

- Decomposing parent scope into sub-issues (start workflow)
- Decomposing blocked issue after research adds cross-domain scope (research-complete workflow)
- Creating bundled issues (audit workflow)
- After hierarchy changes (Sync Parent Description action)
