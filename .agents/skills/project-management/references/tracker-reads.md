# Tracker reads

Read before you add or change a mode, a tracker read or a tracker route in a workflow of this package, and when a workflow step resolves or checks the team scope.

## Team scope

A Linear list read with no `--team` returns the whole workspace, with two exceptions: `cycles list` and `statuses` default to `LINEAR_TEAM`. No `issues list` format carries the team, `--format=raw` included. Only `issues get` and `issues bulk-get` with `--format=raw` carry `.team.name`. Check a list row against the scope by its identifier prefix, the team key, as [tpm-audit § 1.1.1](../workflows/tpm-audit.md#111-resolve-team-scope) does.

## Scope by Path

Because a Linear list read is workspace-wide unless it passes `--team`, each path states whether it resolves the team scope (tpm-audit § 1.1.1) and what it filters. TPM comparison `issues list` reads pass `--team` on the server. Closed comparison rows come only from per-input `--state "Done,Canceled" --search` reads without `--max`; tpm-audit § 1.5 owns the comparison and truncation rules. Silence is not inheritance: a new mode adds its row.

| Path | Resolves | Filters |
|------|----------|---------|
| tpm-audit `project`, `team` | yes | § 1.3 projects; § 1.4 input and § 1.5 active/closed issue lists pass `--team`; § 1.4.1 comments cover inputs and candidates |
| tpm-audit `issues`, Linear | yes | § 1.5 active/closed issue lists pass `--team`; § 1.4.1 comments cover inputs and candidates; a § 1.4 input issue outside scope halts |
| tpm-audit `issues`, GitHub | n/a, reads nothing from Linear | n/a |
| tpm-audit `single`, Linear | yes | § 1.3 projects; § 14 title list passes `--team` |
| tpm-audit `single`, GitHub | n/a, reads nothing from Linear | n/a |
| tpm-audit `project-order` | yes | § 11 initiatives and projects; per-project issue lists pass `--team` |
| tpm-roadmap-plan | yes, § 1.1 | § 1.4 projects; § 1.5 active/closed issue lists pass `--team` and comments cover inputs and candidates |
| tpm-cycle-plan | **no** | **no**. § 1 picks the active project from `session-status`'s workspace-wide started projects, and every issue read is scoped to that pick. The § 1 map read is scoped to `LINEAR_TEAM` ([project-map.md § Audit](project-map.md#audit)) |
| audit-issues §§ 7.2-7.5 | n/a, executes an artifact tpm-audit produced under its scope | reads rooted at an in-scope project or an issue this run mutated |
| audit-issues § 1.2.1, § 3 | **no** | **no**. `session-status` selects projects workspace-wide. The § 3 map read is scoped to `LINEAR_TEAM` ([project-map.md § Audit](project-map.md#audit)) |
| cycle-plan, roadmap-plan, roadmap-create | **no** | **no**. Project, initiative, and label reads span the workspace. roadmap-create's map read is scoped to the team it creates in |
| research-spike | **no** | **no**. Project and label reads span the workspace. The § 3 map read is scoped to `LINEAR_TEAM` ([project-map.md § Audit](project-map.md#audit)) |
| research-complete | n/a | reads are rooted at the caller's issue identifier |
| research-issue | n/a | reads rooted at the caller's identifiers; the project it creates into is the caller's pick |
