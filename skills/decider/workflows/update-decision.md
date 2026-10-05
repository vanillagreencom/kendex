# Update Decision

Change an existing decision when a newer one displaces it, a re-assessment keeps or changes its choice, or it is withdrawn with no replacement.

| Update | When | Status becomes |
|--------|------|----------------|
| Supersede | The new decision fully replaces this one | `Superseded by [NEW_DECISION_ID]` |
| Partially supersede | The new decision replaces specific components | `Active ([COMPONENTS] → [NEW_DECISION_ID])` |
| Revisit | A re-assessment keeps the choice | `Active`, unchanged |
| Retire | The choice is withdrawn and nothing replaces it | `Retired` |

A re-assessment that changes the choice is a new record, per `create-decision.md`, and this workflow supersedes the old one with it.

## 1. Decision file

Set `**Status**:` to the value above. For a revisit, rewrite the `**Decision**:`, `**Why**:`, `**Rejected**:` and `**Revisit when**:` lines to the re-assessed choice; the record states the current policy, and git history holds the earlier wording. For a retirement, shrink the file to its title, back-link, `**Date**:`, `**Status**: Retired` and one `**Decision**:` line naming what it held; the file stays so the INDEX link resolves.

## 2. INDEX row

Set the Status column of that decision's row to the same value. For a revisit, rewrite the Decision, Rationale and Revisit When cells with the file. Never remove a row: the ID stays reserved and a citation still resolves to it.

## 3. Code markers

Skip for a revisit. For a supersession, repoint `REVISIT([DECISION_ID])` comments at the new ID; for a partial supersession, only those covering the superseded components. For a retirement, remove each marker and leave a comment at its site only where the code still needs the reason.

## 4. Return

```
Updated: [DECISION_ID] → [STATUS]
```
