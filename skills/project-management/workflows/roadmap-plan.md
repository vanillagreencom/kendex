# Roadmap Planning Workflow

Plan a roadmap: research gate, specialist consultation, TPM analysis, architecture review, user approval, plan file.

## Inputs

| Invocation | Effect |
|------------|--------|
| `roadmap plan [feature]` | Plan from scratch |
| `roadmap plan [feature] @[research-path]` | Plan with existing research |
| `... --origin-issue [ISSUE_ID]` | Supply origin-issue context for the hierarchy decision |
| `... --planner-handoff @[plan-file]` | Consume a plan from a scout → planner chain |

Extract `FEATURE`, `RESEARCH_PATH`, `ORIGIN_ISSUE`, and `PLANNER_HANDOFF` (each null when absent). With `--origin-issue`, fetch it and keep `id`, `title`, `project`, `description`, `children`:

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ORIGIN_ISSUE_ID]
```

With `--planner-handoff`, read the file and keep its plan path, recommended approach, proposed phases or issue candidates, any TPM handoff recommendation, and referenced issue or project names. Never run `planner` from here — the chain is main → scout → planner → tpm → main, and this workflow only consumes a handoff the main agent already has. A handoff informs the analysis; it skips no gate, no TPM step, no approval, and no creation confirmation.

---

## 1. Research Gate

**Skip if** `RESEARCH_PATH` was provided.

Search for existing research: resolve `RESEARCH_WORKFLOW_LABEL` from the project taxonomy and the live inventory (`cache labels list --format=safe`), then query it. If no unambiguous assignable label exists, skip the lookup and continue to § 2 — do not query a hard-coded fallback label.

```bash
.agents/skills/linear/scripts/linear.sh cache issues list --label "[RESEARCH_WORKFLOW_LABEL]" --state "Done" --max
```

Filter for `FEATURE` keywords. A match supplies `RESEARCH_PATH` from the issue → § 2.

With no match, ask the user — spending a research cycle is their call:

- **Run research spike (recommended)** — informed planning. Run `⤵ workflows/research-spike.md [FEATURE] § 1-4`, then re-run `roadmap plan [FEATURE] @[RESEARCH_OUTPUT_PATH]`.
- **Skip research** — set `RESEARCH_PATH` = null → § 2.

---

## 2. Consult Specialists

Match `FEATURE` keywords and component paths to domain agents (project-configurable) to get `RELEVANT_AGENTS[]`, then delegate to each in parallel:

<delegation_format>
Feature: [FEATURE]
Research: [RESEARCH_PATH or "None"]

List implementation issues for your domain only. Reply as a table with these columns:

| Field | Description |
|-------|-------------|
| Title | Verb: outcome |
| Estimate | 1-5 points per PR unit — each child of a container bundle is its own PR; only a `(one PR)` parent estimates as one combined PR |
| Depends on (proposed) | Title reference to another proposed issue |
| Depends on (existing) | [ISSUE_ID] references |
| Conflicts with | Existing code or patterns this would replace |
| Breaking changes | APIs or contracts affected |
| Skills/docs updates | Files needing updates |
| Labels | Full issue-label set if you know the project taxonomy, otherwise blank |

An issue only belongs on this list if it changes what a user or operator experiences, or blocks work that does. Do not list observations, hypotheticals, or edge cases no real input reaches.
</delegation_format>

Build `PROPOSED_ISSUES[]` per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md), keeping `agent` as the source field and carrying `labels[]` when the specialist supplied them.

---

## 3. TPM Analysis

Write the input file per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md) to `tmp/roadmap-input-YYYYMMDD-HHMMSS.json`, including `origin_issue` and `planner_handoff` (null when absent). Delegate to a one-shot `[TPM]` sub-agent:

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-roadmap-plan.md

Arguments: --input [INPUT_FILE_PATH]
</delegation_format>

Materialize the returned artifact the same way as audit-issues § 4.2 — the `File:` line is a destination hint, the caller writes the inline JSON, and a missing payload with an unreadable path halts for a rerun. Read `hierarchy_recommendation`, `cross_project_findings`, `architecture_gaps[]`, `organized_issues[]`, and `project_placement`.

---

## 4. Architecture Review

Delegate to the architecture review agent:

<delegation_format>
Review proposed roadmap for: [FEATURE]

Proposed project: [project_placement.project_name]

Organized issues:
[organized_issues]

Cross-project findings:
[cross_project_findings]

Report as JSON:
1. Validate the cross-project findings — confirm or refute each duplicate and conflict
2. Existing code this would deprecate
3. Breaking changes at module boundaries
4. Prerequisite refactors
5. Risk assessment (high/medium/low) with rationale
</delegation_format>

Keep the result as `ARCH_FINDINGS` (`validated_findings[]`, `deprecated_code[]`, `breaking_changes[]`, `required_refactors[]`, `risk_assessment`).

---

## 5. Present and Approve

<output_format>

### ROADMAP PLAN — [FEATURE]

Research: [RESEARCH_PATH or "None — less informed planning"] · Origin: [ORIGIN_ISSUE.id or "None"] · Hierarchy: [hierarchy_recommendation.type] · Risk: [risk_assessment.level]

### PROJECT: [project_placement.project_name]

[project_placement.project_description]

| Relation | Project | Why |
|----------|---------|-----|

### ISSUES ([N] total, [M] bundles)

| # | Title | Est | Agent | Pri | Parent | Deps | Critical |
|---|-------|-----|-------|-----|--------|------|----------|

### EXISTING WORK AFFECTED (omit empty sections)

| Issue | Action | Why |
|-------|--------|-----|
| [ISSUE_ID] | cancel \| expand \| descope | [REASON] |

### ARCHITECTURE GAPS

| Component | Status | Recommendation |
|-----------|--------|----------------|

### BREAKING CHANGES

| Boundary | Impact | Migration |
|----------|--------|-----------|

### DECLINED ([N]) — proposed but not filed

- [TITLE] — [which creation-bar test it fails]
</output_format>

Ask: `Approve` | `Adjust` | `Cancel`. `Cancel` discards the plan and ends the workflow. `Adjust` takes free text, updates the in-memory TPM JSON, and re-presents:

| Adjustment | JSON update |
|------------|-------------|
| Remove an issue | `action: "skip"`, recompute dependent priorities |
| Change priority / estimate | Update the field |
| Change agent | Update `agent`, recompute the bundle parent's agent label, recompute affected `labels[]` through the taxonomy |
| Add an issue | Re-run `roadmap plan` — a new issue needs specialist input |

---

## 6. Save the Plan

Write both files. The JSON is the contract `roadmap create` consumes; the markdown is the human-readable copy.

- `docs/roadmaps/roadmap-[FEATURE].json` — the TPM JSON with § 5 adjustments applied and `context.plan_path` set to the markdown path.
- `docs/roadmaps/roadmap-[FEATURE].md` — the § 5 report, plus a `**Plan data**: docs/roadmaps/roadmap-[FEATURE].json` line and the creation date.

<output_format>

### PLAN SAVED

**Plan**: docs/roadmaps/roadmap-[FEATURE].md
**Data**: docs/roadmaps/roadmap-[FEATURE].json

**Next**: `roadmap create @docs/roadmaps/roadmap-[FEATURE].md`
</output_format>

## 7. Return State

**If managed**: return to the parent workflow's next section. **If standalone**: session complete.
