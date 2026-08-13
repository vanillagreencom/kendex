# Update Decision

Change an existing decision's standing when a newer one displaces it or conditions force a re-assessment.

| Update | When | Status becomes |
|--------|------|----------------|
| Supersede | The new decision fully replaces this one | `Superseded by [NEW_DECISION_ID]` |
| Partially supersede | The new decision replaces specific components | `Active ([COMPONENTS] → [NEW_DECISION_ID])` |
| Revisit | Conditions changed and the decision was re-assessed | `Revisited` |

## 1. Decision file

Set `**Status**:` to the value above. For a revisit, append the outcome:

```markdown
## Revisit Outcome ([DATE])

[REVISIT_OUTCOME]
```

## 2. INDEX row

Set the Status column of that decision's row to the same value — the file and the index must not disagree.

## 3. Code markers

Skip for a revisit that leaves the decision valid. Otherwise repoint `REVISIT([DECISION_ID])` comments at the new ID; for a partial supersession, only those covering the superseded components.

## 4. Return

```
Updated: [DECISION_ID] → [STATUS]
```
