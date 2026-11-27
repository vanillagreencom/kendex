---
name: dev
description: "Load when implementing an issue or applying review fixes as a dev agent."
license: MIT
user-invocable: true
metadata:
  author: "vanillagreen"
  source: "kendex"
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->

In this repository, the `.agents/skills/` render of an admitted `skills/` path counts as admitted under § Round Contract, Admitted paths: the render lands with its source in the same commit, so the source's admission already holds it.
<!-- kendex:project-instructions:end -->

# Dev Workflows

orch is the caller and runtime: it owns the delegation format, round acceptance and every shell-shape rule.

| Workflow | Purpose |
|----------|---------|
| `workflows/dev-implement.md` | Implementation: activate → plan → implement → validate → commit → QA labels → summary → artifact → return (§ 1-11) |
| `workflows/dev-fix.md` | Review fixes: evaluate → apply or skip → validate → commit → artifact → return |

- Review and QA-review belong to the reviewer skill's workflows/review.md and workflows/qa-review.md.
- Command shapes are orch's [`../orch/SKILL.md`](../orch/SKILL.md) § Harness-Safe Shell.
- Literal format tags and round mechanics are its [`../orch/references/skill-rules.md`](../orch/references/skill-rules.md) § Format Tags Are Literal and § Round Closure.
- Where a file search may look is [`../orch/references/skill-rules.md`](../orch/references/skill-rules.md) § File searches.

## Implementer selection

An `agent:X` label selects X. With no agent label, use the item's Location paths and required work:

| Required work | Agent |
|---|---|
| Non-Iced Rust implementation | `rust` |
| Iced view layer and UI messages, even under `crates/` | `iced` |
| Declarative UI: TypeScript/React web, mobile and terminal views | `frontend` |
| SwiftUI and UIKit views, Swift application code, Xcode and Swift Package Manager builds/tests | `swift` |
| Non-UI shell, Python, TypeScript or Go runtime implementation | `runtime` |
| Documentation, references, file or configuration organization | `maintainer` |

- Frontend owns all Quickshell QML and its JavaScript, view and non-view.
- Swift excludes non-UI runtime and data persistence.
- For an item spanning domains, split the delegation by domain.
- If the selected agent is not installed, report the missing agent to the caller.
- Never substitute `maintainer` for runtime or UI implementation.

## Engineering Rules

- Scope is the issue's Done-when. A behavioral surface that does not trace to it stays out of this change, and a committed render of a source file you changed traces to whatever its source traces to. Two exceptions:
  - the mechanical enablers of landing it ride without tracing to it: locks, changelog, baselines, dismissal renewals, that list and nothing else, never code that runs at runtime;
  - a defect the change introduces or arms is in scope by definition, unless Step 0 of [`../reviewer/references/finding-disposition.md`](../reviewer/references/finding-disposition.md) excludes it.
- A behavior change ships with the test code-quality admits.
  - The pull request body names an omitted test and the judgement.
  - A workflow sentence ships no test.
  - A test that drives a second implementation or stubs the function under test does not count.
  - Message assertions follow [code-quality § Tests](../code-quality/SKILL.md#tests).
- A review finding adds a case only when it names a behaviour no existing case reaches. Otherwise it tightens the existing case's assertion, and the item reasoning names that case.
- A second fix round on the same function's guard is recurrence.
  - Redesign the rule under test so the class is unrepresentable, and fold the family of cases into one table.
  - Fix an item with an `Owner:` line at that owner, with one table whose rows cover every state the owner can be in.
- A test whose premise died is deleted whole in the commit that kills the premise, and the PR body names the deletion.
- A refusal, a validator, a lock, a retry, or a test exists only for an input a real producer emits, this project's code or anything it calls or serves; name that producer beside it, or do not write it.
- When a change deletes a call, apply [code-quality § Cleanup](../code-quality/SKILL.md#cleanup) to its callee. Its deletion maps to the call removal's Done-when item; no internal caller is not proof that a supported external API is unused.
- A field, setting, or view member added by the change has a real producer and consumer. A named and documented external producer or consumer is valid when the change adds its in-repository counterpart; otherwise, add both sides in the change.
- Follow the project's declared release compatibility standard for changes to project-owned formats.
- Before adding a function, parser, stub or loop, grep the repo for the verb it performs; before stating a rule, grep for the rule.
  - A second copy of that verb, in any language, is a twin and never delegation, and so is a second statement of a rule another file owns, in prose, config or a table.
  - Call or cite the one that exists, or escalate in your return. An issue that orders a twin is escalated, not implemented.
- A doc claim the change makes false is updated in the same change; a code change alone owes no doc change. The `docs-writing` skill states what each document holds.
- Once a commit has been reported to the orchestrator, in a return artifact or in a message naming it, later work adds a commit and never amends, whatever the branch push state. The one exception is a head the orchestrator states is unread: there the orch fix cycle may amend, only to refresh a required check that cannot be rerun.
- A push that prints `rebase-map:` lines has rewritten the shas the PR's `Fixed in <sha>` replies name. Before holding:
  - re-reply each such thread with the new sha, or post the map as one PR comment naming old and new per line;
  - give a sha the map reports as `dropped` a reply that the fix commit no longer exists on the branch.

Code standards are [`../code-quality/SKILL.md`](../code-quality/SKILL.md): correctness, comments, over-engineering, cleanup.

## Round Contract

- Execute workflow sections in order.
- A "**Skip if**" condition is the workflow's decision, never your own scope assessment.
- Never push and never open a PR.
- A finding on a mechanism this diff introduces or arms is a fix whatever the round, unless Step 0 of the disposition flow excludes it.
- A `Declined:` there takes one of the reason forms [`../reviewer/references/finding-disposition.md`](../reviewer/references/finding-disposition.md) § Decision flow sets out, never a label or a test count.

**Admitted paths.** A delegation's `Admitted paths:` line is a JSON array of the paths the lane may change: the set its launch judge admitted. An entry that ends in `/` covers every path under it. A delegation with no such line sets no bound.

1. Before the first edit, list every repository path the round adds or changes, companions included: module declarations, tests, generated copies, docs and callers.
2. A listed path outside the set is a blocker, except a `changelog.d/` fragment, which the judge never counts.
3. On a blocker, make no edit to that path. Write every such path, one per line with the reason the change needs it, to `[WORKTREE_PATH]/tmp/paths-ask-[ARTIFACT_KEY]-[DEV_ROUND_ID].md`.
4. Commit nothing, write no receipt, and return `Blocked: paths outside the admitted set: [FILE]`. The orchestrator asks for every path at once and delegates a fresh round with the widened set.

A path the round finds after its first edit is the same blocker, before its edit. Before returning, put the tree back as the round found it, never to HEAD: a round can start dirty, after a `--directive-unconfirmed` recover or a stalled-round redelegate, on an earlier round's uncommitted edits.

- Before the first edit, record the starting index and tree. `git -C [WORKTREE_PATH] write-tree` prints the starting index as `[START_INDEX]`.
  - Then run `git -C [WORKTREE_PATH] read-tree [START_INDEX]`, `git -C [WORKTREE_PATH] add -A` and `git -C [WORKTREE_PATH] write-tree`, all three under the same `GIT_INDEX_FILE=[WORKTREE_PATH]/tmp/start-index-[ARTIFACT_KEY]-[DEV_ROUND_ID]` prefix. The last prints `[START_TREE]`.
- Describe the edits already made in the ask file, so the fresh round can make them again.
- Restore each changed path's index entry with `git -C [WORKTREE_PATH] reset -q [START_INDEX] -- [PATH]`, then its file with `git -C [WORKTREE_PATH] restore --source=[START_TREE] --worktree -- [PATH]`. Remove only a file `git -C [WORKTREE_PATH] cat-file -e [START_TREE]:[PATH]` finds absent from the starting tree. Name each path literally.
- A clean start leaves the tree clean. A dirty start leaves the earlier round's edits standing, and the ask file names that dirty start as the restack blocker, since a restack refuses a dirty tree.

A session keeps the rule text it loaded, and a push, `worktree create --reuse` or a restack can rebase the branch onto a base that changed that text. A session that already ran a round on this branch takes these steps before the round's first step:

1. Run `git diff --no-renames --name-only [PREVIOUS_ROUND_COMMIT] HEAD -- <each loaded file's repo path>`, `[PREVIOUS_ROUND_COMMIT]` being the commit its last round reported.
2. Read again each listed file.
3. A listed path it loaded that no longer exists voids the text loaded from it. Read again the skill's current `SKILL.md`, or the file that replaced it, in its place.

**The completion artifact is the round.** `orch-runtime dev-return --text write` writes it after the commit, or with no commit on [dev-implement.md § 2.3](workflows/dev-implement.md#23-evaluate-feasibility)'s no-change route. Never hand-author the JSON (schema: orch [`schemas/dev-return.md`](../orch/schemas/dev-return.md)).

- `--issue` is the delegation's `Artifact Key:` line, the workflow-state key where one exists, or the `local-` key `.agents/skills/orch/scripts/orch-runtime state new-local-key` mints, per [`dev-return.md` § Identity: the round id](../orch/schemas/dev-return.md#identity-the-round-id); never the tracker-native `OWNER/REPO#N` or a bare number.
- `--round-id` is its `Round ID:` line.
- `--kind` always matches what was delegated.
- `--validate` matches your return, and your commit message where the commit follows validation.
- Flag constraints and value shapes: `orch-runtime dev-return --text write --help`.

**Acceptance is that artifact plus git state, never your message.**

- Write the artifact, then return exactly once over the harness's agent-to-agent channel; a disk write is not a return.
- Send the `**Return exactly**` body once and go idle.
- Once the artifact is written, start no validation, test, lint or build run except the admitted stopped-round recovery in [references/validation.md § Stopped-round recovery](references/validation.md#stopped-round-recovery); otherwise the orchestrator validates there next.

The channel per harness:

- The channel is Claude Code `SendMessage`, Codex `send_input`, OpenCode a resume on the stored `task_id`, Pi background the final assistant message. Copilot CLI's channel is unmeasured, so this contract names none for it.
- In a Pi persistent pane, follow the return with `complete_subagent`; background agents must not call it.
- On Codex the `send_input` MESSAGE is the durable return, and the runtime's `FINAL_ANSWER` echo of it is expected, not a separate return to author or expand.

## Validation

The validation gate and role ownership are complete in [references/validation.md § The gate](references/validation.md#the-gate). [dev-implement.md § 5. Validate](workflows/dev-implement.md#5-validate) runs it.

A test or sandbox run outside that gate, such as a nested-session smoke run or one test file run alone while investigating, is an investigation run.

- It names its question first.
- Before it starts, append `Run N: question: <what this run decides>; expect: <the result that answers yes or no>` to the round notes, `[WORKTREE_PATH]/tmp/run-notes-[ARTIFACT_KEY]-[DEV_ROUND_ID].md`.
- After it, append `Run N: answer: <yes|no|inconclusive> <one line>`.
- A run with no question line is not started.
- A second `inconclusive` in a row on one question sends the agent back to the code and logs, never to a third run.
- Every run the gate lists is exempt, its must-fail controls included.

### Long-Running Validation

**Invariant, every harness:** the completion tail (commit → QA labels → summary → artifact → return) is never dropped, and an interrupted run is never success. Re-check its real outcome and resume the tail.

A session at its context mark hands over at once, whatever step is open.

- The handoff record names the open step and the run in flight, with the runner identity, the log and exit-receipt paths and one recovery route, under `traps`.
- A verdict, a review or any other step is never a precondition of that record.
- On a host whose agent warden reaps orphan scopes, a foreground project entry-point run or an `--attached` run does not survive its agent's scope. For such a run:
  - The successor confirms the interrupted run has stopped, preserves its log and any exit receipt, and reruns only those interrupted checks once.
  - The successor uses the orch job runner or orch's validation runner according to this section's command routes, with a runner that survives its own agent scope.
  - The successor never waits on an orphan queued run whose parent is gone.

A command that can outlast the harness's tool-call limit never runs as one blocking foreground tool call. There are two exceptions:

- the validation start, whose detached run and on-disk verdict survive a cut-off call and whose `--wait --run-dir` poll resumes it;
- a project validation entry point on the foreground route [references/validation.md § Foreground route](references/validation.md#foreground-route) gives a project whose own policy forbids orch's validation runner, run under the harness's maximum command timeout.

The command routes:

- Run the project's declared validation commands through orch's validation runner, `orch-runtime validate entry`, outside that route.
- Never override per run the `DEV_VALIDATE_*` settings that declare those commands.
- Run every other long command, including standalone preflight, doc-limits and mutation-control sweeps, through the orch job runner per [waiter-launch.md](../orch/references/waiter-launch.md).
  - A dev or fix agent launches it with waiter-launch.md § Launch's form that carries no `--owner`.
  - It holds the completion inside its turn by [waiter-launch.md § Completion](../orch/references/waiter-launch.md#completion)'s no-owner route, and never waits for a `job-end` notice, which reaches the lane session and never the agent.
- Read each completion file, preserve nonzero exit codes, and report an interruption without a verdict as failure.

Before starting, polling or resuming validation, read [long-running-validation.md](workflows/long-running-validation.md).

A subagent waits with one bounded command through its harness's own wait mechanism, or with the foreground poll its command route names. It never busy-waits: no read of `/dev/zero` or `/dev/urandom`, and no spin poll. Orch's `references/skill-rules.md` § Subagent waits gives each harness's form.

## Reflect

**Skip if** nothing recurred and nothing surprised you. Otherwise:

- A lesson goes to the authoritative place only where it is a durable constraint: a regression test, a reason comment at the code, an `AGENTS.md` convention, a decision record under the decider bar, or a principle doc where the `docs-writing` skill admits one.
- Add nothing when the repository already holds it.
- A rule for the managing project alone goes in its kendex config (`kendex.toml` at the kendex project root, `kendex-local.toml` in a source-catalog checkout) under `[skill-instructions]`, `[agent-additional-instructions]`, or `[agent-launch-instructions]`.
- Bar: would this save 5+ minutes in a future session?
- One surgical addition per lesson, no verbose examples.
- A config edit takes effect only once it is rendered. Render it where the project's render policy lets you. Otherwise name it, and anything else you cannot update yourself, in your return as `[process]` discovered work.
