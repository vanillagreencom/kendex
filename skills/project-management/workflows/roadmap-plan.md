# Roadmap Planning Workflow

Plan a new roadmap with research gate, specialist consultation, cross-project analysis, and architecture review.

## Inputs

| Command | Action |
|---------|--------|
| `roadmap plan [feature]` | Plan roadmap for feature |
| `roadmap plan [feature] @[research-path]` | Plan with existing research |
| `roadmap plan [feature] @[research-path] --origin-issue [ISSUE_ID]` | Plan with origin issue context for hierarchy |
| `roadmap plan [feature] --planner-handoff @[plan-file]` | Plan with an existing planner output from scout → planner chain |

---

## 1. Check Research Gate

### 1.1 Parse Arguments

Extract `FEATURE`, optional `RESEARCH_PATH`, optional `--origin-issue [ISSUE_ID]`, and optional `--planner-handoff @[PLAN_FILE]` from arguments.

If `--origin-issue` provided, fetch issue details and store as `ORIGIN_ISSUE`:
```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ORIGIN_ISSUE_ID]
```
Store `id`, `title`, `project`, `description`, `children`. If not provided, set `ORIGIN_ISSUE` = null.

If `--planner-handoff` is provided, read the planner file and extract `PLANNER_HANDOFF`:
- plan path
- plan summary / recommended approach
- proposed phases or issue candidates
- TPM Handoff Recommendation / TPM Handoff Prompt if present
- Linear issue IDs or project names mentioned

If no planner handoff is provided, set `PLANNER_HANDOFF` = null. Do not run `planner` inside this workflow; the normal orchestration chain is main → scout → planner → tpm → main, and this workflow consumes a planner handoff only when the main agent already has one. A planner handoff augments roadmap analysis; it does **not** skip the research gate, research-spike branch, TPM analysis, user approval, or Linear creation/confirmation steps.

### 1.2 Check for Research Context

| Condition | Action |
|-----------|--------|
| `@research-path` provided | Store path → § 2 |
| No path provided | Search for existing → § 1.3 |

### 1.3 Search Existing Research

1. **Resolve research issue label**:
   - Load issue-label inventory: `.agents/skills/linear/scripts/linear.sh cache labels list --format=safe`.
   - Load project taxonomy/application rules.
   - Resolve `RESEARCH_WORKFLOW_LABEL` to the project-configured issue label for completed research artifacts.
   - If no unambiguous assignable issue label exists, skip existing-research lookup and continue to § 2 (do not query a hard-coded fallback label).

2. **Search for research**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --label "[RESEARCH_WORKFLOW_LABEL]" --state "Done" --max
   ```

3. **Filter results** for `FEATURE` keywords in title/description.

4. **Route based on results**:

   | Result | Action |
   |--------|--------|
   | Matching research found | Extract path from issue → § 2 |
   | No matching research | → § 1.4 |

### 1.4 Offer Research Spike

1. **Ask user**:
   - **Run research spike (Recommended)** -- Informed planning with technical investigation
   - **Skip research** -- Less informed planning, higher risk of gaps

2. **Route based on selection**:

   | Selection | Action |
   |-----------|--------|
   | Run research spike | `⤵ workflows/research-spike.md [FEATURE] § 1-4`. After return, re-run `roadmap plan [FEATURE] @[RESEARCH_OUTPUT_PATH]` |
   | Skip research | Set `RESEARCH_PATH` = null → § 2 |

---

## 2. Determine Scope

### 2.1 Identify Relevant Agents

Infer from component paths (project-configurable). Match feature keywords to domain agents.

**Store matched agents** as `RELEVANT_AGENTS[]` for § 3 delegation.

---

## 3. Consult Specialist Agents

For each agent in `RELEVANT_AGENTS[]` (parallel sub-agent calls):

### 3.1 Delegate to Specialist Agents

**Delegation prompt:** Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

<delegation_format>
Feature: [FEATURE]
Research: [RESEARCH_PATH or "None"]

List implementation issues for your domain:

| Field | Description |
|-------|-------------|
| Title | Verb: outcome format (e.g., "Add dispose safety seam") |
| Estimate | 1-5 points -- see [recommendation-bias.md](../../linear-orch/workflows/recommendation-bias.md): 1 parent + children = 1 PR |
| Depends on (proposed) | Title reference to other proposed issues |
| Depends on (existing) | [ISSUE_ID] references |
| Conflicts with | Existing code/patterns that would be replaced |
| Breaking changes | APIs or contracts affected |
| Skills/docs updates | Files needing updates |
| Labels | Optional full issue-label set if known; include agent/domain/workflow labels from project taxonomy, otherwise leave blank for orchestrator/TPM completion |

Reply with structured table. Include ONLY issues for your domain.
</delegation_format>

### 3.2 Collect Responses

1. **Store all proposed issues** with source agent label and any proposed `labels[]`.

2. **Build initial `PROPOSED_ISSUES[]`** per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md). Keep `agent` as a derived/source field, but also carry `labels[]` when available so TPM can output a full validated label set.

---

## 4. Delegate Analysis to TPM

### 4.1 Write Input File

Write input per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md) to `tmp/roadmap-input-YYYYMMDD-HHMMSS.json`. Include `origin_issue` and `planner_handoff` fields (null if not provided).

### 4.2 Delegate to TPM

**Delegation prompt:** Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-roadmap-plan.md

Arguments: --input [INPUT_FILE_PATH]
</delegation_format>

### 4.3 Collect TPM Output

1. **Collect JSON path**: Agent returns `.JSON` file. If missing, halt.

2. **Read file**: Use Read tool to get structured output.

3. **Extract from output** (schema: project-management skill schemas roadmap-plan-output):
   - `hierarchy_recommendation` -- parent/child structure decision (if origin_issue was provided)
   - `cross_project_findings` -- duplicates, conflicts
   - `architecture_gaps[]` -- missing coverage
   - `organized_issues[]` -- with bundles, dependencies, critical path, priorities
   - `project_placement` -- recommended project name and relations

---

## 5. Analyze Impact

### 5.1 Delegate to Architecture Review Agent

**Delegate to architecture review agent**: Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

<delegation_format>
Review proposed roadmap for: [FEATURE]

Proposed project: [project_placement.name from TPM output]

Organized issues:
[organized_issues from TPM output]

Cross-project findings:
[cross_project_findings from TPM output]

Analyze and report:
1. Validate cross-project findings (confirm/refute duplicates, conflicts)
2. Existing code that would be deprecated
3. Breaking changes at module boundaries
4. Required refactors to accommodate new work
5. Risk assessment (high/medium/low with rationale)

Reply with structured findings as JSON.
</delegation_format>

### 5.2 Collect Arch-Review Output

Store `ARCH_FINDINGS`:
- `validated_findings[]` -- confirmed cross-project issues
- `deprecated_code[]` -- files/modules being replaced
- `breaking_changes[]` -- boundary impacts
- `required_refactors[]` -- prerequisite work
- `risk_assessment` -- overall risk level and rationale

---

## 6. Present Plan

### 6.1 Build Plan Summary

<output_format>

### ROADMAP PLAN — [FEATURE]

**Research**: [RESEARCH_PATH or "None -- less informed planning"]
**Origin Issue**: [ORIGIN_ISSUE.id: ORIGIN_ISSUE.title or "None"]
**Hierarchy**: [hierarchy_recommendation.type] -- [rationale]
**Risk**: [ARCH_FINDINGS.risk_assessment.level] -- [rationale summary]

---

### 📋 RECOMMENDED ACTIONS

**Cancel Existing** (if any)

| # | Issue | Reason |
|---|-------|--------|
| 1 | [ISSUE_ID] | Superseded by [new issue title] |

**Modify Existing** (if any)

| # | Issue | Change | Reason |
|---|-------|--------|--------|
| 1 | [ISSUE_ID] | Expand/Descope | [overlap details] |

**Conflicts to Resolve** (if any)

| # | New Issue | Conflicts With | Resolution |
|---|-----------|----------------|------------|
| 1 | [TITLE] | [ISSUE_ID] | [how to resolve] |

---

### 🏗️ PROJECT: [project_placement.name]

**Description**: [project_placement.description]

**Relations**:

| Relation | Project | Reason |
|----------|---------|--------|
| blocked-by | [PROJECT] | [REASON] |
| blocks | [PROJECT] | [REASON] |

---

### 📦 ISSUES ([N] total, [M] bundles)

| # | Title | Est | Agent | Pri | Parent | Deps | Critical |
|---|-------|-----|-------|-----|--------|------|----------|
| 1 | [Bundle: Data Dashboard] | — | multi | P2 | — | — | — |
| 2 | Add data source feed | 2 | [AGENT_TYPE] | P2 | #1 | — | Y |
| 3 | Add dashboard panel view | 2 | [AGENT_TYPE] | P2 | #1 | #2 | — |
| 4 | [Standalone issue] | 3 | [AGENT_TYPE] | P1 | — | [ISSUE_ID] | — |

Legend: Parent = bundle parent #, Deps = blocking dependencies, Pri = priority, Critical = on critical path

---

### 🕳️ ARCHITECTURE GAPS (if any)

| # | Component | Status | Recommendation |
|---|-----------|--------|----------------|
| 1 | Error handling | Missing | Create issue (included above) |
| 2 | Metrics collection | Stubbed | Defer → Deferred project |

---

### ⚠️ BREAKING CHANGES (if any)

| # | Boundary | Impact | Migration |
|---|----------|--------|-----------|
| 1 | Shared service API | Downstream consumers must update | Add deprecation, migrate in next phase |

</output_format>

### 6.2 Get Approval

1. **Ask user**:
   - **Approve** -- Save plan file
   - **Adjust** -- Specify changes (free text)
   - **Cancel** -- Discard plan

2. **Route based on selection**:

   | Selection | Action |
   |-----------|--------|
   | Approve | → § 7 |
   | Adjust | Incorporate feedback, update in-memory TPM JSON (§ 6.3), re-present § 6.1 |
   | Cancel | **END** -- Plan discarded |

### 6.3 Adjustment Propagation

| Adjustment | JSON update |
|-----------|-------------|
| Remove issue | Set `action: "skip"`, recompute dependent priorities |
| Change priority | Update `priority` field |
| Change agent | Update `agent`, recompute bundle parent `agent_label`, recompute affected `labels[]` through taxonomy before creation |
| Change estimate | Update `estimate` field |
| Add issue | Re-run `roadmap plan` (cannot add without specialist input) |

---

## 7. Save Plan File

### 7.1 Write Plan Files

Write markdown to `docs/roadmaps/roadmap-[FEATURE].md` and JSON to `docs/roadmaps/roadmap-[FEATURE].json`.

**JSON**: Save the TPM JSON output (with any § 6.3 adjustments applied). Set `context.plan_path` to the markdown path before writing.

**Markdown**:

```markdown
# Roadmap: [FEATURE]

**Research**: [RESEARCH_PATH or "None"]
**Origin Issue**: [ORIGIN_ISSUE.id or "None"]
**Hierarchy**: [hierarchy_recommendation.type or "none"]
**Plan data**: docs/roadmaps/roadmap-[FEATURE].json
**Created**: [DATE]
**Risk**: [LEVEL]

## Recommended Actions

### Cancel Existing Issues
| Issue | Reason |
|-------|--------|
| [ISSUE_ID] | Superseded by [new issue title] |

### Modify Existing
| Issue | Change | Reason |
|-------|--------|--------|
| [ISSUE_ID] | [expand/descope] | [details] |

### Conflicts to Resolve
| New Issue | Conflicts With | Resolution |
|-----------|----------------|------------|
| [TITLE] | [ISSUE_ID] | [how to resolve] |

## Project: [Name]

**Description**: [What this project delivers]

### Project Relations
| Relation | Project | Reason |
|----------|---------|--------|
| blocked-by | [PROJECT] | [REASON] |
| blocks | [PROJECT] | [REASON] |

### Issues

| Title | Est | Agent | Labels | Pri | Parent | Dependencies | Critical |
|-------|-----|-------|--------|-----|--------|--------------|----------|
| [Bundle: Name] | — | multi | agent:multi,[domain] | P2 | — | — | — |
| [Child issue] | 2 | [AGENT_TYPE] | agent:[TYPE],[domain] | P2 | [parent title] | — | — |
| [Standalone] | 3 | [AGENT_TYPE] | agent:[TYPE],[domain] | P1 | — | [ISSUE_ID] | Y |

## Architecture Gaps

| Component | Status | Recommendation |
|-----------|--------|----------------|
| [NAME] | [Missing/Stubbed] | [Action] |

## Breaking Changes

| Boundary | Impact | Migration |
|----------|--------|-----------|
| [Module/Boundary] | [Description] | [Plan] |
```

### 7.2 Report Completion

<output_format>

### ✅ PLAN SAVED

**Plan**: docs/roadmaps/roadmap-[FEATURE].md
**Data**: docs/roadmaps/roadmap-[FEATURE].json

**Next**: Run `roadmap create @docs/roadmaps/roadmap-[FEATURE].md` to execute plan

</output_format>

---

## 8. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — roadmap plan complete.
