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

Load IN ORDER before anything else. Do not proceed if any fails.

1. Load `github`.
2. Load `worktree`.
3. Load tracker: Linear issue → load `linear`; GitHub issue → use `github` only.

> **MODE SWITCH**: Loading this skill puts you in **orchestrator mode**. Do not write code yourself. Delegate all implementation, review, and QA work to specialist sub-agents using the workflows in this skill.

> If you are running in **Claude Code**: Always create a team before launching agents. Spawn and delegate to agents within the team context so they share state and can be messaged for re-delegation. When asking the user a question or presenting options, always use the `AskUserQuestion` tool. `SendMessage` accepts exactly `to`, `summary`, `message` — extra fields (`type`, `recipient`, `content`, `body`) have caused duplicate delivery on idle wake-up.

> If you are running in **Codex**: Under `approval_policy = never`, the Codex CLI classifies shell CONTROL SYNTAX as approval-required no matter how harmless the inner commands are — `for`/`while` loops, multi-command blocks (`;`- or newline-separated), `VAR=x cmd` env-assignment prefixes, `$(...)` substitution (a literal backtick anywhere in the command counts, even inside a quoted search pattern — write the regex hex escape `\x60` instead), and redirection all rejected with `approval required by policy, but AskForApproval is set to Never`. That error means the command *shape* was flagged, not access: do not retry the same shape and do not wait for approval (none can arrive) — rewrite as one simple command per tool call. Replace polling loops with the orch waiters `.agents/skills/orch/scripts/ci-wait` (CI status), `.agents/skills/orch/scripts/approval-wait` (review approval), and `.agents/skills/orch/scripts/queue-wait` (merge-queue / auto-merge outcome) — orch scripts, never `github.sh` subcommands; replace multi-item sweeps such as per-worktree `git status` with a separate single command per item; derive values with helper scripts (`git-context`, `workflow-state`) instead of substitution; write files with harness file tools or `apply_patch`, never redirection. The classifier also rejects some porcelain verbs outright — a policy-rejected top-level `git rebase` has a documented replacement: the worktree skill's guarded `create <ID> --reuse`/`--restack` path with `worktree restack continue|skip|abort` controls, or, when that too is unavailable, the exact replay in worktree `SKILL.md` § Policy-blocked rebase (cherry-pick replay fallback) — never an improvised force-push. Authoring rules for generated workflow commands live in § Harness-Safe Shell.
>
> Spawn generated vstack agents with `agent_type` set to the actual generated agent name and `fork_context: false`. Reviewers returned by `list-review-agents` must first spawn as `agent_type=<reviewer-name>`; dev agents selected from `agent:X` labels must first spawn as `agent_type=X`. The spawn API's `task_name` schema accepts only lowercase letters, digits, and underscores (`[a-z0-9_]`) and rejects hyphenated names before launch (vstack#751), so spawn a canonical hyphenated agent name by translating hyphens to underscores in the runtime `task_name` only (`reviewer-arch` → `task_name=reviewer_arch`; `agent_type` still resolves the generated agent whose name is canonical). Attempt this translation before any `worker` fallback — a `task_name` schema rejection is a naming mismatch, not a missing agent type. Use `worker` only for an intentional generic-worker fallback, when no matching generated agent exists, when the selected agent is deliberately generic, or after the generated-agent spawn is attempted and the Codex spawn API rejects or does not expose that generated `agent_type`. In fallback, preserve the logical selected agent name in reports and workflow-state keys (`child_sessions[agent]`, `review_agent_ids[reviewer-name]`); record the runtime `agent_type=worker` and fallback reason separately in status and workflow state. Translated or not, the canonical hyphenated name is the identity everywhere orch records it — workflow-state keys, report artifacts, delegation records; the underscore `task_name` is a runtime detail recorded, like the worker fallback, in runtime metadata (`review_agent_runtime_types[reviewer-name].task_name`). Two-step pattern: (1) spawn the selected runtime agent with the `<bootstrap_format>` message, (2) `send_input` a `DELEGATION:` prefixed message containing exactly the filled `<delegation_format>` content — nothing more.
>
> The Codex collaboration runtime also caps concurrent agent threads — MultiAgentV2's configurable default is 4 total, counting this primary session (`features.multi_agent_v2.max_concurrent_threads_per_session` in `~/.codex/config.toml`; set the legacy `agents.max_threads` too, but never alone — MultiAgentV2 silently ignores it, so raising only that key changes nothing (openai/codex#33447, #33039) — and a running session keeps its old cap until restarted); a spawn beyond the effective cap fails with `collab spawn failed: agent thread limit reached`. Set `REVIEWER_SLOT_BUDGET` in `vstack.settings.toml` `[env]` to the cap the machine config declares (`"4"` on a default config) so review workflows compute the available reviewer slots and run reviewers in bounded waves when the set does not fit — see [Review Agent Lifecycle Management](#review-agent-lifecycle-management). If the budget is left at `0` (unlimited) and a reviewer spawn hits that error anyway, review workflows demote the cycle to bounded waves automatically — sized by the reviewers that did spawn — and recommend the observed budget (`review-pr.md` § 2.2 persistent-mode thread-limit recovery).
>
> For **Codex Desktop app handoff**, invoke `workflows/handoff.md` with `harness=codex-app`. When `handoff` receives multiple issues and the runtime exposes Codex app thread tools, default to `harness=codex-app` unless the user explicitly selected another harness. Before creating child threads, run the Codex app agent preflight to check whether tracked `.codex/agents/*.toml` files are present in the saved project branch, because setup hooks run too late for subagent type discovery. If preflight reports a warning, present the exact message and continue only after explicit user acceptance of the risk that child sessions may fall back to `worker`; stop only on a preflight `severity=error` or if the user declines. Create one Codex app thread per issue with `codex_app.create_thread`, target a worktree environment whose `startingState` is `type="branch"` with `branchName` set to the resolved base branch, start it with exactly `$orch start [ISSUE_ID]` or `$orch start github [OWNER/REPO]#[N]`, and record the returned thread ID. Do not use a `working-tree` starting state for orch app handoff unless the user explicitly requests a dirty local snapshot; that path can start the child before generated Codex agents are visible and force `worker` fallback. Do not silently create degraded child threads; the user must accept the warning first. If the runtime separates thread creation from prompting, call `codex_app.send_message_to_thread` once with that same start prompt. The Codex CLI does not expose these tools; do not emulate app handoff with terminal launch, `codex debug app-server`, raw `codex app-server`, or manual app-thread instructions.

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
| `submit-pr` | `[PR_NUMBER]` | `workflows/submit-pr.md` | Local review, push, create PR, async triage, approval gate, CI verify |
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
| `workflows/submit-pr.md` | `submit-pr` | Local pre-PR review, push, create PR, async comment triage, approval gate before CI verify, merge gates |
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
| `review-artifact-check` | Validate a reviewer's on-disk JSON artifact (exists, `mtime >=` delegation epoch, `jq -e '.verdict'`, and no self-reported no-review) and print `{ok, path, reason}` — the sole review-pr completion condition. An artifact whose `qa_metadata` admits no review happened (`review_performed: false` or a no-scope reason) is rejected with reason `no_review` regardless of verdict; an artifact declaring `qa_metadata` whose `blockers[]`/`suggestions[]` are lost (missing/non-array) OR whose present items omit a required `review-finding` field — including the routing-critical `category ∈ {fix,issue}` on suggestions (vstack#810) — is rejected with reason `incomplete` (plus a `detail` field naming the offending item and field); artifacts without `qa_metadata` are unaffected. `--file <path> [delegated_at_epoch]` validates one explicit artifact; the optional boundary applies the same freshness gate so a stale/misdated external review is rejected |
| `dev-return-write` | Deterministically write a dev agent's round-scoped completion artifact (`[WORKTREE]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json`) with `jq`, atomically (temp+mv), instead of hand-authoring the JSON. `--worktree PATH --kind implement\|fix --issue ID --round-id RID --branch B --commit SHA --validate STR [--validate-note TEXT] [--qa-label L]... [--bundled] [--no-summary] [--summary-file PATH] [--item N DECISION REASONING]...`; writes `round_id`/`schema_version`, validates inputs (exit 2 on bad `--kind`, missing required arg, malformed `--validate`, bad `--item` DECISION, empty REASONING, an `--issue`/`--round-id` outside `^[A-Za-z0-9._-]+$`, or a `fix`/`--bundled` invocation with no `--item`) and prints the artifact's absolute path. Canonical schema: `schemas/dev-return.md` |
| `dev-artifact-check` | Validate a dev agent's round-scoped completion artifact and print `{ok, path, reason}` (`valid`\|`missing`\|`invalid`\|`incomplete`, gates ordered missing → invalid → incomplete → valid). Round mode `--worktree WT --issue ISSUE --round-id RID [--expect-items N,N,...]` resolves `WT/tmp/dev-return-ISSUE-RID.json`, requires its internal `round_id == RID` (clock-independent identity — no mtime gate, vstack#776), the type-strict scalars (`.kind` ∈ implement\|fix; `.issue/.branch/.commit/.validate` non-empty strings; `.round_id` string; `.schema_version` number), and the items rule (`--expect-items` = exact delegated set for fix rounds; else non-empty well-formed for fix/bundled; `implement` allows `items: []`). A fresh valid artifact for the current round lets `dev-start.md` § 3 accept a completion whose return never arrived because the validation outlasted the turn (vstack#770); git/tracker corroboration stays in orch. `--file <path> [--round-id RID] [--expect-items ...]` validates one explicit artifact. One identity model (round id) — no mtime gate, no legacy positional mode |
| `tracker-for-issue` | Print `github` for `issue-*` ids and `linear` otherwise |
| `approval-wait` | Poll for the reviewer-gate verdict plus unresolved-thread count — the submit-pr § 4 review-gate poller: GitHub-native approval (`reviewDecision`/`latestReviews`) by default, `--mode review` waits for a non-author review of the current head + zero unresolved threads, `--resolve-mode` prints the project's effective gate mode; never parses bot reactions or sticky prose |
| `ci-wait` | Block until CI completes on a PR — runs after the review gate; correlates the current-head substantive run with custom aggregate status (and with the head's Actions run list when the check rollup hides a newer dispatch), and `CI_WAIT_NO_CHECKS_GRACE` (default 180s) bounds unregistered checks |
| `queue-wait` | Block until a PR's merge-queue / auto-merge outcome is decided — the merge-pr § 3.2 queue watch. Reads `gh pr view --json state,mergedAt` plus the GraphQL `isInMergeQueue`/`mergeQueueEntry`/`autoMergeRequest` fields each poll (`gh pr view` exposes no queue-membership field) and holds `WAS_QUEUED` across polls, so an ejection is distinguishable from a PR that was never queued; delegates the failed-required-check disarm cause to `ci-wait` (`--no-check-probe` opts out) |
| `PR_REVIEW_GATE` | Reviewer-gate mode (gate 4): `approval` requires the GitHub-native approval verdict; `review` requires a non-author review of the current head + zero unresolved threads (for commenting-only review bots that never approve); `off` = reviewer-less repo, wait skipped and gate recorded not-applicable (default `approval`; legacy `PR_APPROVAL_GATE` `on`/`off` maps to `approval`/`off` when unset) |
| `PR_REVIEW_CHECK` | Exact name the trusted review bot publishes on analyzed heads (e.g. `Devin Review`): in `review` mode a `success` signal of that name on the current head — a check-run conclusion or a commit-status context, whichever surface the bot publishes (vstack#654, vstack#681) — is accepted as review evidence when no review object is pinned there, for bots that submit reviews only with findings. Matched by name/context only; trust is user configuration, like `PR_REVIEW_NUDGE`. Empty (default) = review objects only |
| `PR_REVIEW_ON_TIMEOUT` | Deadline behavior when no reviewer posts (credits exhausted): `block` (default) → `timeout`, workflow prompts; `proceed` → `proceeded` (exit 0) recorded as a reviewer-down override so a dead reviewer never stalls the fleet, but only with zero unresolved threads (open threads return `comments` first) and CI/comment-hygiene gates still apply; a `changes_requested` always blocks |
| `PR_REVIEW_OUTAGE_CONTEXT` | Makes `proceed` end-to-end where CI independently gates on review evidence: names a commit-status context orch posts as `success` on a proceeded head, which the repo-side gate accepts (`outageok` term) + refire-bridge re-runs (DEVELOPMENT.md "Reviewer-outage recognition"). Empty (default) = orch-side-only. SECURITY: branch-protection relaxation bounded by the genuine-silence predicate + bot-only status trust; trusted publishers only |
| `orch-env` | Print the effective value of a vstack `[env]` setting (process env > `vstack.settings.toml` > supplied default; numeric defaults reject non-numeric values) — how workflows read `CI_FIX_MAX_CYCLES` |
| `refix-route` | Decide whether a fix round needs re-review — prints `{decision, class, reason, …}` from the diff summary plus the round's blocker count. Route on `class`, never on `scope` alone (`review-pr` § 4 / § 7 / § 10) |
| `session-init` | Initialize session state for a new worktree (called by `initialize.md`) |
| `open-terminal` | Launch-only handoff helper for Linear/GitHub worktrees. `--lane auto[:<harness>]` picks the account with the most headroom via `lanes` and refuses to launch when every lane is over `--lane-max-pct` (default 90); `--lane <config-dir>` pins one explicitly. The lane resolves BEFORE any worktree is created, and rides on the launched command as an env prefix so a stalled session shows its account in `ps` |
| `lanes` | Enumerate harness auth lanes on this machine (Claude config dirs, Codex home) and measure each one's live usage. `lanes list [--harness claude\|codex\|all] [--json]` emits `{alias, harness, config_dir, status, plan, session_5h_pct, weekly_pct, model_pct, model_label, headroom_pct, resets, detail}` per lane; `lanes pick [--harness H] [--max-pct N]` prints the launch env prefix for the lane with the most headroom and exits **3** when none qualifies. Headroom is `100 - max(bucket)` — the BINDING window, never an average. Mechanism only: per-project policy belongs in each consumer's own wrapper |
| `parallel-groups` | Local cache for safe parallel handoff analysis |

`ci-wait --json` returns `{status, verdict, elapsed_seconds, pending_checks, failed_checks, passed_checks}` where `status` is `complete`/`timeout`/`error` and `verdict` is `pass`/`fail`/`pending`. It ignores later all-skipped dispatches when selecting the current-head substantive workflow run and treats an aggregate status still linked to an older run as pending while a newer substantive run has no failures. A settled failure attributable only to superseded runs — e.g. a review run cancelled by concurrency whose same-second review-comment sibling never surfaces in the check rollup — is additionally correlated against the head's Actions run list (vstack#650, vstack#699): any queued or in-progress substantive-event run on the head — including a rerun attempt of an older run, which keeps its original run id — keeps the verdict pending; a newest same-workflow run (by id, or by a rerun attempt's fresher settlement) that completed successfully discards the stale failures; and a failed newest run — or a cancelled run with no newer or fresher sibling — stays terminal. Current-run failures remain terminal; a missing replacement reaches the existing timeout and never passes. Every exit path emits a final stdout result (a `CI passed`/`CI failed`/`CI timeout`/`CI error` line without `--json`); checks still in progress at the deadline report `status: "timeout"`, never silent success.

`approval-wait --json` returns `{status, review_decision, approvals, changes_requested, unresolved_count, elapsed_seconds}` where `status` is `approved`/`reviewed`/`changes_requested`/`comments`/`timeout`/`proceeded`/`error`. `proceeded` (exit 0) is the `PR_REVIEW_ON_TIMEOUT=proceed` reviewer-down degrade — a deadline reached with zero unresolved threads and no reviewer evidence; the `--on-timeout block|proceed` flag overrides the setting. Approval is GitHub-native only, either signal: `reviewDecision == "APPROVED"`, or — when `reviewDecision` is empty because no required-review protection exists — at least one reviewer whose latest review is APPROVED and none whose latest review is CHANGES_REQUESTED. Any reviewer counts, human or bot; emoji reactions, sticky comments, and checklist prose are never parsed. `REVIEW_REQUIRED` never falls back to `latestReviews`. `status: "comments"` is an early return when unresolved review threads exist without a verdict, so callers triage instead of idling to the deadline. Every exit path emits a final stdout result (an `Approval ...`/`Review ...` line without `--json`); no verdict at the deadline reports `status: "timeout"` (or `proceeded` under `PR_REVIEW_ON_TIMEOUT=proceed` when there is zero reviewer evidence and no unresolved threads), never silent success.

`approval-wait --mode review` (vstack#642) waits for a formal review instead of an approval — for repos whose review bots only post COMMENTED reviews. It succeeds with `status: "reviewed"` (exit 0, JSON adds `mode`, `head_sha`, `reviews_at_head`) when a submitted review is pinned to the current head SHA (re-read every poll, so a force-push resets the wait), is not DISMISSED and not the PR author's own — any state counts, an approval is also a review — with no non-author reviewer's latest review standing at CHANGES_REQUESTED and zero unresolved review threads. With `PR_REVIEW_CHECK` set to the trusted review bot's published name, a `success` signal of exactly that name on the current head also counts as review evidence — the newest check-run with that name concluding `success`, or, when no check-run matches, a commit-status context of that name at state `success` (vstack#654, vstack#681; some bots publish statuses, not check-runs) — for bots that submit a review object only when they have findings, under the same CHANGES_REQUESTED and thread conditions; the JSON result then carries `review_evidence` (`"review"` or `"check"`) naming the signal that passed, plus `review_evidence_surface` (`"check_run"` or `"status"`) for check evidence. `approval-wait --resolve-mode` prints the project's effective gate mode (`approval`/`review`/`off`): `PR_REVIEW_GATE` when set, else legacy `PR_APPROVAL_GATE` (`on` → `approval`, `off` → `off`), else `approval` — the single implementation of that derivation; workflows read the mode through it. In both wait modes the poller also nudges silent reviewers: after `PR_REVIEW_NUDGE_SECS` (default 600s) without the mode's signal for the current head — the clock restarts on every push — it posts the user-configured `PR_REVIEW_NUDGE` comment once per head SHA, or with that setting empty falls back to a GitHub-native re-review request to the PR's requested and past reviewers.

`queue-wait --json` (vstack#819) returns `{status, verdict, elapsed_seconds, polls, pr_state, merged_at, in_merge_queue, merge_queue_state, auto_merge_enabled, was_queued, was_in_merge_queue}` where `status` is `complete`/`timeout`/`error` and `verdict` is `merged`/`ejected`/`disarmed`/`closed`/`queued`/`not_queued`/`unknown`, plus `cause` when known (`merge_group_failed`, `check_failed`, `auto_merge_cleared`, `never_armed`, `closed_without_merge`) and `transient_api_errors` when any were absorbed. Exit `0` only for `merged`; `1` for every other verdict and non-auth error; `3` on auth failure. It is the merge-pr § 3.2 queue watch as one command, which is what makes it usable under Codex `approval=never` where that section's `sleep`-poll loop is rejected — and, more fundamentally, the only place `WAS_QUEUED` can live: a per-poll re-entry carries no memory, so it cannot tell an ejected PR from one that was never queued. Ejection is `WAS_QUEUED` plus lost queue membership while still OPEN; `disarmed` is an armed-but-never-enqueued PR whose `autoMergeRequest` cleared, or whose required check failed (that half is delegated to `ci-wait ... --json` → `verdict=fail`, rate-limited by `QUEUE_WAIT_PROBE_INTERVAL` and scoped to the armed-not-enqueued shape, since a merge-queue repo already signals failure by ejection; `--no-check-probe` disables it). Ejection/disarm verdicts are confirmed across `QUEUE_WAIT_CONFIRM_POLLS` (default 2) consecutive polls so one eventually-consistent blip cannot trigger a recovery cycle, and a candidate seen at least once still wins at the deadline. `QUEUE_WAIT_ARM_GRACE` (default 120s) bounds how long a never-armed PR polls before reporting `not_queued`. A deadline reached with the PR still queued reports `status: "timeout"`, `verdict: "queued"` — the merge stays armed and fires on its own, so it is neither a merge failure nor a success.

`session-init --json` reports worktree Linear auth as the structured `linear_auth` object from `linear auth-check`. `linear_auth.error = "not installed"` is reserved for a missing Linear skill command; API key, 1Password, and API failures keep their original auth-check diagnostic.

`approval-wait`, `ci-wait`, and `queue-wait` all use `scripts/lib/gh-auth.sh`, which wraps the GitHub skill's shared auth helpers, for a bounded auth-resolution ladder — see `DEVELOPMENT.md` for the full ladder description. GitHub auth is env-first: already-resolved `GH_TOKEN`, `GITHUB_TOKEN`, or `GH_BOT_TOKEN` values from the parent process win before local files are read, and `op read` is only used for the final selected `op://` reference. Auth preflight validates selected env tokens with `gh api user`; `gh auth status` is only authoritative for keyring auth when no env token is selected. The waiters probe each candidate auth source at most once before moving to the next fallback. The `github.sh` router additionally prefers a resolved `GH_BOT_TOKEN` before a resolved `GITHUB_TOKEN` for bot-capable operations. Exit `3` on hard auth failure; callers treat all three scripts consistently.

### `workflow-state` actions

To target a state directory from a worktree, pass the global `--state-dir <path>` flag before the subcommand: it applies to every action and takes precedence over `ORCH_STATE_DIR`. Prefer the flag over an `ORCH_STATE_DIR=… workflow-state …` env prefix — the env-assignment prefix is rejected under Codex `approval=never` as a flagged command shape, while a plain flag is classifier-safe. `ORCH_STATE_DIR` remains supported as an environment fallback (default: `tmp`). Put non-secret workflow settings in committed `vstack.settings.toml` under `[env]`; `.env.local` remains supported for secrets and personal overrides.

State keys are the normalized issue IDs — `issue-N` for GitHub issues (per `start` routing), `PROJ-123` for Linear — never the bare GitHub issue number. As a safety net, every action except `init` aliases a bare numeric key to the `issue-N` state file when only that file exists; the exact-key file wins when present, and the command errors (exit 2) instead of guessing when files exist under both keys.

```bash
.agents/skills/orch/scripts/workflow-state --state-dir /path/to/tmp append PROJ-123 fixed_items '{"description":"Fix"}'
```

| Action | Purpose |
|--------|---------|
| `--state-dir <path>` (global, before subcommand) | Override state directory for every action; precedence over `ORCH_STATE_DIR` |
| `init <ID> --agent <name> --worktree <path> [--branch <b>] [--team <t>]` | Initialize state file |
| `exists [--json] <ID>` | Check state file exists; `--json` prints `{issue_id,path,exists}` and exits 0 |
| `path <ID>` | Print state file path |
| `get <ID> <.field>` | Read state field |
| `set <ID> <field> <value>` | Write state field |
| `set-git-head <ID> <field> [worktree]` | Write current `HEAD` SHA to a field without command substitution |
| `set-now <ID> <field>` | Write current epoch seconds to a field without command substitution |
| `new-round-id <ID> <field>` | Generate a unique per-delegation round token (`date +%s%N`-`$RANDOM` — nanosecond timestamp + random suffix, distinct even across rapid re-stamps), store it at `<field>`, and print it — binds a dev completion artifact to its delegation (vstack#776) |
| `append <ID> <field> <value>` | Append to array field |
| `increment <ID> <field>` | Increment counter |
| `update <ID> <jq-expr>` | Arbitrary jq mutation (e.g. nested merges) |

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/workflow-state.md` | Persistent state file schema (issue/agent/worktree identity, `child_sessions`, `review_agents`/`review_agent_ids`, cycle counters, `json_paths`, fixed/escalated items, PR comment review tracking) |
| `schemas/dev-return.md` | Dev completion-artifact (`tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json`) schema: round-id identity, fields, kind rules, `items[]` shape, written by `dev-return-write`, validated by `dev-artifact-check` |
| [`../reviewer/schemas/review-finding.md`](../reviewer/schemas/review-finding.md) | Review/QA finding JSON format |

Audit input and roadmap-plan schemas live in `project-management/schemas/` — cross-skill path.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `ORCH_STATE_DIR` | Override state file directory (env fallback for the `--state-dir` flag, which wins when both are set) | `tmp` |
| `ORCH_CACHE_DIR` | Parallel-group safety cache directory | `.cache/orch` |
| `GH_ISSUE_PATTERN` | Regex for issue IDs in branch names | — |
| `CI_FIX_MAX_CYCLES` | Max automated ci-fix cycles per PR submission / merge recovery (read via `orch-env CI_FIX_MAX_CYCLES 6`) | `6` |
| `PR_REVIEW_REFIX_MAX_LINES` | Total changed lines (insertions + deletions) a support-scope fix round may reach before `review-pr` re-reviews it anyway. A round that cleared blockers is re-reviewed regardless (read via `refix-route`) | `200` |
| `REVIEWER_SLOT_BUDGET` | Total concurrent agent-session budget of the runtime, counting the primary session (read via `orch-env REVIEWER_SLOT_BUDGET 0`). `0` = unlimited: all reviewers launch up front and persist. When the reviewer set exceeds the available slots (budget − primary − live dev/QA sessions), review workflows run reviewers in bounded waves. If the runtime contradicts an unlimited budget with a thread-limit spawn failure, the review demotes to bounded waves sized by the observed successful spawns and recommends the observed budget (`review-pr.md` § 2.2). Codex collaboration runtime: set to the config-declared cap (MultiAgentV2 default `4` total including the primary; `features.multi_agent_v2.max_concurrent_threads_per_session` in `~/.codex/config.toml`) | `0` |

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

#### Harness-Safe Shell

Generated workflow commands must be safe for strict harness command policies. Prefer one simple command per tool call with explicit arguments. Avoid inline `$(...)`, shell `for`/`while` loops, array-building snippets, heredocs, pipelines used only for value plumbing, and redirected writes to `tmp/`; Codex can classify those helper shapes as approval-required even when approval policy is `never`.

**Run exactly one command per tool call.** Multiple commands batched into a single call — newline-separated or `;`-separated — are themselves rejected under Codex `approval=never`, even with no redirection, substitution, or pipeline; the multi-command shape alone triggers the block. Never emit a fenced block that stacks several commands for one call. When related `workflow-state` operations belong together, fold reads into one `workflow-state get '{...}'` (a jq object returning every field) and writes into one `workflow-state update '... | ...'` (a piped jq expression applying every mutation atomically) rather than emitting a multi-command block. Split anything that genuinely can't collapse into one expression — `set-git-head`/`set-now` (they compute their value internally), a read mixed with a write, a `// empty` default that would collapse a combined object, or a per-item loop — into separate one-command blocks, each its own tool call.

Use helper scripts instead of shell plumbing:
- `git-context` for branch/head/timestamp/issue values.
- `workflow-state` for state: `get '{...}'` combines related reads into one call, `update '... | ...'` combines related writes into one atomic call, and `set-git-head`/`set-now`/`append`/`increment` cover git-, clock-, and per-item writes.
- Harness file-write/edit tools, or `apply_patch`, for Markdown/JSON bodies and completion summaries.

When a workflow needs several files read, issue separate read commands for each file or use the harness file-read tool; do not wrap required reads in a shell loop. When an optional environment variable affects a command, either omit the option and let the script auto-detect, or first read the value with `printenv VAR` and then run a second command with a literal value. Do not include unset-variable expansions such as `"$OPTIONAL_OVERRIDES"` in required command examples.

**Env-assignment prefixes are normalized at acceptance, not at run time** (vstack#714). A required command shaped `VAR=value cmd args` — however authoritative its source: a maintainer issue spec, a delegated verification list, a review recommendation — is rejected under Codex `approval=never` for the prefix shape alone. Normalize it at the point where the command enters the workflow (issue preparation, delegation assembly), before any agent is asked to run it, into two simple commands: first confirm the ambient environment already satisfies the requirement — `printenv VAR` for ordinary variables; `locale` for locale variables, reading the effective `LC_*` lines (an unset `LC_ALL` with an effective `C`/`POSIX` locale satisfies `LC_ALL=C`) — then run the bare `cmd args` unchanged. The prefix is an environment precondition, not part of the required command; the bare command remains exact. `env VAR=value cmd args` is not the documented substitute: it merely relocates the assignment, the classifier is not documented to accept it, and a shape that might pass cannot carry a required verification step — if an `env` form is rejected, that rejection is final (never retry it). If the ambient environment does not satisfy the precondition, report the mismatch to the orchestrator/user as a blocker instead of running the command under the wrong environment. The rule is generic to any env-assignment prefix; locale (`LC_ALL=C`) is the motivating example.

**A literal backtick anywhere in a generated command is command substitution to the classifier** (vstack#721). A search over backtick-bearing text (Markdown inline code) is rejected for that shape alone, even when the command is a read-only `rg`/`grep`. Author the pattern with the regex hex escape `\x60` in single quotes as one simple command (`[\x60]` inside a bracket expression), in regex mode — `rg -F` has no escapes and would need the literal character. The canonical statement with the worked example lives in reviewer SKILL.md § Harness-Safe Shell; it applies to every generated command list — dev validation steps, delegated audit searches, fix recommendations — not only reviewer checks.

**Never author a workflow step that assumes top-level `git rebase` will run** (vstack#722). Under Codex `approval=never` the classifier rejects the porcelain verb itself — a harness-side classification that no user authorization or delegation can lift, so an "explicitly authorized" rebase fails identically and must not be retried or replaced with an improvised force-push. The documented equivalent for updating a clean, linear issue branch is the worktree skill's guarded `create <ID> --reuse`/`--restack` path or, when the tool path is unavailable, the exact replay in worktree SKILL.md § Policy-blocked rebase (cherry-pick replay fallback) — every step a single simple command, semantically equivalent to the rebase for a clean linear branch. A dirty tree or merge commits in the range put the branch outside that recipe: report a blocker instead of improvising.

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

Delegated command lists — verification steps from issue specs, fix recommendations, QA commands — are normalized per [Harness-Safe Shell](#harness-safe-shell) before they enter a delegation prompt: an env-assignment prefix (`VAR=value cmd args`) never survives delegation; it becomes an ambient-environment precondition check plus the bare command.

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

The `<delegation_format>` message follows as a separate message after bootstrap.

**Pi exception** (`pi-agents-tmux`): one tool call per delegation. Bootstrap is auto-injected as system prompt; the `task` argument is the filled `<delegation_format>` content alone — do not send separately or prepend it. See the Pi note at the top for the full dispatch model.

#### Format Tags Are Literal

`<bootstrap_format>`, `<delegation_format>`, and `<output_format>` tags define exact content:

1. Fill `[PLACEHOLDERS]` with actual values.
2. Omit lines/sections where the placeholder is empty or not applicable.
3. Add nothing else — no commentary, extra fields, rewording, or explanations.
4. Do not paraphrase — use exact structure, headings, and field names.
5. Placeholders hold schema fields only. Never embed workflow steps or process prose inside item records; duplication triggers a second return on idle wake-up.

When a tagged output block is followed by an `Ask user` step (in Claude Code, the `AskUserQuestion` tool), present the filled block as a normal message first. Then invoke the question tool with only a concise question and options — do not copy the report there.

#### Task Layers

Orchestrator steps, sub-workflows, and agent tasks are distinct layers. Agents only act on their own assigned work — never on orchestrator or sub-workflow items.

#### No Duplicate Agent Spawns

Never spawn a fresh agent when the same role/name is alive. Read workflow state, reuse by stored ID, respawn only after one recovery attempt or confirmed stuck/closed status. A prior completion message does not justify a duplicate.

#### Single Return Message

An agent sends exactly one completion message. If a second return arrives, treat it as a violation: diff against the first, flag unrequested commits. Root cause is usually process leakage in `[FORMATTED_ITEMS]` or extra delegation fields.

**Codex dual-channel completion.** On Codex collaboration agents, one completion can arrive over two channels: a `send_input` `MESSAGE`, immediately followed by a `FINAL_ANSWER` that echoes the same result (same commit, scope, and findings). This is the Codex runtime delivering a single completion twice — dual-channel delivery, not `[FORMATTED_ITEMS]` leakage. Treat the `MESSAGE` and its echoed `FINAL_ANSWER` as **one completion** and deduplicate them on the same delegation; do not flag the pair as a violation. Still diff the `FINAL_ANSWER` against the `MESSAGE`: if it carries a new commit, extra changes, or a different scope, that is a genuine second return and must be flagged per the rule above.

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

Reviewer persistence is budget-conditional: persistent when the budget allows, waves when it does not. `orch-env REVIEWER_SLOT_BUDGET 0` prints the runtime's total concurrent agent-session budget, counting the primary session (`0` = unlimited). Available reviewer slots = budget − 1 (primary) − live persistent agent sessions (`child_sessions` entries with status `active`; a record with no `status` field counts as active — legacy records predate the status stamp), minimum 1. Recompute at every review-cycle start — live sessions change between cycles.

**Persistent mode** (unlimited budget, or the reviewer set fits the available slots) — review agents persist across fix → re-review cycles:
- Read `review_agents` and `review_agent_ids` before spawning.
- Reuse the same reviewer by exact name if alive or recoverable.
- Spawn only the missing/stuck subset — do not restart the full pool.
- After fixes: selectively shut down non-reporting agents for low-risk changes; keep all if risk flags present.
- Full shutdown when review passes; clear review agents state.
- A thread-limit spawn failure during a persistent launch demotes the cycle to wave mode automatically: the spawned reviewers become the first wave, the observed spawn count becomes the wave size (persisted as `reviewer_slots_observed` so re-review cycles stay in waves), and the user gets a one-line `REVIEWER_SLOT_BUDGET` recommendation (`review-pr.md` § 2.2). The configured budget is advisory; the runtime cap is authoritative.

**Wave mode** (the reviewer set exceeds the available slots) — reviewers run in sequential waves of up to the available slots:
- Launch up to the available slots, wait for each validated report artifact, retire the completed session to release its slot, launch the next wave.
- Re-review cycles reuse the same wave mechanics: a retired reviewer is recreated fresh, and its delegation must point it at the current diff and its prior report artifact.
- **Invariant**: review state lives in on-disk report artifacts and workflow state, never in reviewer session memory. Retiring a completed reviewer loses nothing, and `review_delegated_at` + `review-artifact-check` freshness gating is unchanged (the timestamp is re-stamped per wave).

QA agents spawn and shut down per-agent.

#### Wait for Agent Return Before Acting

After delegation, wait for the agent's return — but never let the round's closure *depend* on a return message or on any wake arriving.

> If you are running in **Claude Code**: on each idle notification, check the task list — any in-progress → go idle; all completed → proceed; all pending (none claimed) → re-send delegation ONCE, wait one full agent turn, and respawn if still all pending. Never re-send or intervene while any task is in-progress.

**The orchestrator owns round closure — primary path, not a recovery fallback (vstack#803, vstack#818).** For any dev/QA delegation carrying a long validation, the agent may be structurally unable to wait for it: on Claude Code the Bash tool caps at ~10 min, a turn has no wall-clock primitive, and the background-completion wake is not delivered to in-process teammate sub-agents (anthropics/claude-code#78313), so a *correct* agent backgrounds the run and ends its turn (dev SKILL.md § Long-Running Validation) and may emit no further wake at all. Every dev/QA delegation therefore closes on these three orchestrator-side mechanics, all mandatory:

1. **Mint and embed a round token** immediately before delegating (`.agents/skills/orch/scripts/workflow-state new-round-id [ISSUE_ID] dev_round_id` → the delegation's `Round ID:` line), and re-stamp `dev_delegated_at` (now solely the watchdog deadline). Any new dev/QA fix path must do the same.
2. **Arm a single-shot wall-clock watchdog** for `dev_delegated_at + quiet_window` at that same moment, so A/B + the escalation ladder run even if NO wake ever arrives. The requirement is uniform; only the mechanism is harness-specific — Claude Code: a background shell that re-invokes the main loop on exit; Pi: a `bg_task` timer (its no-exit-wake limitation is Pi `bg_task` #15 — pair it with the per-wake check as backstop); Codex/OpenCode: scheduled re-entry / session-file poll. It fires once at the deadline, runs A/B if the round is still outstanding (else no-op), and re-arms only on entering a new nudge/escalation step — never a busy poll.
3. **Run A/B on every wake and at the deadline, and classify mechanically — never from wording or elapsed time (vstack#803).** **A** = `.agents/skills/orch/scripts/dev-artifact-check --worktree [WORKTREE] --issue [ISSUE_ID] --round-id [dev_round_id]` (read `dev_round_id` via `workflow-state get`; fix rounds add `--expect-items`); **B** = the round's git/tracker completion checks. A `finished`/`idle` wake is not evidence the round completed — an agent that idles mid-tail still emits one. Idling on a wake without running A/B is the exact stall in vstack#803.

The **acceptance decision table lives in the delegating workflow** — `dev-start.md` § 3 (implement), `dev-fix.md` § 2 and `review-pr-comments.md` § 6.1 (fixes) — and is a pure function of A and B; the return message is informational for display only, never an acceptance input. Two rules that table cannot state locally: the round token binds A to exactly THIS delegation's receipt (`tmp/dev-return-[ISSUE_ID]-[dev_round_id].json`, internal `round_id` matched, vstack#776), so a stale, same-second, cross-group, or cross-workflow receipt at a shared path can no longer be mis-accepted (mtime freshness is gone); and a path whose agent writes no dev-return artifact (`ci-fix.md` § 3.2 pushes directly) always has A `ok==false` — it is accepted by its own return message and the escalation ladder on a real stall, outside the A/B table, never by a stale artifact.

**Dev-vs-reviewer asymmetry (intentional — do not "align").** Reviewers have no independent git/tracker signal — their JSON *is* the deliverable — so a reviewer `ok==false` after a return is `incomplete` → re-delegate (`review-pr.md` § 3.1). Dev's B signal only distinguishes "code landed, recover the tail" (`ok==false` + pass → one report-only nudge) from "not done" (`ok==false` + fail → escalate); neither branch re-runs the work, and neither accepts without the round-scoped artifact.

**Invalid stall signals** (never sufficient alone or combined): return-message timeout, clean git status/diff/log, no modified files — these reflect worktree state only, as does composite **B**, which never accepts on its own. The sole positive signal that overrides a missing return is a valid `dev-artifact-check` for the current `dev_round_id`; every path converges on it.

**Stall confirmation required** — session-level evidence:
- **Task-based** (Claude Code): status unchanged across multiple idle cycles.
- **Session-file** (Codex, OpenCode): no new log entries for 10+ minutes.
- **Process-level**: agent process exited or zero CPU.

**Escalation** — **quiet ≠ stalled**: only after the 10-minute quiet window from delegation (the same `quiet_window` the watchdog arms on) AND a confirmed stall:
1. Re-message once specifying the missing step.
2. Wait 5 min; re-check. New activity → go idle.
3. Still inactive → shut down → respawn → re-create tasks → re-delegate.

#### Orchestrator Never Fixes Code

Never edit or write code unless the user explicitly asks. Delegate to the domain agent. If an agent appears stuck, follow the [escalation sequence](#wait-for-agent-return-before-acting). Read-only commands and script invocations are permitted.

---

### State Management

#### Durable Workflow State Files

Use workflow state files for data that must survive compaction: issue tracking, sub-issues, agent persistence, cycle counts, fix/escalation tracking, audit trails. Use the `workflow-state` CLI for all reads/writes, including `set-git-head` and `set-now` instead of inline command-substitution state-write snippets.

Location: `<state-dir>/workflow-state-[ID].json` — `[ID]` is the normalized workflow-state key (`issue-N` for GitHub, `PROJ-123` for Linear), and `<state-dir>` resolves to the global `--state-dir <path>` flag, then `$ORCH_STATE_DIR`, then `tmp/`. From a worktree, prefer `--state-dir` over an `ORCH_STATE_DIR=…` env prefix (rejected under Codex `approval=never`).

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

### Platform-Specific Mitigations (Claude Code teams)

Every row below is a Claude Code teams behavior. Other harnesses have their own runtime notes in the labeled blocks at the top of this skill.

| Behavior | Mitigation |
|----------|------------|
| Task status changes generate trailing notifications | On completed tasks, go idle immediately |
| Idle notifications wake orchestrator on every agent turn boundary | Never intervene while any task is in-progress |
| Worktree appears clean during agent research/planning phase | Check session-level activity — not worktree state — before declaring stall |
| Orchestrator loses teammate awareness after context compaction | Re-read `workflow-state` child session data, re-send delegation, only respawn if no response |
| Teammates lost on explicit session restart | Respawn + re-delegate pending tasks |
| Task creation notifications wake idle agents prematurely | Create tasks before spawning, or within existing team context |
