# Roadmap Planning Workflow

Plan a roadmap: research gate, specialist consultation, TPM analysis, architecture review, user approval, plan file.

## Inputs

| Invocation | Effect |
|------------|--------|
| `roadmap plan [feature]` | Plan from scratch |
| `roadmap plan [feature] @[path]` | Plan with existing research — or with a **finished plan (spec)** |
| `... --origin-issue [ISSUE_ID]` | Supply origin-issue context for the hierarchy decision |
| `... --planner-handoff @[plan-file]` | Consume a plan from a scout → planner chain |

1. Extract `FEATURE`, `RESEARCH_PATH`, `ORIGIN_ISSUE`, and `PLANNER_HANDOFF` (each null when absent).

2. Read the `@[path]` file and classify it: research findings inform planning; a **finished plan** — a design document the user has reviewed that already settles approach and workstreams — is the SPEC.

3. With a SPEC: § 1 is satisfied, § 2 runs in slicing mode, the § 5 report presents the derived issues against it, and the spec's path travels as `RESEARCH_PATH` → `research_ref`, which the issue template writes as the `**Research**` line on every created issue (unconditionally; the § 6 research question offers the reference to pre-existing issues only). The spec skips no approval and no creation gate.

4. Refresh a stale cache before the first read here and in §§ 1-2. Planning itself only reads; the § 1 research-spike branch delegates to research-issue, which reconciles again before it creates anything:

   ```bash
   .agents/skills/linear/scripts/linear.sh sync --if-stale 15
   ```

5. With `--origin-issue`, fetch it and keep `id`, `title`, `project`, `description`, `children`:

   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues get [ORIGIN_ISSUE_ID]
   ```

6. With `--planner-handoff`, read the file and keep its plan path, recommended approach, proposed phases or issue candidates, any TPM handoff recommendation, and referenced issue or project names. Never run `planner` from here. A handoff skips no gate, no TPM step, no approval, and no creation confirmation.

---

## 1. Research Gate

**Skip if** `RESEARCH_PATH` was provided.

1. Search existing artifacts on disk first — the project's research and plan directories (`docs/research/`, `docs/plans/`, or the project's equivalents) by `FEATURE` keywords.

2. Then classify a match with the Inputs rule (research vs SPEC) exactly as an `@[path]` argument, and when several match, ask the user which applies; a selected artifact ends this gate → § 2. Only when the disk search finds nothing, query the tracker: resolve `RESEARCH_WORKFLOW_LABEL` from the project taxonomy and the live inventory (`cache labels list --format=safe`), then query it. If no unambiguous assignable label exists, skip the lookup and continue to § 2; do not query a hard-coded fallback label.

   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --label "[RESEARCH_WORKFLOW_LABEL]" --state "Done" --max
   ```

3. Filter for `FEATURE` keywords. A match supplies `RESEARCH_PATH` from the issue → § 2.

With no match, ask the user:

- **Research inline (recommended)** — gather what the plan needs now (code, vendor docs, web), write findings to `docs/research/[FEATURE].md`, and continue with it as `RESEARCH_PATH`. No tracker issue.
- **Delegate a research spike** — standalone tracked research. Run `⤵ workflows/research-spike.md [FEATURE] § 1-4` passing `auto_execute` explicitly: `true` has the researcher run it now, `false` leaves the issue ready for later pickup — never omit the value. Re-run `roadmap plan [FEATURE] @[RESEARCH_OUTPUT_PATH]` once findings exist.
- **Skip research** — set `RESEARCH_PATH` = null → § 2.

---

## 2. Consult Specialists

**Slicing mode (SPEC in hand):** delegate one slicing pass per repo or domain the spec touches — at most one specialist each; the template's `Spec:` line carries the binding constraint, and they cut the spec's phases into PR-sized issues with real estimates and conflicts read from the code. Slicing delegates receive the same `<delegation_format>` below and answer in its table.

Otherwise, match `FEATURE` keywords and component paths to domain agents (project-configurable) to get `RELEVANT_AGENTS[]`, then delegate to each in parallel.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.
`[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Feature: [FEATURE]
Research: [RESEARCH_PATH or "None"]
Spec: [SPEC_PATH or "None"] — when set, its approach and workstreams are binding: do not re-litigate them; cut its phases into PR-sized issues
Worktree: [WORKTREE_PATH]

List implementation issues for your domain only. Reply as a table with these columns:

| Field | Description |
|-------|-------------|
| Title | Verb: outcome |
| Estimate | 1-5 points per PR unit — each child of a container bundle is its own PR; only a `(one PR)` parent estimates as one combined PR |
| Depends on (proposed) | Title reference to another proposed issue |
| Depends on (existing) | Leave blank unless you know a real [ISSUE_ID]; never guess |
| Conflicts with | Existing code or patterns this would replace |
| Breaking changes | APIs or contracts affected |
| Skills/docs updates | Files needing updates |
| Labels | Full issue-label set if you know the project taxonomy, otherwise blank |

An issue only belongs on this list if it changes what a user or operator experiences, or blocks work that does. Do not list observations, hypotheticals, or edge cases no real input reaches.
</delegation_format>

Build `PROPOSED_ISSUES[]` per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md), keeping `agent` as the source field and carrying `labels[]` when the specialist supplied them.

---

## 3. TPM Analysis

Write the input file per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md) to `tmp/roadmap-input-YYYYMMDD-HHMMSS.json`, including `origin_issue`, `planner_handoff`, and `spec_path` (each null when absent; `spec_path` is set exactly when the artifact in hand — the `@[path]` input or the § 1 disk match — classified as a SPEC). Delegate to a one-shot `[TPM]` sub-agent.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.
`[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-roadmap-plan.md

Arguments: --input [INPUT_FILE_PATH]
Worktree: [WORKTREE_PATH]
</delegation_format>

Materialize the returned artifact the same way as audit-issues § 4.2. Read `hierarchy_recommendation`, `cross_project_findings`, `architecture_gaps[]`, `organized_issues[]`, and `project_placement`.

---

## 4. Architecture Review

Delegate to the architecture review agent.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.
`[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Review proposed roadmap for: [FEATURE]

Proposed project: [project_placement.project_name]
Spec: [SPEC_PATH or "None"] — when set, the spec's phases bound the roadmap: report anything beyond them as out-of-spec, with why it is needed
Worktree: [WORKTREE_PATH]

Organized issues:
[organized_issues]

Cross-project findings:
[cross_project_findings]

Report as JSON:
1. Validate the cross-project findings — confirm or refute each duplicate and conflict
2. Existing code this would deprecate
3. Breaking changes at module boundaries
4. Prerequisite refactors
5. Risk assessment (high/medium/low) with reasoning
6. Out-of-spec work (spec mode only): anything needed beyond the spec's phases — each entry names the work and whether the spec's own deliverables need it
</delegation_format>

1. Keep the result as `ARCH_FINDINGS` (`validated_findings[]`, `deprecated_code[]`, `breaking_changes[]`, `required_refactors[]`, `risk_assessment`, `out_of_spec[]`).

2. Fold verified findings into the TPM JSON before presenting: scope additions go into the issues they belong to, ordering fixes into relations, and any standalone addition — a `required_refactors[]` prerequisite, a second-opinion finding, or a needed `out_of_spec[]` entry — re-enters § 2's delegation table for its domain and § 3; the fold never invents issue fields.

3. In spec mode the fold stops at the spec's boundary, with the same exception the TPM applies: an `out_of_spec[]` entry the spec's own deliverables need re-enters planning like any standalone addition; every other entry becomes an `architecture_gaps[]` row with `recommendation: out_of_scope` — never `defer` — naming the spec in `reason`, rendered under ARCHITECTURE GAPS in § 5.

4. For a major feature — any of: ten or more creation entries, entries spanning two or more `agent:*` domains, a listed breaking change, or `risk_assessment.level: high` — planned without an already-reviewed spec, also run the `second-opinion` skill (challenge mode) on the plan here and fold verified findings in the same way. When the skill is not installed, or is installed but cannot complete (no eligible target, missing external CLI, timeout, nonzero exit), the § 5 report's `Cross-model review` field reads `unavailable — <reason>` and the workflow continues. A SPEC that already passed external review skips this (`skipped — reviewed spec`); a non-major plan records `skipped — not required`.

---

## 5. Present and Approve

Render ISSUES from `organized_issues[]` creation-bearing entries only — `action: "create"` and `"supersede"` (the replacement; its cancellation also appears under EXISTING WORK AFFECTED) — `skip` entries (TPM duplicates, creation-bar failures, user removals) render under DECLINED, and `project: "Deferred"` entries under ARCHITECTURE GAPS with Recommendation `defer`. Render every `cross_project_findings.conflicts[]` entry in the Conflicts table.

<output_format>

### ROADMAP PLAN — [FEATURE]

Research: [RESEARCH_PATH or "None — less informed planning"] · Origin: [ORIGIN_ISSUE.id or "None"] · Hierarchy: [hierarchy_recommendation.type] · Risk: [risk_assessment.level] · Cross-model review: [verdict summary | unavailable — <reason> | skipped — reviewed spec | skipped — not required]

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

**Conflicts** ([N])

| # | New issue | Conflicts with | Resolution |
|---|-----------|----------------|------------|

### ARCHITECTURE GAPS

| Component | Status | Recommendation |
|-----------|--------|----------------|

### BREAKING CHANGES

| Boundary | Impact | Migration |
|----------|--------|-----------|

### DECLINED ([N]) — proposed but not filed

- [TITLE] — [which creation-bar test it fails]
</output_format>

Ask: `Approve` | `Adjust` | `Cancel`. `Cancel` discards the plan and ends the workflow. **`Approve` authorizes the presented creation set** — the ISSUES table, which never contains `Deferred`-project entries — **and the EXISTING WORK AFFECTED actions as presented**: `roadmap create` § 2 executes unchanged actions and as-presented conflict resolutions without re-asking, and audit-issues § 6 re-asks only items that changed after it. `Adjust` takes free text, updates the in-memory TPM JSON, and re-presents:

| Adjustment | JSON update |
|------------|-------------|
| Remove an issue | `action: "skip"`, recompute dependent priorities |
| Change priority / estimate | Update the field |
| Change agent | Update `agent`, recompute the bundle parent's agent label, recompute affected `labels[]` through the taxonomy |
| Add an issue | Re-run `roadmap plan` |

---

## 6. Save the Plan

Write both files.

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
