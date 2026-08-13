---
name: orch
description: "PRIMARY AGENT ONLY — single work-item orchestration for Linear or GitHub issues: prepare, delegate implementation, review, submit, merge, and hand off."
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
- **Ask the user only about product or experience.** Every technical choice is settled by rule here or by the specialist who owns it. Merge, scope expansion beyond the issue, and revisiting a recorded decision always ask, whatever `ORCH_DECISION_MODE` says.
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

**`start` routing.** Parse explicit args first: `github OWNER/REPO#N` → `TRACKER=github`, `ISSUE_ID=issue-N`, keep `OWNER/REPO` for the API; otherwise Linear unless the id already starts with `issue-`. A cwd whose git common dir differs from `.git` is a worktree → `workflows/start-worktree.md`; otherwise `workflows/start.md`.

Finding disposition (fix vs issue vs decline) lives in [references/finding-disposition.md](references/finding-disposition.md).

## Scripts

```bash
.agents/skills/orch/scripts/<script> [args]
```

| Script | Intent |
|--------|--------|
| `workflow-state` | Persistent state read/write/append; survives compaction — see below |
| `git-context` | Git-derived values (branch, head, issue id, repo root, common root, timestamps) without inline shell plumbing |
| `pr-view-json` | PR view JSON; the expected `status=no_pr` exits 0 so workflows route to PR creation without a shell fallback |
| `resolve-base-branch` | Print a worktree's base branch (`WORKTREE_DEFAULT_BRANCH`, remote HEAD, then `main`); exits 1 rather than guessing for a missing path or a non-work-tree |
| `base-freshness` | Gate the review cycle on a current base: exit 0 fresh, 4 stale (rebase with `worktree create <ID> --reuse`), 1 unverifiable — treat as stale. Contract: `--help` |
| `review-artifact-check` | Validate a reviewer's on-disk JSON artifact; prints `{ok, path, reason}`. The sole reviewer completion condition. Contract: `--help` + [references/artifact-checks.md](references/artifact-checks.md) |
| `dev-return-write` | Write a dev agent's round-scoped completion artifact deterministically; never hand-author the JSON. `--help`; schema `schemas/dev-return.md` |
| `dev-round-write` | Persist a fix round's delegated item set at stamp time — the on-disk source for `--expect-items-from-round` and for a respawned agent. `--help`; schema `schemas/dev-round.md` |
| `dev-artifact-check` | Validate a dev round's completion artifact by round-id identity; prints `{ok, path, reason}`. `--help` + [references/artifact-checks.md](references/artifact-checks.md) |
| `approval-wait` | Poll the reviewer gate (verdict + unresolved threads); `--resolve-mode` prints the effective gate mode. Contract: [references/gates.md](references/gates.md) |
| `ci-wait` | Block until CI completes on a PR. Contract: [references/gates.md](references/gates.md) |
| `queue-wait` | Block until a merge-queue / auto-merge outcome is decided. Contract: [references/gates.md](references/gates.md) |
| `orch-env` | Effective value of a vstack `[env]` setting (process env > `vstack.settings.toml` > default) |
| `spawn-adapter` | Resolve Codex spawn parameters (`spawn`) and the runtime thread budget (`slots`) |
| `open-terminal` | Launch-only terminal handoff. Model, effort, and permission flags come from `--launch-flags`, chosen per task at launch. `--help` |
| `lanes` | Enumerate harness auth lanes and their live usage; `pick` prints the launch env prefix for the lane with the most headroom, exit 3 when none qualifies. Headroom is the binding window, never an average |

The three waiters share a bounded env-first GitHub auth ladder and exit `3` on hard auth failure — [references/gates.md](references/gates.md).

**Multi-PR watching.** The waiters are single-PR foreground waits. To watch many PRs, never hand-roll a monitor keyed on gate-state transitions — steady states transition nothing and the session sleeps through them. When `.agents/skills/review-gate/scripts/pr-watch.sh` exists, run it as the single state reducer; otherwise fall back to per-PR `approval-wait`/`queue-wait`. Contract and fallback limits: [references/gates.md](references/gates.md).

**`workflow-state`.** Run it with no arguments for the full action reference. From a worktree, pass the global `--state-dir <path>` flag before the subcommand. State keys are normalized issue IDs — `issue-N` for GitHub, `PROJ-123` for Linear — never the bare GitHub number; every action except `init` aliases a bare numeric key to the `issue-N` file when only that file exists, and exits 2 rather than guessing when both exist.

**Review-gate modes.** `approval-wait --resolve-mode` prints the project's effective mode; workflows read it only through that. The engine's `REVIEW_GATE_MODE=off` resolves first; otherwise `PR_REVIEW_GATE` selects `approval` (GitHub-native approval verdict), `review` (non-author review of the current head plus zero unresolved threads — for commenting-only bots), or `off` (reviewer-less repo). Default `approval`. Full setting semantics and waiter JSON contracts: [references/gates.md](references/gates.md).

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/workflow-state.md` | State file: identity, `child_sessions`, reviewer records, cycle counters, fixed/escalated items, PR comment tracking |
| `schemas/dev-return.md` | Dev completion artifact: round-id identity, fields, kind rules, `items[]` |
| `schemas/dev-round.md` | Delegated fix-round item set |
| [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md) | Review/QA finding JSON |

Audit-input and roadmap-plan schemas live in `project-management/schemas/`.

## Configuration

Non-secret settings go in committed `vstack.settings.toml` under `[env]`; `.env.local` holds secrets and personal overrides.

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORCH_STATE_DIR` | State-file directory (the `--state-dir` flag wins when both are set) | `tmp` |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names (matched case-insensitively, then canonicalized: `issue-N` lowercase, Linear-style uppercase) | `[A-Z]+-[0-9]+` |
| `CI_FIX_MAX_CYCLES` | Max automated ci-fix cycles per PR submission or merge recovery | `6` |
| `REVIEWER_SLOT_BUDGET` | The runtime's total concurrent agent-session budget, counting the primary session; `0` = unlimited. On Codex, set it to the cap `spawn-adapter slots` reports | `0` |
| `ORCH_DECISION_MODE` | `ask` presents every workflow decision; `auto-recommended` executes the recommended option and logs `auto-selected: [option] — [reason]` in workflow-state `auto_decisions`. The always-ask set in [The Cycle](#the-cycle) applies in every mode | `ask` |
| Review-gate settings | `REVIEW_GATE_MODE`, `PR_REVIEW_GATE`, `PR_REVIEW_CHECK`, `PR_REVIEW_ON_TIMEOUT`, `PR_REVIEW_NUDGE*`, `PR_REVIEW_WAIT_SECS` — [references/gates.md](references/gates.md) | — |
| Lane settings | `ORCH_LANE_DIRS`, `ORCH_LANE_ALIASES`, `ORCH_LANE_MAX_PCT`, `ORCH_TMUX_VERIFY_SECS` — `lanes --help`, `open-terminal --help` | — |

System dependencies: `jq`; `bash` 4+; `flock` (util-linux).

## Tests

`bash skills/orch/tests/run-all.sh` (append a name fragment to filter). Each `tests/*.sh` is self-contained; the runner discovers files at execution time.

---

## Runtime Notes

> If you are running in **Claude Code**: create a team before launching agents so agents share state and can be re-delegated. Task creation *and* assignment both wake a live agent — for a fresh spawn create tasks first, and for re-delegation send the delegation message BEFORE creating and assigning the task, or the agent starts from the bare `task_assignment` payload without it. Ask questions with `AskUserQuestion`. `SendMessage` accepts exactly `to`, `summary`, `message`; extra fields have caused duplicate delivery.

> If you are running in **Codex**: under `approval_policy = never` the CLI rejects shell CONTROL SYNTAX — loops, multi-command blocks, env prefixes, substitution (a literal backtick counts), redirection — with `approval required by policy, but AskForApproval is set to Never`. The *shape* was flagged, not access: never retry it and never wait for approval; rewrite as one simple command per tool call.
>
> - Polling loops → the orch waiters `.agents/skills/orch/scripts/ci-wait` (CI status), `.agents/skills/orch/scripts/approval-wait` (review approval), `.agents/skills/orch/scripts/queue-wait` (merge-queue / auto-merge outcome) — orch scripts, never `github.sh` subcommands.
> - Rejected top-level `git rebase` → the worktree skill's guarded `create <ID> --reuse --replay` with `worktree restack continue|skip|abort` (worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback)); never an improvised force-push.
> - Spawn generated agents with `fork_context: false`; resolve parameters with `scripts/spawn-adapter spawn <canonical-agent-name>`. Pass the canonical hyphenated name — it is the identity everywhere orch records anything, and the adapter confines the runtime spelling to `record.runtime_metadata`. `--fallback-reason` is for a deliberate generic-worker fallback, never one a name-schema rejection caused. Spawn with `<bootstrap_format>`, then `send_input` a `DELEGATION:`-prefixed `<delegation_format>`.
> - Thread cap: `scripts/spawn-adapter slots` prints the effective cap and the `REVIEWER_SLOT_BUDGET` it implies, warning when only the legacy key is set (silently ignored, so raising it alone changes nothing) and noting that a running session keeps its old cap until restarted. Set the reported budget in `vstack.settings.toml` `[env]`.
>
> Full shape catalogue, rewrite patterns, and the Codex Desktop app-handoff contract: [references/codex-runtime.md](references/codex-runtime.md).

> If you are running in **OpenCode**: a spawned sub-agent's persistent identity is the `task_id` returned by `functions.task`. Store it in workflow state (`child_sessions[agent].agent_id`, `review_agent_ids[reviewer-name]`) and re-delegate with `functions.task(task_id=<stored_id>)`. Spawn fresh only when no ID is stored, one resume attempt failed, or the task is confirmed dead.

> If you are running in **Pi** with `pi-agents-tmux`: delegation is one `subagent` call — the bootstrap is auto-injected as the child's system prompt and the `task` argument is the filled `<delegation_format>` alone; prepending the bootstrap double-injects the role boundaries. Store the returned `taskId` in workflow state. Pane, steering, and completion-recovery details: [references/pi-runtime.md](references/pi-runtime.md).

---

## Skill Rules

### Workflow Execution

- **Sequential sections.** Mark in-progress, execute every sub-section, mark completed, proceed. Never create tasks for sub-sections, never complete a parent before its children, never skip a step on a predicted outcome — the workflow text decides.
- **Skip-if.** Evaluate "Skip if [condition]" literally; when true, append "(SKIPPED)" and mark completed.
- **Nested workflows.** Invoke `⤵`-marked workflows through the harness mechanism, never inlined. Record the return point (`→ § X`) first.
- **Worktree scope.** Inside a worktree, never create, switch to, or act on another worktree or branch. If the resolved `ISSUE_ID` differs from the current branch, stop and ask: reuse, abort, or switch explicitly.

#### Harness-Safe Shell

Generated commands must survive strict harness command policies. **Run exactly one simple command per tool call with explicit arguments.** Inline `$(...)`, `for`/`while` loops, array building, heredocs, value-plumbing pipelines, redirected writes, and multi-command blocks are all rejected shapes. Fold related `workflow-state` reads into one `get '{...}'` and writes into one `update '... | ...'`; use `git-context` for derived values and harness file tools or `apply_patch` for file bodies. Three rules reach every generated command list — dev validation steps, delegated audit searches, fix recommendations:

- **Env-assignment prefixes are normalized at acceptance, not at run time**: confirm the ambient environment satisfies the precondition (`printenv VAR`; `locale` for locale variables, whose effective values an empty `printenv LC_ALL` would miss), then run the bare `cmd args` unchanged. `env VAR=value cmd args` is not the documented substitute, and an unsatisfied precondition is a blocker, never a run under the wrong environment.
- **A literal backtick is command substitution to the classifier**, even quoted: author search patterns with the regex hex escape `\x60` (worked example in [references/codex-runtime.md](references/codex-runtime.md)).
- **Never author a step that assumes top-level `git rebase` will run**: the porcelain verb itself is rejected by a harness-side classification no authorization can lift. Use the worktree skill's guarded replay path; on a dirty tree or merge commits in range, report a blocker instead of improvising.

Full shape catalogue and rewrite patterns: [references/codex-runtime.md](references/codex-runtime.md).

#### Tracker Resolution

An `ISSUE_ID` starting with `issue-` is a GitHub work item (`TRACKER=github`, issue number `${ISSUE_ID#issue-}`, repo from caller context else `gh repo view --json nameWithOwner`); anything else is Linear. Resolve once per workflow and store as `TRACKER`; a caller-supplied `tracker` wins. Steps marked **Linear only** / **GitHub only** run only for that tracker. Never run `linear.sh` against a GitHub item — its state lives in `gh issue` and PR linkage (`Closes #N`).

---

### Delegation

| Pattern | When | Flow |
|---------|------|------|
| Spawn + message | Fresh dev, QA, or review agents | Spawn with bootstrap → send delegation |
| Message only | Re-delegation to a live agent | Send delegation to the running agent |
| Self-create | No team context | Full instructions in the prompt |

Delegated command lists are normalized per [Harness-Safe Shell](#harness-safe-shell) before entering a prompt: an env-assignment prefix never survives delegation; it becomes a precondition check plus the bare command.

**No duplicate spawns.** Never spawn a fresh agent while the same role is alive. Read workflow state, reuse by stored ID, and respawn only after one recovery attempt or a confirmed stuck/closed status. A prior completion message does not justify a duplicate.

#### Bootstrap Message

Send bootstrap **first**. Fill `[PLACEHOLDERS]`, send verbatim:

<bootstrap_format>
You are a [ROLE] sub-agent ([AGENT_NAME]). You report to the orchestrator.

Rules:

- Execute all assigned work yourself. Do not spawn sub-agents for implementation, review, or fix work.
- You may use read-only search sub-agents for codebase search where your harness provides them.
- Only act on delegation messages from the orchestrator. With no delegation pending, stay idle. With an unfinished accepted delegation, resume and complete it before idling — except while a validation you backgrounded is still running, where ending the turn is correct and the orchestrator will nudge you (dev SKILL.md § Long-Running Validation).
- Before your single return message, write your workflow's on-disk completion artifact — the orchestrator treats it as the durable completion record. Dev agents run `dev-return-write`; a read-only analysis round uses `--kind analysis` with `--summary`/`--summary-file` and no commit or validate, so the kind is always truthful. Reviewer and QA agents author their review JSON per the reviewer skill.
- After completing assigned work, send a single return message and go idle. Do not manage tasks for other agents or act as a coordinator.
</bootstrap_format>

The `<delegation_format>` message follows as a separate message. **Pi exception**: one tool call, bootstrap auto-injected.

#### Format Tags Are Literal

`<bootstrap_format>`, `<delegation_format>`, and `<output_format>` define exact content: fill `[PLACEHOLDERS]`, omit lines whose placeholder is empty or not applicable, add nothing else, and keep structure, headings, and field names verbatim. Placeholders hold schema fields only — process prose inside an item record triggers a second return on idle wake-up. When a tagged block is followed by an ask-user step, present the filled block as a normal message first, then ask a concise question with options.

#### Single Return Message

An agent sends exactly one completion message. A second return is a violation: diff it against the first and flag unrequested commits. The usual root cause is process leakage in `[FORMATTED_ITEMS]` or extra delegation fields.

**Codex dual-channel completion.** On Codex collaboration agents one completion can arrive twice — a `send_input` `MESSAGE` immediately followed by a `FINAL_ANSWER` echoing the same result. That is the Codex runtime delivering one completion over two channels: treat the pair as **one completion** and deduplicate it, not a violation. Still diff the `FINAL_ANSWER` against the `MESSAGE`; a new commit, extra changes, or a different scope is a genuine second return and is flagged.

---

### Agent Lifecycle

`SPAWN (bootstrap) → DELEGATE → WORK → RETURN (single message) → IDLE / RE-DELEGATE`.

**Dev agents persist** for the whole session and are re-delegated for review-fix, QA-fix, comment-fix, and CI-fix rounds. Shut them down only on explicit user request or a confirmed stall — quiet is not stalled, idle is not stuck.

**Reviewer persistence is budget-conditional.** `orch-env REVIEWER_SLOT_BUDGET 0` prints the runtime's budget counting the primary session (`0` = unlimited). Available reviewer slots = budget − 1 − live `child_sessions` entries whose `status` is `active` (a record with no `status` counts as active), minimum 1; recompute at every review-cycle start. Within budget, reviewers persist across fix and re-review cycles: reuse by exact name and spawn only the missing subset. Over budget — or when a spawn fails with the runtime's thread-limit error — run bounded waves: launch up to the available slots, wait for each validated artifact, retire the completed session to release its slot, launch the next wave, and persist the observed wave size as `reviewer_slots_observed` so later cycles start in wave mode. **Invariant:** review state lives in on-disk artifacts and workflow state, never in reviewer session memory, so retiring a completed reviewer loses nothing and a recreated one is pointed at the current diff plus its prior report.

QA agents spawn and shut down per agent.

#### Round Closure

The orchestrator owns round closure. A correct dev or QA agent may background a long validation and end its turn with no further wake, so every dev/QA delegation carries three mechanics:

1. **Mint and embed a round token** immediately before delegating (`workflow-state new-round-id [ISSUE_ID] dev_round_id` → the delegation's `Round ID:` line) and re-stamp `dev_delegated_at`. A fix round also persists its delegated item set at that moment (`dev-round-write`), so a respawned agent reads its items from disk instead of guessing.
2. **Arm a single-shot wall-clock watchdog** for `dev_delegated_at + 10 min` at the same moment, so the check runs even if no wake ever arrives. It fires once, runs A/B if the round is still outstanding, and re-arms only on entering a new escalation step — never a busy poll. Harness mechanisms: [references/artifact-checks.md](references/artifact-checks.md).
3. **Run A/B on every wake and at the deadline**, classifying mechanically rather than from wording or elapsed time. **A** = `dev-artifact-check --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (fix rounds add `--expect-items-from-round`); **B** = the round's git and tracker completion checks. A `finished` or `idle` wake is not evidence.

The acceptance decision table lives in the delegating workflow (`dev-start.md` § 3, `dev-fix.md` § 2, `review-pr-comments.md` § 6.1) and is a pure function of A and B; the return message is display-only. The round token binds A to exactly this delegation's receipt. A path whose agent writes no dev-return artifact (`ci-fix.md`) is accepted by its return message plus the escalation ladder, never by a stale artifact. Dev-vs-reviewer asymmetry and invalid stall signals: [references/artifact-checks.md](references/artifact-checks.md).

**Escalation.** Only after the 10-minute quiet window AND a confirmed stall (task status unchanged across idle cycles, no session-log entries for 10+ minutes, or the agent process exited): re-message once naming the missing step → wait 5 minutes → new activity means go idle, still inactive means shut down, re-create tasks, respawn, re-delegate.

---

### State Management

Durable data — issue tracking, agent persistence, cycle counts, fix and escalation records, audit trails — lives in workflow state through the `workflow-state` CLI only, including `set-git-head` and `set-now` instead of inline command substitution. Location: `<state-dir>/workflow-state-[ID].json`, where `<state-dir>` is the `--state-dir` flag, then `$ORCH_STATE_DIR`, then `tmp/`.

After compaction, resume from the step after the last completed one: read workflow state for team name, cycles, and agent IDs, re-send delegations using stored IDs, and respawn only an agent that stays silent through one idle cycle. Never repeat completed actions.

---

### Coordination

**Containers.** A parent with children is a CONTAINER by default: no `(one PR)` title marker, and children present or an `agent:multi` label. The `(one PR)` marker always wins and opts even an `agent:multi` bundle into single-PR delegation. A container is never orchestrated and never gets a PR — each child is the PR unit, selection operates on unblocked children, and the container closes LAST when its final child merges. Containers hold no implementation state: no worktree, no branch, no workflow-state beyond bookkeeping.

**Ancestor gate.** Every directly selected issue walks its full `parent_id` chain and classifies each ancestor. An enclosing `(one PR)` bundle becomes the work item — the child only on explicit user choice — and promotion REPLACES the selection: continue as the bundle or stop and route to its worktree; the superseded child id never proceeds. The selected item dispatches only when its own `state_type` is non-terminal AND the union of its `blocked_by` with every container ancestor's resolves terminal. Fetch blocker states in chunks of at most 50 ids (`issues bulk-get` caps at 50 rows), verify every requested id came back, and keep an item blocked on a missing lookup — never fail open on a truncated read. One hop is never enough. Entry workflows (start, start-worktree, handoff, dev-start) carry the mechanics.

**Sequencing.** Infer the agent from the label or component path, then confirm with Creates ↔ Consumes: no data flow, no blocking relation, whatever the agent ordering suggests. Existing blocking relations on the issues outrank inference. Cross-bundle relations go on the parent issues; dependent children of one container get sibling child-blocks-child relations, which ARE the execution order since selection dispatches only unblocked children. Only an explicit `(one PR)` bundle leaves intra-bundle ordering to the delegated session.

**Single-PR bundles.** Only a parent marked `(one PR)`, a delegation carrying `Audit Bundle: yes` (review-pr's post-audit children, worked inside this PR's session), or a leaf issue with an internal checklist, is delegated as one session covering all children. One composite task per sub-issue, not one per section. Multi-domain bundles process groups sequentially, collecting handoff notes between groups.

**Tracked issue creation.** Never create a tracked issue directly from an orchestration session — route it through TPM (project-management), which owns labels, project, priority, estimate, and relations. A direct create prints a URL and looks like success while the issue lands with none of those, and without an `agent:*` label it is invisible to agent routing. The only direct creates are the ones a workflow step specifies with its label set (`plan-issues`, `start-new`, the `merge-pr` rebundle).

---

### Review Pipeline

**Finding schema.** [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md) is the contract; `review-artifact-check` enforces it. Routing reads `verdict` (`action_required` when blockers exist, else `pass`) and each suggestion's `category` ∈ {`fix`, `issue`}.

**Disposition.** Classify each suggestion per [references/finding-disposition.md](references/finding-disposition.md): apply in-PR, file as a tracked issue, or decline with one line. Filing is the exception — see the filing bar there.

**Issue audit pipeline.** Every follow-up that clears the filing bar goes through this pipeline however it was discovered — `category=issue` suggestions, escalated blockers, dev "deliberately left out" lists, and gaps noticed while reading reports or code. Collect them, transform into audit input (schema in `project-management/schemas/`), and delegate to TPM for creation, populating dependency fields when order is known. Never file them directly.
