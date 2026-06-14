# Workflow State Schema

Persistent state file for orch workflows. Survives context compaction.

**Location**: `$ORCH_STATE_DIR/workflow-state-[ISSUE_ID].json` (default: `tmp/`)

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
    "backend": { "status": "active", "agent_id": "agent_abc123", "runtime_agent_type": "backend", "agent_type_fallback": null, "spawned_at": "2026-03-19T10:00:00Z" },
    "frontend": { "status": "closed", "agent_id": "agent_def456", "runtime_agent_type": "worker", "agent_type_fallback": "spawn_rejected_or_unavailable", "spawned_at": "2026-03-19T09:00:00Z" }
  },
  "review_agents": ["security-review", "test-review", "doc-review"],  // project-configured
  "review_agent_ids": {
    "security-review": "agent_rev123",
    "test-review": "agent_rev456",
    "doc-review": "agent_rev789"
  },
  "review_agent_runtime_types": {
    "security-review": { "agent_type": "security-review", "fallback": null },
    "doc-review": { "agent_type": "worker", "fallback": "spawn_rejected_or_unavailable" }
  },
  "pre_delegate_sha": "abc123f",
  "skip_qa": false,
  "cycles": 0,
  "submit_cycles": 0,
  "review_delegated_at": 1769600000,
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
      "source": "qa-review"
    }
  ],
  "audit_issues_created": ["PROJ-200", "PROJ-201"],
  "pr_review_baseline": {
    "last_ts": "2026-01-28T10:00:00Z",
    "last_threads": 2
  },
  "pr_comment_review": {
    "iterations": 0,
    "fixes": [],
    "issues_created": [],
    "skipped": [],
    "replied": [],
    "ci_gate_rerouted": false
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
| `child_sessions` | object | Per-agent lifecycle keyed by logical agent name: `{agent: {status, agent_id, runtime_agent_type, agent_type_fallback, spawned_at}}` |
| `review_agents` | string[] | Reviewer names currently expected to stay alive across fix/re-review cycles |
| `review_agent_ids` | object | Reviewer session IDs keyed by name — reuse before spawning `{"name":"id",...}` |
| `review_agent_runtime_types` | object | Reviewer runtime agent metadata keyed by logical reviewer name: `{name: {agent_type, fallback}}`; records Codex `worker` fallback without changing logical keys |
| `pre_delegate_sha` | string | HEAD before delegation — scopes re-review diffs |
| `skip_qa` | boolean | Skip QA for re-cycle (cleared after routing) |
| `cycles` | number | Review/fix cycle count |
| `submit_cycles` | number | Submit-PR iteration count (bot review/CI loops) |
| `review_delegated_at` | number | Epoch seconds of last review delegation — gates the § 3 filesystem-fallback watchdog |
| `review_skipped` | string | Set to `tiny-docs` when the user takes the tiny/docs-only review skip path |
| `json_paths` | string[] | Accumulated review JSON file paths |
| `fixed_items` | object[] | Blockers successfully fixed |
| `escalated_items` | object[] | Blockers that couldn't be fixed |
| `audit_issues_created` | string[] | Issue IDs created by audit |
| `pr_review_baseline` | object | Baseline for PR comment loop detection |
| `pr_comment_review` | object | PR comment review tracking: `iterations`, `fixes[]`, `issues_created[]`, `skipped[]`, `replied[]` (thread IDs answered), `ci_gate_rerouted` (CI ran early once) |

## CLI

All operations use `.agents/skills/orch/scripts/workflow-state` (run with `help` for full usage).

```bash
.agents/skills/orch/scripts/workflow-state init PROJ-123 --agent backend --worktree /tmp/wt
.agents/skills/orch/scripts/workflow-state get PROJ-123 .cycles
.agents/skills/orch/scripts/workflow-state increment PROJ-123 cycles
.agents/skills/orch/scripts/workflow-state append PROJ-123 json_paths "review.json"
.agents/skills/orch/scripts/workflow-state set PROJ-123 pr_review_baseline '{"last_ts":"2026-01-28","last_threads":2}'
```
