# Parent Issue Template

Format for parent/bundle issues that coordinate sub-issues across domains.

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
4. **Label**: `agent:multi` if children span 2+ distinct `agent:X` domains
5. **Blocking relations**: Read [agent-sequencing.md](../../orch/workflows/agent-sequencing.md)
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
