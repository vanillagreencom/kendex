---
name: orchestration
description: "Per-issue inside-worktree lifecycle: dev → review → submit → merge, with delegation to specialist sub-agents and review pipelines."
license: MIT
user-invocable: true
dependencies:
  required: [linear, github, worktree, issue-lifecycle, project-management, decider]
metadata:
  author: vanillagreen
  version: "2.0.0"
---

# Orchestration

## STOP — Required Setup

You MUST complete these steps IN ORDER before doing anything else in this skill.
Do not skip ahead to workflows or commands.

1. Load the `linear` skill now.
2. Load the `github` skill now.
3. Only after both skills are loaded, continue to the workflows below.

If you cannot load a skill, stop and tell the user. Do not proceed without them.

---

> **MODE SWITCH**: Loading this skill puts you in **orchestrator mode**. Do not write code yourself. Delegate all implementation, review, and QA work to specialist sub-agents using the workflows in this skill.

> If you are running in **Claude Code**: Always create a team before launching agents. Spawn and delegate to agents within the team context so they share state and can be messaged for re-delegation. When asking the user a question or presenting options, always use the `AskUserQuestion` tool. `SendMessage` accepts exactly `to`, `summary`, `message` — extra fields (`type`, `recipient`, `content`, `body`) have caused duplicate delivery on idle wake-up.

> If you are running in **Codex**: Spawn workers with `fork_context: false`. Two-step pattern: (1) spawn with the `<bootstrap_format>` message, (2) `send_input` a `DELEGATION:` prefixed message containing exactly the filled `<delegation_format>` content — nothing more.

> If you are running in **OpenCode**: The persistent identity of a spawned sub-agent is the `task_id` returned by `functions.task`. On first spawn, store that `task_id` in workflow state (`child_sessions[agent].agent_id` for dev/QA, `review_agent_ids[reviewer-name]` for reviewers). On re-delegation (fix cycles, re-review), call `functions.task(task_id=<stored_id>)` — never spawn a fresh task when a stored ID exists. Fresh spawn only if: no stored ID, one resume attempt fails, or the prior task is confirmed dead.

> If you are running in **Pi** with `pi-agents-tmux`: use `subagent` for delegation. The Pi dispatch model is **one tool call per delegation** — no separate "send bootstrap, then send delegation" two-step. The agent's bootstrap is its compiled system prompt (built from frontmatter `description` + role + skills + the canonical `<bootstrap_format>` block) and is injected automatically as `--append-system-prompt` when the child pi process starts. The `task` argument to `subagent` is the filled `<delegation_format>` content — nothing more. Do not prepend the bootstrap block to the `task` string; that double-injects the role boundaries and confuses the child.
>
> Two flavors:
> - **Pane agents** (`pane: true` in agent frontmatter) live in a persistent tmux pane keyed by agent name. The extension reuses the existing pane on every redelegation — do not pass `forceSpawn: true` unless you genuinely need a fresh pane (it errors if a live pane already exists, and tells you to either drop the flag or `/agents:stop <name>` first). Store the returned `taskId` and agent name in workflow state (`child_sessions[agent].agent_id` or `review_agent_ids[...]`). The `taskId` is returned in two places: the structured `taskId` field on the tool result **and** an inline `Task ID: <id>` line in the assistant-visible content text — read whichever your harness exposes; you do not need a follow-up `get_subagent_result` call just to learn the id.
> - **Bg agents** (no `pane: true`) are background one-shot processes. By default each call is ephemeral (no persisted session). For multi-step workflows where the same `reviewer-*` (or other bg agent) must retain conversation context across delegations, pass `sessionKey: "<workflow-scoped-stable-id>"` (e.g. `review-issue-PROJ-123`). Same `agent + sessionKey` resumes the prior pi session; omit it for truly stateless calls.
> On re-delegation to a pane agent, use `steer_subagent` only for true mid-run correction from this same Pi parent session; its success output reads `Bridge: active` and shows the expected child `sessionFile` under this session runtime. If the bridge target is unavailable, the tool queues an inbox fallback that is **not** mid-run steering and will be read only when the pane is idle. For idle follow-up work, queue a new `subagent` task to the same pane. Use `get_subagent_result` only as a recovery/status reader for missed or truncated pane completions; it does not affect ownership or delivery. If it returns `needs_completion`, the child finished a turn without the durable `complete_subagent` record — do not count it as a return; use the verbose diagnostics/outbox path to send one recovery instruction asking the same pane to call `complete_subagent` for the stored `taskId`. Treat Pi custom completion notifications as agent returns only when the task ID matches stored workflow state; repeated display is not a second return. Flightdeck owns only the outer orchestration tmux window; it does not spawn, steer, or manage these inner agent panes.

> Research issues (`research` label) are executed by `agent:researcher`, not by external human sessions. The researcher may run Exa deep research and write findings docs/raw metadata, but must not modify production code. In Pi, treat persistent `researcher` panes like other project agents: key by agent name, store the returned `taskId`, and require exactly one completion message after `findings.md` exists.

> Do not read `README.md` — it is for human setup only.

## Prerequisites — Load Before Any Workflow

Load these dependency skills before executing any workflow. Do not guess commands — load the skill first, then use its scripts/commands.

| Skill | Domain |
|-------|--------|
| `linear` | All issue tracking operations (create, update, query, sync) |
| `github` | All PR and branch operations (create, review, merge, CI) |
| `worktree` | Parallel session management (create, list, remove worktrees) |
| `project-management` | Roadmap, cycle planning, prioritization |
| `decider` | Architectural decision documents |

## Commands

When invoked with `<command> [args]`, route to the corresponding workflow.

### Session

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `start` | `[ISSUE_ID]` | See routing below | Context-aware routing |
| `initialize` | `[ISSUE_ID]` | `workflows/initialize.md` | Team setup, auth, cache, state (standalone) |

**`start` routing logic:**
1. Current directory is a worktree (git common dir differs from `.git`) → `workflows/start-worktree.md`
2. Otherwise (running from main repo) → emit a redirect message (`From main, use 'flightdeck linear start [ISSUE_ID]' — that command lives in the flightdeck skill.`) and stop. orchestration's role is per-issue inside-worktree work; master-side kickoff lives in flightdeck.

### Development

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `dev-start` | `[ISSUE_ID]` | `workflows/dev-start.md` | Delegate implementation |
| `dev-fix` | `[ISSUE_ID]` | `workflows/dev-fix.md` | Delegate review fix items |
| `ci-fix` | `PR_NUMBER` \| `queue` | `workflows/ci-fix.md` | Fix CI failures |

### Review & Submission

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `review` | `[all]` \| `[last N]` \| `[HASH]` | `workflows/review.md` | On-demand review (standalone) |
| `review-pr` | `[PR_NUMBER]` | `workflows/review-pr.md` | Pre-submission review |
| `review-pr-comments` | `PR_NUMBER` \| `BRANCH` | `workflows/review-pr-comments.md` | Triage PR comments |
| `submit-pr` | `[PR_NUMBER]` | `workflows/submit-pr.md` | Push, create PR, bot review, CI |
| `merge-pr` | `PR_NUMBER` \| `all` | `workflows/merge-pr.md` | Verify and merge |
| `fix-reconcile` | — | `workflows/fix-reconcile.md` | Internal (not user-invocable) |
| `post-summary` | `[ISSUE_ID]` | `workflows/post-summary.md` | Post summary comments |

### Master-side commands (moved)

The following commands moved to other skills:

| Command | Now in |
|---------|--------|
| `linear start` (from main), `linear start new`, `linear parallel-check` | `flightdeck` |
| `audit-issues`, `cycle-plan`, `roadmap plan`/`create`, `research-spike`, `research-complete` | `project-management` |

These are still callable when their owning skill is loaded.

### Execution Mode

When executing a command's workflow, follow ALL [Workflow Execution](#workflow-execution) rules:
- Process sections sequentially
- Never skip based on scope assessment
- Use `⤵` markers for nested workflow invocation

## Workflows

### Session Lifecycle

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/initialize.md` | `initialize` | Team setup, auth, cache, state init |
| `workflows/start.md` | `start` (from main repo) | Dashboard, issue selection, research eval, worktree creation |
| `workflows/start-worktree.md` | `start` (from worktree) | Full session: dev → review → submit → finalize |
| `workflows/start-new.md` | `start-new` | Create new issue, spawn worktree session |

### Development

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/dev-start.md` | `dev-start` | Delegate implementation to specialist agents |
| `workflows/dev-fix.md` | `dev-fix` | Delegate fix items to dev agents |
| `workflows/ci-fix.md` | `ci-fix` | Analyze and fix CI failures |

### Review & Submission

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/review.md` | `review` | On-demand review with fix handling |
| `workflows/review-pr.md` | `review-pr` | Pre-submission review with fix handling and QA |
| `workflows/review-pr-comments.md` | `review-pr-comments` | Triage PR review comments via domain agents |
| `workflows/submit-pr.md` | `submit-pr` | Push, create PR, bot review, comment triage, CI |
| `workflows/merge-pr.md` | `merge-pr` | Verify conditions and merge PR(s) |

### Per-Issue Lifecycle

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/fix-reconcile.md` | `fix-reconcile` | Check if fixes address existing open issues |
| `workflows/post-summary.md` | `post-summary` | Post summary and handoff comments |

### Reference

| Workflow | Purpose |
|----------|---------|
| `workflows/agent-sequencing.md` | Cross-domain blocking relations and delegation order |
| `workflows/recommendation-bias.md` | Review finding categorization (fix vs issue) |

## Scripts

```bash
.agents/skills/orchestration/scripts/<script> [args]
```

| Script | Purpose |
|--------|---------|
| `workflow-state` | Persistent state read/write/append (survives compaction) |
| `bot-review-wait` | Block until bot review posts on a PR — invoked by per-issue agents inside their submit-pr flow |
| `ci-wait` | Block until CI completes on a PR — same |
| `session-init` | Initialize session state for a new worktree (called by `initialize.md`) |
| `flightdeck-mode` | Detect Flightdeck-managed mode + report scoped issue/worktree/branch. Used by `merge-pr.md` § 5 to suppress cross-branch sweeps when running under Flightdeck. |

`bot-review-wait --json` returns `status: "error"` and exits non-zero on GitHub auth/API failures instead of polling until timeout with empty output.

Both `bot-review-wait` and `ci-wait` share `scripts/lib/gh-auth.sh` for a four-step auth-resolution ladder: (1) sanitize stale `GH_TOKEN`/`GITHUB_TOKEN` that mask working `gh` keyring auth and continue with a warning; (2) when `GH_TOKEN` ends up empty, load a valid `GH_BOT_TOKEN` from `.env.local`/`.env` (`op://` references resolved via `op read`); (3) on a remaining auth failure, drop env tokens and retry the bot-token load so a stale env token plus broken keyring still recovers if `.env.local` provides a valid bot token; (4) if no auth path works, exit `3` with a clear diagnostic. Exit `3` matches `bot-review-wait`'s auth-error exit so callers can treat the two consistently.

### Tests

`bash skills/orchestration/tests/run-all.sh` runs every script-level regression test (`bot_review_wait.sh`, `ci_wait.sh`). Each test stages a temp repo with a parametrized `gh` stub on `PATH` and exercises every rung of the auth ladder: stale-token sanitize, keyring fallback, `.env.local` `GH_BOT_TOKEN` fallback, and the hard “no working auth path” exit.

### `workflow-state` actions

`ORCH_STATE_DIR` overrides state directory (default: `tmp`).

| Action | Purpose |
|--------|---------|
| `init <ID> --agent <name> --worktree <path>` | Initialize state file |
| `get <ID> <.field>` | Read state field |
| `set <ID> <field> <value>` | Write state field |
| `append <ID> <field> <value>` | Append to array field |
| `increment <ID> <field>` | Increment counter |

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/workflow-state.md` | Persistent state file schema (survives compaction) |
| `schemas/review-finding.md` | Review/QA agent JSON output format |

Key fields per schema:

- **Workflow State**: `issue_id`, `sub_issues`, `agent`, `worktree`, `branch`, `team_name`, `child_sessions`, `review_agents`, `cycles`, `json_paths`, `fixed_items`, `escalated_items`, `audit_issues_created`
- **Review Finding**: `blockers[]` (block merge), `suggestions[]` (fix or issue), `questions[]` (PR triage). Each item: id, title, location, description, recommendation, priority, estimate

The `audit-issues-input` and `roadmap-plan-input` schemas live in `project-management/schemas/`. Per-issue review workflows that build audit input read from there via cross-skill path.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORCH_STATE_DIR` | Override state file directory | `tmp` |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names | — |
| `BOT_REVIEWERS` | Comma-separated bot usernames to wait for | Auto-detects |
| `BOT_CHECK_NAME` | CI check name to treat as early review signal | — |

## System Dependencies

- `jq`
- `bash` 4+
- `flock` (util-linux) for atomic state updates

## Tests

Run the full orchestration regression suite:

```bash
bash skills/orchestration/tests/run-all.sh
# Optional filter:
bash skills/orchestration/tests/run-all.sh flightdeck_mode
```

Each `tests/*.sh` file is self-contained (builds its own sandbox, prints `pass: N fail: M`, exits non-zero on failure). The runner discovers them at execution time, so adding a new test file requires no central registration.

## Skill Rules

### Workflow Execution

#### Sequential Section Execution

Process sections sequentially: mark in-progress, execute all sub-sections within the section, mark completed, then proceed to next. Never create tasks for sub-sections — they are steps within the parent task, not separate tasks. Never mark a parent section complete before all sub-sections are executed.

Never skip steps because the outcome seems predictable, or rationalize skipping based on change scope ("test-only", "small", "only N items", "already reviewed"). The workflow text is the decision authority, not the agent's assessment.

#### Skip-If Condition Evaluation

When a section starts with "Skip if [condition]", evaluate the condition literally. If true, append "(SKIPPED)" to the task subject and mark completed. The workflow decides what to skip, not the agent.

#### Nested Workflow Invocation

Nested workflows (marked with `⤵`) must be invoked through the harness's workflow invocation mechanism — never inlined or substituted with ad-hoc commands. If the marker includes a return point (`→ § X`), record it before invoking.

#### Worktree Scope

If the current directory is a worktree, never automatically create, switch to, or act on a different worktree or branch. When a command's resolved `ISSUE_ID` differs from the current worktree's branch, stop and ask the user: reuse the current worktree, abort, or switch explicitly. Applies to all workflows — `start`, `dev-start`, `dev-fix`, `review-pr`, `submit-pr`, etc.

---

### Delegation

#### Delegation Patterns

| Pattern | When | Flow |
|---------|------|------|
| Spawn + message | Fresh agents (dev, QA, review) | Spawn with bootstrap message → send delegation message |
| Message only | Re-delegation to existing agents | Send delegation message to running agent |
| Self-create | Agent without team context | Full delegation instructions in prompt |
| Consultation | One-off sub-agent | Full instructions in prompt, no task machinery |

#### Bootstrap Message

When spawning a new agent, send the bootstrap message **first** before any delegation. This establishes the agent's role and boundaries. Use the template below — fill `[PLACEHOLDERS]`, send verbatim:

<bootstrap_format>
You are a [ROLE] sub-agent ([AGENT_NAME]). You report to the orchestrator.

Rules:
- Execute all assigned work yourself. Do not spawn sub-agents for implementation, review, or fix work.
- You may use Explore sub-agents for codebase search/research only.
- Only act on delegation messages from the orchestrator. If no delegation is pending, stay idle.
- After completing assigned work, send a single return message and go idle. Wait for further delegation.
- Do not manage tasks for other agents. Do not act as a coordinator.
</bootstrap_format>

The delegation message (containing the `<delegation_format>` content) follows as a separate message after the bootstrap.

**Pi exception** (`pi-agents-tmux`): one tool call per delegation. The bootstrap above is auto-injected by the child pi process as its system prompt (built from the agent's frontmatter + role boundaries); the `task` argument to `subagent` is the filled `<delegation_format>` content alone. Do not send the bootstrap separately and do not prepend it to the `task` string — either double-injects the role boundaries. See the Pi note at the top of this skill for the full dispatch model.

#### Format Tags Are Literal

`<bootstrap_format>`, `<delegation_format>`, and `<output_format>` tags define exact content. When sending or presenting content from these tags:

1. **Fill `[PLACEHOLDERS]`** with actual values
2. **Omit lines/sections** where the placeholder value is empty or not applicable
3. **Add nothing else** — no commentary, no extra fields, no rewording, no explanations before or after the content
4. **Do not paraphrase** — use the exact structure, headings, and field names from the tag
5. **Placeholders hold structured data only** — fill only schema fields. Never embed workflow steps, commit/validate/push, or "let the orchestrator …" lines inside item records; the agent's `Follow workflow:` already owns process, and duplication triggers a second return on idle wake-up.

#### Task Layers

Work is organized in visually distinct layers: orchestrator workflow steps, nested sub-workflows, and agent tasks. Agents only act on their own assigned work — they never touch orchestrator or sub-workflow items.

#### No Duplicate Agent Spawns

Never spawn a fresh agent when the same role/name is already alive. Read workflow state first, reuse by stored agent/session ID when possible, and only respawn after one recovery attempt or confirmed stuck/closed status.

Idle agents are reusable. A prior completion message does not justify a duplicate reviewer or dev agent.

#### Single Return Message

An agent sends exactly one completion message when its assigned work is done. The agent must not send additional messages after it.

If a second return arrives, treat it as a violation, not new work. Diff against the first and flag any unrequested commits to the user. Root cause is usually process leakage in `[FORMATTED_ITEMS]` or extra fields on the delegation call.

---

### Agent Lifecycle

#### Lifecycle Stages

```
1. SPAWN        Spawn agent with bootstrap message → agent learns its role and boundaries
2. DELEGATE     Send delegation message (filled <delegation_format>)
3. WORK         Agent executes assigned work itself — no sub-delegation
4. RETURN       Agent sends single completion message to orchestrator
5. IDLE/REDEL   Agent goes idle — may receive new delegation for fix cycles
```

#### Dev Agent Persistence

Dev agents persist for the entire session. Never shut down a dev agent unless one of these conditions is met:
1. **Explicit user request** — the user directly asks to shut down the agent
2. **Confirmed stuck/incorrect** — verified via the [escalation sequence](#wait-for-agent-return-before-acting) (quiet ≠ stalled; idle ≠ stuck)

Re-delegate for review fix items, QA fix items, comment fixes, or CI failure fixes. Each re-delegation: create new tasks → send message with delegation.

#### Review Agent Lifecycle Management

Review agents persist across fix → re-review cycles within the review workflow:
- Read `review_agents` and `review_agent_ids` before spawning anything
- Reuse the same reviewer instance by exact reviewer name whenever it is still alive or recoverable
- Spawn only the missing/stuck subset; do not restart the full review pool for a new cycle
- After fixes, selectively shut down non-reporting agents for low-risk changes; keep all alive if risk flags present
- Full shutdown when review passes, clear review agents state

QA agents spawn and shut down per-agent.

#### Wait for Agent Return Before Acting

After delegation, wait for the agent's return message. Do not act on idle notifications. On each idle notification, check the task list:
- Any in-progress → **go idle** (agent is working)
- All completed → proceed
- All pending (none claimed) → re-send delegation ONCE, wait one full agent turn. If still all pending, respawn.

Never re-send or intervene while any task is in-progress.

**Quiet ≠ stalled.** Do not interpret read/search activity without file writes as a stall. Minimum quiet window: 10 minutes from delegation before escalation. No exceptions.

**Invalid stall signals** (never sufficient alone or combined): return-message timeout, clean `git status`/`git diff`/`git log`, no modified files. These observe worktree state only.

**Stall confirmation required.** Verify inactivity using session-level evidence:
- **Task-based** (Claude Code): task status unchanged across multiple idle cycles
- **Session-file** (Codex, OpenCode): no new session log entries for 10+ minutes
- **Process-level**: agent process exited or zero CPU for extended period

**Escalation sequence** (only after quiet window + confirmed stall):
1. Re-message once with clarification specifying the missing step.
2. Wait 5 min. Re-check activity signals. New activity → go idle.
3. Still inactive → shut down → respawn → re-create tasks → re-delegate.

#### Orchestrator Never Fixes Code

Never edit or write code in the worktree unless the user explicitly asks you to. Always delegate to the domain agent. If an agent appears stuck, follow the [escalation sequence](#wait-for-agent-return-before-acting) above. Read-only commands and script invocations are permitted.

---

### State Management

#### Durable Workflow State Files

Use workflow state files for any data that must survive context compaction: issue tracking, sub-issues, agent persistence, cycle counts, fix/escalation tracking, and audit trails. Use the `workflow-state` CLI for all state reads/writes.

State file location: `$ORCH_STATE_DIR/workflow-state-[ID].json` (default: `tmp/`)

#### Compaction Recovery Protocol

After context compaction, conversation history is discarded but external state persists:
1. Check the task list — find last completed task, resume from next
2. Read workflow state file for persistent data (team name, cycles, agent IDs)
3. If team-based: re-read team config from disk to restore member list
4. Re-send delegation to existing agents using stored agent/session IDs.
5. If no response after one idle cycle, respawn only the missing/stuck agent.

Never repeat completed actions.

---

### Coordination

#### Agent Sequencing by Data Dependency

When multiple agents work on related issues, determine blocking relations from data dependencies:
1. Infer agent from label or component path
2. Identify candidate pairs from sequential requirements
3. Confirm with Creates ↔ Consumes analysis — no data flow = no blocking
4. Set blocking relations on parent issues, not children, when bundled

Default sequential requirements:
- Backend → Frontend (if data dependency — UI needs backend types/APIs first)
- `*` → Generalist (runs last — may reference changes from any domain)

#### Bundled Issue Task Structure

When a parent issue has sub-issues assigned to the same agent, create one composite task per sub-issue covering all relevant sections, not one task per section. Agents execute all referenced sections, then mark the single task complete.

```
§ 1: Environment Setup          (one task)
§ 2: Activate Issue              (one task)
§ 3: Block Issue                 (one task, usually SKIPPED)
§ 4-10: PROJ-001 — First sub    (composite — all sections for this sub-issue)
§ 4-10: PROJ-002 — Second sub   (composite — all sections for this sub-issue)
§ 11: Return to Orchestrator     (one task)
```

#### Multi-Agent Bundles

When sub-issues span domains:
- Process groups sequentially per agent-sequencing rules
- Collect handoff notes between groups
- All dev agents persist per [Dev Agent Persistence](#dev-agent-persistence) rules

#### Parallel Work Safety Analysis

Before running issues in parallel, verify safety across five dimensions:
1. **Dependency resolution** — direct blocks/blockedBy, shared blockers
2. **Agent overlap** — same agent on multiple issues risks file conflicts
3. **Code scope** — analyze file paths, modules, type/value flows
4. **Build config** — manifest file changes create hard separations
5. **Active work** — check for existing worktrees and open PRs

Grouping constraints: limit concurrent issues, limit same-agent per group, manifest conflicts as hard separations.

---

### Review Pipeline

#### Review Finding Schema

All review/QA agents output JSON:

```json
{
  "agent": "agent-name",
  "timestamp": "2026-01-14T03:30:00Z",
  "verdict": "pass|action_required",
  "summary": "1-2 sentence summary",
  "blockers": [{
    "id": 1, "title": "Title (5-10 words)",
    "location": "src/file.rs (`function_name`)",
    "description": "What the issue is",
    "recommendation": "How to fix it",
    "priority": 1, "estimate": 2
  }],
  "suggestions": [{
    "id": 1, "title": "Title (5-10 words)",
    "location": "src/file.rs (`function_name`)",
    "description": "What could be improved",
    "recommendation": "How to improve it",
    "priority": 3, "estimate": 2,
    "category": "fix|issue"
  }],
  "questions": [{
    "id": 1, "location": "src/file.rs",
    "question": "Why is this async?",
    "draft_response": "Because...",
    "source": "@reviewer",
    "source_id": "PRRT_kwDO...",
    "source_type": "inline"
  }],
  "qa_metadata": {}
}
```

Verdict: `action_required` if blockers exist, `pass` otherwise. Location uses function/struct names, never line numbers.

Each item requires: `id`, `title` (5-10 words), `location` (file path with function/struct names, no line numbers), `description`, `recommendation`, `priority` (1-4), `estimate` (1-5). Suggestions also require `category` (fix or issue).

#### Recommendation Categorization

For each review suggestion, evaluate in order:

1. **Actionable?** Specific deliverable, observable impact, bounded scope. Vague → omit.
2. **Related?** Semantic relevance to issue/changes. Doc updates for changed code → always fix. Unrelated → issue.
3. **Size?** Small → fix. Needs delegation/tracking → issue.

Category signals:

| Signal | Category |
|--------|----------|
| Small, quick to apply | `fix` |
| Doc/reference updates for changed code | `fix` — always |
| Needs tracking, delegation, or history | `issue` |
| Architectural change, cross-component | `issue` |
| Test coverage (existing test) | `fix` |
| Test coverage (new suite) | `issue` |
| Error handling gaps | `issue` |
| Security vulnerabilities | `fix` if quick, else `issue` — never skip |

"Low priority" ≠ omit. Track if actionable.

#### Issue Audit Pipeline

Collect review JSON → transform `category=issue` suggestions into audit input → delegate to TPM agent for tracked issue creation. Sources: suggestions, escalated blockers, planned items, discovered work.

Audit item requires: index, title, location (no line numbers), description (2-3 sentences), recommendation (bullet-list), priority, estimate, found_by, origin (suggestion/escalated/planned/discovered). Populate dependency fields when implementation order is known.

---

### Platform-Specific Mitigations

| Behavior | Mitigation |
|----------|------------|
| Task status changes generate trailing notifications | On completed tasks, go idle immediately |
| Idle notifications wake orchestrator on every agent turn boundary | Never intervene while any task is in-progress |
| Worktree appears clean during agent research/planning phase | Check session-level activity — not worktree state — before declaring stall |
| Orchestrator loses teammate awareness after context compaction | Re-read `workflow-state` child session data, re-send delegation, only respawn if no response |
| Teammates lost on explicit session restart | Respawn + re-delegate pending tasks |
| Task creation notifications wake idle agents prematurely | Create tasks before spawning, or within existing team context |
