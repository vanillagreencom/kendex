# Roadmap Creation Workflow

Execute an approved roadmap plan: resolve existing work, create the project, create the issues through the audit pipeline.

## 1. Load the Plan

`roadmap create @[plan-file]`. Without a plan file, error: "Requires a plan file from `workflows/roadmap-plan.md`."

Read the markdown for `FEATURE` and its `**Plan data**` path, then read that JSON as `TPM_OUTPUT` — the JSON is the contract, the markdown is the human copy. A plan whose JSON is missing or unreadable halts: re-run `roadmap plan`.

From `TPM_OUTPUT` take `project_placement`, `organized_issues[]`, `cross_project_findings`, `hierarchy_recommendation`, `architecture_gaps[]`, and `context`.

---

## 2. Resolve Existing Work

**Skip if** `cross_project_findings` has no `cancel`, `expand`, `descope`, or conflict entries.

Cancelling and rescoping existing issues is a work decision the plan gate already took for the rows it presented: actions and conflict resolutions unchanged since roadmap-plan § 5 `Approve` execute as presented without re-asking — only under the same provenance as `approved_at_plan_gate`: this wrapper collected that answer in this session on this identical presented set. A plan loaded in a later session, or edited since, presents every action. Otherwise present only what changed since that gate or was not shown there, then ask once: `Execute all` | `Review each` | `Skip`.

<output_format>

### EXISTING WORK AFFECTED

| # | Issue | Action | Why |
|---|-------|--------|-----|
| 1 | [ISSUE_ID] | cancel \| expand \| descope | [REASON] |

**Conflicts** ([N])

| # | New issue | Conflicts with | Resolution |
|---|-----------|----------------|------------|
</output_format>

`Review each` asks per action (`Execute` | `Skip` | `Modify` with free text). Execute cancellations per the Linear CLI's workflow-actions § State Transitions (cancel/absorb) with the plan's reason named in the comment, and modifications per § Descriptions.

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

Deterministic mapping only — do NOT re-analyze, and do NOT re-type: generate the file with a script (`jq` over `TPM_OUTPUT`) for every conversion, so field values transfer byte-exact. Convert `TPM_OUTPUT` to the issue-mode format of [audit-output.md](../schemas/audit-output.md), one `issues[]` entry per `organized_issues[i]` — skipping entries whose `project` is `Deferred` (deferred architecture gaps), which the § 5 report lists as deferred and which are never created in the roadmap project:

| Field | Source |
|-------|--------|
| `index` | Sequential, 1-based |
| `identifier` | null — all proposed |
| `title`, `action`, `target`, `reason` | Same fields on `organized_issues[i]` |
| `project.recommended` | `project_placement.project_name`; `recommended_id` = `PROJECT_ID` from § 3.2 |
| `add_relations` | `depends_on_proposed` titles → `blocked_by: ["#N"]` by index; `depends_on_existing` → `blocked_by: ["[ISSUE_ID]"]`. Relations are already lifted to parent level — preserve them |
| `hierarchy` | Bundle children are always `make_child` of `#[parent_index]`. Parents and standalone issues follow `hierarchy_recommendation`: `children_of_origin` → `make_child` of the origin ID, anything else → `none`, `mixed` → per the TPM grouping |
| `supersedes` | Supersession entries in `cross_project_findings` — unless § 2 already executed them |
| existing-work actions § 2 executed | Every cancel/expand/descope action § 2 already carried out enters as `action: "skip"` with `reason: "executed at § 2"`; a `supersede` whose cancellation § 2 completed enters as a plain `create` with `supersedes` cleared, so the approved replacement is still filed — never a live `cancel`/`supersede`, so § 6 asks about no action twice and § 7 repeats none |
| `obsolete` | `organized_issues[i].obsolete` |
| `priority_misalignment`, `agent_mismatch` | null — already correct |

Each entry's `create_fields` carries `description` (synthesized from title, feature context, and breaking changes), `recommendation` (requirement bullets, plus doc updates and migration steps), `location`, `estimate`, `priority`, `labels[]` (authoritative, validated in § 4.1), `agent_label`, `is_bundle_parent`, and `source_path` = the plan markdown path. A bundle parent sets `is_bundle_parent: true` with no description or recommendation — [parent-issue-template.md](../templates/parent-issue-template.md) content is generated after the children exist, via workflow-actions § Descriptions (parent rebuild).

Top-level: `{"mode": "issue", "source": "roadmap-create", "parent_issue": [from hierarchy_recommendation.origin_issue or null], "research_ref": [context.research_path], "plan_path": [context.plan_path], "approved_at_plan_gate": [true|false]}`.

`approved_at_plan_gate` is true only when this wrapper, in this session, collected `Approve` at roadmap-plan § 5 and the converted set is identical to the creation set that gate presented — its ISSUES table; `Deferred`-project entries were never part of it, so skipping them here keeps the sets identical. An item modified since — a § 2 conflict resolution, any post-approval edit — is marked `"reapprove": true` on its entry, and a set that no longer matches the approved one at all sets the flag false. audit-issues § 6 reads this to skip re-asking what the user already answered. `research_ref` — the SPEC path when planning from one — renders as the template's `**Research**` line on every created issue, unconditionally; the § 6 research question is a separate offer to pre-existing issues.

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
