# Update Decision Workflow

Update the status or content of existing decision entries — supersession, partial supersession, or revisitation.

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| `decision_id` | Caller (decision ID to update) | Yes |
| `update_type` | Caller | Yes |
| `new_decision_id` | Caller (for supersession) | Conditional |
| `components` | Caller (for partial supersession) | Conditional |
| `revisit_outcome` | Caller (for revisitation) | Conditional |

---

## 1. Determine Update Type

| Type | When | Status Change |
|------|------|---------------|
| `supersede` | New decision fully replaces this one | `Superseded by [NEW_DECISION_ID]` |
| `partial_supersede` | New decision replaces specific components | `Active ([COMPONENTS] -> [NEW_DECISION_ID])` |
| `revisit` | Conditions changed, decision re-assessed | `Revisited` (append outcome) |

---

## 2. Update Decision File

1. **Read** `[project decision documents]/[DECISION_ID]-[DESCRIPTOR].md`

2. **Update status line**:

   **Full supersession:**
   ```markdown
   **Status**: Superseded by [NEW_DECISION_ID]
   ```

   **Partial supersession:**
   ```markdown
   **Status**: Active ([COMPONENTS] -> [NEW_DECISION_ID])
   ```

   **Revisitation:**
   ```markdown
   **Status**: Revisited
   ```
   Append revisit outcome to end of file:
   ```markdown
   ## Revisit Outcome ([DATE])
   [REVISIT_OUTCOME]
   ```

---

## 3. Update INDEX.md

1. **Read** `[project decision documents]/INDEX.md`

2. **Find row** for `[DECISION_ID]`

3. **Update Status column** with same value as § 2

---

## 4. Update Code References

**Skip if** `update_type` is `revisit` and decision remains valid.

For `supersede` or `partial_supersede`:

1. **Search** codebase for `REVISIT([DECISION_ID])` comments
2. **Update** to reference new decision ID:
   ```
   // REVISIT([NEW_DECISION_ID]): [updated reason]
   ```
3. **For partial supersession**: Only update comments related to the superseded components

---

## 5. Return

```
Updated: [DECISION_ID] -> [STATUS]
```
