# Decision Entry Template

Skeleton for `[DECISION_ID]-[DESCRIPTOR].md`. Constraints: `../schemas/decision-format.md`.

```markdown
# [DECISION_ID]: [TITLE]

[← Decision Index](INDEX.md)

**Date**: [YYYY-MM-DD]
**Status**: Active
**Research**: [RESEARCH_REF or —]

**Context**: [the problem or need]

**Decision**: [what was chosen]

**Rationale**:
- [reason]
- [reason]

**Revisit When**: [conditions that trigger re-evaluation]

**Verification**: [command, benchmark, or test that shows it holds]

**References**: [related decision IDs, research IDs, links]
```

## Sizes

Choose the smallest size that covers the decision's scope, and promote a bold-label field to an `##` section once it outgrows a line.

| Size | Lines | Scope | Adds to the skeleton |
|------|-------|-------|----------------------|
| Minimal | 15-30 | One choice, clear winner | Nothing |
| Standard | 80-200 | Alternatives weighed, pattern worth documenting | `## Summary`, `## Pattern`, a rationale comparison table, `## Decision Criteria` (when to use the chosen approach vs the alternative), `## Alternatives Considered` (alternative → why rejected) |
| Comprehensive | 200-600 | Architecture-level, several concerns | The above plus `## Requirements`, `## Design` subsections, `## Impact` (which other decisions change and why), `## Resolved Decisions`, `## Appendices`, and the optional `**Applies to**` / `**Refines**` / `**API Contract**` metadata lines |

Reference research for the full analysis — the decision document stays a summary. Code blocks name their language; cross-references are markdown links.
