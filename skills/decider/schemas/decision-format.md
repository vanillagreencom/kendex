# Decision Format

## INDEX.md

```markdown
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
```

- Column order is a machine contract: the `decisions` CLI selects rows starting `| YYYY-MM-DD |` and reads the eight cells positionally.
- The Link cell names the record's document. While the document exists, the cell is a link, `[Full](D0NN-x.md)`. Once the document is gone, the cell is the backticked filename, `` `D0NN-x.md` ``, so no dead link stays in a scope the commit-guards md-refs lane judges.
- `decisions check` compares the filename the cell resolves to, not the cell as written, so the record keeps its identity across branches through either form.
- Rows are append-only, never re-sorted or removed: `next-id` allocates past the highest ID in the index and on the base branch, so a deleted row would free its ID for an unrelated choice.
- Row format: `../templates/index-row.md`.
- Below the table: a Format Reference section that names the decider package's decision format and its bar by the package's name, with no path or heading. It copies nothing from either.

## Decision document

File name `[DECISION_ID]-kebab-case-descriptor.md` — `D001-session-caching.md`, `ADR-0001-runtime-choice.md`. A `DECISION_ID` is a prefix plus numeric suffix; a project keeps one scheme (`D001` by default; keep `ADR-0001` where established).

An active, superseded or withdrawn significant record has a short document. A removed routine record has no document, except a one-line document kept where a citation outside the repository needs the path: the title, the back-link, `**Status**:` and one `**Decision**:` line naming what it held or where its reason lives.

| Element | Format |
|---------|--------|
| Title | `# [DECISION_ID]: Title` |
| Index back-link | `[← Decision Index](INDEX.md)`, immediately after the title |
| Date | `**Date**: YYYY-MM-DD` |
| Status | `**Status**: [VALUE]`, one of § Status values |
| Research | `**Research**: [REF]`: the issue or evidence link, or `—` when none |
| Decision | `**Decision**:` what was chosen, stated explicitly |
| Why | `**Why**:` the constraints, accepted costs and material consequences the code cannot show |
| Rejected | `**Rejected**:` the main alternative and why it lost |
| Revisit when | `**Revisit when**:` the condition that re-opens the choice |

- A withdrawn decision's `**Why**:` also gives the reason for withdrawal.
- Optional metadata lines, each one line: `**Supersedes**:` or `**Refines**:` naming the earlier decision and the scope taken from it, and `**Applies to**:` for a scoped decision.
- Nothing else: no summary, context, design, verification, impact or appendix section. A measurement, a test name or a run order belongs to the issue, the test or the code.
- Each `**Key**: value` line, metadata included, is its own paragraph, with one blank line before the next: `../templates/decision-entry.md`.

## Status values

| Value | Meaning |
|-------|---------|
| `Active` | In effect, the default for a new decision |
| `Active ([COMPONENTS] → [DECISION_ID])` | Partially superseded: the named components only |
| `Superseded by [DECISION_ID]` | Fully replaced |
| `Withdrawn` | No longer in effect, with no replacement |
| `Retired` | The legacy spelling of `Withdrawn`, with the same meaning |
| `Removed` | The choice holds; its reason lives in the code or principle doc the Rationale cell names |

- A `Withdrawn` record keeps its short document, its withdrawal reason and its INDEX link.
- A legacy `Retired` record may have no document, with a backticked filename in its Link cell, or only a one-line document.
- A `Removed` row alone keeps the ID reserved. Its Link cell follows § INDEX.md.

## Cross-references

| From → to | Format |
|-----------|--------|
| Decision → decision | `[DECISION_ID](DECISION_ID-descriptor.md)` |
| Decision → issue or evidence | the tracker link, or the attachment on that issue |
| Decision → code | `` `path/to/file.rs` `` or a relative link |
| Code → decision | `// REVISIT([DECISION_ID]): [reason]` |
| Code → removed decision | the reason as a comment at the code, or a `<path>.md § Heading` citation of the principle doc |
| Issue → decision | `**Decision [DECISION_ID]**: [path/to/DECISION_ID-descriptor.md]` |

A `REVISIT` comment goes only where the code carries out the choice.

A citation of a decision ID outside its own INDEX row needs a tracked decision document or a link to the rule's current home.
