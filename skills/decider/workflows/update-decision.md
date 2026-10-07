# Update Decision

Change an existing decision when a newer one displaces it, a re-assessment keeps or changes its choice, it is withdrawn with no replacement, its reason moves to the code or principle doc it governs, or its filename no longer describes it.

| Update | When | Status becomes |
|--------|------|----------------|
| Supersede | The new decision fully replaces this one | `Superseded by [NEW_DECISION_ID]` |
| Partially supersede | The new decision replaces specific components | `Active ([COMPONENTS] → [NEW_DECISION_ID])` |
| Revisit | A re-assessment keeps the choice | `Active`, unchanged |
| Rename | The filename no longer describes the existing decision | Unchanged |
| Retire | The choice is withdrawn and nothing replaces it | `Withdrawn` |
| Remove | The choice is routine and holds; its reason now lives in the code or principle doc it governs | `Removed` |

A re-assessment that changes the choice is a new record, per `create-decision.md`, and this workflow supersedes the old one with it.

## 1. Decision file

Set `**Status**:` to the value above. For a revisit, rewrite the `**Decision**:`, `**Why**:`, `**Rejected**:` and `**Revisit when**:` lines to the re-assessed choice; the record states the current policy, and git history holds the earlier wording. For a rename, move the existing file to `[ID]-kebab-descriptor.md`; keep its ID and status, and leave no file at the old path. For a retirement, keep the significant decision's short file and add the withdrawal reason to `**Why**:`. For a removal, delete the file once § 3 has repointed every citation of it. Keep a one-line document for a removed record, the title, back-link, `**Status**:` and one `**Decision**:` line naming what it held or where its reason lives, only where a citation outside the repository needs the path.

## 2. INDEX row

Set the Status column of that decision's row to the same value. For a revisit, rewrite the Decision, Rationale and Revisit When cells with the file. For a removal, write where the reason now lives in the Rationale cell: the code path or the principle doc. For a retirement, keep the document link and state the withdrawal reason in the Rationale cell. For a removal that deletes the document, rewrite the Link cell to the backticked filename, `[Full](D0NN-x.md)` becoming `` `D0NN-x.md` ``, so no dead link remains; `decisions check` compares the filename the cell resolves to, so the record keeps its identity across branches. Never remove a row: it keeps the ID reserved and a citation resolving.

## 3. Citations

For a rename, change the existing row's Link cell and every citation of the old filename to the new filename in the same change. Keep the ID. Run `decisions check`: it accepts a rename of a record inherited from the base branch, with the old file gone and the new file present. An ID allocated independently on each branch remains a collision, even when both rows have the same text.

Skip for a revisit. For a supersession, repoint `REVISIT([DECISION_ID])` comments at the new ID; for a partial supersession, only those covering the superseded components. For a retirement or a removal, find every citation of the ID and of the document's file name by a literal search for both, in code, docs and `AGENTS.md`; a sibling record's `[ID](ID-descriptor.md)` link is one. A removal's citations point at the reason's new home: the comment at the code or the principle doc's section. A retirement's historical citations keep pointing at its retained document. Remove active-policy citations and `REVISIT` markers; keep a comment at the site only where the code still needs the reason.

## 4. Return

```
Updated: [DECISION_ID] → [STATUS]
```
