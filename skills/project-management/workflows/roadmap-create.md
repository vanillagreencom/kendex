# Roadmap Creation Workflow

Execute approved roadmap plan and create entities in issue tracker.

## Inputs

| Command | Action |
|---------|--------|
| `roadmap create @[plan-file]` | Execute plan file |
| `roadmap create` | Error: requires plan file |

**Requires**: Plan file from `workflows/roadmap-plan.md` output

---

## 1. Load Plan File

### 1.1 Parse Arguments

Extract `PLAN_PATH` from `@[path]` argument.

**Missing file** → Error: "Requires plan file from `workflows/roadmap-plan.md`"

### 1.2 Read Plan File

1. **Read `PLAN_PATH`** with Read tool.

2. **Extract from markdown**:

   | Field | Location |
   |-------|----------|
| `FEATURE` | Title after "Roadmap: " |
| `RESEARCH_PATH` | Research field |
| `JSON_PATH` | "Plan data" field (or derive: change `.md` → `.json`) |
| `CANCEL_ACTIONS[]` | "Cancel Existing Issues" table |
| `MODIFY_ACTIONS[]` | "Modify Existing" table |
| `CONFLICTS[]` | "Conflicts to Resolve" table |
| `PROJECT_NAME` | "Project: " heading |
| `PROJECT_DESC` | Description field |
| `PROJECT_RELATIONS[]` | "Project Relations" table |
| `ISSUES[]` | "Issues" table |
| `ISSUES[].labels[]` | "Labels" column, comma-separated (legacy plans may omit; must be completed before create) |
| `GAPS[]` | "Architecture Gaps" table |
| `BREAKING_CHANGES[]` | "Breaking Changes" table |

3. **Load JSON** (if present):

   Read `JSON_PATH` with Read tool. If file exists, store as `TPM_OUTPUT`. If absent, set `TPM_OUTPUT` = null (legacy fallback).

---

## 2. Execute Recommended Actions

**Skip if** no `CANCEL_ACTIONS`, `MODIFY_ACTIONS`, or `CONFLICTS`.

### 2.1 Present Action Summary

<output_format>

### 📋 ACTIONS TO EXECUTE

**Cancel Existing** ([N] issues)

| # | Issue | Reason |
|---|-------|--------|
| 1 | [ISSUE_ID] | [REASON] |

**Modify Existing** ([N] issues)

| # | Issue | Change | Reason |
|---|-------|--------|--------|
| 1 | [ISSUE_ID] | [CHANGE] | [REASON] |

**Conflicts to Resolve** ([N])

| # | New Issue | Conflicts With | Resolution |
|---|-----------|----------------|------------|
| 1 | [TITLE] | [ISSUE_ID] | [RESOLUTION] |

</output_format>

### 2.2 Confirm Actions

1. **Ask user**:
   - **Execute all** -- Run all actions
   - **Review each** -- Approve action-by-action
   - **Skip actions** -- Proceed to project creation

2. **Route based on selection**:

   | Selection | Action |
   |-----------|--------|
   | Execute all | → § 2.3 |
   | Review each | → § 2.4 |
   | Skip actions | → § 3 |

### 2.3 Execute All Actions

1. **Execute cancellations** per workflow-actions § Cancel / Merge / Combine. Use "Superseded" pattern with reason from plan.

2. **Execute modifications** per workflow-actions § Scope Changes.

→ § 2.5

### 2.4 Review Each Action

For each action:

→ Ask user:
- **Execute** -- Run this action
- **Skip** -- Skip this action
- **Modify** -- Change approach (free text)

Execute approved actions per § 2.3 patterns.

### 2.5 Resolve Conflicts

**Skip if** no `CONFLICTS[]`.

For each conflict:

→ Ask user:
- **Proceed as planned** -- Continue with resolution in plan
- **Modify approach** -- Update approach (free text), store for issue creation
- **Skip this issue** -- Remove from creation

---

## 3. Create Project

### 3.1 Check Initiative Context

1. **List active initiatives**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache initiatives list --status Active
   ```

2. **Ask user**:
   - **Link to [INITIATIVE_NAME]** -- One option per active initiative
   - **Create new initiative** -- For multi-month efforts
   - **No initiative** -- Standalone project

3. **Route based on selection**:

   | Selection | Action |
   |-----------|--------|
   | Link to existing | Store `INITIATIVE_ID` → § 3.3 |
   | Create new | → § 3.2 |
   | No initiative | Set `INITIATIVE_ID` = null → § 3.3 |

### 3.2 Create Initiative

→ Ask user with free text:
- Initiative name
- Initiative description (multi-month objective)

```bash
.agents/skills/linear/scripts/linear.sh initiatives create \
  --name "[INITIATIVE_NAME]" \
  --description "[DESCRIPTION]"
```

Store `INITIATIVE_ID`.

### 3.3 Create Project

1. **Create project**:
   ```bash
   .agents/skills/linear/scripts/linear.sh projects create \
     --name "[PROJECT_NAME]" \
     --description "[PROJECT_DESC]" \
     --state "planned"
   ```

2. **Store `PROJECT_ID`**.

### 3.4 Link to Initiative

**Skip if** `INITIATIVE_ID` is null.

```bash
.agents/skills/linear/scripts/linear.sh initiatives add-project [INITIATIVE_ID] --project [PROJECT_ID]
```

---

## 4. Set Project Relations

**Skip if** no `PROJECT_RELATIONS[]`.

See workflow-actions § Project Relations.

For each relation in plan:

| Relation | Command |
|----------|---------|
| blocked-by | `.agents/skills/linear/scripts/linear.sh projects add-dependency [PROJECT_ID] --blocked-by [OTHER_PROJECT_ID]` |
| blocks | `.agents/skills/linear/scripts/linear.sh projects add-dependency [OTHER_PROJECT_ID] --blocked-by [PROJECT_ID]` |

---

## 5. Determine Project Placement

Project ordering handled when `workflows/audit-issues.md` runs with `project-order`. That workflow delegates to TPM to investigate scope, dependencies, and architecture for optimal ordering.

1. **Ask user** for immediate manual placement:
   - **Auto-place (Recommended)** -- Let audit-issues determine position later
   - **Place after [PROJECT]** -- Position manually now
   - **Place before [PROJECT]** -- Position manually now

2. **Route based on selection**:

   | Selection | Action |
   |-----------|--------|
   | Auto-place | → § 6 |
   | Place after | `.agents/skills/linear/scripts/linear.sh projects set-sort-order [PROJECT_ID] --after [REF_PROJECT_ID]` → § 6 |
   | Place before | `.agents/skills/linear/scripts/linear.sh projects set-sort-order [PROJECT_ID] --before [REF_PROJECT_ID]` → § 6 |

---

## 6. Create Issues

### 6.0 Load Label Policy

Before converting or creating any issue payload:

1. **Load live issue-label inventory** per [labels.md](../references/labels.md):
   ```bash
   .agents/skills/linear/scripts/linear.sh sync --reconcile
   .agents/skills/linear/scripts/linear.sh cache labels list --format=safe
   ```
2. **Load project taxonomy/application rules** from project configuration/docs (for example `vstack.toml` `[skill-instructions]`).
3. **Use issue labels only**. Do not validate against project labels.
4. **Halt before § 6.1** if taxonomy is missing and labels cannot be validated.

### 6.1 Create Issues via Audit

**If `TPM_OUTPUT` is not null** → JSON conversion below (skip tpm-audit).

**If `TPM_OUTPUT` is null** → legacy fallback below.

#### If TPM_OUTPUT present (preferred)

Deterministic mapping only -- do NOT re-analyze. Convert `TPM_OUTPUT` to project-management skill schemas audit-output ISSUE mode format.

**Per-issue mapping** (`organized_issues[i]` → `issues[i]`):

| audit-output field | Source |
|-------------------|--------|
| `index` | Sequential (1-based) |
| `identifier` | null (all proposed) |
| `title` | `organized_issues[i].title` |
| `action` | `organized_issues[i].action` (from TPM § 5.2) |
| `target` | `organized_issues[i].target` |
| `project.recommended` | `project_placement.project_name` |
| `project.recommended_id` | Resolved from cache or null (new project created in § 3) |
| `add_relations` | See relation mapping below |
| `hierarchy` | See hierarchy mapping below |
| `priority_misalignment` | null (priority already correct) |
| `agent_mismatch` | null (agent already correct) |
| `supersedes` | From `cross_project_findings` supersession entries |
| `obsolete` | From TPM § 5.1 (null if not obsolete) |
| `reason` | `organized_issues[i].reason` |

**Relation mapping**:
- `depends_on_proposed` title refs → `add_relations.blocked_by: ["#N"]` (resolve title to index)
- `depends_on_existing` refs → `add_relations.blocked_by: ["[ISSUE_ID]"]`
- Relations already lifted to parent level by TPM § 4.2 -- preserve as-is

**Hierarchy mapping**:

| hierarchy_recommendation | Bundle parent | Bundle child | Standalone |
|--------------------------|--------------|-------------|-----------|
| `children_of_origin` | `make_child` of origin ID | `make_child` of `#parent_index` | `make_child` of origin ID |
| `new_project` | `none` | `make_child` of `#parent_index` | `none` |
| `mixed` | Per TPM grouping | `make_child` of `#parent_index` | Per TPM grouping |
| `none` / absent | `none` | `make_child` of `#parent_index` | `none` |

Bundle children always reference their bundle parent as `#N`.

**Creation metadata** -- embed per-issue for `audit-issues` § 7.2 template use:

```json
"create_fields": {
  "description": "[Synthesized from title + feature context + breaking_changes]",
  "recommendation": "* Implement [title]\n* [doc_updates as bullets]\n* [breaking_changes as migration bullets]",
  "location": "[agent path -- project-configurable]",
  "estimate": 3,
  "priority": 1,
  "agent_label": "agent:[TYPE]",
  "labels": ["agent:[TYPE]", "[DOMAIN_LABEL]", "[WORKFLOW_LABEL]"],
  "is_bundle_parent": false,
  "source_path": "docs/roadmaps/roadmap-[FEATURE].md"
}
```

For bundle parents: use parent-issue-template format (`is_bundle_parent: true`, no description/recommendation -- populated after children created via § Sync Parent Description). Keep `agent_label` for backward compatibility, but `labels[]` is authoritative for create.

**Label mapping and preflight**:
- Source labels from `organized_issues[i].labels[]`.
- If `labels[]` is missing but legacy `agent`/`agent_label` exists, complete `labels[]` from project taxonomy and issue context before mutation.
- Validate every `labels[]` set against § 6.0 inventory/taxonomy before writing the audit file.
- Unknown labels, parent/group labels, missing required categories, or exclusivity violations halt the workflow and ask the user. Do not let the Linear CLI warn-and-skip invalid labels.
- Unknown labels, parent/group labels, missing required categories, or exclusivity violations halt before mutation.

**Top-level metadata**:

```json
{
  "mode": "issue",
  "source": "roadmap-create",
  "parent_issue": "[from hierarchy_recommendation.origin_issue or null]",
  "research_ref": "[from context.research_path]",
  "plan_path": "[from context.plan_path]"
}
```

1. **Write** to `tmp/audit-roadmap-YYYYMMDD-HHMMSS.json`.

2. **Run Workflow**: `⤵ workflows/audit-issues.md --analyzed tmp/audit-roadmap-YYYYMMDD-HHMMSS.json § 5-9 → § 6.2`

#### If TPM_OUTPUT absent (legacy fallback)

Build audit-input file from markdown plan per [audit-issues-input.md](../schemas/audit-issues-input.md):

| Plan field | Audit input field |
|------------|-------------------|
| Issue title | `title` |
| Description + dependencies context | `description` |
| Agent component path | `location` (project-configurable) |
| "From roadmap" | `recommendation` |
| TPM-computed `priority` | `priority` (from `organized_issues[].priority` -- do NOT default to P2) |
| Estimate | `estimate` |
| Labels column | `labels[]` (full issue-label set; if absent, complete from taxonomy before create) |
| `"issue"` | `category` |
| `"tpm"` | `found_by` |
| `"planned"` | `origin` |
| TPM-assigned `blocks`/`blocked_by` | `blocks_items`/`blocked_by_items` (preserve TPM's parent-level assignments for bundles) |
| Deps column (existing) | `blocked_by_issues` ([ISSUE_ID] refs) |

Source: `"roadmap-create"` | Parent issue: from `hierarchy_recommendation` in markdown.

**Hierarchy**: Use `hierarchy_recommendation` from markdown to set `parent_issue`:
- `children_of_origin` → `parent_issue: [ORIGIN_ISSUE_ID]`
- `new_project` → `parent_issue: null`
- `mixed` → split items per TPM grouping (some parented, some standalone)
- `none` / absent → `parent_issue: null`

**Dependency conversion**: Preserve TPM's parent-level relation assignments for bundled issues (per [agent-sequencing.md](../../linear-orch/workflows/agent-sequencing.md) rule 5). For non-bundled issues, convert plan's `#N` references to `blocked_by_items: [N]` and existing refs to `blocked_by_issues: ["[ISSUE_ID]"]`.

**Source path**: Format as file path, not markdown link: `docs/roadmaps/roadmap-[FEATURE].md`

**Label preflight**: For every fallback issue, build and validate full `labels[]` using § 6.0 before invoking `audit-issues`. Legacy plans without labels must be completed through project taxonomy; if required labels cannot be determined, halt and ask the user.

1. **Write file** to `tmp/audit-roadmap-YYYYMMDD-HHMMSS.json`.

2. **Run Workflow**: `⤵ workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6.2`

### 6.2 Set Cross-Project Relations

**Skip if** no cross-project dependencies in plan.

For dependencies referencing issues outside `PROJECT_NAME`:
```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [ISSUE_ID] --related [EXTERNAL_ISSUE_ID]
```
`blocks`/`blocked_by` require same project. Use `related` for cross-project informational links.

---

## 7. Validate Creation

### 7.1 Query Created Entities

```bash
.agents/skills/linear/scripts/linear.sh cache projects get [PROJECT_ID]
.agents/skills/linear/scripts/linear.sh cache projects list-dependencies [PROJECT_ID]
.agents/skills/linear/scripts/linear.sh cache issues list --project "[PROJECT_NAME]" --max
```

### 7.2 Verify Structure

Check:
- [ ] All issues in correct project
- [ ] Parent/child structure matches plan
- [ ] Dependencies set correctly
- [ ] Project relations established
- [ ] Critical path issues labeled

**Discrepancies** → Report in summary (§ 8), do not auto-fix.

---

## 8. Archive Plan File

```bash
mkdir -p docs/roadmaps/archived
mv [PLAN_PATH] docs/roadmaps/archived/roadmap-[FEATURE]-$(date +%Y%m%d).md
mv [JSON_PATH] docs/roadmaps/archived/roadmap-[FEATURE]-$(date +%Y%m%d).json 2>/dev/null || true
```

### 8.1 Present Summary

<output_format>

### ✅ ROADMAP CREATED

**Project**: [PROJECT_NAME] ([PROJECT_ID])
**Initiative**: [INITIATIVE_NAME or "None"]

| Metric | Count |
|--------|-------|
| Issues created | [N] |
| Bundles | [M] |
| Relations added | [R] |
| Actions executed | [A] |

**Discrepancies** (if any):

| Issue | Expected | Actual |
|-------|----------|--------|
| [TITLE] | [EXPECTED] | [ACTUAL] |

**Plan archived**: docs/roadmaps/archived/roadmap-[FEATURE]-YYYYMMDD.md

</output_format>

---

## 9. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — roadmap created.
