---
name: project-management
description: "Load to plan a cycle, audit issues, build a roadmap, or decompose research into issues."
summary: "TPM planning, audit, roadmap, and research-driven decomposition: the cycle-plan, audit-issues, roadmap and research wrappers and the TPM workflows under them."
license: MIT
user-invocable: true
dependencies:
  required: [orch, linear, github]
  optional: [decider, second-opinion]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "3.0.0"
tags: [planning]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:project-instructions:end -->

# Project Management

Wrappers run in the primary session: they own the user dialog and every tracker mutation. TPM workflows analyze and return JSON inline; they never mutate the tracker and never write the artifact.

## Disposition

- **Creation bar.** File an issue only when all three hold: it changes what a user or operator experiences, or blocks work that does; no open issue, active branch, or one-line fix already covers it; and someone could pick it up and finish it without a new investigation. A reproducible anomaly with evidence in hand passes all three as an investigation issue. Everything else is declined with one line in the report — no issue, no placeholder, no tracking artifact. A severe-sounding edge case that no real input reaches fails the first test, and so does a hypothetical of low severity, a coverage ask for a path that has not regressed, and a refactor that neither changes behavior nor unblocks user-visible work. The classes in [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Decision flow Step 0 fail this bar too, whatever source the candidate arrived from — a review, or a backlog sweep that never ran Step 0. Among what does reach it, two exceptions file at any likelihood: a security or data-loss defect a shipped path reaches, and an edge case whose failure is critical harm or financial loss.
- **Name what reaches it.** Every issue carries a `Reached by:` line giving the user action, run, check, or shipped producer that arrives at the defect; an owner-directed item names the ask. The thread a finding came from, a shape ("a name containing a quote"), or something true in theory is not a reach, and an item with nothing to name is a decline, not an issue. That judgement is the author's: what `linear.sh issues create` refuses under `LINEAR_REQUIRE_REACH` is a body with no `Reached by:` line at all, an unsubstituted placeholder and a null token (`TBD`, `n/a`, `none`, `-`) counting as absent. A filing whose source is a review round carries, at priority 2, a `Symptom:` line naming the run, the user, or the red check that already showed the defect (`--review-born`). Priority 2 from any other source is structural, reports no symptom, and is not checked for one. Where a review-born finding files at all is [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Filing bar.
- **Burn down more than you create.** Every audit that reads an issue backlog sweeps its comparison set for issues the codebase has already satisfied, duplicated, or superseded, and proposes those for cancellation in the same pass, along with every active issue that fails the creation bar as it stands today. Report `created N / closed M`. `project-order` reorders projects, reads no backlog, and does not sweep.
- **Ask about work, never about mechanics.** The user decides what gets created, cancelled, and activated. Labels, priorities, relations, hierarchy, sort order, and project moves are corrections the workflow applies on its own authority.
- **Research is part of planning, not a work item.** Gather prior art, vendor docs, and approach comparisons inline during planning as an artifact on disk that issues cite. A tracker research issue exists only when the research is delegated as standalone work — run by the researcher agent, or prepared for later pickup (`research-spike`).
- **One approval per decision.** Ask the user to approve a body of work once — at the roadmap plan gate. Creation re-asks only what changed after that answer.

## Commands

| Command | Arguments | Workflow |
|---------|-----------|----------|
| `cycle-plan` | — | [cycle-plan](workflows/cycle-plan.md) |
| `audit-issues` | `project` \| `project "Name"` \| `team` \| `issue [IDs]` \| `--issues [file]` \| `--analyzed [file]` \| `project-order` | [audit-issues](workflows/audit-issues.md) |
| `roadmap plan` | `[feature]` \| `[feature] @[research-or-plan-path]` | [roadmap-plan](workflows/roadmap-plan.md) |
| `roadmap create` | `@[plan-file]` | [roadmap-create](workflows/roadmap-create.md) |
| `research-spike` | — | [research-spike](workflows/research-spike.md) |
| `research-complete` | `[ISSUE_ID]` | [research-complete](workflows/research-complete.md) |
| `research-issue` | — | [research-issue](workflows/research-issue.md) — internal, invoked by `research-spike` |

`audit-issues` is **primary-session only** ([audit-issues](workflows/audit-issues.md) preamble): the roadmap-plan § 5 answer that roadmap-create carries in is validated and admitted at § 6, never around it.

The `@[path]` given to `roadmap plan` may be research findings or a **finished plan** (a design the user has reviewed). A finished plan is the spec: derive issues from it instead of re-planning, and every issue cites it.

TPM analysis workflows, each returning JSON per its schema: [tpm-cycle-plan](workflows/tpm-cycle-plan.md), [tpm-audit](workflows/tpm-audit.md) (project / team / issue / project-order modes), [tpm-roadmap-plan](workflows/tpm-roadmap-plan.md).

## Execution Rules

- Run workflow sections in order. Skip only on an explicit **Skip if** condition, never on your own scope assessment.
- `<delegation_format>` and `<output_format>` are literal templates: fill `[PLACEHOLDERS]`, drop lines whose placeholders are empty, add nothing.
- Send a user-visible `<output_format>` report as a normal assistant message first, then invoke the question tool separately with only the question and short option labels. Never paste the report into question text or options.
- The Linear cache holds the whole workspace: `sync` sends no team filter, and `cache issues list` neither filters by team nor returns one. The two analysis workflows resolve the configured team and scope their own cached reads to it (tpm-audit § 1.1.1, tpm-roadmap-plan § 1.1) — an issue outside it is never an input, a comparison, a duplicate, an obsolescence candidate, or a cancellation, and a project outside it is never a placement. Every other workflow reads the cache workspace-wide.
- Every path's scope status is enumerated in § Scope by Path; a mode added later states its own row rather than inheriting silence.
- Sync the Linear cache before a workflow's first cache read: `sync --reconcile` in a run that mutates the tracker, `sync --if-stale 15` in a read-only lookup. That sync is the freshness mechanism; a cached read itself enforces presence, so a read that comes back missing halts the workflow and reports the sync failure — never a partial result, a live-only substitute, or a retry against the unsynced cache.
- Resolve tracker context once per run (audit-issues § 1.2) and route every preflight, fetch, and mutation through it. A GitHub-tracked run must not require Linear installation, sync, or authentication; where GitHub lacks a Linear concept, degrade in a documented note, never silently.
- Before any issue create or label update, run the label preflight in [references/labels.md](references/labels.md) against the live inventory and project taxonomy; any § Validation failure there halts before mutation.
- In multi-issue analysis, keep verification context per issue. One issue's PR, branch, or resolved path set never scopes another's checks.

## Scope by Path

The Linear cache is workspace-wide, so each path states whether it resolves the team scope (tpm-audit § 1.1.1) and what it filters. Silence is not inheritance: a new mode adds its row.

| Path | Resolves | Filters |
|------|----------|---------|
| tpm-audit `project`, `team` | yes | § 1.3 projects, § 1.4 input set, § 1.5 comparison set |
| tpm-audit `issues`, Linear | yes | § 1.5 comparison set; a § 1.4 input issue outside scope halts |
| tpm-audit `issues`, GitHub | n/a — reads no Linear cache | n/a |
| tpm-audit `project-order` | yes | § 11 initiatives, projects, and per-project issues |
| tpm-roadmap-plan | yes, § 1.1 | § 1.4 projects, § 1.5 comparison set |
| tpm-cycle-plan | **no** | **no** — `session-status` picks the active project workspace-wide, and every later read is scoped to that pick |
| audit-issues §§ 7.2-7.5 | n/a — executes an artifact tpm-audit produced under its scope | reads rooted at an in-scope project or an issue this run mutated |
| audit-issues § 1.2.1, § 3 | **no** | **no** — `session-status` selects projects workspace-wide |
| cycle-plan, roadmap-plan, roadmap-create, research-spike | **no** | **no** — project, initiative, and label reads span the workspace |
| research-complete | n/a | reads are rooted at the caller's issue identifier |
| research-issue | n/a | reads rooted at the caller's identifiers; the project it creates into is the caller's pick |

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

`orch` skill (the excluded classes the creation bar defers to live in its `references/finding-disposition.md`), `linear` skill (Linear-tracked work), `github` skill + `gh` (GitHub-tracked issue audits), `git` and `jq` (audit verification scope).
