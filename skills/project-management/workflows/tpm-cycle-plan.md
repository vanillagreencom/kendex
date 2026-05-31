# Cycle Planning Analysis

Analyze backlog, compute architecture order, and generate cycle plan recommendations.

**Do NOT** modify the issue tracker. Return recommendations only.

## 1. Plan Cycle

### 1.1 Query State

1. **Fetch state**:
   ```bash
   .agents/skills/linear/scripts/linear.sh session-status
   ```

2. **Extract** from response:
   - `project.name` → use as `[ACTIVE_PROJECT]` in all queries
   - `project.id`, `cycle.id`, `cycle.name` → use in 1.5
   - `.issues.backlog`, `.issues.actionable`, `.issues.in_progress` → check project status
   - `backlog_projects` → projects ordered by `sort_order` (manual ordering)
   - `next_project` → first ready project by sort_order

3. **If project complete** (all three arrays empty) → early return:

   1. **Build JSON** per [cycle-plan-output.md](../schemas/cycle-plan-output.md) Status: project_complete, filename `tmp/cycle-plan-project-complete-YYYYMMDD-HHMMSS.json`.
      - `status`: "project_complete"
      - `completed_project`: project info
      - `next_projects[]`: ordered candidates from `backlog_projects`
      - `recommended`: first ready project with `reason`
      - `actions.mark_complete`: `{"project_id": "[ID]", "project_name": "[NAME]"}`

   2. **Return the JSON** in your response (the calling agent writes the file):

      <output_format>
      File: tmp/cycle-plan-project-complete-YYYYMMDD-HHMMSS.json
      ```json
      {complete JSON object}
      ```
      </output_format>

4. **Load label policy context** if any label recommendations may be produced:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache labels list --format=safe
   ```
   Use project taxonomy/application rules to classify label categories. TPM does not mutate labels, but any `actions.set_labels[]` recommendation must specify the intended update mode/category and enough data for the caller to preflight a full final label set.

### 1.2 Calculate Velocity

Uses cycle scope history (estimation points per day), not issue counts.

1. **Extract from session-status** (1.1):
   - `prev_cycle.completedScopeHistory` — daily completed estimation points in previous cycle
   - `cycle.completedScopeHistory` — daily completed estimation points in current cycle

2. **Compute** and store for 1.7:
   - `previous`: Last entry of `prev_cycle.completedScopeHistory` (total points completed in previous cycle). 0 if array empty or missing.
   - `current`: Last entry of `cycle.completedScopeHistory` (points completed so far in current cycle). 0 if array empty or missing.
   - `baseline`: `previous` if > 0, else `current` if > 0, else 10 (initial default only for first-ever cycle)
   - `adjustment`: null unless trigger met

3. **Fallback** (if `completedScopeHistory` arrays are empty/missing — first cycle or no data):
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --project "[ACTIVE_PROJECT]" --state "Done" --updated-since 14d --max
   ```
   Sum `.estimate` fields: `jq '[.[].estimate // 0] | add'`
   Split by `updated_at` into current (7d) and previous (7-14d) windows.

4. **Check adjustment triggers** — set `adjustment` object if condition met:

   | Condition | `adjustment.proposal` |
   |-----------|----------------------|
   | Current >= 150% baseline for 2+ cycles | `increase_baseline` |
   | Current <= 50% baseline for 2+ cycles | `decrease_baseline` |
   | All cycles 100% with days remaining | `increase_capacity` |

   Set `velocity.adjustment` per schema when trigger met.

### 1.3 Get Backlog Candidates

1. **Use `.issues.backlog`** from 1.1. If empty:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --project "[ACTIVE_PROJECT]" --state "Backlog" --max
   ```

   **Filter**: Exclude sub-issues (`parent_id` non-empty) — plan parents only; children follow via cycle-plan 4.2 bundle cascade. `.issues.backlog` already excludes sub-issues; apply the same filter to fallback cache queries.

2. **Extract** for each issue:
   - `id`, `title`, `description`, `priority`, `estimate`, `agent`, `labels`
   - `blocked_by[]` — issues blocking this one
   - `blocks[]` — issues this one blocks (enabling value)

### 1.4 Determine Architecture Order

**Ordering criteria** (in priority order):

1. **Blocking status**: Unblocked issues before blocked issues

2. **Architecture/code dependencies**: What must logically be built first

3. **Priority**: Existing P1-P4 as tiebreaker

#### 1.4.1 Analyze Blocking Dependencies

Partition backlog into:
- **Unblocked**: `blocked_by` is empty or all blockers are Done
- **Blocked**: Has incomplete blockers

For blocked issues, check if blocker is in the unblocked set — if so, both can be in same cycle (blocker first).

#### 1.4.2 Analyze Architecture Dependencies

Read relevant codebase to understand implementation order. For each issue, determine:
- **Creates**: What modules/types/APIs does this issue create?
- **Consumes**: What existing code does it depend on?
- **Enables**: How many other issues does completing this unblock?

**Architecture layers** (build bottom-up):
- L0: Foundation types, core modules
- L1: Infrastructure (IPC, threading, memory)
- L2: Features (message handlers, data stores)
- L3: Integration (bridges, cross-stack)
- L4: Testing/observability

#### 1.4.3 Identify Missing Blocking Relations

For issues in the same project with architecture dependencies but no blocking relation:

1. **Creates-Consumes check**: If issue A creates a module/type and issue B consumes it (from 1.4.2 analysis), A should block B.

2. **Same-file check**: If two issues modify the same file (from location fields), the lower-layer issue should block the higher-layer one.

Add discovered relations to `actions.add_relations[]`:
```json
{"from": "[ISSUE_ID]", "rel": "blocks", "to": "[OTHER_ISSUE_ID]", "reason": "A creates [type] consumed by B"}
```

**Blocking level rule**: Before adding, resolve `from`/`to` to parent if either has `parent_id`. Child→external relations must be lifted to parent level. If both resolve to same parent, skip (intra-bundle).

#### 1.4.4 Compute Final Order

For each unblocked issue, compute position score:

```
position = (layer x 100) + (enables x -10) + (current_priority x 1)
```

Lower position = higher in order. This ensures:
- Foundation layers come first
- Issues that unblock more work come earlier within a layer
- Current priority breaks ties

#### 1.4.5 Map Position to Priority

Architecture order determines new priority for cycle assignment:

| Position | Priority | Rationale |
|----------|----------|-----------|
| 1-2 | P1 (Urgent) | Critical path, must complete first |
| 3-5 | P2 (High) | Important, early in architecture order |
| 6-10 | P3 (Normal) | Standard work, follows dependencies |
| 11+ | P4 (Low) | Nice-to-have, deferred if cycle full |

**Note**: P0 = None (unassigned). Use P1-P4 for active work.

**Output**: Ordered list with `position`, `new_priority`, `rationale`, `enables[]`

### 1.5 Select Target Cycle

1. **Use cycle info** from 1.1.

2. **Select target** — first match wins:

   | Condition | Target |
   |-----------|--------|
   | Current cycle <=3 days remaining | Next cycle |
   | Current cycle >3 days + has capacity | Current cycle |
   | Current cycle full | Next cycle |
   | No cycles exist | Recommend cycle creation |

   Capacity formula: `(baseline x 0.8) - (in-progress + todo estimate points)`

3. **If no cycles exist** → set `actions.create_cycle` per schema.

### 1.6 Calculate Capacity & Health

1. **Calculate capacity** — 80% of baseline (estimation points from 1.2):
   - 60% planned work
   - 20% bugs/technical debt
   - 20% buffer

2. **Fetch health metrics**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --project "[ACTIVE_PROJECT]" --state "In Progress" --max
   .agents/skills/linear/scripts/linear.sh cache issues list --project "[ACTIVE_PROJECT]" --label "blocked" --max
   ```

3. **Compute** for 1.7:
   - `health.stale`: In Progress issues where `updated_at > 3 days ago`
   - `health.blocked`: Count of issues with `blocked` label

### 1.7 Return Output

1. **Build JSON** per [cycle-plan-output.md](../schemas/cycle-plan-output.md) Status: plan_ready, filename `tmp/cycle-plan-ready-YYYYMMDD-HHMMSS.json`.
   - `planned_work[]` (from 1.4 order, up to capacity):
     - `id`, `title`, `priority` (new, from 1.4.4), `estimate`, `agent`
     - `blocked_by` (null if unblocked, issue ID if blocker in same cycle)
     - `rationale` — why this position in architecture order
     - `enables[]` — issues unblocked by completing this
   - `not_included[]` for remaining backlog with `reason`:
     - "Blocked by [ISSUE_ID] (not in cycle)" — blocker not included
     - "Blocked by [ISSUE_ID] (included, will unblock)" — blocker is in planned_work
     - "Over capacity" — fits criteria but exceeds points
     - "Lower priority deferred" — below cycle threshold
   - `actions` per schema:
     - `add_relations[]` — blocking relations from 1.4.3 (`{from, rel, to, reason}`)
     - `set_priorities[]` — priority updates from 1.4.5
     - `set_sort_order[]` — sort order from 1.4.4 position (`{id, sort_order}`, spacing of 100, parent/standalone only)
     - `assign_to_cycle[]` — issue IDs to assign
     - `set_estimates[]` — estimate updates if needed
     - `set_labels[]` — label updates if needed; each entry must specify `mode` (`add`, `replace_category`, or `replace_all`), `category` when applicable, `labels[]` being added/replaced, and either `preserve_existing: true` or explicit `final_labels[]`
     - `create_cycle` — cycle creation if needed (from 1.5)

2. **Return the JSON** in your response (the calling agent writes the file):

   <output_format>
   File: tmp/cycle-plan-ready-YYYYMMDD-HHMMSS.json
   ```json
   {complete JSON object}
   ```
   </output_format>

---

**END**: Analysis complete.
