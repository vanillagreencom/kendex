# Cycle Planning Workflow

Generate a cycle plan, get the user's approval on what ships, and apply it.

## 1. Generate the Plan

This workflow mutates project state, so it reconciles before anything reads the cache:

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
```

1. **Delegate** to a one-shot `[TPM]` sub-agent.

   Fill `Worktree:` and `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`.
   `[DIR]` is the caller's own checkout, main checkout included.

   <delegation_format>
   Follow workflow: .agents/skills/project-management/workflows/tpm-cycle-plan.md
   Worktree: [WORKTREE_PATH]
   Worktree Check: `pwd -P` before any repo-relative command; it must print [WORKTREE_PATH]. On any other path, stop and report where the shell started.
   </delegation_format>

2. **Materialize the artifact.** The agent returns a `File:` hint and fenced JSON. Write the inline JSON to that path under the current repo root and read it; if inline JSON is missing and the path is not already readable, halt and request a rerun with inline JSON.

3. **Route on `status`**: `project_complete` → § 2, `plan_ready` → § 3.

## 2. Project Complete

The JSON carries `completed_project`, `next_projects` (by `sort_order`), `recommended`, and `actions.mark_complete`.

Mark the finished project complete without asking:

```bash
.agents/skills/linear/scripts/linear.sh projects update [mark_complete.project_id] --state completed
```

Then present the candidates and ask which to start.

<output_format>

### PROJECT COMPLETE — [completed_project.name]

| # | Project | Pri | Ready | Blocked by |
|---|---------|-----|-------|------------|
| 1 | [NAME] | P[N] | yes/no | [BLOCKERS or —] |

Recommended: [recommended.name] — [recommended.reason]
</output_format>

Ask: `Activate [recommended.name]` | other projects with `ready: true` | `Skip`. Activating starts the project and re-runs § 1; `Skip` ends the workflow. A project with `ready: false` is not offered — show its blockers instead.

```bash
.agents/skills/linear/scripts/linear.sh projects update [PROJECT_ID] --state started
```

## 3. Approve the Plan

The JSON carries `velocity`, `capacity`, `planned_work`, `not_included`, `health`, and `actions`. Take `velocity.adjustment` as computed and report it in the plan; never ask.

<output_format>

### CYCLE PLAN — [cycle.name]

[project.name] ([project.progress]%) · [cycle.start] → [cycle.end] ([cycle.days_remaining] days) · [capacity.available] pts available
[velocity.adjustment: baseline [from] → [to] pts/cycle — [reason]. Omit when null]

**Planned**

| Pri | Issue | Title | Est | Agent | Why here |
|-----|-------|-------|-----|-------|----------|

**Not included**

| Issue | Title | Why |
|-------|-------|-----|

**Relations to add** (omit when empty)

| From | → | To | Why |
|------|---|-----|-----|

**Health**: blocked [N] · stale [N] · velocity [N] pts/cycle
</output_format>

Ask: `Approve plan` | `Modify` | `Cancel`. `Modify` takes free-text changes, adjusts the `actions` object, and re-presents. `Cancel` ends the workflow.

## 4. Execute

### 4.1 Label Preflight

**Skip if** `actions.set_labels[]` is empty. Load the inventory and taxonomy, then compute each issue's full final label set per [labels.md](../references/labels.md):

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

Preserve unrelated labels and replace only the action's target category unless it says `replace_all_labels: true`. Any § Validation failure there halts before mutation.

### 4.2 Create the Cycle

**Skip if** `actions.create_cycle` is null.

```bash
.agents/skills/linear/scripts/linear.sh cycles create --team [create_cycle.team] --start [create_cycle.start] --end [create_cycle.end]
```

Keep the returned cycle ID for assignment.

### 4.3 Apply Actions

In this order:

1. `actions.add_relations[]` — `issues add-relation [FROM_ID] --blocks [TO_ID]`
2. `actions.set_priorities[]`, `actions.set_estimates[]`, `actions.set_labels[]` — per the Linear CLI's workflow-actions patterns
3. `actions.assign_to_cycle[]` — the state change
4. `actions.set_sort_order[]` — `issues update [ID] --sort-order [VALUE]`, parents and standalone issues only
5. `actions.update_initiative` / `actions.update_project` — per workflow-actions § Projects and Initiatives

Then sync bundle state: an assigned parent pulls its pending children into the same cycle and state; an assigned child whose parent sits in Backlog moves that parent to Todo in the same cycle. A parent with children stays a container unless its title carries `(one PR)`.

No comments on priority updates.

## 5. Report

<output_format>

### CYCLE PLAN APPLIED

| Action | Count |
|--------|-------|
| Relations added | N |
| Priorities set | N |
| Estimates set | N |
| Labels set | N |
| Assigned to cycle | N |
| Sort order set | N |
</output_format>

## 6. Return State

**If managed**: return to the parent workflow's next section. **If standalone**: session complete.
