# Decision Format

Canonical constraints for decision documents and their index.

## INDEX.md

```markdown
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
```

The column order is a machine contract: the `decisions` CLI selects rows starting `| YYYY-MM-DD |` and reads the eight cells positionally. The Link cell must name the decision document — body search and `get` resolve it through that cell. Rows are append-only, never re-sorted. Row format and field sizing: `../templates/index-row.md`.

Below the table the index carries a Format Reference section stating what to log, what not to log, and the status values in use.

## Decision document

File name `[DECISION_ID]-kebab-case-descriptor.md` — `D001-session-caching.md`, `ADR-0001-runtime-choice.md`. A `DECISION_ID` is a prefix plus a numeric suffix, and a project keeps one scheme throughout (`D001` by default; preserve `ADR-0001` where already established).

| Element | Format |
|---------|--------|
| Title | `# [DECISION_ID]: Title` |
| Index back-link | `[← Decision Index](INDEX.md)`, immediately after the title |
| Date | `**Date**: YYYY-MM-DD` |
| Status | `**Status**: [VALUE]` — see below |
| Research | `**Research**: [REF]`, or `—` when none |
| Decision | What was chosen, stated explicitly |
| Rationale | Why — bullets, table, or section |
| Revisit When | Conditions for re-evaluation |

Optional metadata lines: `**Applies to**:` (scoped decisions), `**Refines**:` (extends prior decisions), `**API Contract**:` (defines or changes one). Optional sections: `## Summary`, `## Context`, `## Pattern`, `## Verification`, `## Alternatives Considered`, `## Impact`, `## Appendices`.

## Status values

| Value | Meaning |
|-------|---------|
| `Active` | In effect — the default for a new decision |
| `Active ([COMPONENTS] → [DECISION_ID])` | Partially superseded: the named components only |
| `Superseded by [DECISION_ID]` | Fully replaced |
| `Revisited` | Re-evaluated, outcome recorded in the document |

`list` returns every decision whose status starts with `Active`, so partial supersessions stay listed.

## Cross-references

| From → to | Format |
|-----------|--------|
| Decision → decision | `[DECISION_ID](DECISION_ID-descriptor.md)` |
| Decision → research | `[RESEARCH-ID](../research/RESEARCH-ID/findings.md)` |
| Decision → code | `` `path/to/file.rs` `` or a relative link |
| Code → decision | `// REVISIT([DECISION_ID]): [reason]` |
| Issue → decision | `**Decision [DECISION_ID]**: [path/to/DECISION_ID-descriptor.md]` |
