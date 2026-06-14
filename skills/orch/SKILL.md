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
  version: "2.0.0"
---

# Orchestration

## STOP — Required Setup

Load IN ORDER before anything else. Do not proceed if any fails.

1. Load `github`.
2. Load `worktree`.
3. Load tracker: Linear issue → load `linear`; GitHub issue → use `github` only.

> **MODE SWITCH**: Loading this skill puts you in **orchestrator mode**. Do not write code yourself. Delegate all implementation, review, and QA work to specialist sub-agents using the workflows in this skill.

> If you are running in **Claude Code**: Always create a team before launching agents. Spawn and delegate to agents within the team context so they share state and can be messaged for re-delegation. When asking the user a question or presenting options, always use the `AskUserQuestion` tool. `SendMessage` accepts exactly `to`, `summary`, `message` — extra fields (`type`, `recipient`, `content`, `body`) have caused duplicate delivery on idle wake-up.

> If you are running in **Codex**: Spawn generated vstack agents with `agent_type` set to the actual generated agent name and `fork_context: false`. Reviewers returned by `list-review-agents` must first spawn as `agent_type=<reviewer-name>`; dev agents selected from `agent:X` labels must first spawn as `agent_type=X`. Use `worker` only for an intentional generic-worker fallback, when no matching generated agent exists, when the selected agent is deliberately generic, or after the generated-agent spawn is attempted and the Codex spawn API rejects or does not expose that generated `agent_type`. In fallback, preserve the logical selected agent name in reports and workflow-state keys (`child_sessions[agent]`, `review_agent_ids[reviewer-name]`); record the runtime `agent_type=worker` and fallback reason separately in status and workflow state. Two-step pattern: (1) spawn the selected runtime agent with the `<bootstrap_format>` message, (2) `send_input` a `DELEGATION:` prefixed message containing exactly the filled `<delegation_format>` content — nothing more.
>
> For **Codex Desktop app handoff**, invoke `workflows/handoff.md` with `harness=codex-app`. When `handoff` receives multiple issues and the runtime exposes Codex app thread tools, default to `harness=codex-app` unless the user explicitly selected another harness. Create one Codex app thread per issue with `codex_app.create_thread`, start it with exactly `$orch start [ISSUE_ID]` or `$orch start github [OWNER/REPO]#[N]`, and record the returned thread ID. If the runtime separates thread creation from prompting, call `codex_app.send_message_to_thread` once with that same start prompt. The Codex CLI does not expose these tools; do not emulate app handoff with terminal launch, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.

> If you are running in **OpenCode**: The persistent identity of a spawned sub-agent is the `task_id` returned by `functions.task`. On first spawn, store that `task_id` in workflow state (`child_sessions[agent].agent_id` for dev/QA, `review_agent_ids[reviewer-name]` for reviewers). On re-delegation (fix cycles, re-review), call `functions.task(task_id=<stored_id>)` — never spawn a fresh task when a stored ID exists. Fresh spawn only if: no stored ID, one resume attempt fails, or the prior task is confirmed dead.

> If you are running in **Pi** with `pi-agents-tmux`: use `subagent` for delegation. The Pi dispatch model is **one tool call per delegation** — no separate "send bootstrap, then send delegation" two-step. The agent's bootstrap is its compiled system prompt (built from frontmatter `description` + role + skills + the canonical `<bootstrap_format>` block) and is injected automatically as `--append-system-prompt` when the child pi process starts. The `task` argument to `subagent` is the filled `<delegation_format>` content — nothing more. Do not prepend the bootstrap block to the `task` string; that double-injects the role boundaries and confuses the child.
>
> Two flavors:
> - **Pane agents** (`pane: true` in agent frontmatter) live in a persistent tmux pane keyed by agent name. The extension reuses the existing pane on every redelegation — do not pass `forceSpawn: true` unless you genuinely need a fresh pane (it errors if a live pane already exists, and tells you to either drop the flag or `/agents:stop <name>` first). Store the returned `taskId` and agent name in workflow state (`child_sessions[agent].agent_id` or `review_agent_ids[...]`). The `taskId` is returned in two places: the structured `taskId` field on the tool result **and** an inline `Task ID: <id>` line in the assistant-visible content text — read whichever your harness exposes; you do not need a follow-up `get_subagent_result` call just to learn the id.
> - **Bg agents** (no `pane: true`) are background one-shot processes. By default each call is ephemeral (no persisted session). For multi-step workflows where the same `reviewer-*` (or other bg agent) must retain conversation context across delegations, pass `sessionKey: "<workflow-scoped-stable-id>"` (e.g. `review-issue-PROJ-123`). Same `agent + sessionKey` resumes the prior pi session; omit it for truly stateless calls. Bg agents complete by final assistant message captured by `subagent`; do not instruct them to call `complete_subagent`.
> On re-delegation to a pane agent, use `steer_subagent` only for true mid-run correction from this same Pi parent session; its success output reads `Bridge: active` and shows the expected child `sessionFile` under this session runtime. If the bridge target is unavailable, the tool queues an inbox fallback that is **not** mid-run steering and will be read only when the pane is idle. For idle follow-up work, queue a new `subagent` task to the same pane. Use `get_subagent_result` only as a recovery/status reader for missed or truncated pane completions; it does not affect ownership or delivery. If it returns `needs_completion`, the child finished a turn without the durable `complete_subagent` record — do not count it as a return; use the verbose diagnostics/outbox path to send one recovery instruction asking the same pane to call `complete_subagent` for the stored `taskId`. Treat Pi custom completion notifications as agent returns only when the task ID matches stored workflow state; repeated display is not a second return.

> Research issues (`research` label) are executed by `agent:researcher`, not by external human sessions. The researcher may run Exa deep research and write findings docs/raw metadata, but must not modify production code. In Pi, treat persistent `researcher` panes like other project agents: key by agent name, store the returned `taskId`, and require exactly one completion message after `findings.md` exists.

## Commands

When invoked with `<command> [args]`, route to the corresponding workflow.

### Session

| Command | Arguments | Workflow | Notes |
|---------|-----------|----------|-------|
| `start` | `[ISSUE_ID]` \| `github OWNER/REPO#N` | `workflows/start.md` or `workflows/start-worktree.md` | Context-aware routing |
| `start new` | `linear|github ...` | `workflows/start-new.md` | Create one issue then start it |
| `handoff` | `linear|github ...` | `workflows/handoff.md` | Launch-only; no monitoring; Codex Desktop creates one app thread per issue |
| `plan-issues` | `PLAN_PATH linear|github` | `workflows/plan-issues.md` | Convert plan items into issues |
| `parallel-check` | `[ISSUE_IDS]` | `workflows/parallel-check.md` | Safe parallel handoff analysis |
| `initialize` | `[ISSUE_ID]` | `workflows/initialize.md` | Team setup, auth, cache, state (standalone) |

**`start` routing logic:**
1. Parse explicit args first:
   - `github OWNER/REPO#N` → `TRACKER=github`, `ISSUE_ID=issue-N`, `OWNER/REPO` retained for GitHub API calls.
   - `[ISSUE_ID]` → Linear unless it already starts with `issue-`.
2. Current directory is a worktree (git common dir differs from `.git`) → `workflows/start-worktree.md` with the parsed issue context.
3. Otherwise → `workflows/start.md`

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
| `review-codebase` | `[PATH]` | `workflows/review-codebase.md` | Ad-hoc whole-codebase reviewer fanout |
| `review-pr` | `[PR_NUMBER]` | `workflows/review-pr.md` | Pre-submission review |
| `review-pr-comments` | `PR_NUMBER` \| `BRANCH` | `workflows/review-pr-comments.md` | Triage PR comments |
| `submit-pr` | `[PR_NUMBER]` | `workflows/submit-pr.md` | Push, create PR, bot review, CI |
| `merge-pr` | `PR_NUMBER` \| `all` | `workflows/merge-pr.md` | Verify and merge |
| `fix-reconcile` | — | `workflows/fix-reconcile.md` | Internal (not user-invocable) |
| `post-summary` | `[ISSUE_ID]` | `workflows/post-summary.md` | Post summary comments |

### Execution Mode

Follow ALL [Workflow Execution](#workflow-execution) rules for every command.

## Workflows

### Session Lifecycle

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/initialize.md` | `initialize` | Team setup, auth, cache, state init |
| `workflows/start.md` | `start` from main repo | Select/prepare one Linear or GitHub work item |
| `workflows/start-worktree.md` | `start` (from worktree) | Full session: dev → review → submit → finalize |
| `workflows/start-new.md` | `start new` | Create one Linear or GitHub issue |
| `workflows/handoff.md` | `handoff` | Launch-only work item handoff |
| `workflows/plan-issues.md` | `plan-issues` | Convert plan items into issues |
| `workflows/parallel-check.md` | `parallel-check` | Check safe parallel handoff groups |

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
| `workflows/review-codebase.md` | `review-codebase` | Whole-codebase reviewer fanout with findings only |
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
.agents/skills/orch/scripts/<script> [args]
```

| Script | Purpose |
|--------|---------|
| `workflow-state` | Persistent state read/write/append (survives compaction) |
| `git-context` | Print git-derived workflow values such as branch, head SHA, issue id, repo root, and timestamps without inline shell plumbing |
| `pr-view-json` | Print PR view JSON and return success for expected `status=no_pr` so workflows can route to PR creation without shell fallback expressions |
| `resolve-base-branch` | Print the worktree base branch (`WORKTREE_DEFAULT_BRANCH`, remote HEAD, or `main`) |
| `review-init` | Initialize standalone review context and print branch/worktree/issue/state JSON |
| `tracker-for-issue` | Print `github` for `issue-*` ids and `linear` otherwise |
| `bot-review-wait` | Block until bot review posts on a PR — invoked by per-issue agents inside their submit-pr flow |
| `ci-wait` | Block until CI completes on a PR — same |
| `session-init` | Initialize session state for a new worktree (called by `initialize.md`) |
| `open-terminal` | Launch-only handoff helper for Linear/GitHub worktrees |
| `parallel-groups` | Local cache for safe parallel handoff analysis |

`bot-review-wait --json` returns `status: "error"` and exits non-zero on GitHub auth/API failures instead of polling until timeout with empty output. If a bot's direct signal remains pending after GitHub reports `reviewDecision=APPROVED`, the waiter treats the reviewer as approved only when any configured `BOT_CHECK_NAME` has passed and there are no unresolved review threads, then skips stale sticky-checklist waiting.

`session-init --json` reports worktree Linear auth as the structured `linear_auth` object from `linear auth-check`. `linear_auth.error = "not installed"` is reserved for a missing Linear skill command; API key, 1Password, and API failures keep their original auth-check diagnostic.

Both `bot-review-wait` and `ci-wait` share `scripts/lib/gh-auth.sh` for a four-step auth-resolution ladder — see `DEVELOPMENT.md` for the full ladder description. GitHub auth is env-first: already-resolved `GH_TOKEN`, `GITHUB_TOKEN`, or `GH_BOT_TOKEN` values from the parent process win before local files are read, and `op read` is only used for the final selected `op://` reference. Exit `3` on hard auth failure; callers treat both scripts consistently.

### `workflow-state` actions

`ORCH_STATE_DIR` overrides state directory (default: `tmp`). Put non-secret workflow settings in committed `vstack.settings.toml` under `[env]`; `.env.local` remains supported for secrets and personal overrides.

| Action | Purpose |
|--------|---------|
| `init <ID> --agent <name> --worktree <path> [--branch <b>] [--team <t>]` | Initialize state file |
| `exists [--json] <ID>` | Check state file exists; `--json` prints `{issue_id,path,exists}` and exits 0 |
| `path <ID>` | Print state file path |
| `get <ID> <.field>` | Read state field |
| `set <ID> <field> <value>` | Write state field |
| `set-git-head <ID> <field> [worktree]` | Write current `HEAD` SHA to a field without command substitution |
| `set-now <ID> <field>` | Write current epoch seconds to a field without command substitution |
| `append <ID> <field> <value>` | Append to array field |
| `increment <ID> <field>` | Increment counter |
| `update <ID> <jq-expr>` | Arbitrary jq mutation (e.g. nested merges) |

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/workflow-state.md` | Persistent state file schema (issue/agent/worktree identity, `child_sessions`, `review_agents`/`review_agent_ids`, cycle counters, `json_paths`, fixed/escalated items, PR comment review tracking) |
| [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md) | Review/QA finding JSON format |

Audit input and roadmap-plan schemas live in `project-management/schemas/` — cross-skill path.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORCH_STATE_DIR` | Override state file directory | `tmp` |
| `ORCH_CACHE_DIR` | Parallel-group safety cache directory | `.cache/orch` |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names | — |
| `BOT_REVIEWERS` | Comma-separated bot usernames to wait for | Auto-detects |
| `BOT_CHECK_NAME` | CI check name to treat as early review signal | — |

## System Dependencies

- `jq`
- `bash` 4+
- `flock` (util-linux) for atomic state updates

## Tests

```bash
bash skills/orch/tests/run-all.sh          # full suite
bash skills/orch/tests/run-all.sh session_init  # filter
```

Each `tests/*.sh` is self-contained (prints `pass: N fail: M`, exits non-zero on failure). The runner discovers files at execution time — no registration needed.

## Skill Rules

### Workflow Execution

#### Sequential Section Execution

Process sections in order: mark in-progress, execute all sub-sections, mark completed, proceed. Never create tasks for sub-sections — they are steps within the parent task. Never mark a parent complete before all sub-sections finish.

Never skip steps based on predicted outcome or change scope. The workflow text decides, not the agent.

#### Skip-If Condition Evaluation

Evaluate "Skip if [condition]" literally. If true, append "(SKIPPED)" and mark completed. The workflow decides what to skip.

#### Nested Workflow Invocation

`⤵`-marked workflows must be invoked through the harness mechanism — never inlined. Record the return point (`→ § X`) before invoking.

#### Worktree Scope

In a worktree, never create, switch to, or act on a different worktree or branch. If the resolved `ISSUE_ID` differs from the current branch, stop and ask: reuse, abort, or switch explicitly.

#### Tracker Resolution

Resolve once per workflow, store as `TRACKER`:

1. Caller `tracker` param wins.
2. `ISSUE_ID` starts with `issue-` → `github`. Issue number = `${ISSUE_ID#issue-}`; repo from caller context when supplied, otherwise from `gh repo view --json nameWithOwner`.
3. Otherwise → `linear`.

```bash
.agents/skills/orch/scripts/tracker-for-issue "[ISSUE_ID]"
```

Use the output as `TRACKER` before any tracker test. Steps marked **Linear only** / **GitHub only** run only for that tracker. Never run `linear.sh` against a GitHub item — GitHub state lives in `gh issue`/PR linkage (`Closes #N`).

---

### Delegation

#### Delegation Patterns

| Pattern | When | Flow |
|---------|------|------|
| Spawn + message | Fresh agents (dev, QA, review) | Spawn with bootstrap → send delegation |
| Message only | Re-delegation to existing agents | Send delegation to running agent |
| Self-create | Agent without team context | Full instructions in prompt |
| Consultation | One-off sub-agent | Full instructions in prompt, no task machinery |

#### Bootstrap Message

Send bootstrap **first** before any delegation. Fill `[PLACEHOLDERS]`, send verbatim:

<bootstrap_format>
You are a [ROLE] sub-agent ([AGENT_NAME]). You report to the orchestrator.

Rules:
- Execute all assigned work yourself. Do not spawn sub-agents for implementation, review, or fix work.
- You may use Explore sub-agents for codebase search/research only.
- Only act on delegation messages from the orchestrator. If no delegation is pending, stay idle.
- After completing assigned work, send a single return message and go idle. Wait for further delegation.
- Do not manage tasks for other agents. Do not act as a coordinator.
</bootstrap_format>

The `<delegation_format>` message follows as a separate message after bootstrap.

**Pi exception** (`pi-agents-tmux`): one tool call per delegation. Bootstrap is auto-injected as system prompt; the `task` argument is the filled `<delegation_format>` content alone — do not send separately or prepend it. See the Pi note at the top for the full dispatch model.

#### Format Tags Are Literal

`<bootstrap_format>`, `<delegation_format>`, and `<output_format>` tags define exact content:

1. Fill `[PLACEHOLDERS]` with actual values.
2. Omit lines/sections where the placeholder is empty or not applicable.
3. Add nothing else — no commentary, extra fields, rewording, or explanations.
4. Do not paraphrase — use exact structure, headings, and field names.
5. Placeholders hold schema fields only. Never embed workflow steps or process prose inside item records; duplication triggers a second return on idle wake-up.

When a tagged output block is followed by `Ask user`/`AskUserQuestion`, present the filled block as a normal message first. Then invoke the question tool with only a concise question and options — do not copy the report there.

#### Task Layers

Orchestrator steps, sub-workflows, and agent tasks are distinct layers. Agents only act on their own assigned work — never on orchestrator or sub-workflow items.

#### No Duplicate Agent Spawns

Never spawn a fresh agent when the same role/name is alive. Read workflow state, reuse by stored ID, respawn only after one recovery attempt or confirmed stuck/closed status. A prior completion message does not justify a duplicate.

#### Single Return Message

An agent sends exactly one completion message. If a second return arrives, treat it as a violation: diff against the first, flag unrequested commits. Root cause is usually process leakage in `[FORMATTED_ITEMS]` or extra delegation fields.

---

### Agent Lifecycle

#### Lifecycle Stages

```
1. SPAWN       Spawn with bootstrap → agent learns role and boundaries
2. DELEGATE    Send filled <delegation_format>
3. WORK        Agent executes itself — no sub-delegation
4. RETURN      Agent sends single completion message
5. IDLE/REDEL  Agent idles — may receive new delegation for fix cycles
```

#### Dev Agent Persistence

Dev agents persist for the entire session. Only shut down when:
1. User explicitly requests it.
2. Stall confirmed via the [escalation sequence](#wait-for-agent-return-before-acting) (quiet ≠ stalled; idle ≠ stuck).

Re-delegate for review fix, QA fix, comment fix, or CI fix cycles. Each re-delegation: create new tasks → send delegation message.

#### Review Agent Lifecycle Management

Review agents persist across fix → re-review cycles:
- Read `review_agents` and `review_agent_ids` before spawning.
- Reuse the same reviewer by exact name if alive or recoverable.
- Spawn only the missing/stuck subset — do not restart the full pool.
- After fixes: selectively shut down non-reporting agents for low-risk changes; keep all if risk flags present.
- Full shutdown when review passes; clear review agents state.

QA agents spawn and shut down per-agent.

#### Wait for Agent Return Before Acting

After delegation, wait for the agent's return message. On each idle notification, check the task list:
- Any in-progress → go idle.
- All completed → proceed.
- All pending (none claimed) → re-send delegation ONCE, wait one full agent turn. If still all pending, respawn.

Never re-send or intervene while any task is in-progress.

**Quiet ≠ stalled.** Minimum quiet window: 10 minutes from delegation before escalation.

**Invalid stall signals** (never sufficient alone or combined): return-message timeout, clean git status/diff/log, no modified files. These reflect worktree state only.

**Stall confirmation required** — session-level evidence:
- **Task-based** (Claude Code): status unchanged across multiple idle cycles.
- **Session-file** (Codex, OpenCode): no new log entries for 10+ minutes.
- **Process-level**: agent process exited or zero CPU.

**Escalation** (only after quiet window + confirmed stall):
1. Re-message once specifying the missing step.
2. Wait 5 min; re-check. New activity → go idle.
3. Still inactive → shut down → respawn → re-create tasks → re-delegate.

#### Orchestrator Never Fixes Code

Never edit or write code unless the user explicitly asks. Delegate to the domain agent. If an agent appears stuck, follow the [escalation sequence](#wait-for-agent-return-before-acting). Read-only commands and script invocations are permitted.

---

### State Management

#### Durable Workflow State Files

Use workflow state files for data that must survive compaction: issue tracking, sub-issues, agent persistence, cycle counts, fix/escalation tracking, audit trails. Use the `workflow-state` CLI for all reads/writes, including `set-git-head` and `set-now` instead of inline command-substitution state-write snippets.

Location: `$ORCH_STATE_DIR/workflow-state-[ID].json` (default: `tmp/`)

#### Compaction Recovery Protocol

After compaction, external state persists:
1. Check task list — find last completed, resume from next.
2. Read workflow state for persistent data (team name, cycles, agent IDs).
3. If team-based: re-read team config from disk.
4. Re-send delegation using stored agent/session IDs.
5. If no response after one idle cycle, respawn only the missing/stuck agent.

Never repeat completed actions.

---

### Coordination

#### Agent Sequencing by Data Dependency

Determine blocking relations from data dependencies:
1. Infer agent from label or component path.
2. Identify candidate pairs from sequential requirements.
3. Confirm with Creates ↔ Consumes analysis — no data flow = no blocking.
4. Set blocking relations on parent issues (not children) when bundled.

Default sequential requirements:
- Backend → Frontend (UI needs backend types/APIs first).
- `*` → Generalist (runs last — may reference any domain's changes).

#### Bundled Issue Task Structure

One composite task per sub-issue (not one task per section). Agents execute all referenced sections, then mark the single task complete.

```
§ 1: Environment Setup          (one task)
§ 2: Activate Issue             (one task)
§ 3: Block Issue                (one task, usually SKIPPED)
§ 4-10: PROJ-001 — First sub   (composite — all sections for this sub)
§ 4-10: PROJ-002 — Second sub  (composite — all sections for this sub)
§ 11: Return to Orchestrator   (one task)
```

#### Multi-Agent Bundles

When sub-issues span domains: process groups sequentially per agent-sequencing rules, collect handoff notes between groups, and persist all dev agents per [Dev Agent Persistence](#dev-agent-persistence).

#### Parallel Work Safety Analysis

Verify safety across five dimensions before running issues in parallel:
1. **Dependency resolution** — direct blocks/blockedBy, shared blockers.
2. **Agent overlap** — same agent on multiple issues risks file conflicts.
3. **Code scope** — file paths, modules, type/value flows.
4. **Build config** — manifest changes create hard separations.
5. **Active work** — existing worktrees and open PRs.

Grouping constraints: limit concurrent issues, limit same-agent per group, manifest conflicts as hard separations.

---

### Review Pipeline

#### Review Finding Schema

Full schema in reviewer skill: [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md). Summary:

- `verdict`: `action_required` if blockers exist, `pass` otherwise.
- `location`: file path with function/struct name — never line numbers.
- Each item: `id`, `title` (5-10 words), `location`, `description`, `recommendation`, `priority` (1-4), `estimate` (1-5).
- Suggestions also require `category`: `fix` or `issue`.

#### Recommendation Categorization

Evaluate each suggestion in order:

1. **Actionable?** Specific deliverable, observable impact, bounded scope. Vague → omit.
2. **Related?** Doc updates for changed code → always `fix`. Unrelated → `issue`.
3. **Size?** Small → `fix`. Needs delegation/tracking → `issue`.

| Signal | Category |
|--------|----------|
| Small, quick to apply | `fix` |
| Doc/reference for changed code | `fix` — always |
| Needs tracking or history | `issue` |
| Architectural/cross-component | `issue` |
| Test coverage (existing test) | `fix` |
| Test coverage (new suite) | `issue` |
| Error handling gaps | `issue` |
| Security vulnerabilities | `fix` if quick, else `issue` — never skip |

"Low priority" ≠ omit. Track if actionable.

#### Issue Audit Pipeline

Collect review JSON → transform `category=issue` suggestions into audit input → delegate to TPM for tracked issue creation. Sources: suggestions, escalated blockers, planned items, discovered work.

Audit item fields: `index`, `title`, `location` (no line numbers), `description` (2-3 sentences), `recommendation` (bullet list), `priority`, `estimate`, `found_by`, `origin` (`suggestion`/`escalated`/`planned`/`discovered`). Populate dependency fields when order is known.

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
