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

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

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
- Required commands accepted from issue specs or delegated verification lists are normalized before running: an env-assignment prefix (`VAR=value cmd args`, e.g. `LC_ALL=C tools/test-ci-changes`) becomes an ambient-environment precondition check (`printenv VAR`, or `locale` for locale variables) followed by the bare `cmd args` unchanged. `env VAR=value cmd` is not an acceptable substitute; a failed precondition is a blocker to report, not a license to run under the wrong environment. Canonical rule: orch SKILL.md § Harness-Safe Shell.
- Never put a literal backtick in a generated search command: command-shape guards classify any backtick as command substitution and reject the command before it runs, even for a read-only audit over Markdown inline code. Write the pattern with the regex hex escape `\x60` in single quotes as one simple command — e.g. `rg -n '\x60vstack refresh\x60' skills/`, with `[\x60]` inside a bracket expression — and use regex mode, since `rg -F` has no escapes. Canonical rule: reviewer SKILL.md § Harness-Safe Shell.
- If a required branch update is rejected as a policy-blocked `git rebase`, the rejection is a harness-side classification of the porcelain verb that no user authorization can lift: do not retry it, delegate it, or improvise a force-push. Use the worktree skill's guarded `create <ID> --reuse`/`--restack` path, or the single-simple-command replay in worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback); a dirty tree or merge commits in the range are blockers to report, not cases to improvise.
- **Return requires an agent-to-agent message.** Every `**Return exactly**` step must be delivered through the harness return channel (Claude Code: `SendMessage`; Codex: `send_input`; OpenCode: resume via stored `task_id`; Pi bg: final assistant message captured by `subagent`). Disk writes do not reach the orchestrator. In Pi persistent panes, after printing the exact return body once, call `complete_subagent` with the final status/summary/files/validation; bg agents must not call `complete_subagent`. On Codex, the `send_input` `MESSAGE` is the durable return; the Codex runtime may additionally echo it as a `FINAL_ANSWER`. That echo is expected and is not a separate return — send the return exactly once via `send_input`, then go idle; do not author or expand a different final payload.

## Long-Running Validation

A `tools/validate`-class command or full hermetic suite can outlast a single turn. **Invariant, every harness:** never let it end your turn mid-checklist silently. The completion tail — commit → QA labels → summary → `dev-return-write` artifact → return — is what the orchestrator accepts on, and the round-scoped artifact is the durable record (orch [`schemas/dev-return.md`](../orch/schemas/dev-return.md)). If a long run is cut short, re-check its real outcome (still running? exit code? log tail?) and resume the tail; never read an interruption as success, and never treat it as license to drop the round. How you wait is harness-specific — use only your own:

- **Claude Code** — the Bash tool caps at ~10 min and a turn has no wall-clock primitive, so background the BARE command with its output redirected to a log — `[VALIDATE_CMD] > [LOG] 2>&1` via `run_in_background`, never piped or chained: unpiped, the completion wake's exit code IS the command's; through any pipe it becomes the last stage's. The log's `END OF OUTPUT — exit status: N` block is the authoritative verdict either way. **End your turn** and wait for the completion wake or the orchestrator's report-only tail nudge. The wake is not reliably delivered to in-process teammate sub-agents, so it may never arrive: **idling after backgrounding is normal, not a stall** — the orchestrator's wall-clock watchdog closes the round (orch SKILL.md § Wait for Agent Return Before Acting). Do not poll for status or exit code; a poll is an instant no-op turn that advances no wall clock.
- **Codex** — run it in the **foreground and block**: there is no ~10-min tool cap, and under `approval_policy = never` the classifier rejects poll-loop shapes anyway.
- **Pi** — pane agents block naturally in their tmux shell; run it in the foreground.

## Configuration

Agent types referenced in workflows (names are project-configurable):
- **Dev agents**: `[AGENT_TYPE]` — specialist agents receiving implementation delegations
- **Review agents**: `[REVIEW_AGENT]` — agents that review specific aspects (correctness, quality, security, testing, docs, errors, structure)
- **QA agents**: `[QA_AGENT]` — agents for safety, performance, and architecture review

Commit format: `[PREFIX]([ISSUE_ID]): [DESCRIPTION]` — configurable per project conventions.
