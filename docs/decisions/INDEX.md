# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-09-19 | D001 | KEN-1584 | Commit the project lock as a portable record | A clone without the record reads every render as unmanaged | check claims matching copies itself, respelled path declarations need a remedy, or the relocate guard must survive a cleared cache | Active | [Full](D001-portable-lock.md) |

---

## Format Reference

Log: technology selections with alternatives, performance trade-offs, path choices whose conditions may change. Do not log: variable names, small refactors, bug fixes, choices with no realistic alternative, standard pattern applications.

Status values: `Active`, `Active ([COMPONENTS] → [DECISION_ID])`, `Superseded by [DECISION_ID]`, `Revisited`. Row format and cross-reference forms are in the decider skill's `schemas/decision-format.md`.
