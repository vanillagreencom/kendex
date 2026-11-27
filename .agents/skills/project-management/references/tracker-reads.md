# Tracker reads

Read before you add or change a mode, a tracker read or a tracker route in a workflow of this package, and when a workflow step resolves or checks the team scope.

## GitHub runs

A workflow that supports GitHub:

- Resolves the tracker once per run, as [audit-issues § 1.2](../workflows/audit-issues.md#12-resolve-tracker) does.
- Routes every preflight, read and write through it.
- Never requires a Linear installation or authentication for a GitHub-tracked run.
- Degrades in a documented note, never silently, where GitHub lacks a Linear concept.

## Team scope

A Linear list read with no `--team` returns the whole workspace, with two exceptions: `cycles list` and `statuses` default to `LINEAR_TEAM`. No `issues list` format carries the team, `--format=raw` included. Only `issues get` and `issues bulk-get` with `--format=raw` carry `.team.name`. Check a list row against the scope by its identifier prefix, the team key, as [tpm-audit § 1.1.1](../workflows/tpm-audit.md#111-resolve-team-scope) does.

## Scope by Path

A Linear list read is workspace-wide unless it passes `--team`.

- Each path states whether it resolves the team scope (tpm-audit § 1.1.1) and what it filters.
- TPM comparison `issues list` reads pass `--team` on the server.
- Closed comparison rows come only from per-input `--state "Done,Canceled" --search` reads without `--max`. tpm-audit § 1.5 owns the comparison and truncation rules.
- Silence is not inheritance: a new mode adds its entry.

The paths:

- **tpm-audit `project`, `team`.** Resolves the scope.
  - § 1.3 projects are filtered to it.
  - § 1.4 input and § 1.5 active/closed issue lists pass `--team`.
  - § 1.4.1 comments cover inputs and candidates.
- **tpm-audit `issues`, Linear.** Resolves the scope.
  - § 1.5 active/closed issue lists pass `--team`.
  - § 1.4.1 comments cover inputs and candidates.
  - A § 1.4 input issue outside the scope halts.
- **tpm-audit `issues`, GitHub.** Not applicable: it reads nothing from Linear.
- **tpm-audit `single`, Linear.** Resolves the scope.
  - § 1.3 projects are filtered to it.
  - The § 14 title list passes `--team`.
- **tpm-audit `single`, GitHub.** Not applicable: it reads nothing from Linear.
- **tpm-audit `project-order`.** Resolves the scope.
  - § 11 initiatives and projects are filtered to it.
  - Per-project issue lists pass `--team`.
- **tpm-roadmap-plan.** Resolves the scope, in § 1.1.
  - § 1.4 projects are filtered to it.
  - § 1.5 active/closed issue lists pass `--team`.
  - With removed terms, § 1.1 resolves each `teams[]` entry with `teams get`, and § 1.5 also reads the active rows of each whose key is not `TEAM_PREFIX` and not already read, one `--team` read per team, for § 2.1 alone.
  - § 1.5 comments cover inputs and candidates.
- **tpm-cycle-plan.** **Does not** resolve the scope, and **does not** filter.
  - § 1 picks the active project from `session-status`'s workspace-wide started projects.
  - Every issue read is scoped to that pick.
  - The § 1 map read is scoped to `LINEAR_TEAM` ([project-map.md § Audit](project-map.md#audit)).
- **audit-issues §§ 7.2-7.5.** Not applicable: it executes an artifact tpm-audit produced under its scope.
  - Reads are rooted at an in-scope project or an issue this run mutated.
- **audit-issues § 1.2.1, § 3.** **Does not** resolve the scope, and **does not** filter.
  - `session-status` selects projects workspace-wide.
  - The § 3 map read is scoped to `LINEAR_TEAM` ([project-map.md § Audit](project-map.md#audit)).
- **cycle-plan, roadmap-plan.** **Do not** resolve the scope, and **do not** filter.
  - Project, initiative, and label reads span the workspace.
- **roadmap-create.** Resolves the scope in § 2, per tpm-audit § 1.1.1, only to split its actions by team. **Does not** filter.
  - Project, initiative, and label reads span the workspace.
  - The § 1 map read is scoped to the team it creates in.
- **research-spike.** **Does not** resolve the scope, and **does not** filter.
  - Project and label reads span the workspace.
  - The § 3 map read is scoped to `LINEAR_TEAM` ([project-map.md § Audit](project-map.md#audit)).
- **research-complete.** Not applicable.
  - Reads are rooted at the caller's issue identifier.
- **research-issue.** Not applicable.
  - Reads are rooted at the caller's identifiers.
  - The project it creates into is the caller's pick.
