# Workflow State Schema

Persistent state file for orch workflows. Survives context compaction.

**Location**: `<state-dir>/workflow-state-[ISSUE_ID].json` — `<state-dir>` resolves to the global `--state-dir <path>` flag, then `$ORCH_STATE_DIR`, then `tmp/`.

**Key**: `[ISSUE_ID]` is the normalized workflow-state key — `issue-N` for GitHub issues, `PROJ-123` for Linear — never the bare GitHub issue number. Every `workflow-state` action except `init` aliases a bare numeric key to the `issue-N` file when only that file exists; the exact-key file wins when present, and the command errors instead of guessing when files exist under both keys.

## Schema

```json
{
  "issue_id": "PROJ-123",
  "sub_issues": ["PROJ-124", "PROJ-125"],
  "agent": "backend",
  "worktree": "/absolute/path/to/worktree",
  "branch": "user/proj-123",
  "team_name": "proj-123",
  "qa_labels": ["needs-perf-test", "needs-safety-audit"],
  "child_sessions": {
    "backend": { "status": "active", "agent_id": "agent_abc123", "runtime_agent_type": "backend", "agent_type_fallback": null, "spawned_at": "[ISO_8601_UTC]" },
    "frontend": { "status": "closed", "agent_id": "agent_def456", "runtime_agent_type": "worker", "agent_type_fallback": "spawn_rejected_or_unavailable", "spawned_at": "[ISO_8601_UTC]" }
  },
  "review_agents": ["security-review", "test-review", "doc-review"],  // project-configured
  "review_agent_ids": {
    "security-review": "agent_rev123",
    "test-review": "agent_rev456",
    "doc-review": "agent_rev789"
  },
  "review_agent_runtime_types": {
    "security-review": { "agent_type": "security-review", "task_name": "security_review", "fallback": null },
    "doc-review": { "agent_type": "worker", "fallback": "spawn_rejected_or_unavailable" }
  },
  "review_wave_done": ["security-review"],
  "pre_delegate_sha": "abc123f",
  "skip_qa": false,
  "cycles": 0,
  "rereview_cycles": 0,
  "submit_cycles": 0,
  "review_delegated_at": 1769600000,
  "dev_delegated_at": 1769600000,
  "dev_round_id": "1769600000123456789-1837",
  "worktree_gen": "1769599990-3f7a1c05be24d918",
  "review_skipped": "tiny-docs",
  "json_paths": [
    "tmp/review-security-20260128-100000.json"
  ],
  "fixed_items": [
    {
      "description": "Null pointer dereference in empty buffer",
      "location": "src/lib.rs:42",
      "commit": "abc123f",
      "source": "pr-review"
    }
  ],
  "escalated_items": [
    {
      "description": "Auth token refresh not implemented",
      "location": "src/auth/mod.rs",
      "reason": "Requires API design decision",
      "outcome": "blocked",
      "source": "qa-review"
    }
  ],
  "audit_issues_created": ["PROJ-200", "PROJ-201"],
  "rebase_map": {
    "0a1b2c3d4e5f60718293a4b5c6d7e8f901234567": "76543210f9e8d7c6b5a49382716051423344abcd"
  },
  "pr": {
    "baseline_lines": 138
  },
  "pr_review_baseline": {
    "last_threads": ["PRRT_kwDOABC123", "PRRT_kwDODEF456"]
  },
  "pr_comment_review": {
    "iterations": 0,
    "fixes": [],
    "issues_created": [],
    "skipped": [],
    "replied": [],
    "patched_causes": [],
    "frozen_causes": []
  },
  "pr_approval": {
    "forced": false,
    "gate": "on"
  },
  "merge_queue_watch": {
    "state_path": "/repository/.git/kendex/orch/merge-queue/PROJ-123.json",
    "watch_id": "1769600000-1234-5678",
    "repository": "owner/repo",
    "pr_number": 42,
    "head_sha": "abcdef0123456789abcdef0123456789abcdef01"
  }
}
```

## Field Definitions

| Field | Type | Description |
|-------|------|-------------|
| `issue_id` | string | Parent issue identifier |
| `sub_issues` | string[] | Child issue IDs if bundled |
| `agent` | string | Primary dev agent type |
| `worktree` | string | Absolute path to git worktree |
| `branch` | string | Git branch name |
| `team_name` | string | Agent team name (optional, for recovery) |
| `qa_labels` | string[] | QA trigger labels from dev return |
| `child_sessions` | object | Per-agent lifecycle keyed by logical agent name: `{agent: {status, agent_id, runtime_agent_type, agent_type_fallback, spawned_at}}`. `status` is `"active"` while the session is live (`dev-start.md` § 2 stamps it at spawn) and `"closed"` once the caller's shutdown step retires it (`start-worktree.md` § 5.5). Reviewer slot accounting treats a record with a missing `status` field as active |
| `review_agents` | string[] | Reviewer names currently expected to stay alive across fix/re-review cycles; in wave mode (`REVIEWER_SLOT_BUDGET` exceeded) only the currently launched wave |
| `review_agent_ids` | object | Reviewer session IDs keyed by name — reuse before spawning `{"name":"id",...}` |
| `review_agent_runtime_types` | object | Reviewer runtime agent metadata keyed by logical reviewer name: `{name: {agent_type, task_name?, fallback}}`; records a Codex `worker` fallback and, when the runtime `task_name` schema forced a hyphens-to-underscores spelling, the translated `task_name` — without changing the logical keys |
| `review_wave_done` | string[] | Wave mode only: reviewers whose report artifact validated (or who went unresponsive) in the current review cycle. Reset at each new cycle's first wave; the next wave launches the first budget-sized batch of `[AGENTS]` not listed here |
| `reviewer_slots_observed` | number | Effective wave size proven by the runtime when a persistent (unlimited-budget) launch hit the thread limit. While set, `review-pr.md` § 2 enters wave mode at this size even though `REVIEWER_SLOT_BUDGET` is `0` |
| `pre_delegate_sha` | string\|null | HEAD before delegation — scopes re-review diffs. review-pr § 2.2 sends it to a re-review re-entry as `Diff-range`, a boundary no reviewer can derive from its own delegation |
| `skip_qa` | boolean | Skip QA for re-cycle (cleared after routing) |
| `cycles` | number | General fix-round tally — `dev-fix.md` increments it on every fix round (review-pr § 4 and § 7, plus pre-loop review/submit rounds). It fills review-pr § 1.2's previous-cycle block and the session summaries; it decides no cap |
| `rereview_cycles` | number | § 4 → § 2 re-review cycles entered, counting entries already taken. `workflow-state set … rereview_panel` raises it in the same locked write it gates, so only that re-entry spends the budget `REVIEW_MAX_CYCLES` bounds — a § 7 QA re-check (`qa_recheck_panel`) and any fix round do not |
| `submit_cycles` | number | Submit-PR iteration count (created-issue re-submit loops) |
| `review_delegated_at` | number | Epoch seconds of last review delegation — the freshness boundary `review-pr.md` § 3 passes to `review-artifact-check` |
| `dev_delegated_at` | number | Epoch seconds of last dev/QA delegation (implement, fix, or analysis) — the watchdog deadline for stall escalation. It does not gate artifact acceptance; the round id does |
| `worktree_gen` | string | The session-guard lease generation this session took possession of the worktree under, recorded by `worktree-claim` at the first round stamp and re-verified at every later one; a stamp whose generation differs from the lease refuses |
| `dev_round_id` | string | Unique per-delegation round token, minted by `workflow-state new-round-id [ISSUE] dev_round_id` immediately before each dev/QA delegation (implement, fix, or analysis) and embedded in it. It is the completion artifact's identity ([`dev-return.md`](dev-return.md)) and, on a fix round, the delegated-item record's ([`dev-round.md`](dev-round.md)) |
| `review_skipped` | string | Set to `tiny-docs` when a trivial diff skipped review by rule |
| `rereview_skipped` | string | Why a fix round routed to submit WITHOUT re-review. Present only when the skip happened |
| `rereview_panel` | object | `{agents: string[], reason}` for a § 4 fix round re-reviewed by a scoped panel instead of the full set. Setting it is the § 4 → § 2 re-review re-entry: the write raises `rereview_cycles` and refuses once that count reaches `REVIEW_MAX_CYCLES`, which is therefore the number of re-entries allowed |
| `qa_recheck_panel` | object | `{agents: string[], reason}` for review-pr § 7's § 7 → § 6 QA re-check. A QA re-check is not a re-review cycle, so this key is deliberately separate from `rereview_panel`: the cap neither counts nor refuses it, and a § 4 loop that spent its whole budget still gets its QA re-check |
| `verification_panel` | object | `{agents: string[], reason}` for review-pr § 7's § 7 → § 2 pass over a fix diff no reviewer has seen. A verification pass is not a fix cycle, so this key is separate from `rereview_panel`: the cap neither counts nor refuses it, which is what § 4's rule states in words |
| `auto_decisions` | string[] | Audit trail of decisions taken without a user prompt under `ORCH_DECISION_MODE=auto-recommended`: one `auto-selected: [option] — [reason]` line per auto-executed ask-user step. Absent under the default `ask` mode |
| `json_paths` | string[] | Accumulated review JSON file paths |
| `fixed_items` | object[] | Blockers successfully fixed. A `commit` of the form `dropped:<sha>` marks a fix whose commit vanished in a rebase (its patch was already upstream) — publishers omit it or cite the upstream equivalent, never print it as a live SHA |
| `escalated_items` | object[] | Items dev did not apply, plus items still outstanding when review-pr's cycle cap ends the fix loop. `outcome` records the per-item decision — `"blocked"` (could not fix; the cap path always writes this) or `"skipped"` (deliberately skipped); an entry without `outcome` is treated as blocked. The audit builder maps it to a distinct `origin`. An item is never in both buckets: every dev-fix outcome write clears the item from both, matched on (location, description), before appending its own entry |
| `audit_issues_created` | string[] | Issue IDs created by audit |
| `rebase_map` | object | Old→new commit SHA map accumulated from `worktree push` auto-rebase output (`rebase-map:` lines), written by orch `worktree-push`. Keys are pre-rebase SHAs; values are post-rebase SHAs, or the literal `"dropped"` when the replayed commit vanished. `worktree-push` rewrites the SHAs stored elsewhere in state at push time — `fixed_items[].commit` and `pr_comment_review.fixes[].commit` become the new SHA truncated to the recorded length, or the marked form `dropped:<recorded sha>` for a dropped mapping. The map remains for artifact-sourced references (e.g. perf QA `benchmark_commit`) — resolve through it repeatedly until no key matches |
| `pr` | object | Pull-request growth state. `baseline_lines` is the one authoritative value. Accepted round-mode implementation receipts write it only when null; fix rounds only read it. Rebases and later rounds do not move it |
| `pr_review_baseline` | object | `last_threads[]` — the unresolved review-thread IDs present at the end of the last triage pass. `review-pr-comments.md` § 6.3 calls a thread new when its id is absent from this array; never store a count here |
| `pr_comment_review` | object | PR comment review tracking: `iterations`, `fixes[]`, `issues_created[]`, `skipped[]`, `replied[]` (thread IDs answered), `patched_causes[]` — one `{cause, commit}` per patched cause, the single record [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence) reads: this workflow writes it where the reply resolves the thread, and [dev-fix.md](../workflows/dev-fix.md) § 2 writes it for the `pr-review`, `qa-review`, and `review` loops, whose items land in `fixed_items`; `frozen_causes[]` — one `{cause, issue}` per cause frozen by [finding-disposition.md § Recurrence](../references/finding-disposition.md#recurrence), written before the `Tracked:` reply; a later finding on a listed cause is declined, never re-triaged |
| `pr_approval` | object | Reviewer-gate override tracking: `forced` (the user chose Force merge past a missing verdict), `reviewer_down` (`PR_REVIEW_ON_TIMEOUT=proceed` auto-proceeded past the deadline with every reviewer silent), `gate` (legacy: `off` for a reviewer-less repo, still written and still read as the gate-4 fallback) |
| `pr_review` | object | Reviewer-gate mode tracking: `mode` ("approval"/"review"/"off" as printed by `approval-wait --resolve-mode` from `PR_REVIEW_GATE`, or derived from legacy `PR_APPROVAL_GATE`) |
| `merge_queue_watch` | object | Pointer to the lifecycle file owned by `merge-queue-watch`. `state_path`, `watch_id`, `repository`, `pr_number`, and `head_sha` bind workflow state to the prepared repository, PR, head, and generation. Its terminal statuses, its cleanup dispositions, and the fields `consume` revalidates before claiming are `merge-queue-watch --help` |

## CLI

All operations use `.agents/skills/orch/scripts/workflow-state` (run with `help` for full usage).

To target a state directory from a worktree, pass the global `--state-dir <path>` flag before the subcommand — it takes precedence over `ORCH_STATE_DIR`. Prefer it over an `ORCH_STATE_DIR=… workflow-state …` env prefix (rejected under Codex `approval=never`). `ORCH_STATE_DIR` stays supported as an environment fallback.

`set` values are JSON only when they look like it — a `{`/`[` prefix, exactly `null`/`true`/`false`, or all digits. `append` is narrower: only a `{`/`[` prefix is spliced as JSON (a bare `null`/`true`/`123` appends as a string). Every other value is stored as a raw string: pass plain strings bare — `set PROJ-123 pr_review.mode review`, never `'"review"'`. `update` always takes a jq expression.

```bash
.agents/skills/orch/scripts/workflow-state init PROJ-123 --agent backend --worktree /tmp/wt
.agents/skills/orch/scripts/workflow-state get PROJ-123 .cycles
.agents/skills/orch/scripts/workflow-state get PROJ-123 .rereview_cycles
.agents/skills/orch/scripts/workflow-state increment PROJ-123 cycles
.agents/skills/orch/scripts/workflow-state append PROJ-123 json_paths "review.json"
.agents/skills/orch/scripts/workflow-state set PROJ-123 pr_review.mode review
.agents/skills/orch/scripts/workflow-state set PROJ-123 pr_review_baseline '{"last_threads":["PRRT_kwDOABC123","PRRT_kwDODEF456"]}'
.agents/skills/orch/scripts/workflow-state --state-dir /path/to/tmp append PROJ-123 fixed_items '{"description":"Fix"}'
```
