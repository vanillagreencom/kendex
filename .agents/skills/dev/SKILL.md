---
name: dev
description: "Load when implementing an issue or applying review fixes as a dev agent."
summary: "Dev-agent workflows for implementing an issue and applying review fixes, invoked by orch or specialist agents."
license: MIT
user-invocable: true
dependencies:
  required: [orch, github, decider, code-quality]
  optional: [linear]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.0.0"
tags: [automation]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Dev Workflows

orch is the caller and runtime: it owns delegation format, round acceptance, and every shell-shape rule.

| Workflow | Purpose |
|----------|---------|
| `workflows/dev-implement.md` | Implementation: activate → plan → implement → validate → commit → QA labels → summary → artifact → return (§ 1-11) |
| `workflows/dev-fix.md` | Review fixes: evaluate → apply or skip → validate → commit → artifact → return |

Review and QA-review belong to the reviewer skill: [`../reviewer/workflows/review.md`](../reviewer/workflows/review.md), [`../reviewer/workflows/qa-review.md`](../reviewer/workflows/qa-review.md). Command shapes, literal format tags, and round mechanics are orch's: [`../orch/SKILL.md`](../orch/SKILL.md) § Harness-Safe Shell, § Format Tags Are Literal, § Round Closure.

## Engineering Rules

- Scope is the issue's Done-when. A behavioral surface that does not trace to it stays out of this change. Two exceptions. The mechanical enablers of landing it ride without tracing to it: locks, changelog, baselines, dismissal renewals, that list and nothing else, never code that runs at runtime. A committed render of a source file you changed is neither exception, since it traces to whatever its source traces to, and a defect the change introduces or arms is in scope by definition unless Step 0 of [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) excludes it.
- Every behavior change ships with a test that runs against the script or program enforcing it, at the smallest surface that fails. A workflow sentence ships no test. A test that pins prose, drives a second implementation, or stubs the function under test does not count as a test.
- A refusal, a validator, a lock, a retry, or a test exists only for an input a real producer emits, this project's code or anything it calls or serves; name that producer beside it, or do not write it.
- When a change deletes a call, apply [code-quality § Cleanup](../code-quality/SKILL.md#cleanup) to its callee. Its deletion maps to the call removal's Done-when item; no internal caller is not proof that a supported external API is unused.
- A field, setting, or view member added by the change has a real producer and consumer. A named and documented external producer or consumer is valid when the change adds its in-repository counterpart; otherwise, add both sides in the change.
- No migration or compat code for this project's own formats, its manifest, settings, lock and cache shapes, never another tool's on-disk state, which an adapter may have to keep recognising: write no reader for an artifact an older version of this project wrote, and decline a finding that asks you to carry one forward. A layout, schema or cache change is one changelog line and a fresh install.
- Before adding a function, parser, stub or loop, grep the repo for the verb it performs; before stating a rule, grep for the rule. A second copy of that verb, in any language, is a twin and never delegation, and so is a second statement of a rule another file owns, in prose, config or a table: call or cite the one that exists, or escalate in your return. An issue that orders a twin is escalated, not implemented.
- Stale docs are bugs: contradicting a committed doc means updating it in the same change.
- Once a pushed head has been reviewed, later rounds add commits and never amend; before any review has run on a head, the kendex-issues fix cycle may amend only to refresh a required check that cannot be rerun.

Code standards are [`../code-quality/SKILL.md`](../code-quality/SKILL.md): correctness, comments, over-engineering, cleanup.

## Round Contract

Execute workflow sections in order; a "**Skip if**" condition is the workflow's decision, never your own scope assessment. Never push and never open a PR. The orchestrator does that after review passes. A finding on a mechanism this diff introduces or arms is a fix whatever the round, unless Step 0 of the disposition flow excludes it; a `Declined:` there takes one of the reason forms [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Decision flow sets out, never a label or a test count.

**The completion artifact is the round.** `dev-return-write` writes it after the commit; never hand-author the JSON (schema: orch [`schemas/dev-return.md`](../orch/schemas/dev-return.md)).

- `--issue` is the delegation's `Artifact Key:` line, the normalized workflow-state key (`issue-N` for GitHub, `PROJ-123` for Linear), never the tracker-native `OWNER/REPO#N` or a bare number. `--round-id` is its `Round ID:` line.
- `--kind` always matches what was delegated. `--validate` matches your commit message and return; a pass that needed a re-run is still `pass`, with the caveat in `--validate-note`. Flag constraints and value shapes: `dev-return-write --help`.

**Acceptance is that artifact plus git state, never your message.** Write the artifact, then return exactly once over the harness's agent-to-agent channel: Claude Code `SendMessage`, Codex `send_input`, OpenCode a resume on the stored `task_id`, Pi background the final assistant message. A disk write is not a return. Send the `**Return exactly**` body once and go idle: in a Pi persistent pane follow it with `complete_subagent` (background agents must not call it); on Codex the `send_input` MESSAGE is the durable return and the runtime's `FINAL_ANSWER` echo of it is expected, not a separate return to author or expand.

## Validation

Deterministic gate findings are fixed here, never carried into review. Fix what is simple and related and re-run; when a failure is complex or unrelated, commit anyway and report it; after the same failure three times, stop looping. Every unresolved failure is reported three times over: in the commit message, in `--validate`, and in your return.

### Long-Running Validation

**Invariant, every harness:** the completion tail (commit → QA labels → summary → artifact → return) is never dropped, and an interrupted run is never success. Re-check its real outcome and resume the tail. How you wait is your harness's:

- **Claude Code.** Background the BARE command with output redirected to a log via `run_in_background`, never piped or chained; the log's `END OF OUTPUT — exit status: N` block is the authoritative verdict. Then end your turn. **Idling after backgrounding is normal, not a stall.** The orchestrator's watchdog closes the round. Never poll.
- **Codex.** Foreground and block.
- **Pi.** Run it in the foreground.

## Reflect

**Skip if** nothing recurred and nothing surprised you. Otherwise put the lesson where it will be read again: architecture docs when patterns, APIs, or documented behavior changed, or the managing project's kendex config (`kendex.toml` at the kendex project root, `kendex-local.toml` in a source-catalog checkout) under `[skill-instructions]`, `[agent-additional-instructions]`, or `[agent-launch-instructions]`. Bar: would this save 5+ minutes in a future session? One surgical addition per lesson, no verbose examples. A config edit takes effect only once it is rendered, which you cannot do from a worktree, so name it, and anything else you cannot update yourself, in your return as `[process]` discovered work.

## Configuration

Agent-type placeholders are project-configurable: `[AGENT_TYPE]` (dev agents receiving implementation delegations), `[REVIEW_AGENT]`, `[QA_AGENT]`. Commit format: `[PREFIX]([ISSUE_ID]): [DESCRIPTION]`. `DEV_VALIDATE_CMD` (`kendex.settings.toml` `[env]`) names the project's validation command for the Validate step; unset → the project's documented build/test/lint command.
