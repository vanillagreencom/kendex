---
name: project-management
description: "Load to plan a cycle, audit issues, build a roadmap, or decompose research into issues."
summary: "TPM planning, audit, roadmap, and research-driven decomposition: the cycle-plan, audit-issues, roadmap and research wrappers and the TPM workflows under them."
license: MIT
user-invocable: true
dependencies:
  required: [orch, linear, github, reviewer]
  optional: [decider, second-opinion]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
tags: [planning]
---

# Project Management

This skill plans tracker work: cycles, issue audits, roadmaps and research decomposition. An agent that loads it has one of two roles:

- **Primary session.** It runs a wrapper command from § Commands. A wrapper owns the user dialog and every tracker write.
- **Analysis agent.** The `tpm` agent running a TPM workflow, or the [proposal sweep](workflows/proposal-sweep.md) subagent the overseer launches. It analyzes and returns JSON inline: a TPM workflow to its wrapper, the sweep to the overseer. It never writes to the tracker.

## Goals

These goals decide a case that no workflow step covers:

1. The tracker holds only items that pass the creation bar, and containers that group the parts of one deliverable.
2. A lane can pick up, land and prove each item alone.
3. The user decides what work exists, once per decision. The workflow decides the mechanics.

## Disposition

The rules for an item are in [references/filing.md](references/filing.md): Judge the approach, Creation bar, Group by project or label, never by parent, Name what reaches it, Requirements, Estimate, Done when with the post-merge box form, One landing per subsystem, and Research. Read that file before you judge, write, split or file a tracked item, and at a launch read.

## Commands

| Command | Arguments | Workflow |
|---------|-----------|----------|
| `cycle-plan` | none | [cycle-plan](workflows/cycle-plan.md) |
| `audit-issues` | `project` \| `project "Name"` \| `team` \| `issue [IDs]` \| `--issues [file]` \| `--single [file]` \| `--analyzed [file]` \| `project-order` | [audit-issues](workflows/audit-issues.md) |
| `roadmap plan` | `[feature]` \| `[feature] @[research-or-plan-path]` | [roadmap-plan](workflows/roadmap-plan.md) |
| `roadmap create` | `@[plan-file]` | [roadmap-create](workflows/roadmap-create.md) |
| `research-spike` | none | [research-spike](workflows/research-spike.md) |
| `research-complete` | `[ISSUE_ID]` | [research-complete](workflows/research-complete.md) |
| `research-issue` | none | [research-issue](workflows/research-issue.md), internal, invoked by `research-spike` |
| `proposal-sweep` | fleet brief | [proposal-sweep](workflows/proposal-sweep.md), internal, invoked by `oversee` |

`audit-issues` runs in the primary session only ([audit-issues](workflows/audit-issues.md) preamble). The roadmap-plan § 5 answer that roadmap-create carries in is validated and admitted at audit-issues § 6, never around it.

The `@[path]` given to `roadmap plan` is research findings or a **finished plan**, a design the user has reviewed. A finished plan is the spec: derive issues from it instead of planning again, and every issue cites it.

The TPM analysis workflows each return JSON per their schema: [tpm-cycle-plan](workflows/tpm-cycle-plan.md), [tpm-audit](workflows/tpm-audit.md) in its `project`, `team`, `issue`, `single` and `project-order` modes, and [tpm-roadmap-plan](workflows/tpm-roadmap-plan.md).

## Execution Rules

- **Ask about work, never about mechanics.** Creation and cancellation follow [audit-issues § 6](workflows/audit-issues.md#6-approve-creations-and-cancellations), and the user decides activation. Labels, priorities, relations, hierarchy, sort order and project moves are corrections the workflow applies on its own authority.
- **One approval per decision.** Ask the user to approve a body of work once, at the roadmap plan gate. A create asks again only about what changed after that answer.
- Run the sections of a workflow in order. Skip a section only on its explicit **Skip if** condition, never on your own judgement of scope.
- `<delegation_format>` and `<output_format>` are literal templates. Fill each `[PLACEHOLDER]`, remove the lines whose placeholders are empty, and add nothing.
- Send a user-visible `<output_format>` report as a normal assistant message first. Then invoke the question tool separately, with only the question and short option labels. Never paste the report into the question or its options.
- A failed Linear read halts the workflow with its diagnostic, never a partial result. A `--max` read reads every page or fails, and a bounded list read prints a `linear-list: truncated` notice on stderr when it left rows unread. A team or issue audit reads its pass inventory by [tpm-audit § 1.1.2](workflows/tpm-audit.md#112-read-the-pass-inventory).
- Resolve the tracker context once per run (audit-issues § 1.2), and route every preflight, fetch and write through it. A GitHub-tracked run never requires a Linear installation or authentication. Where GitHub lacks a Linear concept, degrade in a documented note, never silently.
- Before any issue create or label update, run the label preflight in [references/labels.md](references/labels.md) against the live inventory and the project taxonomy. Any § Validation failure there halts before the write.
- A project declares its taxonomy where [references/labels.md § Project Taxonomy Contract](references/labels.md#project-taxonomy-contract) states. A project that declares none has no required categories to enforce.
- In a multi-issue analysis, keep the verification context per issue. One issue's PR, branch or resolved path set never scopes another issue's checks.
- A tracker comment carries one update. A run of time stamps is one line and a link. Completion and verification comment producers keep their own forms.

## Read when

- When a run writes, cites, hands over or cannot find a plan, research, roadmap or audit file: [references/planning-artifacts.md](references/planning-artifacts.md).
- Before you add or change a mode, a tracker read or a tracker route in a workflow of this package, and when a step resolves or checks the team scope: [references/tracker-reads.md](references/tracker-reads.md).
- When you decide what an initiative, a project or a label holds, which project kind applies, or which project an item goes in: [references/project-map.md](references/project-map.md).

## Hierarchy

`Initiative → Project → Milestone → Issue → Sub-Issue`. Parent and child share a project; under a project map, the parent's route sets it ([references/project-map.md § Routing](references/project-map.md#routing)). Blocking relations may cross projects freely ([references/dependencies.md](references/dependencies.md)).

## Contracts

| Kind | Files |
|------|-------|
| Schemas | [audit-issues-input](schemas/audit-issues-input.md), [audit-output](schemas/audit-output.md), [roadmap-plan-input](schemas/roadmap-plan-input.md), [roadmap-plan-output](schemas/roadmap-plan-output.md), [cycle-plan-output](schemas/cycle-plan-output.md) |
| Templates | [issue-description-template](templates/issue-description-template.md), [parent-issue-template](templates/parent-issue-template.md), [initiative-project-template](templates/initiative-project-template.md) |
| References | [filing](references/filing.md), [planning-artifacts](references/planning-artifacts.md), [tracker-reads](references/tracker-reads.md), [labels](references/labels.md), [dependencies](references/dependencies.md), [project-map](references/project-map.md) |
| Tracker CLI | Linear: `.agents/skills/linear/scripts/linear.sh`; GitHub: `gh` + `.agents/skills/github/scripts/github.sh` |
