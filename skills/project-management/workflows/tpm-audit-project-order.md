# Project Order Audit Workflow

Analyze project architectural dependencies, verify/fix ordering, handle state transitions.

**Do NOT** modify the issue tracker. Return recommendations only.

---

## 1. Fetch All Projects and Initiatives

1. **Fetch all projects and initiatives**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache initiatives list
   .agents/skills/linear/scripts/linear.sh cache projects list --state started
   .agents/skills/linear/scripts/linear.sh cache projects list --state planned
   .agents/skills/linear/scripts/linear.sh cache projects list --state backlog
   .agents/skills/linear/scripts/linear.sh cache projects list --state completed
   ```

2. **Record** for projects: `id`, `name`, `state`, `progress`, `sort_order`, `blocked_by[]`, `blocks[]`, `description`, `content`

3. **Record** for initiatives: `id`, `name`, `projects[]` (array of project names)

### 1.1 Build Initiative Mapping

Initiatives include their projects by name. Build mapping:

```
initiative_map = {}
for initiative in initiatives:
    for project_name in initiative.projects:
        initiative_map[project_name] = initiative.name
```

Use this mapping to add `initiative` field to each project in output.

---

## 2. Analyze Architectural Layers

For each `planned` or `backlog` project (not `started` or `completed`):

### 2.1 Extract Project Scope

From `name` + `description` + `content`:
- **Domain**: infra | data | ui | testing | polish
- **Deliverables**: What this project produces
- **Consumes**: What other projects' outputs this needs

**Verify against architecture docs**: Check if deliverables depend on unbuilt code or other projects' outputs. Read architecture documentation to confirm dependencies.

### 2.2 Fetch Project Issues

1. **Fetch issues**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --project "[PROJECT_NAME]" --state "Backlog,Todo,In Progress" --max
   ```

2. **Extract** from issue titles/descriptions:
   - Technical components touched
   - Dependencies on other projects' work
   - What this enables for downstream

### 2.3 Determine Layer Position

Assign layer based on architectural analysis:

| Layer | Criteria |
|-------|----------|
| 0 | Foundation — no project dependencies, enables others |
| 1 | Core infrastructure — depends on L0, enables L2+ |
| 2 | Feature implementation — depends on L0-L1 |
| 3 | Integration/testing — depends on features existing |
| 4 | Polish/release — depends on everything |

---

## 3. Determine Correct Order

### 3.1 Understand Ordering Model

**CRITICAL**: Issue trackers typically use per-state-column ordering, NOT global ordering:

| State | Column | sortOrder Meaning |
|-------|--------|-------------------|
| started | In Progress | Active work (usually 1 project) |
| planned | Planned | Queue for next work (sortOrder within column) |
| backlog | Backlog | Future work (sortOrder within column) |

**sortOrder is relative within a column only**. A `planned` project with sortOrder 937 is NOT "after" a `backlog` project with sortOrder -11000. They're in different queues.

**Execution order**: started → planned (top to bottom) → backlog (top to bottom)

### 3.2 Build Dependency Graph

For each project pair (A, B):
- If A.deliverables consumed by B → A must precede B
- If A.layer < B.layer → A should precede B
- If same layer → order by priority, then alphabetical

### 3.3 Calculate Recommended Order

Topological sort by: (1) layer, (2) dependency edges, (3) priority

Output: `recommended_order[]` with positions 1, 2, 3... (logical execution order)

### 3.4 Compare to Current

1. **Determine current position** — state-aware ranking:
   1. `started` projects = position 0 (active)
   2. `planned` projects = positions 1, 2, ... by sortOrder within planned (lower = earlier)
   3. `backlog` projects = positions N+1, N+2, ... by sortOrder within backlog (lower = earlier)

2. **Compare** recommended position (from 3.3) against current.

3. **For mismatches**, determine action:
   - Project in wrong state? → recommend state change
   - Correct state but wrong position? → recommend reorder within that state
   - Add to `reorder[]` with `target_state` field

4. **Calculate** `new_sort_order` values with proper spacing (-10000, -9000, ...) **per state column**.

---

## 4. Detect State Transitions

### 4.1 Completed Projects

For each `started` project where `progress == 1.0`:
- Add to `complete_candidates[]`
- Note what it unblocks

### 4.2 Next Project

Assuming reorders applied, find position 1 among `planned`/`backlog` with no incomplete blockers → `recommended_next`

**If no unblocked projects**: Set `recommended_next` to `null` with rationale listing what blocks each candidate.

---

## 5. Return Output

1. **Build JSON** per [audit-project-order-output.md](../schemas/audit-project-order-output.md). Set the destination hint to `tmp/audit-project-order-YYYYMMDD-HHMMSS.json`.

2. **Return the JSON inline** in your response. Do not write the artifact yourself; the calling agent writes the file in its worktree using the returned `File:` hint.

   <output_format>
   File: tmp/audit-project-order-YYYYMMDD-HHMMSS.json
   ```json
   {complete JSON object}
   ```
   </output_format>

---

**END**: Audit complete.
