---
name: orch
description: "PRIMARY AGENT ONLY. Load to orchestrate a Linear or GitHub work item from preparation through merge."
summary: "Work-item orchestration for Linear or GitHub issues: prepare, delegate implementation, review, submit, merge, hand off, and oversee fleets of sessions."
license: MIT
user-invocable: true
dependencies:
  required: [github, worktree, dev, project-management, decider, reviewer]
  optional: [linear, review-gate, second-opinion]
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "3.0.0"
tags: [automation]
---

# Orchestration

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Load `github` and `worktree` before anything else; a Linear work item also needs `linear`. The dev and reviewer skills call orch scripts.

> **MODE SWITCH**: you are the orchestrator. Delegate every implementation, review, and QA task to a specialist sub-agent. Never edit code unless the user explicitly asks.

## The Cycle

Get the issue → dev implements → review → dev fixes blockers → re-review → push PR → review gate → shepherd to merge.

- **Bounded loops.** A fix round addresses blockers only; re-review narrows to the fix diff and the domains it touched; two consecutive rounds with no new blocker end the review.
- **No edge-case churn.** A finding that cannot affect real usage is declined with a one-line reason — not fixed, not filed.
- **Review must converge**, by [references/finding-disposition.md](references/finding-disposition.md):
  - Every finding runs its [§ Decision flow](references/finding-disposition.md#decision-flow), Step 0 first, and ends as one of the reply forms that section sets out.
  - A defect class recurring across rounds → its [§ Recurrence](references/finding-disposition.md#recurrence), never patched per comment, for a rule restated in prose or a table as much as for code.
  - A defect in code the issue's Done-when does not need, or a PR past its size tripwire → a cut, not a fix round. A round whose only findings are scope or wording asks ends the review: reply, resolve, push nothing, merge through the gate. Never `--admin`.
- **Ask the user only about product or experience.** Scope expansion beyond the issue and revisiting a recorded decision always ask, whatever `ORCH_DECISION_MODE` says. Merge asks unless `ORCH_MERGE_AUTONOMY=auto`, which merges without asking only when every merge gate is green.
- **Acceptance is artifact-based.** A round closes on a validated on-disk artifact plus git/tracker state, never on a return message.

## Commands

Route `<command> [args]` to its workflow and follow [Workflow Execution](#workflow-execution).

| Command | Arguments | Workflow | Purpose |
|---------|-----------|----------|---------|
| `start` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/start.md` / `workflows/start-worktree.md` | Prepare one work item; from a worktree, run the full session |
| `start new` | `linear\|github ...` | `workflows/start-new.md` | Create one issue, then start it |
| `handoff` | `linear\|github ...` | `workflows/handoff.md` | Launch independent sessions |
| `plan-issues` | `PLAN_PATH linear\|github` | `workflows/plan-issues.md` | Convert plan items into issues |
| `dev-start` | `[ISSUE_ID]` | `workflows/dev-start.md` | Delegate implementation |
| `dev-fix` | `[ISSUE_ID]` | `workflows/dev-fix.md` | Delegate fix items |
| `ci-fix` | `PR_NUMBER` \| `queue` | `workflows/ci-fix.md` | Analyze and fix CI failures |
| `review` | `[all]` \| `[last N]` \| `[HASH]` | `workflows/review.md` | On-demand review of local changes |
| `review-codebase` | `[PATH]` | `workflows/review-codebase.md` | Whole-codebase fanout, findings only |
| `review-pr` | `[PR_NUMBER]` | `workflows/review-pr.md` | Review cycle with fixes and QA |
| `review-pr-comments` | `PR_NUMBER` \| `BRANCH` | `workflows/review-pr-comments.md` | Triage PR review comments |
| `submit-pr` | `[PR_NUMBER]` | `workflows/submit-pr.md` | Push, create PR, gates, merge |
| `merge-pr` | `PR_NUMBER` \| `all` | `workflows/merge-pr.md` | Verify conditions and merge |
| `post-summary` | `[ISSUE_ID]` | `workflows/post-summary.md` | Post summary and handoff comments |
| `oversee` | — | `workflows/oversee.md` | Fleet mode: one session per unblocked item, shepherd every PR to merge |

**`start` routing.** `github OWNER/REPO#N` → `TRACKER=github`, `ISSUE_ID=issue-N`, keep `OWNER/REPO` for the API; otherwise Linear unless the id starts with `issue-`. A cwd whose git common dir differs from `.git` is a worktree → `workflows/start-worktree.md`; otherwise `workflows/start.md`.

## Scripts

```bash
.agents/skills/orch/scripts/<script> [args]
```

| Script | Intent |
|--------|--------|
| `workflow-state` | Persistent state read/write/append — see below |
| `git-context` | Git-derived values (branch, head, issue id, roots, timestamps) |
| `pr-view-json` | PR view JSON; `status=no_pr` exits 0 and routes to PR creation, not an error |
| `resolve-base-branch` | Print a worktree's base branch; exits 1 rather than guess |
| `sync-base` | Resolve, fetch, and fast-forward the checkout that owns the base branch; prints the branch name |
| `container-close` | Serialize a Linear container close across linked checkouts; prints `closed` or `deferred`, with closed diagnostics on stderr |
| `base-freshness` | Gate the review cycle on a current base; unverifiable = stale. `--help` |
| `review-artifact-check` | Validate a reviewer's JSON artifact — the sole reviewer completion condition. `--help` + [references/artifact-checks.md](references/artifact-checks.md) |
| `dev-return-write` | Write a dev agent's round-scoped completion artifact; never hand-author the JSON. `--help`; schema `schemas/dev-return.md` |
| `worktree-claim` | Claim or refresh an issue worktree lease; exits 75 when a foreign owner or lock holds it. `--help` |
| `worktree-push` | Push an issue worktree via `worktree push` and reconcile rebased SHAs in workflow state (`.rebase_map`, `fixed_items`, `pr_comment_review.fixes`) in the same call. `--help` |
| `dev-round-write` | Persist a fix round's delegated item set at stamp time. `--help`; schema `schemas/dev-round.md` |
| `dev-artifact-check` | Validate a dev round's completion artifact by round id. `--help` + [references/artifact-checks.md](references/artifact-checks.md) |
| `approval-wait` | Poll the reviewer gate; `--resolve-mode` prints the effective gate mode. `--help` + [references/gates.md](references/gates.md) |
| `ci-wait` | Block until CI completes on a PR. `--help` + [references/gates.md](references/gates.md) |
| `queue-wait` | Foreground merge-queue / auto-merge waiter and verdict producer. `--help` + [references/gates.md](references/gates.md) |
| `merge-queue-watch` | Durable prepared-head lifecycle: detached launch, liveness, verdict claim, merge-pr completion, and lane acknowledgment. `--help` |
| `orch-env` | Effective value of a kendex `[env]` setting (process env > `.env.local` > `.kendex/settings.toml` > `kendex.settings.toml` > default) |
| `spawn-adapter` | Resolve Codex spawn parameters (`spawn`) and the runtime thread budget (`slots`) |
| `open-terminal` | Terminal handoff; model, effort, and permission flags via `--launch-flags`. `--help` |
| `lanes` | Enumerate harness auth lanes; `pick` prints the launch env prefix for the least-loaded qualifying lane, exit 3 when none qualifies; `context` reports each live lane's context use, read from its pane status line. `--help` |
| `reconcile-work-items` | Read-only tracker sweep (parked containers, items stale past `RECONCILE_STALE_HOURS`, Done items with unchecked boxes). Exit 1 on findings |
| `oversee-watch` | Block until the fleet needs the overseer, then print one `EVENT` line. `--help` |

The three waiters exit `3` on hard auth failure — [references/gates.md](references/gates.md).

**Multi-PR watching.** Never hand-roll a monitor. When `.agents/skills/review-gate/scripts/pr-watch.sh` exists, run it (oversee: through `oversee-watch`); otherwise per-PR `approval-wait`/`queue-wait`. [references/gates.md](references/gates.md).

**`workflow-state`.** Run it with no arguments for the action reference. State keys are normalized issue IDs — `issue-N` for GitHub, `PROJ-123` for Linear; `schemas/workflow-state.md`.

**Review-gate modes.** Read the effective gate mode (`approval`, `review`, or `off`) only through `approval-wait --resolve-mode`. [references/gates.md](references/gates.md).

**Detached merge boundary.** At every lane boundary, run `merge-queue-watch consume --root [MAIN_REPO_ROOT] --issue [STATE_KEY]` before unrelated work; it atomically claims one normalized action, which `merge-pr.md` § 5 routes and `merge-queue-watch --help` defines. The overseer wakes and confirms; it never consumes, recovers, or completes a lane's lifecycle.

Standalone merge-pr initializes the lifecycle in `merge-pr.md` § 4 before preparation.

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/workflow-state.md` | State file |
| `schemas/dev-return.md` | Dev completion artifact |
| `schemas/dev-round.md` | Delegated fix-round item set |
| [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md) | Review/QA finding JSON |

## Configuration

Non-secret settings go in committed `kendex.settings.toml` under `[env]`; `.env.local` holds secrets and personal overrides. Keys: [README.md](README.md) § Configuration; review-gate keys in [references/gates.md](references/gates.md); lane keys in `lanes --help` and `open-terminal --help`.

System dependencies: `jq`; `bash` 3.2; `flock` (util-linux).

## Tests

`bash skills/orch/tests/run-all.sh` (append a name fragment to filter).

---

## Runtime Notes

> If you are running in **Codex**: `approval required by policy, but AskForApproval is set to Never` flags the command's SHAPE — never retry it, never wait for approval; rewrite it per [references/codex-runtime.md](references/codex-runtime.md). Polling loops → the orch waiters `.agents/skills/orch/scripts/ci-wait`, `approval-wait`, `queue-wait` — never `github.sh` subcommands. Merge-pr detaches only through `merge-queue-watch`; the waiters stay foreground producers. Spawn generated agents through `scripts/spawn-adapter` with `fork_context: false`, then `send_input` a `DELEGATION:`-prefixed `<delegation_format>`.

> If you are running in **OpenCode**: store the `task_id` returned by `functions.task` in workflow state (`child_sessions[agent].agent_id`, `review_agent_ids[reviewer-name]`) and re-delegate with `functions.task(task_id=<stored_id>)`. Spawn fresh only when no ID is stored, one resume attempt failed, or the task is confirmed dead.

> If you are running in **Pi** with `pi-agents-tmux`: delegation is one `subagent` call whose `task` argument is the filled `<delegation_format>` alone — never prepend role text. Store the returned `taskId` in workflow state. [references/pi-runtime.md](references/pi-runtime.md).

---

## Skill Rules

### Workflow Execution

- **Sequential sections.** Mark in-progress, execute every sub-section, mark completed, proceed. Never create tasks for sub-sections, never complete a parent before its children, never skip a step on a predicted outcome.
- **Skip-if.** Evaluate "Skip if [condition]" literally; when true, append "(SKIPPED)", mark completed.
- **Nested workflows.** Invoke `⤵`-marked workflows through the harness mechanism, never inlined. Record the return point (`→ § X`) first.
- **Worktree scope.** Inside a worktree, never act on another worktree or branch, never commit or stash in the main checkout, and never run a kendex command that writes the project scope (`refresh`, `apply`) — every concurrent session shares that checkout, and those prune it. If the resolved `ISSUE_ID` differs from the current branch, stop and ask: reuse, abort, or switch.
- **Unsent input is not an instruction.** Text already sitting in the composer when a session reaches its prompt belongs to the harness, not to the user: clear it, act on nothing it says.

#### Harness-Safe Shell

**Run exactly one simple command per tool call with explicit arguments.** Rejected shapes and substitutes: [references/codex-runtime.md](references/codex-runtime.md). Normalize delegated command lists the same way before they enter a prompt: an env-assignment prefix becomes a precondition check plus the bare command. Reviewer-derived text — a finding's location, description, or cause — never crosses argv: write it to a file with the harness file-write tool and bind the path (`--items-file`, `--adds-file`, `append-file`, jq `--slurpfile`).

#### Tracker Resolution

An `ISSUE_ID` starting with `issue-` is GitHub (`TRACKER=github`, issue number `${ISSUE_ID#issue-}`, repo from caller context else `gh repo view --json nameWithOwner`); anything else is Linear. A caller-supplied `tracker` wins; resolve once per workflow into `TRACKER` and `ISSUE_REF` (`#N` for GitHub, the Linear identifier otherwise) — the only form a `Closes` line renders. Run **Linear only** / **GitHub only** steps only for that tracker; never run `linear.sh` against a GitHub item.

---

### Delegation

| Pattern | When | Flow |
|---------|------|------|
| Spawn + message | Fresh dev, QA, or review agents | Spawn → send delegation |
| Message only | Re-delegation to a live agent | Send delegation to the running agent |
| Self-create | No team context | Full instructions in the prompt |

**No duplicate spawns.** Never spawn a fresh agent while the same role is alive. Reuse by stored ID; respawn only after one recovery attempt or a confirmed stuck/closed status.

#### Format Tags Are Literal

`<delegation_format>` and `<output_format>` are exact: fill `[PLACEHOLDERS]`, omit lines whose placeholder is empty, add nothing else, keep structure and field names verbatim. Placeholders hold schema fields only — never process prose. When a tagged block precedes an ask-user step, present the filled block first, then ask.

#### Single Return Message

An agent sends exactly one completion message. A second return is a violation: diff it against the first and flag unrequested commits.

**Codex dual-channel completion.** The Codex runtime delivers one completion over two channels — a `send_input` `MESSAGE` then a `FINAL_ANSWER` echoing it: treat the pair as **one completion** and deduplicate it. Still diff them; a new commit or extra changes is a genuine second return and is flagged.

---

### Agent Lifecycle

`SPAWN → DELEGATE → WORK → RETURN (single message) → IDLE / RE-DELEGATE`.

**Dev agents persist** for the whole session, re-delegated for every fix round. Shut down only on explicit user request or a confirmed stall.

**Reviewer persistence is budget-conditional.** Available slots = budget (`orch-env REVIEWER_SLOT_BUDGET 0`; `0` = unlimited) − 1 − live `child_sessions` entries whose `status` is `active` (no `status` counts as active), minimum 1; recompute at every review-cycle start. Within budget, reuse reviewers by exact name and spawn only the missing subset. Over budget — or on a thread-limit spawn error — run waves: launch up to the available slots, retire each session on its validated artifact, persist the wave size as `reviewer_slots_observed`. Review state lives on disk, never in reviewer session memory.

QA agents spawn and shut down per agent.

#### Round Closure

The orchestrator owns round closure. Every dev/QA delegation carries three mechanics:

1. **Possession and round token** — immediately before delegating: `worktree-claim --worktree [WORKTREE_PATH] --issue [ISSUE_ID]` → the delegation's `Worktree Lease:` line; exit 75 aborts when a foreign holder has the worktree. Then `workflow-state new-round-id [ISSUE_ID] dev_round_id` → the `Round ID:` line, re-stamp `dev_delegated_at`; a fix round also runs `dev-round-write`, which records HEAD, items, and optional `Adds:` paths in an immutable authorization under the git common directory, outside the delegated worktree. Missing or mismatched authorization requires a fresh round; never recreate it after delegation.
2. **Arm a single-shot wall-clock watchdog** at the same moment — one backgrounded `dev-artifact-check --wait 600 --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`): returns when the artifact lands (`accept`/`retry`) or at the deadline (`wait`). Run A/B on its return; re-arm only on a new escalation step — never poll. [references/artifact-checks.md](references/artifact-checks.md).
3. **Run the check on every wake and at the deadline** — never classify from wording or elapsed time. `dev-artifact-check --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`) prints `verdict`; act on it.

The acceptance table lives in the delegating workflow (`dev-start.md` § 3, `dev-fix.md` § 2, `review-pr-comments.md` § 6.1); the return message is display-only; tracker corroboration (**B**) applies only where that table names it. `ci-fix.md` (no dev-return artifact) is accepted by its return message plus the escalation ladder.

**Escalation.** Only after the 10-minute quiet window AND a confirmed stall (task status unchanged, no session-log entries for 10+ minutes, or the process exited): re-message once naming the missing step → wait 5 minutes → still inactive: shut down, re-create tasks, respawn, re-delegate. The respawn takes a fresh runtime instance and a fresh round id; the canonical agent name is the identity every record is keyed on and stays as it was.

---

### State Management

Durable data lives in workflow state through the `workflow-state` CLI only (`set-git-head`/`set-now`, never inline substitution). Location: `<state-dir>/workflow-state-[ID].json`, where `<state-dir>` is the `--state-dir` flag, then `$ORCH_STATE_DIR`, then `tmp/`.

After compaction, resume from the step after the last completed one: read workflow state, re-send delegations by stored ID, respawn only an agent silent through one idle cycle. Never repeat completed actions.

---

### Coordination

**Containers.** An issue with children or an `agent:multi` label and no `(one PR)` title marker is a CONTAINER. A container is never orchestrated and never gets a PR — each child is the PR unit, selection operates on unblocked children, and the container closes LAST when its final child merges.

**Ancestor gate.** Every selected issue walks its full `parent_id` chain. An enclosing `(one PR)` bundle REPLACES the selection. Dispatch requires the item's own `state_type` non-terminal and the union of its `blocked_by_open` with every container ancestor's `blocked_by_open` empty. `blocked_by` remains relation history and does not decide dispatch. Mechanics: start, start-worktree, handoff, dev-start.

**Sequencing.** Order by data flow (Creates ↔ Consumes), never by agent ordering; existing blocking relations outrank inference. Cross-bundle relations go on the parent issues; dependent children of one container get child-blocks-child relations, which ARE the execution order; only an explicit `(one PR)` bundle leaves intra-bundle ordering to the delegated session.

**Single-PR bundles.** Exactly three opt-ins delegate all children as one session: a parent marked `(one PR)`, a delegation carrying `Audit Bundle: yes`, or a leaf issue with an internal checklist. One composite task per sub-issue; multi-domain bundles process groups sequentially, collecting handoff notes between groups.

**Tracked issue creation.** Route every tracked issue through TPM (project-management) — never create one directly from an orchestration session, except where a workflow step specifies it with its label set (`plan-issues`, `start-new`, the `merge-pr` rebundle).

---

### Review Pipeline

**Finding schema.** [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md), enforced by `review-artifact-check`. Routing reads `verdict` (`action_required` when blockers exist, else `pass`) and each suggestion's `category` ∈ {`fix`, `issue`}.

**Disposition.** Classify each suggestion per [references/finding-disposition.md](references/finding-disposition.md): apply in-PR, file as a tracked issue, or decline with one line. The filing bar lives there.

**Issue audit pipeline.** Collect every follow-up that clears the filing bar (`category=issue` suggestions, escalated blockers, dev "deliberately left out" lists, gaps noticed) into audit input (schema in `project-management/schemas/`) and delegate to TPM, with dependency fields populated when order is known. Never file directly.
