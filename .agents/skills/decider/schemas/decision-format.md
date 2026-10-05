# Decision Format

Canonical constraints for decision documents and their index.

## INDEX.md

```markdown
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
```

Column order is a machine contract: the `decisions` CLI selects rows starting `| YYYY-MM-DD |` and reads the eight cells positionally. The Link cell must name the decision document, a retired one included. Rows are append-only, never re-sorted or removed: `next-id` allocates past the highest ID in the index and on the base branch, so a removed row frees its ID for an unrelated choice. Row format: `../templates/index-row.md`.

Below the table: a Format Reference section with one link to this schema and one to the bar, the decider `SKILL.md` § What warrants a decision record, and why. It copies nothing from either.

## Decision document

File name `[DECISION_ID]-kebab-case-descriptor.md` — `D001-session-caching.md`, `ADR-0001-runtime-choice.md`. A `DECISION_ID` is a prefix plus numeric suffix; a project keeps one scheme (`D001` by default; keep `ADR-0001` where established).

| Element | Format |
|---------|--------|
| Title | `# [DECISION_ID]: Title` |
| Index back-link | `[← Decision Index](INDEX.md)`, immediately after the title |
| Date | `**Date**: YYYY-MM-DD` |
| Status | `**Status**: [VALUE]` — see below |
| Research | `**Research**: [REF]`: the issue or evidence link, or `—` when none |
| Decision | `**Decision**:` what was chosen, stated explicitly |
| Why | `**Why**:` the reason the code cannot show |
| Rejected | `**Rejected**:` the main alternative and why it lost |
| Revisit when | `**Revisit when**:` the condition that re-opens the choice |

Optional metadata lines, each one line: `**Supersedes**:` or `**Refines**:` naming the earlier decision and the scope taken from it, and `**Applies to**:` for a scoped decision. Nothing else: no summary, context, design, verification, impact or appendix section. A measurement, a test name or a run order belongs to the issue, the test or the code.

## Status values

| Value | Meaning |
|-------|---------|
| `Active` | In effect — the default for a new decision |
| `Active ([COMPONENTS] → [DECISION_ID])` | Partially superseded: the named components only |
| `Superseded by [DECISION_ID]` | Fully replaced |
| `Retired` | Withdrawn with no replacement; the row and a one-line document keep the ID reserved |

A re-assessment that keeps the choice stays `Active` with its text rewritten; one that changes the choice is a new record that supersedes this one (`../workflows/update-decision.md`). `list` returns every decision whose status starts with `Active`, including partial supersessions.

## Cross-references

| From → to | Format |
|-----------|--------|
| Decision → decision | `[DECISION_ID](DECISION_ID-descriptor.md)` |
| Decision → issue or evidence | the tracker link, or the attachment on that issue |
| Decision → code | `` `path/to/file.rs` `` or a relative link |
| Code → decision | `// REVISIT([DECISION_ID]): [reason]`, only where that code carries out the choice |
| Issue → decision | `**Decision [DECISION_ID]**: [path/to/DECISION_ID-descriptor.md]` |
