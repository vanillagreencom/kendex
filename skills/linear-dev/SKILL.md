---
name: linear-dev
description: "Linear dev-agent workflows for issue implementation and review-fix delegation, invoked by an orchestrator (linear-orch) or specialist agents."
license: MIT
user-invocable: true
dependencies:
  required: [linear-orch, github, decider, linear]
metadata:
  author: vanillagreen
  version: "1.2.0"
---

# Linear Dev Workflows

Linear dev-agent workflows for specialist agents receiving delegations from an orchestrator.

## Workflows

| Workflow | Agent Type | Purpose |
|----------|------------|---------|
| `workflows/dev-implement.md` | Dev agents | Full implementation lifecycle: activate → plan → implement → validate → commit → QA labels → summary → finalize (§ 1-11) |
| `workflows/dev-fix.md` | Dev agents | Process review fix items: evaluate → apply/skip → validate → commit → return |

Review and QA-review workflows live in the reviewer skill: [`../reviewer/workflows/review.md`](../reviewer/workflows/review.md) and [`../reviewer/workflows/qa-review.md`](../reviewer/workflows/qa-review.md).

## References

| Topic | Source |
|-------|--------|
| Review finding schema | Reviewer skill (`schemas/review-finding.md`) |
| Review / QA-review ethos, scope boundaries, and workflows | Reviewer skill (`SKILL.md`, `workflows/review.md`, `workflows/qa-review.md`) |
| Recommendation bias | linear-orch skill (`workflows/recommendation-bias.md`) |
| Label application | Project label application guide |
| Benchmark baselines | Project benchmarking skill if installed |
| Regression classification | Project benchmarking skill if available |

## Execution Rules

- Execute all workflow sections in order. The workflow decides what to skip via "**Skip if**" conditions — never skip based on your own scope assessment.
- `<delegation_format>` and `<output_format>` tags are literal templates: fill `[PLACEHOLDERS]`, omit empty lines, add nothing else, do not paraphrase.
- **Return requires an agent-to-agent message.** Every `**Return exactly**` step must be delivered through the harness return channel (Claude Code: `SendMessage`; Codex: `send_input`; OpenCode: resume via stored `task_id`; Pi bg: final assistant message captured by `subagent`). Disk writes do not reach the orchestrator. In Pi persistent panes, after printing the exact return body once, call `complete_subagent` with the final status/summary/files/validation; bg agents must not call `complete_subagent`.

## Configuration

This skill is workflow-based. All behavior is defined in the workflow files.

Agent types referenced in workflows (names are project-configurable):
- **Dev agents**: `[AGENT_TYPE]` — specialist agents receiving implementation delegations
- **Review agents**: `[REVIEW_AGENT]` — agents that review specific aspects (correctness, quality, security, testing, docs, errors, structure)
- **QA agents**: `[QA_AGENT]` — agents for safety, performance, and architecture review

Commit format: `[PREFIX]([ISSUE_ID]): [DESCRIPTION]` — configurable per project conventions.
