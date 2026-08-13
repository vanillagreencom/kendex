# Cycle Plan Output Schema

Returned inline by `tpm-cycle-plan.md` and written by the caller to `tmp/cycle-plan-project-complete-YYYYMMDD-HHMMSS.json` or `tmp/cycle-plan-ready-YYYYMMDD-HHMMSS.json`.

## Status: project_complete

The active project has no backlog, actionable, or in-progress issues left.

```json
{
  "status": "project_complete",
  "completed_project": {"id": "uuid", "name": "Phase 1: Foundation"},
  "next_projects": [
    {"id": "uuid", "name": "Phase 2: Data Layer", "priority": 2, "sort_order": 1.5, "ready": true, "blocked_by_incomplete": []}
  ],
  "recommended": {"id": "uuid", "name": "Phase 2: Data Layer", "reason": "First ready by sort_order"},
  "actions": {"mark_complete": {"project_id": "uuid", "project_name": "Phase 1: Foundation"}}
}
```

`ready: true` means every dependency is satisfied; `sort_order` is the manual ordering from the tracker UI; `recommended` is the first project with `ready: true`.

## Status: plan_ready

```json
{
  "status": "plan_ready",
  "project": {"id": "uuid", "name": "Phase 1: Foundation", "progress": 45},
  "cycle": {"id": "uuid", "name": "Cycle 5", "start": "2026-01-13", "end": "2026-01-20", "days_remaining": 7},
  "velocity": {"current": 95, "previous": 138, "baseline": 138, "adjustment": null},
  "capacity": {"total": 110, "planned": 85, "available": 25},
  "health": {
    "blocked": {"count": 1, "indicator": "yellow"},
    "stale": {"count": 0, "indicator": "green"},
    "velocity": {"value": 12, "indicator": "green"}
  },
  "planned_work": [
    {
      "id": "[ISSUE_ID]", "url": "https://tracker.example.com/...", "title": "Implement feature",
      "priority": 1, "estimate": 3, "agent": "backend",
      "blocked_by": null,
      "rationale": "L1 infrastructure, unblocks 3 issues",
      "enables": ["[OTHER_ISSUE_ID_1]", "[OTHER_ISSUE_ID_2]"]
    }
  ],
  "not_included": [
    {"id": "[ISSUE_ID]", "url": "...", "title": "Future work", "reason": "Blocked by [OTHER_ISSUE_ID] (not in cycle)"}
  ],
  "actions": {
    "add_relations": [{"from": "[ISSUE_ID]", "rel": "blocks", "to": "[OTHER_ISSUE_ID]", "reason": "A creates types consumed by B"}],
    "assign_to_cycle": ["[ISSUE_ID_1]", "[ISSUE_ID_2]"],
    "set_priorities": [{"id": "[ISSUE_ID]", "priority": 1}],
    "set_sort_order": [{"id": "[ISSUE_ID]", "sort_order": 100}],
    "set_estimates": [{"id": "[ISSUE_ID]", "estimate": 3}],
    "set_labels": [
      {"id": "[ISSUE_ID]", "mode": "replace_category", "category": "agent", "labels": ["agent:[TYPE]"], "preserve_existing": true}
    ],
    "update_initiative": {"id": "uuid", "status": "Active"},
    "update_project": {"id": "uuid", "state": "started"},
    "create_cycle": null
  }
}
```

### planned_work

Ordered by architecture analysis: unblocked before blocked, then layer (L0 foundation → L4 testing), then enabling value, then priority. `rationale` explains the position; `enables[]` lists what completing it unblocks; `blocked_by` is null unless the blocker is in this same cycle.

`not_included[].reason` is one of: `"Blocked by [ID] (not in cycle)"`, `"Blocked by [ID] (included, will unblock)"`, `"Over capacity"`, `"Lower priority deferred"`.

### set_labels

Each entry describes intent, not a partial replacement. The caller fetches the issue's current labels, computes the full final set, preserves unrelated labels unless `mode` is `replace_all`, preflights, and only then calls `issues update --labels`.

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Issue to update |
| `mode` | Yes | `add`, `replace_category`, or `replace_all` |
| `category` | When category-aware | Taxonomy category affected (`agent`, `platform`, `domain`) |
| `labels[]` | Yes | Labels being added or replacing the category |
| `preserve_existing` | Unless `final_labels[]` is set | Must be `true` for `add` and `replace_category` |
| `final_labels[]` | For `replace_all` | The full final issue-label set |

### create_cycle

Non-null only when no cycles exist: `{"team": "TeamName", "start": "2026-01-27", "end": "2026-02-03"}`.

### velocity

All values are estimation points summed from `completedScopeHistory`, never issue counts. `adjustment` is null unless a trigger fires:

```json
{"proposal": "increase_baseline|decrease_baseline|increase_capacity", "from": 10, "to": 15, "reason": "..."}
```

| Trigger | Proposal |
|---------|----------|
| Current ≥150% of baseline for 2+ cycles | `increase_baseline` |
| Current ≤50% of baseline for 2+ cycles | `decrease_baseline` |
| Every cycle at 100% with days remaining | `increase_capacity` |

### health

| Indicator | Green | Yellow | Red |
|-----------|-------|--------|-----|
| `blocked` (issues carrying the `blocked` label) | 0 | 1-2 | 3+ |
| `stale` (In Progress, untouched >3 days) | 0 | 1-2 | 3+ |
| `velocity` (share of baseline) | ≥80% | 50-80% | <50% |
