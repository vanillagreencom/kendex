# Parent Issue Template

A parent with children is a **container**: never orchestrated directly, never its own PR, and it carries no deliverable of its own. Each child ships as its own PR, and the container closes when its last child is Done or Canceled. When to file one is SKILL.md § Disposition.

Work that ships in one PR is a leaf work item with an internal checklist, never a parent; a title marks nothing. The one exception is the review audit's in-PR bundle, whose children the reviewed issue's own PR works (orch skill-rules § Coordination).

## Template

```markdown
[SUMMARY: one or two plain sentences on the subject the children share and its impact]

Done when every child is Done or cancelled.

## Done when

- [ ] Every child Done or cancelled

## Sub-Issues

- [ISSUE_ID]: [title] (agent:X) [blocks [ISSUE_ID]]
- [ISSUE_ID]: [title] (agent:Y)

## Filing record

**Research**: [RESEARCH_REF]
**Decision [DXXX]**: [DECISION_PATH]
**Source**: [ORIGIN_CONTEXT]
**Reached by**: [REACH]

## Context

- [Key constraint from the decision or research]
```

## Rules

The one Done-when box is the parent's whole checklist. When the last child is Done or Canceled, orch's `container-close` ticks it with each child's state as its `Evidence:` line in the update that sets the parent Done. A parent whose every child was canceled is set Canceled with its box left open. A goal measure or other outcome the children together produce is its own child: a leaf blocked by the siblings it measures, carrying that box and its holder's read, completed by that holder with `issues complete [CHILD_ID] --done-when-met [N] --evidence-file [EVIDENCE_FILE]`.

1. `## Sub-Issues`, never `## Requirements`. No implementation detail lives here.
2. All children share the parent's project. See [dependencies.md](../references/dependencies.md).
3. Record dependencies under linear SKILL.md § Blocked Label vs Issue Relations.
4. Label the parent with the project's multi-agent label (for example `agent:multi`) when children span 2+ agent domains.
5. A coordination-only parent carries no estimate. Clear it with `issues update [ISSUE_ID] --clear-estimate`; Linear stores "no estimate" and formatters render it as `0`.
6. Drop any header line with no value; `**Reached by**` is filled or the parent is not created ([issue-description-template.md](issue-description-template.md) § Field Mapping).
7. A coordination parent has no defect of its own, so its `[REACH]` is the run that produced it — the roadmap layer, the audit, or the merge-pr rebundle that detached its children — named as that run, not as a defect. Such a parent is structural and never `--review-born`.
8. After any hierarchy change, regenerate Summary and Sub-Issues from the current children.
9. Filing headers follow [issue-description-template.md](issue-description-template.md) § Rules. Keep them under Filing record. Synthesize the opening from all children.
