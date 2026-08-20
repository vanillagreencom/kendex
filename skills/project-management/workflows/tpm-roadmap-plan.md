# Roadmap Planning Analysis

Analyze proposed issues for cross-project conflicts, architecture coverage, and organization.

**Do NOT modify the tracker.** Return recommendations only.

**Hold the creation bar** ([SKILL.md](../SKILL.md) § Disposition). A proposed issue survives only when it changes what a user or operator experiences (or blocks work that does), nothing open already covers it, and it is finishable as written. Everything else gets `action: "skip"` with a one-line reason. A roadmap that only adds work has not checked what it makes obsolete.

## Input

`--input [file_path]` per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md). Extract `FEATURE`, `RESEARCH_PATH`, `SPEC_PATH`, `ORIGIN_ISSUE`, `PLANNER_HANDOFF`, `PROPOSED_ISSUES[]`.

**Spec mode** (`SPEC_PATH` set): the plan's decisions are binding. Organize, dedupe, order, and bundle its work and check it against the tracker, but never change its approach, drop a workstream it names, or add scope beyond its phases — an architecture gap is `include` only when the spec's own deliverables need it; anything outside the spec's phases is `out_of_scope` — never `defer`, which would place it in `organized_issues[]` and reach creation — with the spec named in `reason`. Disagreement with the spec is a `declined`/`reason` note for the caller, never a silent reorganization.

A `PLANNER_HANDOFF` is high-signal technical context from the scout → planner chain, not a project-management decision. Preserve its plan path, proposed phases, and explicit TPM questions through the analysis; let it inform placement, grouping, dependency order, and the roadmap-vs-child-issue call — but verify every claim against current issue and project state.

---

## 1. Load Context

### 1.2 Label Policy

```bash
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

Load the project taxonomy alongside it; ask the caller to run `sync --reconcile` if the cache is missing or stale. This workflow does not mutate labels, but every issue it emits must carry a `labels[]` set valid against that inventory. Preserve input `labels[]` when present; derive the agent label and complete required categories from the taxonomy when only `agent` was supplied; flag the gap in `reason` rather than inventing a label when a required category cannot be determined. Never emit a parent/group label.

### 1.3 Origin Issue

**Skip if** `origin_issue` is null.

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ORIGIN_ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache issues children [ORIGIN_ISSUE_ID] --recursive --format=safe
```

Decide whether the proposed issues decompose the origin issue's scope (`children_of_origin`), reach beyond it (`new_project`), or split (`mixed`), and store `hierarchy_recommendation` with `type`, `origin_issue`, and `rationale`.

### 1.4 Projects

```bash
.agents/skills/linear/scripts/linear.sh cache projects list --state started
.agents/skills/linear/scripts/linear.sh cache projects list --state planned
.agents/skills/linear/scripts/linear.sh cache projects list --state backlog
.agents/skills/linear/scripts/linear.sh cache projects list --state completed
```

Store `id`, `name`, `state`, `description`, `content` per project.

### 1.5 Issues

Fetch every project's issues in ONE command — never loop `--project` per project, since restricted harness approval policies reject loop-shaped commands and each row already carries its `project` name:

```bash
.agents/skills/linear/scripts/linear.sh cache issues list --all-projects --state "Backlog,Todo,In Progress,In Review,Done" --max
```

Store `id`, `title`, `description`, `project`, `state`, `agent`, `labels[]`, `blocked_by[]`, `blocks[]` for comparison.

### 1.6 Research

**Skip if** `RESEARCH_PATH` is null. Read it and extract the technical findings, recommendations, and constraints; in spec mode, also its phases and per-phase deliverables, which bound § 3 and § 4.

---

## 2. Cross-Project Analysis

Compare each proposed issue against every fetched issue. Same title and scope is an exact duplicate (`skip`, reference the existing one); overlapping scope with a different approach means `expand` the existing issue or descope the proposal; a proposal that entirely replaces an existing issue means `cancel` the old one. Record in `cross_project_findings.duplicates[]`.

For each `conflicts_with` entry, search existing issues and code for the target and assess whether the proposal breaks existing work, collides with work in progress, or can coexist with modification. Record in `cross_project_findings.conflicts[]`.

Then place the roadmap: use an existing planned or backlog project when its scope matches, otherwise recommend a new one. For a new project, set relations from dependency direction — consuming another project's output is `blocked-by`, enabling one is `blocks`, no dependency means no relation:

```bash
.agents/skills/linear/scripts/linear.sh cache projects list-dependencies [PROJECT_ID]
```

Store in `project_placement`.

---

## 3. Architecture Coverage

Read the architecture docs relevant to `FEATURE` and the proposed agents, and extract module paths, named components, interfaces, and performance targets. For each in-scope component, check whether a proposed issue covers it, an existing issue covers it, or it is already implemented:

```bash
ls "[MODULE_PATH]"
rg -n "pub struct|pub fn|pub trait|export class|export function" "[MODULE_PATH]"
rg -n "TODO|unimplemented|todo|FIXME" "[MODULE_PATH]"
```

Record uncovered components in `architecture_gaps[]`: `include` when the gap blocks proposed work or the feature needs it (add to `organized_issues[]`), `defer` when it is nice-to-have (add with `project: "Deferred"`), `out_of_scope` when unrelated to the feature (record the gap only). A gap that clears none of the creation-bar tests is `out_of_scope`, not a deferred issue.

---

## 4. Organize

1. **Dependencies.** Map `depends_on_proposed` title references to concrete issues, identify chains, and error on a cycle.

2. **Bundles.** Group 2+ issues that share an agent with small estimates, share a work type (all tests, all config, all docs), or form one deliverable. Give each bundle a parent titled for the deliverable; append `(one PR)` only when the grouping reason was "would naturally be one PR/CI run" — an unmarked parent is a container whose children each ship separately. The parent takes the shared agent label, or the project's multi-agent label when children span 2+ agents, plus a full `labels[]` set that passes the label policy.

3. **Relation level.** Move `blocks`/`blocked_by` between bundled issues up to their bundle parents. Children carry no external blocking relations; only parents carry cross-bundle dependencies.

4. **Order.** Assign a layer (L0 foundation → L1 infrastructure → L2 features → L3 integration → L4 testing and polish) and compute `position = (layer x 100) + (enables_count x -10) + (estimate x 1)`. Lower is earlier.

5. **Priority.** L0 on the critical path, or L0/L1 enabling 2+ issues → P1; L1/L2 → P2; L3 → P3; L4 → P4. An issue blocking a P1 becomes P1; apply transitively until stable. `critical_path: true` when an issue blocks 2+ others.

Store in `organized_issues[]` sorted by `position`, each with `priority`, full `labels[]`, and `agent_label` for bundle parents.

---

## 5. Validate

For each organized issue, search the fetched issues for Done-state work covering the same scope. Match on title similarity plus description overlap, verify against the code that the implementation exists, and mark `obsolete` only at ≥90% confidence with evidence `{completed_by[], files_verified[]}`.

Assign the action: obsolete → `cancel`; exact duplicate → `skip`; partial overlap recommending expansion → `expand`; replaces an existing issue → `supersede`; fails the creation bar → `skip` with the failing test named; otherwise `create`. Store `action`, `target` (the existing issue for `expand`/`supersede`, else null), and `reason`.

---

## 6. Return Output

Build the JSON per [roadmap-plan-output.md](../schemas/roadmap-plan-output.md) and return it inline — the calling agent writes the file.

<output_format>
File: tmp/roadmap-plan-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>
