---
name: orch
description: "PRIMARY AGENT ONLY — single work-item orchestration for Linear or GitHub issues: prepare, delegate implementation, review, submit, merge, and handoff."
license: MIT
user-invocable: true
dependencies:
  required: [github, worktree, dev, project-management, decider]
  optional: [linear]
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "2.0.0"
---

# Orchestration

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

## STOP — Required Setup

Load IN ORDER before anything else; do not proceed if any fails: 1. `github`. 2. `worktree`. 3. Tracker — Linear issue → load `linear`; GitHub issue → use `github` only.

> **MODE SWITCH**: Loading this skill puts you in **orchestrator mode**. Do not write code yourself. Delegate all implementation, review, and QA work to specialist sub-agents using the workflows in this skill.

> If you are running in **Claude Code**: Always create a team before launching agents; spawn and delegate within the team context so agents share state and can be messaged for re-delegation. Task creation and assignment notifications wake a live agent immediately — assignment is a wake, not only spawn-time creation. Fresh spawn: create tasks before spawning, so they exist before the agent does. Re-delegation to a live agent: send the delegation message before creating and assigning the task — an agent woken by the assignment alone starts from the bare `task_assignment` payload without the delegation. Ask questions with the `AskUserQuestion` tool. `SendMessage` accepts exactly `to`, `summary`, `message` — extra fields have caused duplicate delivery on idle wake-up.

> If you are running in **Codex**: Under `approval_policy = never` the CLI classifies shell CONTROL SYNTAX — loops, multi-command blocks, env-assignment prefixes, substitution (a literal backtick counts), redirection — as approval-required regardless of the inner commands, rejecting the shape with `approval required by policy, but AskForApproval is set to Never`. That error means the command *shape* was flagged, not access: do not retry the same shape and do not wait for approval (none can arrive) — rewrite as one simple command per tool call. Replace polling loops with the orch waiters `.agents/skills/orch/scripts/ci-wait` (CI status), `.agents/skills/orch/scripts/approval-wait` (review approval), and `.agents/skills/orch/scripts/queue-wait` (merge-queue / auto-merge outcome) — orch scripts, never `github.sh` subcommands. A policy-rejected top-level `git rebase` has a documented replacement: the worktree skill's guarded `create <ID> --reuse --replay` path with `worktree restack continue|skip|abort` controls (worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback)) — never an improvised force-push. Authoring rules: [§ Harness-Safe Shell](#harness-safe-shell); full shape catalogue and rewrite patterns: [references/codex-runtime.md](references/codex-runtime.md).
>
> Spawn generated vstack agents with `fork_context: false`. **Resolve the spawn parameters with `scripts/spawn-adapter spawn <canonical-agent-name>`** — it returns `agent_type`, the runtime `task_name`, and the exact record shape as one JSON object. Pass the canonical hyphenated name (`reviewer-arch`); the adapter refuses an already-translated one. **The canonical name is the identity everywhere orch records anything** — workflow-state keys, report artifacts, delegation records; the adapter confines the runtime spelling to `record.runtime_metadata`. Use `--fallback-reason TEXT` only for a deliberate generic-worker fallback; a name-schema rejection is never one. Two-step pattern: (1) spawn the runtime agent with the `<bootstrap_format>` message, (2) `send_input` a `DELEGATION:` prefixed message containing exactly the filled `<delegation_format>` content — nothing more.
>
> The Codex collaboration runtime caps concurrent agent threads, counting this primary session; a spawn beyond it fails with `collab spawn failed: agent thread limit reached`. **Run `scripts/spawn-adapter slots` for the effective cap and the `REVIEWER_SLOT_BUDGET` it implies** — it reads the authoritative config key, warns when only the legacy one is set (that key is silently ignored, so raising it alone changes nothing), and notes that a running session keeps its old cap until restarted. Set the reported budget in `vstack.settings.toml` `[env]` so review workflows run reviewers in bounded waves when the set does not fit — see [Review Agent Lifecycle Management](#review-agent-lifecycle-management). If the budget is left at `0` (unlimited) and a spawn hits the limit anyway, review workflows demote the cycle to bounded waves automatically (`review-pr.md` § 2.2).
>
> For **Codex Desktop app handoff**, invoke `workflows/handoff.md` with `harness=codex-app` — the default when `handoff` receives multiple issues and the runtime exposes Codex app thread tools. The full contract (agent preflight and warning acceptance, branch starting state, thread creation) is in [references/codex-runtime.md](references/codex-runtime.md). The Codex CLI does not expose these tools; never emulate app handoff from the terminal.

> If you are running in **OpenCode**: The persistent identity of a spawned sub-agent is the `task_id` returned by `functions.task`. On first spawn, store it in workflow state (`child_sessions[agent].agent_id` for dev/QA, `review_agent_ids[reviewer-name]` for reviewers). On re-delegation, call `functions.task(task_id=<stored_id>)` — never spawn a fresh task when a stored ID exists. Fresh spawn only if: no stored ID, one resume attempt fails, or the prior task is confirmed dead.

> If you are running in **Pi** with `pi-agents-tmux`: delegation is **one `subagent` tool call** — the bootstrap is auto-injected as the child's compiled system prompt, and the `task` argument is the filled `<delegation_format>` content alone; never prepend the bootstrap block (it double-injects the role boundaries). Pane agents (`pane: true`) live in a persistent tmux pane reused on every redelegation; bg agents are one-shot unless a `sessionKey` pins a resumable session. Store the returned `taskId` in workflow state (`child_sessions[agent].agent_id` / `review_agent_ids[...]`). Steering, completion recovery, and notification dedupe: [references/pi-runtime.md](references/pi-runtime.md). Persistent `researcher` panes follow the same rules as other project agents.

> Research issues (`research` label) are executed by `agent:researcher`, not by external human sessions. The researcher may run Exa deep research and write findings docs, but must not modify production code; require exactly one completion message after `findings.md` exists.

## Commands

When invoked with `<command> [args]`, route to the corresponding workflow. Follow ALL [Workflow Execution](#workflow-execution) rules for every command.

| Command | Arguments | Workflow | Purpose |
|---------|-----------|----------|---------|
| `start` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/start.md` / `workflows/start-worktree.md` | Select/prepare one work item; from a worktree, the full session: dev → review → submit → finalize |
| `start new` | `linear|github ...` | `workflows/start-new.md` | Create one issue then start it |
| `handoff` | `linear|github ...` | `workflows/handoff.md` | Launch-only handoff; no monitoring; Codex Desktop creates one app thread per issue |
| `plan-issues` | `PLAN_PATH linear|github` | `workflows/plan-issues.md` | Convert plan items into issues |
| `parallel-check` | `[ISSUE_IDS]` | `workflows/parallel-check.md` | Safe parallel handoff analysis |
| `initialize` | `[ISSUE_ID]` | `workflows/initialize.md` | Team setup, auth, cache, state (standalone) |
| `dev-start` | `[ISSUE_ID]` | `workflows/dev-start.md` | Delegate implementation to specialist agents |
| `dev-fix` | `[ISSUE_ID]` | `workflows/dev-fix.md` | Delegate review fix items to dev agents |
| `ci-fix` | `PR_NUMBER` \| `queue` | `workflows/ci-fix.md` | Analyze and fix CI failures |
| `review` | `[all]` \| `[last N]` \| `[HASH]` | `workflows/review.md` | On-demand review with fix handling (standalone) |
| `review-codebase` | `[PATH]` | `workflows/review-codebase.md` | Whole-codebase reviewer fanout, findings only |
| `review-pr` | `[PR_NUMBER]` | `workflows/review-pr.md` | Pre-submission review with fix handling and QA |
| `review-pr-comments` | `PR_NUMBER` \| `BRANCH` | `workflows/review-pr-comments.md` | Triage PR review comments via domain agents |
| `submit-pr` | `[PR_NUMBER]` | `workflows/submit-pr.md` | Local review, push, create PR, async triage, review gate before CI verify, merge gates |
| `merge-pr` | `PR_NUMBER` \| `all` | `workflows/merge-pr.md` | Verify conditions and merge PR(s) |
| `fix-reconcile` | — | `workflows/fix-reconcile.md` | Check fixes against open issues (internal; not user-invocable) |
| `post-summary` | `[ISSUE_ID]` | `workflows/post-summary.md` | Post summary and handoff comments |

**`start` routing:** parse explicit args first — `github OWNER/REPO#N` → `TRACKER=github`, `ISSUE_ID=issue-N`, `OWNER/REPO` retained for GitHub API calls; otherwise Linear unless the ID already starts with `issue-`. Current directory a worktree (git common dir differs from `.git`) → `workflows/start-worktree.md` with the parsed issue context; otherwise → `workflows/start.md`.

Reference workflows (no command): `workflows/agent-sequencing.md` — cross-domain blocking relations and delegation order; `workflows/recommendation-bias.md` — review finding categorization (fix vs issue).

## Scripts

```bash
.agents/skills/orch/scripts/<script> [args]
```

| Script | Intent |
|--------|--------|
| `workflow-state` | Persistent state read/write/append, survives compaction — see below |
| `git-context` | Git-derived workflow values (branch, head SHA, issue id, repo root, timestamps) without inline shell plumbing |
| `pr-view-json` | PR view JSON; expected `status=no_pr` exits 0 so workflows route to PR creation without shell fallbacks |
| `resolve-base-branch` | Print the worktree base branch (`WORKTREE_DEFAULT_BRANCH`, remote HEAD, or `main`) |
| `base-freshness` | Gate the review cycle on a current base — exit 0 fresh, 4 stale (rebase via `worktree create <ID> --reuse` first), 1 unverifiable (treat as stale); the `start-worktree.md` § 1 gate. Contract: `--help` |
| `review-init` | Initialize standalone review context; prints branch/worktree/issue/state JSON |
| `review-artifact-check` | Validate a reviewer's on-disk JSON artifact; prints `{ok, path, reason}` — the sole review-pr completion condition. Contract: `--help` + [references/artifact-checks.md](references/artifact-checks.md) |
| `dev-return-write` | Write a dev agent's round-scoped completion artifact deterministically; never hand-author the JSON. Flags: `--help`; schema: `schemas/dev-return.md` |
| `dev-artifact-check` | Validate a dev round's completion artifact by round-id identity; prints `{ok, path, reason}`. Contract: `--help` + [references/artifact-checks.md](references/artifact-checks.md) |
| `tracker-for-issue` | Print `github` for `issue-*` ids and `linear` otherwise |
| `approval-wait` | Poll the reviewer gate (verdict + unresolved threads); `--resolve-mode` prints the effective gate mode. Contract: [references/gates.md](references/gates.md) |
| `ci-wait` | Block until CI completes on a PR — runs after the review gate. Contract: [references/gates.md](references/gates.md) |
| `queue-wait` | Block until a PR's merge-queue / auto-merge outcome is decided — the merge-pr § 3.2 queue watch. Contract: [references/gates.md](references/gates.md) |
| `orch-env` | Effective value of a vstack `[env]` setting (process env > `vstack.settings.toml` > supplied default) |
| `refix-route` | Decide whether a fix round needs re-review; prints `{decision, class, reason, …}`. Route on `class`, never on `scope` alone (`review-pr` § 4 / § 7 / § 10) |
| `session-init` | Initialize session state for a new worktree (called by `initialize.md`) |
| `spawn-adapter` | Resolve Codex spawn parameters (`spawn`) and the runtime thread budget (`slots`) — see the Codex runtime notes above |
| `open-terminal` | Launch-only terminal handoff for Linear/GitHub worktrees; `--lane auto[:<harness>]` picks the account with the most headroom via `lanes` and resolves the lane before any worktree is created. Flags: `--help` |
| `lanes` | Enumerate harness auth lanes and their live usage; `pick` prints the launch env prefix for the lane with the most headroom, exit 3 when none qualifies. Headroom is the binding window, never an average; per-project policy belongs in each consumer's wrapper |
| `parallel-groups` | Local cache for safe parallel handoff analysis |

The three waiters share a bounded env-first GitHub auth ladder and exit `3` on hard auth failure — [references/gates.md](references/gates.md).

**`workflow-state`**: run it with no arguments for the full action reference (init/get/set/update/append/increment/set-git-head/set-now/new-round-id/path/exists). From a worktree, pass the global `--state-dir <path>` flag before the subcommand — a plain flag is classifier-safe under Codex `approval=never` where the `ORCH_STATE_DIR=…` env prefix is a rejected shape. State keys are the normalized issue IDs — `issue-N` for GitHub issues (per `start` routing), `PROJ-123` for Linear — never the bare GitHub issue number; every action except `init` aliases a bare numeric key to the `issue-N` state file when only that file exists, and errors (exit 2) instead of guessing when files exist under both keys.

### Review-gate modes

`approval-wait --resolve-mode` prints the project's effective gate mode; workflows read the mode only through it. `PR_REVIEW_GATE` selects `approval` (GitHub-native approval verdict), `review` (non-author review of the current head + zero unresolved threads, for commenting-only review bots), or `off` (reviewer-less repo: wait skipped, gate recorded not-applicable). Default `approval`. Full setting semantics — the legacy `PR_APPROVAL_GATE` mapping, `PR_REVIEW_CHECK`, `PR_REVIEW_ON_TIMEOUT`, `PR_REVIEW_NUDGE*`, `PR_REVIEW_OUTAGE_CONTEXT` — and the waiters' JSON contracts: [references/gates.md](references/gates.md).

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/workflow-state.md` | Persistent state file schema (issue/agent/worktree identity, `child_sessions`, `review_agents`/`review_agent_ids`, cycle counters, fixed/escalated items, PR comment review tracking) |
| `schemas/dev-return.md` | Dev completion-artifact schema (round-id identity, fields, kind rules, `items[]` shape) |
| [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md) | Review/QA finding JSON format |

Audit input and roadmap-plan schemas live in `project-management/schemas/` — cross-skill path.

## Configuration

Put non-secret workflow settings in committed `vstack.settings.toml` under `[env]`; `.env.local` remains supported for secrets and personal overrides.

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORCH_STATE_DIR` | State-file directory (env fallback for the `--state-dir` flag, which wins when both are set) | `tmp` |
| `ORCH_CACHE_DIR` | Parallel-group safety cache directory | `.cache/orch` |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names | — |
| `CI_FIX_MAX_CYCLES` | Max automated ci-fix cycles per PR submission / merge recovery (read via `orch-env CI_FIX_MAX_CYCLES 6`) | `6` |
| `PR_REVIEW_REFIX_MAX_LINES` | Changed-line ceiling a support-scope fix round may reach before `review-pr` re-reviews it anyway; a round that cleared blockers is re-reviewed regardless (read via `refix-route`) | `200` |
| `REVIEWER_SLOT_BUDGET` | The runtime's total concurrent agent-session budget, counting the primary session (read via `orch-env REVIEWER_SLOT_BUDGET 0`; `0` = unlimited). On the Codex collaboration runtime, set it to the config-declared cap (`features.multi_agent_v2.max_concurrent_threads_per_session`) reported by `spawn-adapter slots` | `0` |
| Review-gate settings | `PR_REVIEW_GATE`, `PR_REVIEW_CHECK`, `PR_REVIEW_ON_TIMEOUT`, `PR_REVIEW_NUDGE*`, `PR_REVIEW_OUTAGE_CONTEXT` — [references/gates.md](references/gates.md) | — |

System dependencies: `jq`; `bash` 4+; `flock` (util-linux) for atomic state updates.

## Tests

`bash skills/orch/tests/run-all.sh` (append a name fragment to filter). Each `tests/*.sh` is self-contained; the runner discovers files at execution time.

## Skill Rules

### Workflow Execution

- **Sequential sections.** Process sections in order: mark in-progress, execute all sub-sections, mark completed, proceed. Never create tasks for sub-sections; never mark a parent complete before its sub-sections finish. Never skip steps based on predicted outcome or change scope — the workflow text decides, not the agent.
- **Skip-if.** Evaluate "Skip if [condition]" literally; if true, append "(SKIPPED)" and mark completed.
- **Nested workflows.** `⤵`-marked workflows must be invoked through the harness mechanism — never inlined. Record the return point (`→ § X`) before invoking.

#### Worktree Scope

In a worktree, never create, switch to, or act on a different worktree or branch. If the resolved `ISSUE_ID` differs from the current branch, stop and ask: reuse, abort, or switch explicitly.

#### Harness-Safe Shell

Generated workflow commands must be safe for strict harness command policies. Prefer one simple command per tool call with explicit arguments. Avoid inline `$(...)`, shell `for`/`while` loops, array-building snippets, heredocs, pipelines used only for value plumbing, and redirected writes; Codex can classify those shapes as approval-required even when approval policy is `never`. **Run exactly one command per tool call** — a multi-command block is itself a rejected shape. Fold related `workflow-state` reads into one `get '{...}'` and related writes into one `update '... | ...'`; use `git-context` for derived values and harness file tools or `apply_patch` for file bodies. Full shape catalogue, rewrite patterns, and split rules: [references/codex-runtime.md](references/codex-runtime.md).

**Env-assignment prefixes are normalized at acceptance, not at run time.** A required command shaped `VAR=value cmd args` is rejected under Codex `approval=never` for the prefix shape alone, however authoritative its source. Normalize where the command enters the workflow: confirm the ambient environment satisfies the precondition (`printenv VAR`; `locale` for locale variables), then run the bare `cmd args` unchanged. `env VAR=value cmd args` is not the documented substitute. If the environment does not satisfy the precondition, report a blocker instead of running under the wrong environment.

**A literal backtick anywhere in a generated command is command substitution to the classifier**, even in a quoted read-only search pattern. Author the pattern with the regex hex escape `\x60` in single quotes, in regex mode, as one simple command. The canonical statement with the worked example lives in reviewer SKILL.md § Harness-Safe Shell; it applies to every generated command list — dev validation steps, delegated audit searches, fix recommendations — not only reviewer checks.

**Never author a workflow step that assumes top-level `git rebase` will run.** Under Codex `approval=never` the classifier rejects the porcelain verb itself — a harness-side classification that no user authorization or delegation can lift; never retry it or substitute an improvised force-push. The documented equivalent for a clean, linear issue branch is the worktree skill's guarded replay path (worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback)). A dirty tree or merge commits in the range: report a blocker instead of improvising.

#### Tracker Resolution

Resolve once per workflow with `.agents/skills/orch/scripts/tracker-for-issue "[ISSUE_ID]"`, store as `TRACKER`; a caller `tracker` param wins. `issue-*` → `github` (issue number = `${ISSUE_ID#issue-}`; repo from caller context, else `gh repo view --json nameWithOwner`); otherwise `linear`. Steps marked **Linear only** / **GitHub only** run only for that tracker. Never run `linear.sh` against a GitHub item — GitHub state lives in `gh issue`/PR linkage (`Closes #N`).

---

### Delegation

| Pattern | When | Flow |
|---------|------|------|
| Spawn + message | Fresh agents (dev, QA, review) | Spawn with bootstrap → send delegation |
| Message only | Re-delegation to existing agents | Send delegation to running agent |
| Self-create | Agent without team context | Full instructions in prompt |
| Consultation | One-off sub-agent | Full instructions in prompt, no task machinery |

Delegated command lists — verification steps from issue specs, fix recommendations, QA commands — are normalized per [Harness-Safe Shell](#harness-safe-shell) before they enter a delegation prompt: an env-assignment prefix never survives delegation; it becomes an ambient-environment precondition check plus the bare command.

**Task layers.** Orchestrator steps, sub-workflows, and agent tasks are distinct layers; agents only act on their own assigned work.

**No duplicate spawns.** Never spawn a fresh agent when the same role/name is alive. Read workflow state, reuse by stored ID, respawn only after one recovery attempt or confirmed stuck/closed status. A prior completion message does not justify a duplicate.

#### Bootstrap Message

Send bootstrap **first** before any delegation. Fill `[PLACEHOLDERS]`, send verbatim:

<bootstrap_format>
You are a [ROLE] sub-agent ([AGENT_NAME]). You report to the orchestrator.

Rules:
- Execute all assigned work yourself. Do not spawn sub-agents for implementation, review, or fix work.
- You may use read-only search sub-agents for codebase search/research only, where your harness provides them.
- Only act on delegation messages from the orchestrator. If no delegation is pending, stay idle. If you have an accepted delegation whose checklist is unfinished, resume and complete it before idling — except while a long validation you backgrounded is still running, where ending the turn is correct and the orchestrator will nudge you (dev SKILL.md § Long-Running Validation).
- Before sending your single return message, write your workflow's on-disk completion artifact — the orchestrator treats it as the durable completion record. Dev agents run `dev-return-write` (dev-implement § 10 / dev-fix § 6; never hand-author the JSON); reviewer/QA agents author their review JSON per the reviewer skill. After completing assigned work, send a single return message and go idle. Wait for further delegation.
- Do not manage tasks for other agents. Do not act as a coordinator.
</bootstrap_format>

The `<delegation_format>` message follows as a separate message after bootstrap. **Pi exception** (`pi-agents-tmux`): one tool call per delegation — bootstrap is auto-injected; the `task` argument is the filled `<delegation_format>` content alone (see the Pi runtime note).

#### Format Tags Are Literal

`<bootstrap_format>`, `<delegation_format>`, and `<output_format>` tags define exact content: fill `[PLACEHOLDERS]`, omit lines whose placeholder is empty or not applicable, add nothing else, and do not paraphrase — exact structure, headings, and field names. Placeholders hold schema fields only; never embed workflow steps or process prose inside item records (duplication triggers a second return on idle wake-up). When a tagged output block is followed by an `Ask user` step (in Claude Code, the `AskUserQuestion` tool), present the filled block as a normal message first, then ask only a concise question with options.

#### Single Return Message

An agent sends exactly one completion message. If a second return arrives, treat it as a violation: diff against the first, flag unrequested commits. Root cause is usually process leakage in `[FORMATTED_ITEMS]` or extra delegation fields.

**Codex dual-channel completion.** On Codex collaboration agents, one completion can arrive over two channels: a `send_input` `MESSAGE` immediately followed by a `FINAL_ANSWER` that echoes the same result. This is the Codex runtime delivering a single completion twice — treat the pair as **one completion** and deduplicate them on the same delegation; do not flag it as a violation. Still diff the `FINAL_ANSWER` against the `MESSAGE`: if it carries a new commit, extra changes, or a different scope, that is a genuine second return and must be flagged per the rule above.

---

### Agent Lifecycle

Stages: `SPAWN (bootstrap) → DELEGATE → WORK (agent executes itself, no sub-delegation) → RETURN (single completion message) → IDLE / RE-DELEGATE`.

#### Dev Agent Persistence

Dev agents persist for the entire session; re-delegate them for review-fix, QA-fix, comment-fix, and CI-fix cycles (each re-delegation: send delegation → create and assign new tasks — task assignment wakes a live agent, so the delegation goes first). Shut down only on explicit user request or a stall confirmed via the [escalation sequence](#wait-for-agent-return-before-acting) — quiet ≠ stalled; idle ≠ stuck.

#### Review Agent Lifecycle Management

Reviewer persistence is budget-conditional: persistent when the budget allows, waves when it does not. `orch-env REVIEWER_SLOT_BUDGET 0` prints the runtime's budget counting the primary session (`0` = unlimited). Available reviewer slots = budget − 1 (primary) − live persistent sessions (`child_sessions` entries with status `active`; a record with no `status` field counts as active — legacy records predate the status stamp), minimum 1. Recompute at every review-cycle start.

**Persistent mode** (unlimited budget, or the reviewer set fits): reviewers persist across fix → re-review cycles. Read `review_agents`/`review_agent_ids` before spawning; reuse by exact name; spawn only the missing/stuck subset; full shutdown when review passes. A thread-limit spawn failure during a persistent launch demotes the cycle to wave mode automatically: the spawned reviewers become the first wave, the observed spawn count is persisted as `reviewer_slots_observed` so re-review cycles stay in waves, and the user gets a one-line `REVIEWER_SLOT_BUDGET` recommendation (`review-pr.md` § 2.2). The configured budget is advisory; the runtime cap is authoritative.

**Wave mode** (the set exceeds the slots): launch up to the available slots, wait for each validated report artifact, retire the completed session to release its slot, launch the next wave. Re-review recreates retired reviewers fresh, pointed at the current diff and their prior report artifact. **Invariant**: review state lives in on-disk report artifacts and workflow state, never in reviewer session memory — retiring a completed reviewer loses nothing, and `review_delegated_at` freshness gating is re-stamped per wave.

QA agents spawn and shut down per-agent.

#### Wait for Agent Return Before Acting

After delegation, wait for the agent's return — but never let the round's closure *depend* on a return message or on any wake arriving.

> If you are running in **Claude Code**: on each idle notification, check the task list — any in-progress → go idle (task status changes also generate trailing notifications; on completed tasks go idle immediately); all completed → proceed; all pending (none claimed) → re-send delegation ONCE, wait one full agent turn, respawn if still all pending. Never re-send or intervene while any task is in-progress.

**The orchestrator owns round closure — primary path, not a recovery fallback.** A correct dev/QA agent may background a long validation and end its turn without any further wake (dev SKILL.md § Long-Running Validation), so every dev/QA delegation closes on three mandatory orchestrator-side mechanics:

1. **Mint and embed a round token** immediately before delegating (`workflow-state new-round-id [ISSUE_ID] dev_round_id` → the delegation's `Round ID:` line) and re-stamp `dev_delegated_at` (now solely the watchdog deadline). Any new dev/QA fix path must do the same.
2. **Arm a single-shot wall-clock watchdog** for `dev_delegated_at + quiet_window` at that same moment, so the check runs even if NO wake ever arrives; it fires once at the deadline, runs A/B if the round is still outstanding, and re-arms only on entering a new escalation step — never a busy poll. Harness mechanisms: [references/artifact-checks.md](references/artifact-checks.md).
3. **Run A/B on every wake and at the deadline, and classify mechanically — never from wording or elapsed time.** **A** = `dev-artifact-check --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (read `dev_round_id` via `workflow-state get`; fix rounds add `--expect-items`); **B** = the round's git/tracker completion checks. A `finished`/`idle` wake is not evidence the round completed.

The acceptance decision table lives in the delegating workflow — `dev-start.md` § 3 (implement), `dev-fix.md` § 2 and `review-pr-comments.md` § 6.1 (fixes) — and is a pure function of A and B; the return message is display-only, never an acceptance input. The round token binds A to exactly this delegation's receipt, and a path whose agent writes no dev-return artifact (`ci-fix.md` § 3.2) is accepted by its own return message plus the escalation ladder, never by a stale artifact — details: [references/artifact-checks.md](references/artifact-checks.md).

**Dev-vs-reviewer asymmetry (intentional — do not "align").** Reviewers have no independent git/tracker signal — their JSON *is* the deliverable — so a reviewer `ok==false` after a return is `incomplete` → re-delegate (`review-pr.md` § 3.1). Dev's B signal only distinguishes "code landed, recover the tail" (`ok==false` + pass → one report-only nudge) from "not done" (`ok==false` + fail → escalate); neither branch re-runs the work, and neither accepts without the round-scoped artifact.

**Invalid stall signals** (never sufficient alone or combined): return-message timeout, clean git status/diff/log, no modified files — a worktree also looks clean during an agent's research/planning phase. The sole positive signal that overrides a missing return is a valid `dev-artifact-check` for the current `dev_round_id`.

**Escalation** — **quiet ≠ stalled**: only after the 10-minute quiet window from delegation AND a confirmed stall (task status unchanged across multiple idle cycles; no new session-log entries for 10+ minutes; or agent process exited / zero CPU). Then: (1) re-message once specifying the missing step; (2) wait 5 min, re-check — new activity → go idle; (3) still inactive → shut down → re-create tasks → respawn → re-delegate.

#### Orchestrator Never Fixes Code

Never edit or write code unless the user explicitly asks. Delegate to the domain agent; if an agent appears stuck, follow the [escalation sequence](#wait-for-agent-return-before-acting). Read-only commands and script invocations are permitted.

---

### State Management

**Durable state.** Use workflow state files — through the `workflow-state` CLI only, including `set-git-head`/`set-now` instead of inline command substitution — for data that must survive compaction: issue tracking, agent persistence, cycle counts, fix/escalation tracking, audit trails. Location: `<state-dir>/workflow-state-[ID].json`, where `[ID]` is the normalized state key and `<state-dir>` resolves to the `--state-dir` flag, then `$ORCH_STATE_DIR`, then `tmp/`.

**Compaction recovery.** External state persists: check the task list and resume from the step after the last completed one; read workflow state for persistent data (team name, cycles, agent IDs); re-read team config from disk if team-based; re-send delegation using stored IDs; respawn only the missing/stuck agent if there is no response after one idle cycle. Never repeat completed actions. On an explicit session restart, teammates are lost: respawn and re-delegate pending tasks.

---

### Coordination

**Sequencing by data dependency.** Infer the agent from label or component path, identify candidate pairs, and confirm with Creates ↔ Consumes analysis — no data flow = no blocking. Defaults: Backend → Frontend; `*` → Generalist (runs last). Set blocking relations on parent issues (not children) when bundled. Full relations: `workflows/agent-sequencing.md`.

**Bundled issues.** One composite task per sub-issue, not one task per section: agents execute all referenced sections for their sub-issue, then mark the single task complete; setup, activation, and return steps stay one task each. Multi-domain bundles: process groups sequentially per agent-sequencing, collect handoff notes between groups, persist dev agents per [Dev Agent Persistence](#dev-agent-persistence).

**Parallel work safety.** Before running issues in parallel, verify all five dimensions — dependency resolution, agent overlap, code scope, build config (manifest changes are hard separations), and active work (worktrees, open PRs) — and apply the grouping constraints. Mechanics: `workflows/parallel-check.md`.

---

### Review Pipeline

**Finding schema.** Full schema: [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md). `verdict` is `action_required` when blockers exist, else `pass`; `location` is a file path plus function/struct name — never line numbers; each item carries `id`, `title`, `location`, `description`, `recommendation`, `priority` (1-4), `estimate` (1-5); suggestions also require `category`: `fix` or `issue`.

**Recommendation categorization.** Evaluate each suggestion in order: actionable (vague → omit) → related (doc updates for changed code are always `fix`; unrelated → `issue`) → size (small → `fix`; needs tracking or delegation → `issue`). Security vulnerabilities: `fix` if quick, else `issue` — never skip. Filing bar (vstack#944): file an `issue` only for out-of-scope behavioral defects, est≥2 refactors, decision revisits, or evidenced anomalies; P4 polish is absorbed in-PR when est-1 and related, else dropped with a one-line note. Residue attaches to an existing same-surface bundle by default. Full decision flow and signal table: `workflows/recommendation-bias.md`.

**Issue audit pipeline.** Collect review JSON → transform `category=issue` suggestions into audit input (schema in `project-management/schemas/`) → delegate to TPM for tracked issue creation. Sources: suggestions, escalated blockers, planned items, discovered work; populate dependency fields when order is known.
