# Cycle Planning Analysis

Analyze the backlog, compute architecture order, and recommend a cycle plan.

**Do NOT modify the tracker.** Return recommendations only.

## 1. Query State

```bash
.agents/skills/linear/scripts/linear.sh session-status
```

Read the project map as [tpm-audit § 1.6](./tpm-audit.md#16-extract-project-definitions) does, with its team from `LINEAR_TEAM` ([project-map.md § Audit](../references/project-map.md#audit)): a deliverable's `ends_when` is its entry in the `### Project map` block. `[ACTIVE_PROJECT]`, used everywhere below, is the first `projects[]` entry, in `session-status`'s priority order, that [project-map.md § Project kinds](../references/project-map.md#project-kinds) counts as the active project; record its `name` and its `id` as `[ACTIVE_PROJECT_ID]`. Extract `cycle.id`, `cycle.name`, the `issues.backlog` / `issues.actionable` / `issues.in_progress` entries whose `project_name` is `[ACTIVE_PROJECT]`, `backlog_projects` (ordered by `sort_order`), and `next_project`. Those three lists feed planning only.

Whether `[ACTIVE_PROJECT]` has an open item left is the read [§ Project kinds](../references/project-map.md#project-kinds) defines, by its recorded id:

```bash
.agents/skills/linear/scripts/linear.sh issues list --project-id "[ACTIVE_PROJECT_ID]" --max --format=compact
```

With **no open item left**, which § Project kinds decides from those rows, return early per § 7 with `status: "project_complete"`, filename hint `tmp/cycle-plan-project-complete-YYYYMMDD-HHMMSS.json`, `completed_project`, `next_projects[]` from `backlog_projects`, `recommended` (first ready project, with a reason), `actions.mark_complete` and `blocked_by_active`. `actions.mark_complete` is null when § Project kinds holds the project open. `blocked_by_active` is the started project that holds activation after this run: `completed_project` when it is held open, otherwise the next `projects[]` entry that § Project kinds counts as active, or null. With no entry counting as active, return the same way with `completed_project`, `actions.mark_complete` and `blocked_by_active` null.

If any label recommendation may follow, load the inventory first — `labels list --max --format=safe`. Every `actions.set_labels[]` entry must name its update mode and category and carry enough data for the caller to preflight a full final set.

## 2. Velocity

Velocity is estimation points per cycle from cycle scope history, never issue counts.

From `session-status`, take the last entry of `prev_cycle.completedScopeHistory` as `previous` and of `cycle.completedScopeHistory` as `current` (0 when empty or missing). `baseline` = `previous` if > 0, else `current` if > 0, else 10 for a first-ever cycle.

When both histories are empty, fall back to summing estimates over the last two weeks and splitting by `updated_at` into a current (0-7d) and previous (7-14d) window:

```bash
.agents/skills/linear/scripts/linear.sh issues list --project-id "[ACTIVE_PROJECT_ID]" --state "Done" --updated-since 14d --max
```

Set `velocity.adjustment` only on a trigger: current ≥150% of baseline for 2+ cycles → `increase_baseline`; ≤50% for 2+ cycles → `decrease_baseline`; every cycle finishing at 100% with days to spare → `increase_capacity`. Otherwise null.

## 3. Backlog Candidates

Use the § 1 `issues.backlog` entries, or fall back to a cache query:

```bash
.agents/skills/linear/scripts/linear.sh issues list --project-id "[ACTIVE_PROJECT_ID]" --state "Backlog" --max
```

Plan parents and standalone issues only — exclude anything with a non-empty `parent_id` (`issues.backlog` already applies this filter; apply it yourself to the fallback). Per issue, take `id`, `title`, `description`, `priority`, `estimate`, `agent`, `labels`, `blocked_by[]`, `blocked_by_open[]`, and `blocks[]`.

## 4. Architecture Order

### 4.1 Partition by Blocking

Unblocked means `blocked_by_open` is empty. A blocked candidate whose open blocker is also in the candidate set can share the cycle, blocker first.

### 4.2 Read the Code

For each candidate, determine what it **creates** (modules, types, APIs), what it **consumes**, and how many other issues it **enables**. Assign a layer: L0 foundation types and core modules, L1 infrastructure, L2 features, L3 integration, L4 testing and observability. Build bottom-up.

### 4.3 Record Missing Relations

An architecture dependency with no relation recorded belongs in `actions.add_relations[]` as `{"from", "rel": "blocks", "to", "reason"}`. Two signals: issue A creates something issue B consumes, and two issues modifying the same file where the lower-layer one must land first.

Recommend each relation under linear SKILL.md § Blocked Label vs Issue Relations. See [dependencies.md](../references/dependencies.md) for structural repair.

### 4.4 Order and Prioritize

```
position = (layer x 100) + (enables x -10) + (current_priority x 1)
```

Lower is earlier: foundations first, then whatever unblocks the most work within a layer, with current priority breaking ties. Map position to the cycle priority — 1-2 → P1, 3-5 → P2, 6-10 → P3, 11+ → P4. (P0 means unassigned; active work uses P1-P4.) Record `position`, `new_priority`, `rationale`, and `enables[]` per issue.

## 5. Target Cycle and Capacity

Capacity is `(baseline x 0.8) - (in-progress + todo estimate points)`, budgeted 60% planned work, 20% bugs and technical debt, 20% buffer.

First match wins: current cycle with ≤3 days remaining → next cycle; current cycle with >3 days and capacity → current cycle; current cycle full → next cycle; no cycles at all → set `actions.create_cycle`.

Health metrics for the plan:

```bash
.agents/skills/linear/scripts/linear.sh issues list --project-id "[ACTIVE_PROJECT_ID]" --state "In Progress" --max
.agents/skills/linear/scripts/linear.sh issues list --project-id "[ACTIVE_PROJECT_ID]" --label "blocked" --max
```

`health.stale` counts In Progress issues untouched for more than 3 days; `health.blocked` counts issues carrying the `blocked` label.

## 6. Fill the Plan

Take issues in § 4.4 order up to capacity. Each `planned_work[]` entry carries `id`, `title`, the new `priority`, `estimate`, `agent`, `blocked_by` (null unless the blocker is in this cycle), `rationale` for its position, and `enables[]`.

Everything remaining goes to `not_included[]` with one of: `"Blocked by [ISSUE_ID] (not in cycle)"`, `"Blocked by [ISSUE_ID] (included, will unblock)"`, `"Over capacity"`, `"Lower priority deferred"`.

Populate `actions` per [cycle-plan-output.md](../schemas/cycle-plan-output.md): `add_relations[]` from § 4.3, `set_priorities[]` from § 4.4, `set_sort_order[]` from § 4.4 positions (spacing 100, parents and standalone only), `assign_to_cycle[]`, `set_estimates[]`, `set_labels[]` (each with `mode`, `category` where applicable, the labels involved, and either `preserve_existing: true` or explicit `final_labels[]`), and `create_cycle` from § 5.

## 7. Return Output

Build the JSON per [cycle-plan-output.md](../schemas/cycle-plan-output.md) and return it inline; do not write the file.

<output_format>
File: tmp/cycle-plan-ready-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>
