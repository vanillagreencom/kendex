# Decision Entry Template

Template for creating `[DECISION_ID]-[DESCRIPTOR].md` files in the project decision documents directory.

## Minimal Entry

For focused, single-topic decisions with clear rationale.

```markdown
# [DECISION_ID]: [TITLE]

[← Decision Index](INDEX.md)

**Date**: [YYYY-MM-DD]
**Status**: Active
**Research**: [RESEARCH_REF or —]

**Context**: [1-2 sentences: what problem/need exists]

**Decision**: [1-2 sentences: what was chosen]

**Rationale**:
- [Key reason 1]
- [Key reason 2]

**Revisit When**: [Conditions that would trigger re-evaluation]

**Verification**: [How to verify the decision works — commands, benchmarks, tests]

**References**: [Related decision IDs, research IDs, external links]
```

## Standard Entry

For decisions with alternatives considered, code patterns, and structured rationale.

```markdown
# [DECISION_ID]: [TITLE]

[← Decision Index](INDEX.md)

**Date**: [YYYY-MM-DD]
**Status**: Active
**Research**: [RESEARCH_REF or —]

## Summary

[1-2 paragraph executive summary]

## Context

[Detailed explanation of the problem, what prompted this decision]

## Decision

[Explicit statement of what was chosen]

## Pattern

[Code examples, directory structures, usage patterns — if applicable]

## Rationale

[Comparison table, bullet-point reasoning, or structured analysis]

| Criterion | Chosen Approach | Alternative |
|-----------|-----------------|-------------|
| [criterion] | [advantage] | [disadvantage] |

## Decision Criteria

### Use [chosen approach] when:
- [condition 1]
- [condition 2]

### Use [alternative] when:
- [condition 1]

## Verification

[Commands, tests, benchmarks to verify correctness]

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|--------------|
| [alt 1] | [reason] |
| [alt 2] | [reason] |

## Revisit When

- [Condition 1]
- [Condition 2]
```

## Comprehensive Entry

For large architectural decisions spanning multiple concerns (design, API, schema, deployment).

```markdown
# [DECISION_ID]: [TITLE]

[← Decision Index](INDEX.md)

**Date**: [YYYY-MM-DD]
**Status**: Active
**Research**: [RESEARCH_REF or —]
**Applies to**: [Context string — optional]
**Refines**: [DECISION_ID], [DECISION_ID] — optional, for refinements of prior decisions
**API Contract**: [path — optional]

## Summary

[Comprehensive overview with cross-references to related decisions]

## Requirements

| Requirement | Scope | Notes | Owner |
|-------------|-------|-------|-------|
| [req 1] | [scope] | [notes] | [who] |

## Rationale

[Multi-part reasoning with subsections as needed]

### [Rationale Section 1]
[Detailed justification]

### [Rationale Section 2]
[Detailed justification]

## Design

[Stack diagram, data structures, wire formats, flow descriptions]

### [Design Component 1]
[Specification]

### [Design Component 2]
[Specification]

## Impact

| Decision | Change | Rationale |
|----------|--------|-----------|
| [DECISION_ID] | [what changes] | [why] |

## Resolved Decisions

[Settled questions that came up during research]

## Revisit When

- [Condition 1]
- [Condition 2]

## Appendices

[Detailed schema, code examples, flow diagrams — optional]
```

## Formatting Rules

1. **Title**: `# [DECISION_ID]: [TITLE]` — H1 using the project's decision ID scheme
2. **Back-link**: Always include `[← Decision Index](INDEX.md)` after title
3. **Metadata bold labels**: `**Date**:`, `**Status**:`, `**Research**:` — bold key, colon, space, value
4. **Status values**: `Active`, `Superseded by [DECISION_ID]`, `Revisited`, `Active ([COMPONENTS] -> [DECISION_ID])`
5. **Research refs**: `[RESEARCH-ID](../research/RESEARCH-ID/findings.md)` or `—` if no research
6. **H2 for sections** (`##`), H3 for subsections (`###`), H4 for sub-subsections (`####`)
7. **Tables**: Standard markdown pipe-and-dash format
8. **Code blocks**: Always specify language (e.g., `rust`, `sql`, `json`, `bash`)
9. **Cross-references**: Always use markdown links `[DECISION_ID](DECISION_ID-descriptor.md)`
10. **Code comments**: Use `// REVISIT([DECISION_ID]):` in source code to mark implementation points

## Size Guidelines

| Type | Lines | When |
|------|-------|------|
| Minimal | 15-30 | Single technology choice, clear winner |
| Standard | 80-200 | Multiple alternatives, patterns to document |
| Comprehensive | 200-600 | Architecture-level, multi-concern decisions |

Choose the smallest template that covers your decision's scope. Keep tight — reference research for details.
