# Parent Issue Template

A parent with children is a **container by default**: never orchestrated directly, never its own PR. Each child ships as its own PR and the container closes last.

A **single-PR bundle** — one session, one PR covering every child — is the explicit opt-in exception, marked with `(one PR)` in the parent title. Promoting an existing issue to single-PR parent means retitling it. Prefer a leaf issue with an internal checklist over a single-PR bundle.

## Template

```markdown
**Research**: [RESEARCH_REF]
**Decision [DXXX]**: [DECISION_PATH]
**Source**: [ORIGIN_CONTEXT]
**Reached by**: [REACH]

[SUMMARY — 1-2 sentences on the bundle's overall goal, synthesized from the children, not copied from one of them]

## Sub-Issues

- [ISSUE_ID]: [title] (agent:X) [blocks [ISSUE_ID]]
- [ISSUE_ID]: [title] (agent:Y)

## Acceptance Criteria

- [ ] [Criterion from child [ISSUE_ID]]

## Context

- [Key constraint from the decision or research]
```

## Rules

1. `## Sub-Issues`, never `## Requirements`. No implementation detail lives here.
2. All children share the parent's project. See [dependencies.md](../references/dependencies.md).
3. Sequence dependent children with sibling child-blocks-child relations; cross-bundle dependencies go on the parents.
4. Label the parent with the project's multi-agent label (for example `agent:multi`) when children span 2+ agent domains. A `(one PR)` title marker outranks the label.
5. A coordination-only parent carries no estimate. Clear it with `issues update [ISSUE_ID] --clear-estimate`; Linear stores "no estimate" and formatters render it as `0`.
6. Drop any header line with no value; `**Reached by**` is filled or the parent is not created ([issue-description-template.md](issue-description-template.md) § Field Mapping). Omit Acceptance Criteria when the children have none.
7. A coordination parent has no defect of its own, so its `[REACH]` is the run that produced it — the roadmap layer, the audit, or the merge-pr rebundle that detached its children — named as that run, not as a defect. Such a parent is structural and never `--review-born`.
8. After any hierarchy change, regenerate Summary, Sub-Issues, and Acceptance Criteria from the current children.
