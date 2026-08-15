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
  version: "2.0.0"
---

# Dev Workflows

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

The implementer's side of an orchestrated round: what a specialist agent does between receiving a delegation and returning. orch is both the caller and the runtime — it owns delegation format, round acceptance, and every shell-shape rule.

| Workflow | Purpose |
|----------|---------|
| `workflows/dev-implement.md` | Implementation: activate → plan → implement → validate → commit → QA labels → summary → artifact → return (§ 1-11) |
| `workflows/dev-fix.md` | Review fixes: evaluate → apply or skip → validate → commit → artifact → return |

Review and QA-review belong to the reviewer skill: [`../reviewer/workflows/review.md`](../reviewer/workflows/review.md), [`../reviewer/workflows/qa-review.md`](../reviewer/workflows/qa-review.md). Command shapes, literal format tags, and round mechanics are orch's: [`../orch/SKILL.md`](../orch/SKILL.md) § Harness-Safe Shell, § Format Tags Are Literal, § Round Closure.

## Round Contract

Execute workflow sections in order; a "**Skip if**" condition is the workflow's decision, never your own scope assessment. Never push and never open a PR — the orchestrator does that after review passes.

**The completion artifact is the round.** `dev-return-write` writes it after the commit, so every field is final; never hand-author the JSON (schema: orch [`schemas/dev-return.md`](../orch/schemas/dev-return.md)).

- `--issue` is the delegation's `Artifact Key:` line — the normalized workflow-state key (`issue-N` for GitHub, `PROJ-123` for Linear), never the tracker-native `OWNER/REPO#N` or a bare number — and `--round-id` its `Round ID:` line. The orchestrator resolves the receipt by exactly those two values; any substitute strands it.
- `--validate` is strictly `pass` or `FAILING: check1,check2`, matching your commit message and return. A pass that needed a re-run is still `pass`: put the caveat in `--validate-note` so it lands in the durable record instead of only in a message.
- `--kind` always matches what was delegated. An investigate-and-recommend round is `--kind analysis` — it rejects `--commit`, `--validate`, and `--item`, and carries the recommendation in `--summary` or `--summary-file`. Forcing `implement` or `fix` onto such a round asserts a validation that never ran; skipping the artifact reads as an unfinished round.

**Acceptance is that artifact plus git state, never your message.** The orchestrator polls neither disk nor tracker, so both are required: write the artifact, then return exactly once over the harness's agent-to-agent channel — Claude Code `SendMessage`, Codex `send_input`, OpenCode a resume on the stored `task_id`, Pi background the final assistant message. A disk write is not a return. Send the `**Return exactly**` body once and go idle: in a Pi persistent pane follow it with `complete_subagent` (background agents must not call it); on Codex the `send_input` MESSAGE is the durable return and the runtime's `FINAL_ANSWER` echo of it is expected, not a separate return to author or expand.

## Validation

Deterministic gate findings are fixed here, never carried into review. Fix what is simple and related and re-run; when a failure is complex or unrelated, commit anyway and report it; after the same failure three times, stop looping. Every unresolved failure is reported three times over — in the commit message, in `--validate`, and in your return.

### Long-Running Validation

A full suite can outlast a turn. **Invariant, every harness:** the completion tail (commit → QA labels → summary → artifact → return) is never dropped, and an interrupted run is never success — re-check its real outcome and resume the tail. How you wait is your harness's:

- **Claude Code** — the Bash tool caps at ~10 min and a turn has no wall-clock primitive, so background the BARE command with output redirected to a log via `run_in_background`, never piped or chained: unpiped, the completion wake's exit code IS the command's, and the log's `END OF OUTPUT — exit status: N` block is the authoritative verdict. Then end your turn. That wake is not reliably delivered to in-process teammate sub-agents, so **idling after backgrounding is normal, not a stall** — the orchestrator's watchdog closes the round. Never poll: a poll is an instant no-op turn that advances no wall clock.
- **Codex** — foreground and block. There is no ~10-min tool cap, and under `approval_policy = never` the classifier rejects poll-loop shapes anyway.
- **Pi** — pane agents block naturally in their tmux shell; run it in the foreground.

## Reflect

**Skip if** nothing recurred and nothing surprised you. Otherwise put the lesson where it will be read again — architecture docs when patterns, APIs, or documented behavior changed, or the managing project's vstack config (`vstack.toml` at the vstack project root, `vstack-local.toml` in a source-catalog checkout) under `[skill-instructions]`, `[agent-additional-instructions]`, or `[agent-launch-instructions]`, followed by `vstack refresh`. Bar: would this save 5+ minutes in a future session? One surgical addition per lesson, no verbose examples. What you cannot update yourself goes in your return as `[process]` discovered work.

## Configuration

Agent-type placeholders are project-configurable: `[AGENT_TYPE]` (dev agents receiving implementation delegations), `[REVIEW_AGENT]`, `[QA_AGENT]`. Commit format: `[PREFIX]([ISSUE_ID]): [DESCRIPTION]`. `DEV_VALIDATE_CMD` (`vstack.settings.toml` `[env]`) names the project's validation command for the Validate step; unset → the project's documented build/test/lint command.
