---
name: project-management
description: "TPM-orchestrated planning, audit, roadmap, and research-driven decomposition. Owns the user-facing wrappers (cycle-plan, audit-issues, roadmap-*, research-*) and the underlying TPM execution workflows."
license: MIT
user-invocable: true
dependencies:
  required: [linear, github]
  optional: [decider]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "3.0.0"
tags: [planning]
---

# Project Management

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Wrappers run in the primary session: they own the user dialog and every tracker mutation. TPM workflows analyze and return JSON inline; they never mutate the tracker and never write the artifact.

## Disposition

The backlog is a queue of work someone will do, not a record of everything anyone noticed.

- **Creation bar.** File an issue only when all three hold: it changes what a user or operator experiences, or blocks work that does; no open issue, active branch, or one-line fix already covers it; and someone could pick it up and finish it without a new investigation. A reproducible anomaly with evidence in hand passes all three as an investigation issue — the diagnosis is its deliverable. Everything else is declined with one line in the report — no issue, no placeholder, no tracking artifact. A severe-sounding edge case that no real input reaches fails the first test.
- **Burn down more than you create.** Any audit that proposes creations also sweeps its comparison set for issues the codebase has already satisfied, duplicated, or superseded, and proposes those for cancellation in the same pass. Report `created N / closed M`; an audit reporting only creations has not finished its sweep.
- **Ask about work, never about mechanics.** The user decides what gets created, cancelled, and activated. Labels, priorities, relations, hierarchy, sort order, and project moves are corrections the workflow applies on its own authority.
- **Research is part of planning, not a work item.** Prior art, vendor docs, and approach comparisons are gathered inline during planning and land as an artifact on disk that issues cite. A tracker research issue exists only when the research is deferred as standalone work someone picks up later (`research-spike`); research done now, in-session, never becomes an issue.
- **One approval per decision.** The pipeline asks the user to approve a body of work once — at the roadmap plan gate. Creation re-asks only what changed after that answer; presenting the identical set twice is overhead, not safety.

## Commands

| Command | Arguments | Workflow |
|---------|-----------|----------|
| `cycle-plan` | — | [cycle-plan](workflows/cycle-plan.md) |
| `audit-issues` | `project` \| `project "Name"` \| `issue [IDs]` \| `--issues [file]` \| `--analyzed [file]` \| `project-order` | [audit-issues](workflows/audit-issues.md) |
| `roadmap plan` | `[feature]` \| `[feature] @[research-or-plan-path]` | [roadmap-plan](workflows/roadmap-plan.md) |
| `roadmap create` | `@[plan-file]` | [roadmap-create](workflows/roadmap-create.md) |
| `research-spike` | — | [research-spike](workflows/research-spike.md) |
| `research-complete` | `[ISSUE_ID]` | [research-complete](workflows/research-complete.md) |
| `research-issue` | — | [research-issue](workflows/research-issue.md) — internal, invoked by `research-spike` |

`audit-issues` is **primary-session only**: its § 6 approval gate needs the session's interactive question tool, and § 7 mutates only against approvals collected there. Delegate the `tpm-audit.md` analysis it spawns, never the wrapper.

The `@[path]` given to `roadmap plan` may be research findings or a **finished plan** — a design the user has reviewed, external review included. A finished plan is the spec: the pipeline derives issues from it instead of re-planning, every issue cites it, and it stays the live reference through delivery.

TPM analysis workflows, each returning JSON per its schema: [tpm-cycle-plan](workflows/tpm-cycle-plan.md), [tpm-audit](workflows/tpm-audit.md) (project / issue / project-order modes), [tpm-roadmap-plan](workflows/tpm-roadmap-plan.md).

## Execution Rules

- Run workflow sections in order. Skip only on an explicit **Skip if** condition, never on your own scope assessment.
- `<delegation_format>` and `<output_format>` are literal templates: fill `[PLACEHOLDERS]`, drop lines whose placeholders are empty, add nothing.
- Send a user-visible `<output_format>` report as a normal assistant message first, then invoke the question tool separately with only the question and short option labels. Pasting the report into question text or options buries the choice in the Pi popup.
- Resolve tracker context once per run (audit-issues § 1.2) and route every preflight, fetch, and mutation through it. A GitHub-tracked run must not require Linear installation, sync, or authentication; where GitHub lacks a Linear concept the workflow degrades in a documented note, never silently.
- Before any issue create or label update, run the label preflight in [references/labels.md](references/labels.md) against the live inventory and project taxonomy. Unknown labels, parent/group labels, missing required categories, and exclusivity violations halt before mutation.
- In multi-issue analysis, keep verification context per issue. One issue's PR, branch, or resolved path set never scopes another's checks.

## Hierarchy

`Initiative → Project → Milestone → Issue → Sub-Issue`. Parent and child must share a project; blocking relations may cross projects freely. See [references/dependencies.md](references/dependencies.md).

## Contracts

| Kind | Files |
|------|-------|
| Schemas | [audit-issues-input](schemas/audit-issues-input.md), [audit-output](schemas/audit-output.md), [roadmap-plan-input](schemas/roadmap-plan-input.md), [roadmap-plan-output](schemas/roadmap-plan-output.md), [cycle-plan-output](schemas/cycle-plan-output.md) |
| Templates | [issue-description-template](templates/issue-description-template.md), [parent-issue-template](templates/parent-issue-template.md) |
| References | [labels](references/labels.md), [dependencies](references/dependencies.md) |
| Tracker CLI | Linear: `.agents/skills/linear/scripts/linear.sh`; GitHub: `gh` + `.agents/skills/github/scripts/github.sh` |

## Dependencies

`linear` skill (Linear-tracked work), `github` skill + `gh` (GitHub-tracked issue audits), `git` and `jq` (audit verification scope).
