# Cycle Planning Workflow

Generate cycle plan via TPM agent with user approval.

## 1. Generate Plan

1. **Delegate to `[AGENT_TYPE]`**: Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

   <delegation_format>
   Follow workflow: .agents/skills/project-management/workflows/tpm-cycle-plan.md
   </delegation_format>

2. **After agent returns**: Collect JSON path. Agent returns `.JSON` file. If missing, halt.

3. **Read file**: Use Read tool to get structured output.

4. **Route by status** field from JSON output:

| Status | Action |
|--------|--------|
| `project_complete` | → § 2 |
| `plan_ready` | → § 3 |

## 2. Project Completion

JSON contains `completed_project`, `next_projects` (ordered by sort_order), `recommended`, and `actions.mark_complete`.

### 2.1 Mark Project Complete

**Execute mark_complete action**:

```bash
.agents/skills/linear/scripts/linear.sh projects update [mark_complete.project_id] --state completed
```

### 2.2 Present Next Options

1. **Present options**:
   <output_format>

   ### ✅ PROJECT COMPLETE — [completed_project.name]

   ### 📋 NEXT PROJECT OPTIONS (by sort_order)

   | # | Project | Pri | Ready | Blocked By |
   |---|---------|-----|-------|------------|
   | 1 | Phase 2: Features | P1 | ✅ | - |
   | 2 | Phase 3: Backend Services | P2 | 🚫 | Phase 2: Features |
   | 3 | Testing Infrastructure | P2 | ✅ | - |

   Recommended: [recommended.name] — [recommended.reason]

   Legend: ✅ yes  🚫 blocked
   </output_format>

2. **Ask user**: `Activate [recommended.name] (Recommended)` | `Activate [other options]` | `Skip`

3. **Route based on selection**:

   | Selection | Action |
   |-----------|--------|
   | Activate [NAME] | `.agents/skills/linear/scripts/linear.sh projects update [PROJECT_ID] --state started` → § 1 |
   | Skip | End workflow |

   Only projects with `ready: true` should be activated. If user selects a blocked project, show blockers and ask to resolve first.

## 3. Cycle Plan Approval

JSON contains full plan with `velocity`, `planned_work`, `not_included`, `actions`.

### 3.1 Check Velocity Adjustment

**Skip if** `velocity.adjustment` is null.

1. **Present adjustment**:
   ```
   Velocity adjustment proposed:
   - Current: [CURRENT] pts/week
   - Baseline: [BASELINE] pts/week
   - Proposal: [adjustment.reason]
   - New baseline: [adjustment.to] pts/week
   ```

2. **Ask user**: `Approve` | `Keep current` | `Custom value`

### 3.2 Present Plan

1. **Present plan**:
   <output_format>

   ### CYCLE PLAN — [cycle.name]

   | Field | Value |
   |-------|-------|
   | Project | [project.name] ([project.progress]%) |
   | Dates | [cycle.start] → [cycle.end] ([cycle.days_remaining] days) |
   | Capacity | [capacity.available] pts available |

   ### 📋 PLANNED WORK

   | Pri | Issue | Title | Est | Agent | Rationale |
   |-----|-------|-------|--------|-------|-----------|
   | P1 | [ISSUE_ID] | Add order validation | 3 | [AGENT_TYPE] | L1 infra, unblocks [ISSUE_ID] |
   | P2 | [ISSUE_ID] | Order panel view | 2 | [AGENT_TYPE] | L3 integration, blocked by above |
   | P2 | [ISSUE_ID] | Ring buffer benchmarks | 2 | [AGENT_TYPE] | L4 testing, independent |

   Pri = architecture-derived priority (P1 first, P2 second, etc.)

   ### 🔗 MISSING RELATIONS (if any)

   | From | → | To | Reason |
   |------|---|-----|--------|
   | [ISSUE_ID] | blocks | [ISSUE_ID] | Creates validation consumed by downstream |

   ### ⏭️ NOT INCLUDED

   | Issue | Title | Reason |
   |-------|-------|--------|
   | [ISSUE_ID] | Chart optimization | Blocked by [ISSUE_ID] (not in) |
   | [ISSUE_ID] | Full integration tests | Over capacity |

   ### 📊 HEALTH

   | Blocked | Stale | Velocity |
   |---------|-------|----------|
   | 1 ⚠️ | 0 ✅ | 12 pts/wk ✅ |

   Legend: ✅ healthy  ⚠️ attention needed  🔴 critical
   </output_format>

2. **Ask user**: `Approve plan` | `Modify` | `Cancel`

3. **Route based on selection**:

   | Selection | Action |
   |-----------|--------|
   | Approve | → § 4 |
   | Modify | User specifies changes via free text, adjust `actions` object, re-present plan |
   | Cancel | End workflow |

## 4. Execute Actions

### 4.0 Load Label Policy for Label Updates

Before executing any `actions.set_labels[]` entry:

1. Load issue-label inventory and project taxonomy per [labels.md](../references/labels.md):
   ```bash
   .agents/skills/linear/scripts/linear.sh sync --reconcile
   .agents/skills/linear/scripts/linear.sh cache labels list --format=safe
   ```
2. For each target issue, fetch current labels, compute the full final label set, preserve unrelated labels, and replace only the intended taxonomy category unless the action explicitly says `replace_all_labels: true`.
3. Preflight the final label set. Unknown labels, parent/group labels, missing required categories, or exclusivity violations halt before mutation.

### 4.1 Create Cycle (if actions.create_cycle exists)

**Skip if** `actions.create_cycle` is null.

1. **Create cycle**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cycles create --team [create_cycle.team] --start [create_cycle.start] --end [create_cycle.end]
   ```

2. **Store created cycle ID** for assignment.

### 4.2 Execute Plan Actions

1. **Execute** from `actions` object per workflow-actions patterns. Order: blocking relations first, then priorities, then cycle assignment (state change), then sort order LAST (sortOrder is per-state-column -- setting before state change gets overwritten).

   | Action | Read | Data |
   |--------|------|------|
   | Set priorities | § Priority Updates | `actions.set_priorities[]` |
   | Assign to cycle | § Cycle Assignment | `actions.assign_to_cycle[]` (issue IDs) |
   | Set sort order | `.agents/skills/linear/scripts/linear.sh issues update [ID] --sort-order [VALUE]` | `actions.set_sort_order[]` (parent/standalone only, AFTER cycle assignment) |
   | Set estimates | § Estimate & Label Updates | `actions.set_estimates[]` |
   | Set labels | § Estimate & Label Updates | `actions.set_labels[]` with mode/category/final-label semantics from schema; run § 4.0 first |
   | Update initiative | § Initiative & Project Status | `actions.update_initiative` |
   | Update project | § Initiative & Project Status | `actions.update_project` |

2. **Sync bundle states** per workflow-actions § Parent State Sync:
   - Assigned parent (has children): assign all pending children to the same cycle and state.
   - Assigned child (has `parent_id`): if parent is Backlog → update parent to Todo and assign same cycle.

### 4.3 Set Missing Blocking Relations

If `actions.add_relations[]` exists (from TPM architecture analysis):

For each relation:
```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [FROM_ID] --blocks [TO_ID]
```

TPM populates this when § 1.4 architecture ordering reveals dependencies not yet recorded in issue tracker (e.g., one domain issue should block another domain issue in same project, but no relation exists).

**Note**: Skip comments for priority updates -- rationale already shown in plan presentation.

## 5. Present Results

<output_format>

### ✅ CYCLE PLAN APPLIED

| Action | Count |
|--------|-------|
| Relations added | N |
| Priorities set | N |
| Sort order set | N |
| Assigned to cycle | N |
| Estimates set | N |
| Labels set | N |
</output_format>

## 5.5. Auto-Detect Parallel Groups

**Skip if** fewer than 2 issues were assigned to cycle.

1. **Collect unblocked issue IDs**: From `actions.assign_to_cycle[]`, filter to issues that have NO `blocked_by` relations with other issues in the planned set.

2. **If 2+ unblocked**: Run `.agents/skills/flightdeck/workflows/linear/parallel-check.md` with `[UNBLOCKED_ISSUE_IDS]` via Skill. Persistence happens automatically via § 11 of parallel-check workflow.

3. **Present any safe groups found**: Include in results output so user knows parallel launch is available from next `.agents/skills/flightdeck/workflows/linear/start.md`.

## 6. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — cycle plan complete.
