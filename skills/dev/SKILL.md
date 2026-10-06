---
name: dev
description: "Load when implementing an issue or applying review fixes as a dev agent."
summary: "Dev-agent workflows for implementing an issue and applying review fixes, invoked by orch or specialist agents."
license: MIT
user-invocable: true
dependencies:
  required: [orch, github, decider, code-quality]
  optional: [linear, commit-guards]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "3.0.2"
tags: [automation]
---

# Dev Workflows

orch is the caller and runtime: it owns delegation format, round acceptance, and every shell-shape rule.

| Workflow | Purpose |
|----------|---------|
| `workflows/dev-implement.md` | Implementation: activate → plan → implement → validate → commit → QA labels → summary → artifact → return (§ 1-11) |
| `workflows/dev-fix.md` | Review fixes: evaluate → apply or skip → validate → commit → artifact → return |

Review and QA-review belong to the reviewer skill's workflows/review.md and workflows/qa-review.md. Command shapes are orch's [`../orch/SKILL.md`](../orch/SKILL.md) § Harness-Safe Shell; literal format tags and round mechanics are its [`../orch/references/skill-rules.md`](../orch/references/skill-rules.md) § Format Tags Are Literal and § Round Closure.

## Implementer selection

An `agent:X` label selects X. With no agent label, use the item's Location paths and required work:

| Required work | Agent |
|---|---|
| Non-Iced Rust implementation | `rust` |
| Iced view layer and UI messages, even under `crates/` | `iced` |
| Declarative UI: TypeScript/React web, mobile and terminal views; Quickshell QML/JavaScript | `frontend` |
| SwiftUI and UIKit views, Swift application code, Xcode and Swift Package Manager builds/tests; excludes non-UI runtime and data persistence | `swift` |
| Non-UI shell, Python, TypeScript or Go runtime implementation | `runtime` |
| Documentation, references, file or configuration organization | `maintainer` |

For an item spanning domains, split the delegation by domain. If the selected agent is not installed, report the missing agent to the caller. Never substitute `maintainer` for runtime or UI implementation.

## Engineering Rules

- Scope is the issue's Done-when. A behavioral surface that does not trace to it stays out of this change, and a committed render of a source file you changed traces to whatever its source traces to. Two exceptions:
  - the mechanical enablers of landing it ride without tracing to it: locks, changelog, baselines, dismissal renewals, that list and nothing else, never code that runs at runtime;
  - a defect the change introduces or arms is in scope by definition, unless Step 0 of [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) excludes it.
- Every behavior change ships with a test that runs against the script or program enforcing it, at the smallest surface that fails. A workflow sentence ships no test. A test that drives a second implementation or stubs the function under test does not count. Message assertions follow [code-quality § Tests](../code-quality/SKILL.md#tests).
- A review finding adds a case only when it names a behaviour no existing case reaches. Otherwise it tightens the existing case's assertion, and the item reasoning names that case.
- A second fix round on the same function's guard is recurrence: redesign the rule under test so the class is unrepresentable, and fold the family of cases into one table.
- A test whose premise died is deleted whole in the commit that kills the premise, and the PR body names the deletion.
- Test shape is [code-quality § Tests](../code-quality/SKILL.md#tests) and [§ Prove Your Guards](../code-quality/SKILL.md#prove-your-guards).
- A refusal, a validator, a lock, a retry, or a test exists only for an input a real producer emits, this project's code or anything it calls or serves; name that producer beside it, or do not write it.
- When a change deletes a call, apply [code-quality § Cleanup](../code-quality/SKILL.md#cleanup) to its callee. Its deletion maps to the call removal's Done-when item; no internal caller is not proof that a supported external API is unused.
- A field, setting, or view member added by the change has a real producer and consumer. A named and documented external producer or consumer is valid when the change adds its in-repository counterpart; otherwise, add both sides in the change.
- Follow the project's declared release compatibility standard for changes to project-owned formats.
- Before adding a function, parser, stub or loop, grep the repo for the verb it performs; before stating a rule, grep for the rule.
  - A second copy of that verb, in any language, is a twin and never delegation, and so is a second statement of a rule another file owns, in prose, config or a table.
  - Call or cite the one that exists, or escalate in your return. An issue that orders a twin is escalated, not implemented.
- A doc claim the change makes false is updated in the same change; a code change alone owes no doc change. The `docs-writing` skill states what each document holds.
- Once a commit has been reported to the orchestrator, in a return artifact or in a message naming it, later work adds a commit and never amends, whatever the branch push state. The one exception is a head the orchestrator states is unread: there the kendex-issues fix cycle may amend, only to refresh a required check that cannot be rerun.
- A push that prints `rebase-map:` lines has rewritten the shas the PR's `Fixed in <sha>` replies name: before holding, re-reply each such thread with the new sha, or post the map as one PR comment naming old and new per line; a sha the map reports as `dropped` gets a reply that the fix commit no longer exists on the branch.

Code standards are [`../code-quality/SKILL.md`](../code-quality/SKILL.md): correctness, comments, over-engineering, cleanup.

## Round Contract

Execute workflow sections in order; a "**Skip if**" condition is the workflow's decision, never your own scope assessment. Never push and never open a PR. The orchestrator does that after review passes. A finding on a mechanism this diff introduces or arms is a fix whatever the round, unless Step 0 of the disposition flow excludes it; a `Declined:` there takes one of the reason forms [`../orch/references/finding-disposition.md`](../orch/references/finding-disposition.md) § Decision flow sets out, never a label or a test count.

A session keeps the rule text it loaded, and a push, `worktree create --reuse` or a restack can rebase the branch onto a base that changed that text. A session that already ran a round on this branch runs this diff before the round's first step, `[PREVIOUS_ROUND_COMMIT]` being the commit its last round reported: `git diff --no-renames --name-only [PREVIOUS_ROUND_COMMIT] HEAD -- <each loaded file's repo path>`. Before that first step, it reads again each listed file. A listed path it loaded that no longer exists voids the text loaded from it; it reads again the skill's current `SKILL.md`, or the file that replaced it, in its place.

**The completion artifact is the round.** `dev-return-write` writes it after the commit; never hand-author the JSON (schema: orch [`schemas/dev-return.md`](../orch/schemas/dev-return.md)).

- `--issue` is the delegation's `Artifact Key:` line, the workflow-state key where one exists, or the `local-` key `workflow-state new-local-key` mints, per [`dev-return.md` § Identity: the round id](../orch/schemas/dev-return.md#identity-the-round-id); never the tracker-native `OWNER/REPO#N` or a bare number. `--round-id` is its `Round ID:` line.
- `--kind` always matches what was delegated. `--validate` matches your commit message and return. `--validate-note` carries the test-only validation-ceiling report when that route applies. Flag constraints and value shapes: `dev-return-write --help`.

**Acceptance is that artifact plus git state, never your message.** Write the artifact, then return exactly once over the harness's agent-to-agent channel; a disk write is not a return. Send the `**Return exactly**` body once and go idle. Once the artifact is written, start no validation, test, lint or build run in the worktree: the orchestrator validates there next.

- The channel is Claude Code `SendMessage`, Codex `send_input`, OpenCode a resume on the stored `task_id`, Pi background the final assistant message. Copilot CLI's channel is not yet measured, so this contract names none for it.
- In a Pi persistent pane, follow the return with `complete_subagent`; background agents must not call it.
- On Codex the `send_input` MESSAGE is the durable return, and the runtime's `FINAL_ANSWER` echo of it is expected, not a separate return to author or expand.

## Validation

The validation gate and role ownership are complete in [dev-implement.md § 5. Validate](workflows/dev-implement.md#5-validate). For that gate, run no proof, rerun, receipt, isolation step, or approval step that section does not name. That section also owns the one proposed-rule route and the per-rule control for production gate and guard changes.

A test or sandbox run outside that gate, such as a nested-session smoke run or one test file run alone while investigating, is an investigation run and names its question first. Before it starts, append `Run N: question: <what this run decides>; expect: <the result that answers yes or no>` to the round notes, `[WORKTREE_PATH]/tmp/run-notes-[ARTIFACT_KEY]-[DEV_ROUND_ID].md`; after it, append `Run N: answer: <yes|no|inconclusive> <one line>`. A run with no question line is not started. A second `inconclusive` in a row on one question sends the agent back to the code and logs, never to a third run. Every run the gate lists is exempt, its must-fail controls and scoped-suite fallback included.

### Long-Running Validation

**Invariant, every harness:** the completion tail (commit → QA labels → summary → artifact → return) is never dropped, and an interrupted run is never success. Re-check its real outcome and resume the tail.

A command that can outlast the harness's tool-call limit never runs as one blocking foreground tool call, with two exceptions: the `dev-validate-run` start below, whose detached run and on-disk verdict survive a cut-off call and whose `--wait --run-dir` poll resumes it, and a project validation entry point on the foreground route [dev-implement.md § 5. Validate](workflows/dev-implement.md#5-validate) gives a project whose own policy forbids `dev-validate-run`, run under the harness's maximum command timeout. Run only `DEV_VALIDATE_CMD` and `DEV_VALIDATE_RANGE_CMD` through `dev-validate-run`, outside that route; never override these settings per run. Run every other long command, including standalone preflight, doc-limits, mutation-control sweeps and scoped suites, through the orch job runner per [waiter-launch.md](../orch/references/waiter-launch.md). Read each completion file, preserve nonzero exit codes, and report an interruption without a verdict as failure.

`.agents/skills/orch/scripts/dev-validate-run` runs the configured project validation command for every harness. It bounds the command with `DEV_VALIDATE_TIMEOUT_SECS`, detaches it so the run outlives the shell that launched it, and records the verdict as one `guard-exit=N at=TIME` line beside the log, with `verdict=no-verdict` after it when the bound cut the run off. The wait's cap is that setting plus the kill grace and one poll interval; never choose any of those numbers yourself. Full contract: `dev-validate-run --help`.

- **Claude Code.** Run the BARE command `.agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH]` in the foreground, never piped or chained, under the harness's maximum command timeout; it starts the run detached and then blocks until the verdict. A run that outlasts that timeout comes back cut off or moved to the background: read the `run-dir=` value off the `state=started` line in the output it returned or in the output file the harness names, and take the foreground poll `.agents/skills/orch/scripts/dev-validate-run --wait --run-dir [RUN_DIR]` as the turn's next step, under the same timeout because one call runs for up to nine minutes, repeating for as long as it exits 3 and prints `state=running`. Never end the turn while the run is still running and never wait for a completion notice: a subagent whose turn has ended is not woken when the run ends, and the harness can kill a background shell on a low-memory heuristic that fires with free memory to spare. Neither loses the verdict, because the sentinel is on disk. The verdict is the `validate=` value on the `state=done` line: `pass`, `FAILING`, or `no-verdict` for a run the bound cut off, which [dev-implement.md § 5. Validate](workflows/dev-implement.md#5-validate) routes; the log holds command output and never an exit status. `state=timeout` and `state=lost` are both failed validations. Then resume the tail.
- **Codex.** Run `.agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH]` in the foreground and block. Where the harness's own foreground ceiling cuts that call off, the run and its verdict are still on disk: resume with `--wait --run-dir` on the `run-dir=` value from the `state=started` line, as Claude Code does.
- **Pi.** Pi sets no default foreground timeout. A foreground ceiling comes from the host or an explicit tool timeout. Start `.agents/skills/orch/scripts/dev-validate-run --worktree [WORKTREE_PATH]` through `bg_task action: "spawn"` with `notifyOnExit: true`. Keep the task id and the `run-dir=` value from the task log's `state=started` line. Read the task log on its exit wake and interpret the verdict as Claude Code does. If the task ends without a verdict, resume `.agents/skills/orch/scripts/dev-validate-run --wait --run-dir [RUN_DIR]` through the same background mechanism, repeating while it prints `state=running` and exits 3. Resume the completion tail after reading the verdict. A Pi background child that starts this run needs a `bgTaskTimeoutMs` deadline that covers its work before the run plus `DEV_VALIDATE_TIMEOUT_SECS`, because the deadline counts from the child's launch; otherwise the deadline kills it before its completion tail. For other long commands, follow this section's command-routing rule.
- **A host whose agent warden kills detached jobs**, on any harness: add `--attached` to the start command and run it in the foreground, under a harness timeout above the `cap-secs=` value on its `state=started` line. The route fits only a harness whose call can outlast that cap. The run then stays inside the agent's own process tree and writes the same run directory, sentinel and record, which `dev-return-write` takes as it takes a detached run. A harness that cuts the call off kills only the parent, and the warden then reaps the child before its verdict: the run ends as `state=lost`, a failed validation. The `--wait --run-dir` resume above holds only on a host without such a warden.

## Reflect

**Skip if** nothing recurred and nothing surprised you. Otherwise a lesson goes to the authoritative place only where it is a durable constraint: a regression test, a reason comment at the code, an `AGENTS.md` convention, a decision record under the decider bar, or a principle doc where the `docs-writing` skill admits one. Add nothing when the repository already holds it. A rule for the managing project alone goes in its kendex config (`kendex.toml` at the kendex project root, `kendex-local.toml` in a source-catalog checkout) under `[skill-instructions]`, `[agent-additional-instructions]`, or `[agent-launch-instructions]`. Bar: would this save 5+ minutes in a future session? One surgical addition per lesson, no verbose examples. A config edit takes effect only once it is rendered, which you cannot do from a worktree, so name it, and anything else you cannot update yourself, in your return as `[process]` discovered work.

## Configuration

Agent-type placeholders are project-configurable: `[AGENT_TYPE]` (dev agents receiving implementation delegations), `[REVIEW_AGENT]`, `[QA_AGENT]`. Commit format: `[PREFIX]([ISSUE_ID]): [DESCRIPTION]`. `DEV_VALIDATE_CMD` (`kendex.settings.toml` `[env]`) names the project's validation command for the Validate step; [dev-implement.md § 5. Validate](workflows/dev-implement.md#5-validate) states what it must read and that an empty value is a validation failure, never a fallback. `DEV_VALIDATE_RANGE_CMD` (same table, optional) names the command a fix round runs instead, which validates the changes since the commit it reads as `DEV_VALIDATE_BASE`; unset, a fix round runs `DEV_VALIDATE_CMD`. An orch restack also runs it, as [`../orch/workflows/merge-pr-restack.md`](../orch/workflows/merge-pr-restack.md) sets out. `DEV_VALIDATE_CI_CONTEXT` (same table, optional) names the required status check context whose pull request run covers `DEV_VALIDATE_CMD`; `dev-validate-run --help` states when a `ci` run leaves a round to it. `DEV_VALIDATE_TIMEOUT_SECS` (same table, default 3600) is how long either command may run, and the only number § Long-Running Validation derives its cap from.
