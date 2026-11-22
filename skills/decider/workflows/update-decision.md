# Update Decision

| Update | When | Status becomes |
|--------|------|----------------|
| Supersede | The new decision fully replaces this one | `Superseded by [NEW_DECISION_ID]` |
| Partially supersede | The new decision replaces specific components | `Active ([COMPONENTS] → [NEW_DECISION_ID])` |
| Revisit | A re-assessment keeps the choice | `Active`, unchanged |
| Rename | The filename no longer describes the existing decision | Unchanged |
| Retire | The choice is withdrawn and nothing replaces it | `Withdrawn` |
| Remove | The choice is routine and holds; its reason now lives in the code or principle doc it governs | `Removed` |

A change that touches a record for any reason rewrites its legacy `Retired` status to `Withdrawn` in that same change:

- in the INDEX row;
- in the decision file, where one exists.

A legacy retirement may have no document, with a backticked filename in its Link cell, or only a one-line document. For such a retirement, the rewrite:

- leaves that form as it is;
- recreates no document.

A row nothing touches stays valid as written.

A re-assessment that changes the choice is a new record, per `create-decision.md`, and this workflow supersedes the old one with it.

## 1. Decision file

Set `**Status**:` to the value above. Then, by update:

- **Revisit.** Rewrite the `**Decision**:`, `**Why**:`, `**Rejected**:` and `**Revisit when**:` lines to the re-assessed choice. The record states the current policy; git history holds the earlier wording.
- **Rename.** Move the existing file to `[ID]-kebab-descriptor.md`. Keep its ID and status. Leave no file at the old path.
- **Retire.** Keep the significant decision's short file. Add the withdrawal reason to `**Why**:`.
- **Remove.** Delete the file once § 3 has repointed every citation of it. Keep a one-line document, in the form [Decision Format § Decision document](../schemas/decision-format.md#decision-document) gives, only where a citation outside the repository needs the path.

## 2. INDEX row

Set the Status column of that decision's row to the same value. Then, by update:

- **Revisit.** Rewrite the Decision, Rationale and Revisit When cells with the file.
- **Retire.** Keep the document link. State the withdrawal reason in the Rationale cell.
- **Remove.** Write where the reason now lives in the Rationale cell: the code path or the principle doc.
- **Remove, deleting the document.** Rewrite the Link cell to the backticked filename, `[Full](D0NN-x.md)` becoming `` `D0NN-x.md` ``.

Never remove a row: it keeps the ID reserved.

## 3. Citations

Skip this section for a revisit.

For a rename:

1. Change the existing row's Link cell and every citation of the old filename to the new filename in the same change.
2. Keep the ID.
3. Run `decisions check`.

For a supersession, repoint `REVISIT([DECISION_ID])` comments at the new ID. For a partial supersession, repoint only those covering the superseded components.

For a retirement or a removal:

1. Find every citation of the ID and of the document's file name by a literal search for both, in code, docs and `AGENTS.md`. A sibling record's `[ID](ID-descriptor.md)` link is one.
2. Then, by the update:
   - Removal: point the citations at the reason's new home, the comment at the code or the principle doc's section.
   - Retirement: keep the historical citations pointing at the retained document.
3. Remove active-policy citations and `REVISIT` markers. Keep a comment at the site only where the code still needs the reason.

## 4. Return

```
Updated: [DECISION_ID] → [STATUS]
```
