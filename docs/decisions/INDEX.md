# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-09-19 | D001 | KEN-1584 | Commit the project lock as a portable record | A clone without the record reads every render as unmanaged | check claims matching copies itself, respelled path declarations need a remedy, or the relocate guard must survive a cleared cache | Active | [Full](D001-portable-lock.md) |
| 2026-09-24 | D002 | — | Hosted create may accept early; the launcher backgrounds wait | The overseer is free while the host prepares | A provider cannot claim ownership before preparing, or the launcher must return before create answers | Active | [Full](D002-hosted-launch-handoff.md) |
| 2026-09-25 | D003 | — | One merge path through the app-armed queue; consumers pull renders; organization rulesets | A mixed path rebuilds queue groups; the train loads the control VM | Organization rulesets or Actions unavailable to a served repository; a render-group queue run outlasts direct merge | Active | [Full](D003-one-merge-path.md) |
| 2026-09-25 | D004 | — | Bound the trash by age and size; state that mirrors are kept | Removal never deleted, so a host filled; a mirror bound costs a full clone | A mirror dominates a cache measurement, or the pass shows in apply latency | Active (measurement → D005) | [Full](D004-trash-retention.md) |
| 2026-09-25 | D005 | — | Measure a trash entry once; one size record inside the trash | Entries never change after landing; the walk showed in apply latency | The listing dominates the pass, or an entry gains a writer | Active | [Full](D005-trash-size-record.md) |
| 2026-09-26 | D006 | — | kendex's own private keys show on every package page with settings | kendex has no page; one key, one line, one answer | A second kendex key, reported noise, or a project-wide settings page | Active | [Full](D006-kendex-own-private-keys.md) |

---

## Format Reference

Log: technology selections with alternatives, performance trade-offs, path choices whose conditions may change. Do not log: variable names, small refactors, bug fixes, choices with no realistic alternative, standard pattern applications.

Status values: `Active`, `Active ([COMPONENTS] → [DECISION_ID])`, `Superseded by [DECISION_ID]`, `Revisited`. Row format and cross-reference forms are in the decider skill's `schemas/decision-format.md`.
