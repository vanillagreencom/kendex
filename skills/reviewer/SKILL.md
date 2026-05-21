---
name: reviewer
description: "Review and QA workflows: code-review classification, finding JSON schema, and QA-label review lifecycle. Load this skill when reviewing a diff, classifying findings, returning a verdict, or handling a QA-label-triggered review."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  version: "1.0.0"
---

# Reviewer

Code-review and QA-review workflows plus the structured-finding schema. Load this skill when:

- You are doing a code review (any reviewer specialist: arch, security, error, test, doc, perf, safety, structure) and need to know how to classify findings or format the verdict.
- You are handling a QA-label-triggered review and need the QA review lifecycle.
- You are emitting or consuming a review-finding JSON payload and need the canonical schema.

## Workflows

| Workflow | Agent Type | Purpose |
|----------|------------|---------|
| `workflows/review.md` | Review agents | Code review: diff → classify findings → JSON report → verdict |
| `workflows/qa-review.md` | QA agents | QA label-triggered review: context → agent review → benchmark recording → JSON report → verdict |

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/review-finding.md` | Canonical JSON output shape for any review or QA verdict. Saved to `[worktree-path]/tmp/review-{agent}-YYYYMMDD-HHMMSS.json`. |

## References

| Topic | Source |
|-------|--------|
| Recommendation bias (verification, actionability, fix-vs-issue) | Orchestration skill (`workflows/recommendation-bias.md`) |
| Label application | Project label-application guide |
| Benchmark baselines | Project benchmarking skill if installed |
| Regression classification | Project benchmarking skill if available |

## Execution Rules

- Execute all workflow sections in order. The workflow decides what to skip via "**Skip if**" conditions — never skip based on your own scope assessment.
- `<delegation_format>` and `<output_format>` tags are literal templates: fill `[PLACEHOLDERS]`, omit empty lines, add nothing else, do not paraphrase.
- **Return requires an agent-to-agent message.** Every `**Return exactly**` step must be delivered via the harness's message tool. Disk writes and turn text are not a valid return path. In Pi persistent panes, after printing the exact return body once, call `complete_subagent` with the final status/summary/files/validation; a plain final assistant message without that durable record leaves the parent task in `needs_completion` and is not a valid return.

## Configuration

This skill is workflow-based. All behavior is defined in the workflow files. Reviewer specialist agents (`reviewer-arch`, `reviewer-security`, `reviewer-test`, `reviewer-error`, `reviewer-doc`, `reviewer-perf`, `reviewer-safety`, `reviewer-structure`) and QA agents map to this skill in `vstack.toml [agent-skills]`.
