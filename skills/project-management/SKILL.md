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
  version: "2.0.0"
---

# Project Management

User-facing wrappers and TPM-execution workflows for project-level planning, audit, roadmap, and research-driven decomposition. Invoke these commands through the project-management skill; flightdeck no longer surfaces them as flightdeck commands. Per-issue review (orchestration) also loads this skill when reviewers escalate audit findings.

## Commands

| Command | Arguments | Workflow |
|---------|-----------|----------|
| `cycle-plan` | — | `workflows/cycle-plan.md` |
| `audit-issues` | `project` \| `project "Name"` \| `issue [IDs]` \| `--issues [file]` \| `project-order` | `workflows/audit-issues.md` |
| `roadmap plan` | `[feature]` \| `[feature] @[research-path]` | `workflows/roadmap-plan.md` |
| `roadmap create` | `@[plan-file]` | `workflows/roadmap-create.md` |
| `research-spike` | — | `workflows/research-spike.md` |
| `research-complete` | `[ISSUE_ID]` | `workflows/research-complete.md` |
| `research-issue` | — | `workflows/research-issue.md` (internal — invoked by `research-spike`) |

## Workflows

### User-facing wrappers

| Workflow | Purpose |
|----------|---------|
| [cycle-plan](workflows/cycle-plan.md) | User dialog + Linear actions for cycle planning; delegates analysis to `tpm-cycle-plan` |
| [audit-issues](workflows/audit-issues.md) | User dialog + Linear actions for issue/project audits; delegates to `tpm-audit` / `tpm-audit-project-order` |
| [roadmap-plan](workflows/roadmap-plan.md) | Specialist consultation + research gating; delegates to `tpm-roadmap-plan` |
| [roadmap-create](workflows/roadmap-create.md) | Execute a roadmap plan: project + issue creation via audit |
| [research-spike](workflows/research-spike.md) | User-initiated research with consultation, asset prep, and researcher delegation |
| [research-complete](workflows/research-complete.md) | Route a researcher-completed research issue (Targeted / Pervasive / Strategic) |
| [research-issue](workflows/research-issue.md) | Create research issue + assets, then delegate to `agent:researcher` (called by `research-spike`) |

### TPM-execution (called by the wrappers)

TPM workflows return JSON recommendations only.

| Workflow | Purpose |
|----------|---------|
| [tpm-cycle-plan](workflows/tpm-cycle-plan.md) | Analyze backlog, compute architecture order |
| [tpm-roadmap-plan](workflows/tpm-roadmap-plan.md) | Cross-project analysis, architecture gaps |
| [tpm-audit](workflows/tpm-audit.md) | Audit issues/projects for relations, hierarchy |
| [tpm-audit-project-order](workflows/tpm-audit-project-order.md) | Analyze project dependencies and ordering |

## Templates

| Template | Purpose |
|----------|---------|
| [issue-description-template](templates/issue-description-template.md) | Standard markdown for issue descriptions |
| [parent-issue-template](templates/parent-issue-template.md) | Parent/bundle issues with sub-issue coordination |

## Schemas

| Schema | Purpose |
|--------|---------|
| [audit-issues-input](schemas/audit-issues-input.md) | Input for issue audit workflows |
| [roadmap-plan-input](schemas/roadmap-plan-input.md) | Input for roadmap planning |
| [cycle-plan-output](schemas/cycle-plan-output.md) | TPM cycle plan output |
| [roadmap-plan-output](schemas/roadmap-plan-output.md) | TPM roadmap analysis output |
| [audit-output](schemas/audit-output.md) | TPM audit output |
| [audit-project-order-output](schemas/audit-project-order-output.md) | TPM project-order audit output |

## References

| Topic | Location |
|-------|----------|
| Issue creation | [references/issues.md](references/issues.md) |
| Initiatives & Projects | [references/initiatives-projects.md](references/initiatives-projects.md) |
| Dependencies | [references/dependencies.md](references/dependencies.md) |
| Prioritization factors | [references/prioritization.md](references/prioritization.md) |
| Label management | [references/labels.md](references/labels.md) |
| Issue tracker CLI | Companion issue tracker skill (`.agents/skills/linear/scripts/linear.sh`) |

## Execution Rules

- Execute all workflow sections in order. The workflow decides what to skip via "**Skip if**" conditions — never skip based on your own scope assessment.
- `<delegation_format>` and `<output_format>` tags are literal templates: fill `[PLACEHOLDERS]`, omit empty lines, add nothing else, do not paraphrase.

## Hierarchy

```
Initiative → Project → Milestone → Issue → Sub-Issue
```

| Level | Duration | Example |
|-------|----------|---------|
| Initiative | Months | "Platform MVP" |
| Project | 2-6 weeks | "Phase 1: Foundation" |
| Milestone | Key checkpoint | "Data Pipeline Complete", "Alpha" |
| Issue | 1-5 days | "Implement message queue" |
| Sub-Issue | Breakdown | Child issue for parallel work |

## Prioritization

```
Score = (Critical Path x 3) + (Dependencies x 2) + (Risk x 2) + (Value x 1) - (Estimate x 0.5)
```

**Thresholds**: 8+ P1 | 5-7 P2 | 3-4 P3 | 0-2 P4

## Health Indicators

| Indicator | Green | Yellow | Red |
|-----------|-------|--------|-----|
| Blocked issues | 0 | 1-2 | 3+ |
| In Progress age | <3 days | 3-7 days | >7 days |
| Completion ratio (7d) | >0.8 | 0.5-0.8 | <0.5 |

## Dependencies

- Issue tracker CLI (e.g., `linear` skill)
- `jq`
