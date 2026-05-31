# Cycle Plan Output Schema

Output path: `tmp/cycle-plan-project-complete-YYYYMMDD-HHMMSS.json` or `tmp/cycle-plan-ready-YYYYMMDD-HHMMSS.json`

## Status: project_complete

When active project reaches 100% completion:

```json
{
  "status": "project_complete",
  "completed_project": {"id": "uuid", "name": "Phase 1: Foundation"},
  "next_projects": [
    {
      "id": "uuid",
      "name": "Phase 2: Data Layer",
      "priority": 2,
      "sort_order": 1.5,
      "ready": true,
      "blocked_by_incomplete": []
    }
  ],
  "recommended": {
    "id": "uuid",
    "name": "Phase 2: Data Layer",
    "reason": "First ready by sort_order"
  },
  "actions": {
    "mark_complete": {"project_id": "uuid", "project_name": "Phase 1: Foundation"}
  }
}
```

### Actions

| Field | Description |
|-------|-------------|
| `mark_complete.project_id` | Project ID to mark as completed |
| `mark_complete.project_name` | Project name for confirmation display |

### Selection Criteria

- `ready: true` = all dependencies satisfied
- `sort_order` = manual ordering from issue tracker UI
- `recommended` = first project where `ready: true`

## Status: plan_ready

Normal cycle planning output:

```json
{
  "status": "plan_ready",
  "project": {
    "id": "uuid",
    "name": "Phase 1: Foundation",
    "progress": 45
  },
  "cycle": {
    "id": "uuid",
    "name": "Cycle 5",
    "start": "2026-01-13",
    "end": "2026-01-20",
    "days_remaining": 7
  },
  "velocity": {
    "current": 95,
    "previous": 138,
    "baseline": 138,
    "adjustment": null
  },
  "capacity": {
    "total": 110,
    "planned": 85,
    "available": 25
  },
  "health": {
    "blocked": {"count": 1, "indicator": "yellow"},
    "stale": {"count": 0, "indicator": "green"},
    "velocity": {"value": 12, "indicator": "green"}
  },
  "planned_work": [
    {
      "id": "[ISSUE_ID]",
      "url": "https://tracker.example.com/...",
      "title": "Implement feature",
      "priority": 1,
      "estimate": 3,
      "agent": "backend",
      "blocked_by": null,
      "rationale": "L1 infrastructure, unblocks 3 issues",
      "enables": ["[OTHER_ISSUE_ID_1]", "[OTHER_ISSUE_ID_2]"]
    }
  ],
  "not_included": [
    {
      "id": "[ISSUE_ID]",
      "url": "https://tracker.example.com/...",
      "title": "Future work",
      "reason": "Blocked by [OTHER_ISSUE_ID] (not in cycle)"
    }
  ],
  "actions": {
    "add_relations": [{"from": "[ISSUE_ID]", "rel": "blocks", "to": "[OTHER_ISSUE_ID]", "reason": "A creates types consumed by B"}],
    "assign_to_cycle": ["[ISSUE_ID_1]", "[ISSUE_ID_2]"],
    "set_priorities": [{"id": "[ISSUE_ID]", "priority": 1}, {"id": "[OTHER_ISSUE_ID]", "priority": 2}],
    "set_sort_order": [{"id": "[ISSUE_ID]", "sort_order": 100}, {"id": "[OTHER_ISSUE_ID]", "sort_order": 200}],
    "set_estimates": [{"id": "[ISSUE_ID]", "estimate": 3}],
    "set_labels": [
      {
        "id": "[ISSUE_ID]",
        "mode": "replace_category",
        "category": "agent",
        "labels": ["agent:[TYPE]"],
        "preserve_existing": true
      }
    ],
    "update_initiative": {"id": "uuid", "status": "Active"},
    "update_project": {"id": "uuid", "state": "started"},
    "create_cycle": null
  }
}
```

### Label Update Actions

`actions.set_labels[]` describes intent, not a partial replacement. The caller must fetch current issue labels, compute the full final label set, preserve unrelated labels unless `mode=replace_all`, preflight, and then call `issues update --labels` with the full final set.

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Issue ID to update |
| `mode` | Yes | `add`, `replace_category`, or `replace_all` |
| `category` | When category-aware | Project taxonomy category affected (for example `agent`, `platform`, `domain`) |
| `labels[]` | Yes | Labels to add or replace into the category |
| `preserve_existing` | Yes unless `final_labels[]` present | Must be `true` for `add`/`replace_category` |
| `final_labels[]` | Required for `replace_all` | Full final issue-label set |

Unknown labels, parent/group labels, missing required categories, and exclusivity violations stop execution before mutation.

### Create Cycle Action

When no cycles exist, `create_cycle` is non-null:

```json
"create_cycle": {
  "team": "TeamName",
  "start": "2026-01-27",
  "end": "2026-02-03"
}
```

### Architecture Analysis

The `planned_work[]` is ordered by architecture analysis (1.4):

1. **Blocking status**: Unblocked issues before blocked issues
2. **Architecture layer**: Foundation (L0) → Infrastructure (L1) → Features (L2) → Integration (L3) → Testing (L4)
3. **Enabling value**: Issues that unblock more work come earlier
4. **Priority**: P1-P4 as final tiebreaker

| Field | Description |
|-------|-------------|
| `rationale` | Why this issue is at this position in the order |
| `enables[]` | Issue IDs that become unblocked when this completes |
| `blocked_by` | null if unblocked, or blocker ID if blocker is in same cycle |

### Velocity Adjustment

All velocity values are in **estimation points** (issue tracker `.estimate` field sums from `completedScopeHistory`), not issue counts or velocity-points.

When `adjustment` is non-null:

```json
"adjustment": {
  "proposal": "increase_baseline|decrease_baseline|increase_capacity",
  "from": 10,
  "to": 15,
  "reason": "Current velocity 150%+ of baseline for 2+ cycles"
}
```

| Trigger | Proposal |
|---------|----------|
| Current >= 150% baseline for 2+ cycles | `increase_baseline` |
| Current <= 50% baseline for 2+ cycles | `decrease_baseline` |
| All cycles 100% with days remaining | `increase_capacity` |

### Health Indicators

| Indicator | Green | Yellow | Red |
|-----------|-------|--------|-----|
| blocked | 0 | 1-2 | 3+ |
| stale | 0 | 1-2 | 3+ |
| velocity | >=80% baseline | 50-80% | <50% |
