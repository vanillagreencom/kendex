# Roadmap Creation Workflow

Execute an approved roadmap plan: resolve existing work, create the project, create the issues through the audit pipeline.

## 1. Load the Plan

`roadmap create @[plan-file]`. Without a plan file, error: "Requires a plan file from `workflows/roadmap-plan.md`."

Read the markdown for `FEATURE` and its `**Plan data**` path, then read that JSON as `TPM_OUTPUT` — the JSON is the contract, the markdown is the human copy. A plan whose JSON is missing or unreadable halts: re-run `roadmap plan`.

From `TPM_OUTPUT` take `project_placement`, `organized_issues[]`, `cross_project_findings`, `hierarchy_recommendation`, `architecture_gaps[]`, and `context`.

---

## 2. Resolve Existing Work

**Skip if** `cross_project_findings` has no `cancel`, `expand`, `descope`, or conflict entries.

Cancelling and rescoping existing issues is a work decision. Present them, then ask once: `Execute all` | `Review each` | `Skip`.

<output_format>

### EXISTING WORK AFFECTED

| # | Issue | Action | Why |
|---|-------|--------|-----|
| 1 | [ISSUE_ID] | cancel \| expand \| descope | [REASON] |

**Conflicts** ([N])

| # | New issue | Conflicts with | Resolution |
|---|-----------|----------------|------------|
</output_format>

`Review each` asks per action (`Execute` | `Skip` | `Modify` with free text). Execute cancellations per the Linear CLI's workflow-actions § Cancel / Merge / Combine using the "Superseded" pattern with the plan's reason, and modifications per § Scope Changes.

For each conflict, ask `Proceed as planned` | `Modify approach` (free text, carried into issue creation) | `Skip this issue` (removed from creation).

---

## 3. Create the Project

### 3.1 Initiative

Where a project sits in the portfolio is the user's call. List the active initiatives and ask: `Link to [INITIATIVE]` (one option each) | `Create new initiative` | `No initiative`.

```bash
.agents/skills/linear/scripts/linear.sh cache initiatives list --status Active
```

Creating one takes a name and a multi-month objective as free text:

```bash
.agents/skills/linear/scripts/linear.sh initiatives create --name "[NAME]" --description "[DESCRIPTION]"
```

### 3.2 Project

`--description` is a 255-character subtitle; `--content` is the unlimited markdown body.

```bash
.agents/skills/linear/scripts/linear.sh projects create --name "[PROJECT_NAME]" --description "[PROJECT_DESC]" --state "planned"
.agents/skills/linear/scripts/linear.sh initiatives add-project [INITIATIVE_ID] --project [PROJECT_ID]
```

Skip the second command when no initiative was chosen. Keep `PROJECT_ID`.

### 3.3 Project Relations

**Skip if** `project_placement.relations` is empty.

```bash
.agents/skills/linear/scripts/linear.sh projects add-dependency [PROJECT_ID] --blocked-by [OTHER_PROJECT_ID]     # blocked-by
.agents/skills/linear/scripts/linear.sh projects add-dependency [OTHER_PROJECT_ID] --blocked-by [PROJECT_ID]     # blocks
```

Position within the backlog is not set here — `audit-issues project-order` owns project ordering and derives it from scope and dependencies.

---

## 4. Create the Issues

### 4.1 Label Preflight

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

Load the project taxonomy and validate every issue's `labels[]` per [labels.md](../references/labels.md) before writing the audit file. Complete a set from the taxonomy when only `agent`/`agent_label` is present. Unknown labels, parent/group labels, missing required categories, or exclusivity violations halt before mutation — never let the CLI warn and skip an invalid label.

### 4.2 Convert to Audit Input

Deterministic mapping only — do NOT re-analyze. Convert `TPM_OUTPUT` to the issue-mode format of [audit-output.md](../schemas/audit-output.md), one `issues[]` entry per `organized_issues[i]`:

| Field | Source |
|-------|--------|
| `index` | Sequential, 1-based |
| `identifier` | null — all proposed |
| `title`, `action`, `target`, `reason` | Same fields on `organized_issues[i]` |
| `project.recommended` | `project_placement.project_name`; `recommended_id` = `PROJECT_ID` from § 3.2 |
| `add_relations` | `depends_on_proposed` titles → `blocked_by: ["#N"]` by index; `depends_on_existing` → `blocked_by: ["[ISSUE_ID]"]`. Relations are already lifted to parent level — preserve them |
| `hierarchy` | Bundle children are always `make_child` of `#[parent_index]`. Parents and standalone issues follow `hierarchy_recommendation`: `children_of_origin` → `make_child` of the origin ID, anything else → `none`, `mixed` → per the TPM grouping |
| `supersedes` | Supersession entries in `cross_project_findings` |
| `obsolete` | `organized_issues[i].obsolete` |
| `priority_misalignment`, `agent_mismatch` | null — already correct |

Each entry's `create_fields` carries `description` (synthesized from title, feature context, and breaking changes), `recommendation` (requirement bullets, plus doc updates and migration steps), `location`, `estimate`, `priority`, `labels[]` (authoritative, validated in § 4.1), `agent_label`, `is_bundle_parent`, and `source_path` = the plan markdown path. A bundle parent sets `is_bundle_parent: true` with no description or recommendation — [parent-issue-template.md](../templates/parent-issue-template.md) content is generated after the children exist, via workflow-actions § Sync Parent Description.

Top-level: `{"mode": "issue", "source": "roadmap-create", "parent_issue": [from hierarchy_recommendation.origin_issue or null], "research_ref": [context.research_path], "plan_path": [context.plan_path]}`.

Write it to `tmp/audit-roadmap-YYYYMMDD-HHMMSS.json`, then run:

`⤵ workflows/audit-issues.md --analyzed tmp/audit-roadmap-YYYYMMDD-HHMMSS.json § 5-9 → § 4.3`

### 4.3 Relations Outside the Project

**Skip if** the plan has no dependency on an issue outside `PROJECT_NAME`.

```bash
.agents/skills/linear/scripts/linear.sh issues add-relation [ISSUE_ID] --blocked-by [EXTERNAL_ISSUE_ID]
.agents/skills/linear/scripts/linear.sh issues add-relation [ISSUE_ID] --related [EXTERNAL_ISSUE_ID]
```

Use `blocked_by` for a real dependency and `related` for an informational link. Dependencies cross projects freely — never relocate an issue to record one.

---

## 5. Verify and Report

```bash
.agents/skills/linear/scripts/linear.sh cache projects get [PROJECT_ID]
.agents/skills/linear/scripts/linear.sh cache projects list-dependencies [PROJECT_ID]
.agents/skills/linear/scripts/linear.sh cache issues list --project "[PROJECT_NAME]" --max
```

Confirm every issue landed in the project, the parent/child structure matches the plan, dependencies are set, and project relations exist. Report discrepancies; do not auto-fix them.

Archive the plan:

```bash
mkdir -p docs/roadmaps/archived
mv [PLAN_PATH] docs/roadmaps/archived/roadmap-[FEATURE]-$(date +%Y%m%d).md
mv [JSON_PATH] docs/roadmaps/archived/roadmap-[FEATURE]-$(date +%Y%m%d).json
```

<output_format>

### ROADMAP CREATED — created [N] / closed [M]

**Project**: [PROJECT_NAME] ([PROJECT_ID]) · **Initiative**: [INITIATIVE_NAME or "None"]

| Metric | Count |
|--------|-------|
| Issues created | N |
| Existing issues cancelled | M |
| Bundles | B |
| Relations added | R |

**Discrepancies** (omit when none)

| Issue | Expected | Actual |
|-------|----------|--------|

**Plan archived**: docs/roadmaps/archived/roadmap-[FEATURE]-YYYYMMDD.md
</output_format>

## 6. Return State

**If managed**: return to the parent workflow's next section. **If standalone**: session complete.
