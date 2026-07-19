---
name: dev
description: "Dev-agent workflows for issue implementation and review-fix delegation, invoked by orch or specialist agents."
license: MIT
user-invocable: true
dependencies:
  required: [orch, github, decider]
  optional: [linear]
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.2.0"
---

# Dev Workflows

Dev-agent workflows for specialist agents receiving delegations from an orchestrator.

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
| Recommendation bias | orch skill (`workflows/recommendation-bias.md`) |
| Label application | Project label application guide |
| Benchmark baselines | Project benchmarking skill if installed |
| Regression classification | Project benchmarking skill if available |

## Execution Rules

- Execute all workflow sections in order. The workflow decides what to skip via "**Skip if**" conditions — never skip based on your own scope assessment.
- `<delegation_format>` and `<output_format>` tags are literal templates: fill `[PLACEHOLDERS]`, omit empty lines, add nothing else, do not paraphrase.
- Keep required workflow shell commands harness-safe: use simple explicit commands, avoid shell loops, command substitution, heredocs, array-building snippets, and redirected writes to `tmp/`. Use file-write/edit tools or `apply_patch` for generated Markdown/JSON files.
- If Codex rejects a command with `approval required by policy, but AskForApproval is set to Never`, the classifier flagged the command shape — a loop, multi-command block, `VAR=x` env prefix, `$(...)`, or redirection — not the inner commands. Do not retry that shape or wait for approval; rerun as one simple command per tool call (canonical guidance: orch skill Codex runtime notes and § Harness-Safe Shell).
- Required commands accepted from issue specs or delegated verification lists are normalized before running (vstack#714): an env-assignment prefix (`VAR=value cmd args`, e.g. `LC_ALL=C tools/test-ci-changes`) becomes an ambient-environment precondition check (`printenv VAR`, or `locale` for locale variables) followed by the bare `cmd args` unchanged. `env VAR=value cmd` is not an acceptable substitute; a failed precondition is a blocker to report, not a license to run under the wrong environment. Canonical rule: orch SKILL.md § Harness-Safe Shell.
- **Return requires an agent-to-agent message.** Every `**Return exactly**` step must be delivered through the harness return channel (Claude Code: `SendMessage`; Codex: `send_input`; OpenCode: resume via stored `task_id`; Pi bg: final assistant message captured by `subagent`). Disk writes do not reach the orchestrator. In Pi persistent panes, after printing the exact return body once, call `complete_subagent` with the final status/summary/files/validation; bg agents must not call `complete_subagent`. On Codex, the `send_input` `MESSAGE` is the durable return; the Codex runtime may additionally echo it as a `FINAL_ANSWER`. That echo is expected and is not a separate return — send the return exactly once via `send_input`, then go idle; do not author or expand a different final payload.

## Configuration

Agent types referenced in workflows (names are project-configurable):
- **Dev agents**: `[AGENT_TYPE]` — specialist agents receiving implementation delegations
- **Review agents**: `[REVIEW_AGENT]` — agents that review specific aspects (correctness, quality, security, testing, docs, errors, structure)
- **QA agents**: `[QA_AGENT]` — agents for safety, performance, and architecture review

Commit format: `[PREFIX]([ISSUE_ID]): [DESCRIPTION]` — configurable per project conventions.
