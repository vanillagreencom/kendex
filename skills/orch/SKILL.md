---
name: orch
description: "PRIMARY AGENT ONLY — work-item orchestration for Linear or GitHub issues: prepare, delegate implementation, review, submit, merge, hand off, and oversee fleets of sessions."
license: MIT
user-invocable: true
dependencies:
  required: [github, worktree, dev, project-management, decider, reviewer]
  optional: [linear, review-gate, second-opinion]
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "3.0.0"
---

# Orchestration

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Load `github` and `worktree` before anything else; a Linear work item also needs `linear`. orch is both the coordinator and the shared runtime library — the dev and reviewer skills call its scripts (`dev-return-write`, `resolve-base-branch`, `review-artifact-check`) and do not run standalone.

> **MODE SWITCH**: loading this skill puts you in orchestrator mode. Delegate every implementation, review, and QA task to a specialist sub-agent. Read-only commands and script invocations are yours; editing code is not, unless the user explicitly asks.

## The Cycle

Get the issue → dev implements → review → dev fixes blockers → re-review → push PR → review gate → shepherd to merge.

Four rules bound it:

- **Bounded loops.** A fix round addresses blockers. Minor suggestions never trigger another cycle; re-review narrows to the fix diff and the domains it touched; two consecutive rounds that surface no new blocker end the review.
- **No edge-case churn.** A finding that cannot affect real usage is declined with one line of rationale — not fixed in-PR, not filed. Issue creation is for critical follow-ups only, never the default disposal path for review output.
- **Ask the user only about product or experience.** Every technical choice is settled by rule here or by the specialist who owns it. Scope expansion beyond the issue and revisiting a recorded decision always ask, whatever `ORCH_DECISION_MODE` says. Merge asks unless `ORCH_MERGE_AUTONOMY=auto`, which merges without asking when — and only when — every merge gate is green.
- **Acceptance is artifact-based, never prose-based.** A round closes on a validated on-disk artifact plus git/tracker state. A return message is display material.

## Commands

Route `<command> [args]` to its workflow and follow [Workflow Execution](#workflow-execution).

| Command | Arguments | Workflow | Purpose |
|---------|-----------|----------|---------|
| `start` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/start.md` / `workflows/start-worktree.md` | Select and prepare one work item; from a worktree, run the full session |
| `start new` | `linear\|github ...` | `workflows/start-new.md` | Create one issue, then start it |
| `handoff` | `linear\|github ...` | `workflows/handoff.md` | Launch independent sessions; no monitoring |
| `plan-issues` | `PLAN_PATH linear\|github` | `workflows/plan-issues.md` | Convert plan items into issues |
| `dev-start` | `[ISSUE_ID]` | `workflows/dev-start.md` | Delegate implementation |
| `dev-fix` | `[ISSUE_ID]` | `workflows/dev-fix.md` | Delegate fix items |
| `ci-fix` | `PR_NUMBER` \| `queue` | `workflows/ci-fix.md` | Analyze and fix CI failures |
| `review` | `[all]` \| `[last N]` \| `[HASH]` | `workflows/review.md` | On-demand review of local changes |
| `review-codebase` | `[PATH]` | `workflows/review-codebase.md` | Whole-codebase fanout, findings only |
| `review-pr` | `[PR_NUMBER]` | `workflows/review-pr.md` | Pre-submission review cycle with fixes and QA |
| `review-pr-comments` | `PR_NUMBER` \| `BRANCH` | `workflows/review-pr-comments.md` | Triage PR review comments |
| `submit-pr` | `[PR_NUMBER]` | `workflows/submit-pr.md` | Push, create PR, triage, review gate, CI, merge gates |
| `merge-pr` | `PR_NUMBER` \| `all` | `workflows/merge-pr.md` | Verify conditions and merge |
| `post-summary` | `[ISSUE_ID]` | `workflows/post-summary.md` | Post summary and handoff comments |
| `oversee` | — | `workflows/oversee.md` | Fleet mode: launch one session per unblocked item and shepherd every PR to merge |

**`start` routing.** Parse explicit args first: `github OWNER/REPO#N` → `TRACKER=github`, `ISSUE_ID=issue-N`, keep `OWNER/REPO` for the API; otherwise Linear unless the id already starts with `issue-`. A cwd whose git common dir differs from `.git` is a worktree → `workflows/start-worktree.md`; otherwise `workflows/start.md`.

## Scripts

```bash
.agents/skills/orch/scripts/<script> [args]
```

| Script | Intent |
|--------|--------|
| `workflow-state` | Persistent state read/write/append; survives compaction — see below |
| `git-context` | Git-derived values (branch, head, issue id, repo root, common root, timestamps) without inline shell plumbing |
| `pr-view-json` | PR view JSON; the expected `status=no_pr` exits 0, so workflows route to PR creation without treating it as an error |
| `resolve-base-branch` | Print a worktree's base branch; exits 1 rather than guessing |
| `base-freshness` | Gate the review cycle on a current base; an unverifiable result is treated as stale. Contract: `--help` |
| `review-artifact-check` | Validate a reviewer's on-disk JSON artifact; prints `{ok, path, reason}`. The sole reviewer completion condition. Contract: `--help` + [references/artifact-checks.md](references/artifact-checks.md) |
| `dev-return-write` | Write a dev agent's round-scoped completion artifact deterministically; never hand-author the JSON. `--help`; schema `schemas/dev-return.md` |
| `worktree-claim` | Take or verify this session's possession of an issue worktree over the session-guard lease; exits 75 when a foreign owner or lock holds it, or when the token it is bound to no longer matches the lease; a first claim takes the tree instead. `--help` |
| `dev-round-write` | Persist a fix round's delegated item set at stamp time — the on-disk source for `--expect-items-from-round` and for a respawned agent. `--help`; schema `schemas/dev-round.md` |
| `dev-artifact-check` | Validate a dev round's completion artifact by round-id identity; prints `{ok, path, reason}`. `--help` + [references/artifact-checks.md](references/artifact-checks.md) |
| `approval-wait` | Poll the reviewer gate (verdict + unresolved threads); `--resolve-mode` prints the effective gate mode. Contract: [references/gates.md](references/gates.md) |
| `ci-wait` | Block until CI completes on a PR. Contract: [references/gates.md](references/gates.md) |
| `queue-wait` | Block until a merge-queue / auto-merge outcome is decided. Contract: [references/gates.md](references/gates.md) |
| `orch-env` | Effective value of a vstack `[env]` setting (process env > `vstack.settings.toml` > default) |
| `spawn-adapter` | Resolve Codex spawn parameters (`spawn`) and the runtime thread budget (`slots`) |
| `open-terminal` | Launch-only terminal handoff; model, effort, and permission flags come from `--launch-flags`. `--help` |
| `lanes` | Enumerate harness auth lanes, their live usage, and the launches already in flight on each; `pick` prints the launch env prefix for the qualifying lane with the fewest in-flight claims, headroom breaking the tie, exit 3 when none qualifies. `--help` |
| `reconcile-work-items` | Read-only tracker sweep: parked containers (children Done, parent open), stale started items (untouched past `RECONCILE_STALE_HOURS`, PR merged or absent), Done items with unchecked `- [ ]` boxes. Exit 1 on findings, mutates nothing. |
| `oversee-watch` | Block until the fleet needs the overseer, then print one `EVENT` line: a new pr-watch attention line, a live `--item`'s PR merged, a lane window gone, a lane whose harness exited under a live window, a lane whose account hit its limit with the harness still up, a lane pane at a question prompt, a lane idle at its prompt after a round, or a heartbeat. `--help` |

The three waiters share a bounded env-first GitHub auth ladder and exit `3` on hard auth failure — [references/gates.md](references/gates.md).

**Multi-PR watching.** Never hand-roll a monitor keyed on gate-state transitions — steady states transition nothing and the session sleeps through them. When `.agents/skills/review-gate/scripts/pr-watch.sh` exists, run it as the single state reducer (oversee runs it through `oversee-watch`); otherwise per-PR `approval-wait`/`queue-wait`. Contract and fallback limits: [references/gates.md](references/gates.md).

**`workflow-state`.** Run it with no arguments for the action reference. State keys are normalized issue IDs — `issue-N` for GitHub, `PROJ-123` for Linear — never the bare GitHub number; full key rules in `schemas/workflow-state.md`.

**Review-gate modes.** Workflows read the effective gate mode (`approval`, `review`, or `off`) only through `approval-wait --resolve-mode`. Full setting semantics and waiter JSON contracts: [references/gates.md](references/gates.md).

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/workflow-state.md` | State file: identity, `child_sessions`, reviewer records, cycle counters, fixed/escalated items, PR comment tracking |
| `schemas/dev-return.md` | Dev completion artifact: round-id identity, fields, kind rules, `items[]` |
| `schemas/dev-round.md` | Delegated fix-round item set |
| [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md) | Review/QA finding JSON |

Audit-input and roadmap-plan schemas live in `project-management/schemas/`.

## Configuration

Non-secret settings go in committed `vstack.settings.toml` under `[env]`; `.env.local` holds secrets and personal overrides. Key reference: [README.md](README.md) § Configuration; review-gate keys in [references/gates.md](references/gates.md); lane keys in `lanes --help` and `open-terminal --help`.

System dependencies: `jq`; `bash` 4+; `flock` (util-linux).

## Tests

`bash skills/orch/tests/run-all.sh` (append a name fragment to filter). Each `tests/*.sh` is self-contained; the runner discovers files at execution time.

---

## Runtime Notes

> If you are running in **Codex**: a rejection saying `approval required by policy, but AskForApproval is set to Never` flags the command's SHAPE, not access — never retry it and never wait for approval; rewrite it per [references/codex-runtime.md](references/codex-runtime.md) (rejected shapes, substitutes, env-prefix normalization, the no-`git rebase` rule). Polling loops → the orch waiters `.agents/skills/orch/scripts/ci-wait`, `approval-wait`, `queue-wait` — never `github.sh` subcommands. Spawn generated agents through `scripts/spawn-adapter` with `fork_context: false`, then `send_input` a `DELEGATION:`-prefixed `<delegation_format>` — spawn, naming, and thread-cap contract in the same reference.

> If you are running in **OpenCode**: a spawned sub-agent's persistent identity is the `task_id` returned by `functions.task`. Store it in workflow state (`child_sessions[agent].agent_id`, `review_agent_ids[reviewer-name]`) and re-delegate with `functions.task(task_id=<stored_id>)`. Spawn fresh only when no ID is stored, one resume attempt failed, or the task is confirmed dead.

> If you are running in **Pi** with `pi-agents-tmux`: delegation is one `subagent` call — the child's role boundaries arrive auto-injected as its system prompt and the `task` argument is the filled `<delegation_format>` alone; prepending role text double-injects it. Store the returned `taskId` in workflow state. Pane, steering, and completion-recovery details: [references/pi-runtime.md](references/pi-runtime.md).

---

## Skill Rules

### Workflow Execution

- **Sequential sections.** Mark in-progress, execute every sub-section, mark completed, proceed. Never create tasks for sub-sections, never complete a parent before its children, never skip a step on a predicted outcome — the workflow text decides.
- **Skip-if.** Evaluate "Skip if [condition]" literally; when true, append "(SKIPPED)" and mark completed.
- **Nested workflows.** Invoke `⤵`-marked workflows through the harness mechanism, never inlined. Record the return point (`→ § X`) first.
- **Worktree scope.** Inside a worktree, never create, switch to, or act on another worktree or branch. If the resolved `ISSUE_ID` differs from the current branch, stop and ask: reuse, abort, or switch explicitly.

#### Harness-Safe Shell

**Run exactly one simple command per tool call with explicit arguments** — generated commands must survive strict harness command policies. Rejected shapes, their substitutes, env-prefix normalization, and the no-`git rebase` rule: [references/codex-runtime.md](references/codex-runtime.md).

#### Tracker Resolution

An `ISSUE_ID` starting with `issue-` is GitHub (`TRACKER=github`, issue number `${ISSUE_ID#issue-}`, repo from caller context else `gh repo view --json nameWithOwner`); anything else is Linear. A caller-supplied `tracker` wins; resolve once per workflow and store as `TRACKER`, with `ISSUE_REF` — the tracker's own issue reference, `#N` for GitHub, the Linear identifier as-is otherwise — the only form a `Closes` line renders. Steps marked **Linear only** / **GitHub only** run only for that tracker; never run `linear.sh` against a GitHub item — its state lives in `gh issue` and PR linkage (`Closes #N`).

---

### Delegation

| Pattern | When | Flow |
|---------|------|------|
| Spawn + message | Fresh dev, QA, or review agents | Spawn → send delegation |
| Message only | Re-delegation to a live agent | Send delegation to the running agent |
| Self-create | No team context | Full instructions in the prompt |

Delegated command lists are normalized per [Harness-Safe Shell](#harness-safe-shell) before entering a prompt: an env-assignment prefix never survives delegation — it becomes a precondition check plus the bare command.

**No duplicate spawns.** Never spawn a fresh agent while the same role is alive. Read workflow state, reuse by stored ID, and respawn only after one recovery attempt or a confirmed stuck/closed status. A prior completion message does not justify a duplicate.

#### Format Tags Are Literal

`<delegation_format>` and `<output_format>` define exact content: fill `[PLACEHOLDERS]`, omit lines whose placeholder is empty or not applicable, add nothing else, and keep structure, headings, and field names verbatim. Placeholders hold schema fields only — process prose inside an item record triggers a second return on idle wake-up. When a tagged block is followed by an ask-user step, present the filled block as a normal message first, then ask a concise question with options.

#### Single Return Message

An agent sends exactly one completion message. A second return is a violation: diff it against the first and flag unrequested commits. The usual root cause is process leakage in `[FORMATTED_ITEMS]` or extra delegation fields.

**Codex dual-channel completion.** On Codex collaboration agents one completion can arrive twice — a `send_input` `MESSAGE` immediately followed by a `FINAL_ANSWER` echoing the same result. That is the Codex runtime delivering one completion over two channels: treat the pair as **one completion** and deduplicate it, not a violation. Still diff the `FINAL_ANSWER` against the `MESSAGE`; a new commit, extra changes, or a different scope is a genuine second return and is flagged.

---

### Agent Lifecycle

`SPAWN → DELEGATE → WORK → RETURN (single message) → IDLE / RE-DELEGATE`.

**Dev agents persist** for the whole session and are re-delegated for review-fix, QA-fix, comment-fix, and CI-fix rounds. Shut them down only on explicit user request or a confirmed stall — quiet is not stalled, idle is not stuck.

**Reviewer persistence is budget-conditional.** Available slots = budget (`orch-env REVIEWER_SLOT_BUDGET 0`, counting the primary session; `0` = unlimited) − 1 − live `child_sessions` entries whose `status` is `active` (a record with no `status` counts as active), minimum 1; recompute at every review-cycle start. Within budget, reviewers persist across fix and re-review cycles: reuse by exact name, spawn only the missing subset. Over budget — or on the runtime's thread-limit spawn error — run bounded waves: launch up to the available slots, retire each session on its validated artifact to release the slot, and persist the observed wave size as `reviewer_slots_observed` so later cycles start in wave mode. **Invariant:** review state lives in on-disk artifacts and workflow state, never in reviewer session memory, so retiring a completed reviewer loses nothing.

QA agents spawn and shut down per agent.

#### Round Closure

The orchestrator owns round closure. A correct dev or QA agent may background a long validation and end its turn with no further wake, so every dev/QA delegation carries three mechanics:

1. **Possession and round token** — immediately before delegating: `worktree-claim --worktree [WORKTREE_PATH] --issue [ISSUE_ID]` → the delegation's `Worktree Lease:` line, with exit 75 aborting the delegation when a foreign holder has the worktree or the round's recorded lease generation no longer matches; then `workflow-state new-round-id [ISSUE_ID] dev_round_id` → the delegation's `Round ID:` line, re-stamp `dev_delegated_at`; a fix round also persists its delegated item set (`dev-round-write`) so a respawned agent reads its items from disk.
2. **Arm a single-shot wall-clock watchdog** at the same moment — one backgrounded `dev-artifact-check --wait 600 --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`): it returns the instant the artifact lands (verdict `accept`/`retry`), or at the deadline with `wait`, so round closure never depends on a return message being delivered. Run A/B on its return; re-arm only on entering a new escalation step — never an orchestrator poll loop. Harness mechanisms: [references/artifact-checks.md](references/artifact-checks.md).
3. **Run the check on every wake and at the deadline** — never classify from wording or elapsed time, and a `finished`/`idle` wake is not evidence. `dev-artifact-check --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`) prints `verdict`; act on it.

The acceptance decision table lives in the delegating workflow (`dev-start.md` § 3, `dev-fix.md` § 2, `review-pr-comments.md` § 6.1); the return message is display-only, and tracker corroboration (**B**) applies only where that table names it. A path whose agent writes no dev-return artifact (`ci-fix.md`) is accepted by its return message plus the escalation ladder, never by a stale artifact. Dev-vs-reviewer asymmetry and invalid stall signals: [references/artifact-checks.md](references/artifact-checks.md).

**Escalation.** Only after the 10-minute quiet window AND a confirmed stall (task status unchanged across idle cycles, no session-log entries for 10+ minutes, or the agent process exited): re-message once naming the missing step → wait 5 minutes → new activity means go idle; still inactive means shut down, re-create tasks, respawn, re-delegate.

---

### State Management

Durable data — issue tracking, agent persistence, cycle counts, fix and escalation records, audit trails — lives in workflow state through the `workflow-state` CLI only, including `set-git-head` and `set-now` instead of inline command substitution. Location: `<state-dir>/workflow-state-[ID].json`, where `<state-dir>` is the `--state-dir` flag, then `$ORCH_STATE_DIR`, then `tmp/`.

After compaction, resume from the step after the last completed one: read workflow state for team name, cycles, and agent IDs, re-send delegations using stored IDs, and respawn only an agent that stays silent through one idle cycle. Never repeat completed actions.

---

### Coordination

**Containers.** An issue with children or an `agent:multi` label and no `(one PR)` title marker is a CONTAINER; the marker always wins. A container is never orchestrated and never gets a PR — each child is the PR unit, selection operates on unblocked children, and the container closes LAST when its final child merges. It holds no worktree, branch, or workflow state beyond bookkeeping.

**Ancestor gate.** Every directly selected issue walks its full `parent_id` chain — one hop is never enough. An enclosing `(one PR)` bundle becomes the work item; promotion REPLACES the selection, and the superseded child id never proceeds. Dispatch requires the item's own `state_type` non-terminal AND the union of its `blocked_by` with every container ancestor's resolving terminal. Fetch blocker states in chunks of at most 50 ids, verify every requested id came back, and keep the item blocked on a missing lookup — never fail open on a truncated read. Entry workflows (start, start-worktree, handoff, dev-start) carry the per-workflow mechanics.

**Sequencing.** Order by data flow (Creates ↔ Consumes), never by agent ordering; existing blocking relations on the issues outrank inference. Cross-bundle relations go on the parent issues; dependent children of one container get sibling child-blocks-child relations, which ARE the execution order; only an explicit `(one PR)` bundle leaves intra-bundle ordering to the delegated session.

**Single-PR bundles.** Exactly three opt-ins delegate all children as one session: a parent marked `(one PR)`, a delegation carrying `Audit Bundle: yes`, or a leaf issue with an internal checklist. One composite task per sub-issue, not one per section; multi-domain bundles process groups sequentially, collecting handoff notes between groups.

**Tracked issue creation.** Route every tracked issue through TPM (project-management), which owns labels, project, priority, estimate, and relations — never create one directly from an orchestration session. A direct create prints a URL that looks like success while the issue lands with none of those, and without an `agent:*` label it is invisible to agent routing. The only direct creates are the ones a workflow step specifies with its label set (`plan-issues`, `start-new`, the `merge-pr` rebundle).

---

### Review Pipeline

**Finding schema.** [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md) is the contract, enforced by `review-artifact-check`. Routing reads `verdict` (`action_required` when blockers exist, else `pass`) and each suggestion's `category` ∈ {`fix`, `issue`}.

**Disposition.** Classify each suggestion per [references/finding-disposition.md](references/finding-disposition.md): apply in-PR, file as a tracked issue, or decline with one line. Filing is the exception — the filing bar lives there.

**Issue audit pipeline.** Every follow-up that clears the filing bar — `category=issue` suggestions, escalated blockers, dev "deliberately left out" lists, gaps noticed in reports or code — is collected, transformed into audit input (schema in `project-management/schemas/`), and delegated to TPM for creation, with dependency fields populated when order is known. Never file directly.
