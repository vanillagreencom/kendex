# Roadmap Planning Workflow

Plan a roadmap: research gate, specialist consultation, TPM analysis, architecture review, user approval, plan file.

## Inputs

| Invocation | Effect |
|------------|--------|
| `roadmap plan [feature]` | Plan from scratch |
| `roadmap plan [feature] @[path]` | Plan with existing research — or with a **finished plan (spec)** |
| `... --origin-issue [ISSUE_ID]` | Supply origin-issue context for the hierarchy decision |
| `... --planner-handoff @[plan-file]` | Consume a plan from a scout → planner chain |

Extract `FEATURE`, `RESEARCH_PATH`, `ORIGIN_ISSUE`, and `PLANNER_HANDOFF` (each null when absent). Read the `@[path]` file and classify it: research findings inform planning; a **finished plan** — a design document the user has reviewed (external review included) that already settles approach and workstreams — is the SPEC. With a SPEC: § 1 is satisfied (the spec is the research), § 2 runs in slicing mode, the § 5 report presents the derived issues against it, and the spec's path travels as `RESEARCH_PATH` → `research_ref`, which the issue template writes as the `**Research**` line on every created issue (unconditionally — the § 6 research question offers the reference to pre-existing issues only), so it stays the live reference through delivery. The spec skips no approval and no creation gate. With `--origin-issue`, fetch it and keep `id`, `title`, `project`, `description`, `children`:

```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ORIGIN_ISSUE_ID]
```

With `--planner-handoff`, read the file and keep its plan path, recommended approach, proposed phases or issue candidates, any TPM handoff recommendation, and referenced issue or project names. Never run `planner` from here — the chain is main → scout → planner → tpm → main, and this workflow only consumes a handoff the main agent already has. A handoff informs the analysis; it skips no gate, no TPM step, no approval, and no creation confirmation.

---

## 1. Research Gate

**Skip if** `RESEARCH_PATH` was provided.

Search existing artifacts on disk first — the project's research and plan directories (`docs/research/`, `docs/plans/`, or the project's equivalents) by `FEATURE` keywords; classify a match with the Inputs rule (research vs SPEC) exactly as an `@[path]` argument, and when several match, ask the user which applies rather than choosing one; a selected artifact ends this gate → § 2. Only when the disk search finds nothing, query the tracker: resolve `RESEARCH_WORKFLOW_LABEL` from the project taxonomy and the live inventory (`cache labels list --format=safe`), then query it. If no unambiguous assignable label exists, skip the lookup and continue to § 2 — do not query a hard-coded fallback label.

```bash
.agents/skills/linear/scripts/linear.sh cache issues list --label "[RESEARCH_WORKFLOW_LABEL]" --state "Done" --max
```

Filter for `FEATURE` keywords. A match supplies `RESEARCH_PATH` from the issue → § 2.

With no match, ask the user — spending a research cycle is their call:

- **Research inline (recommended)** — gather what the plan needs now (code, vendor docs, web), write findings to `docs/research/[FEATURE].md`, and continue with it as `RESEARCH_PATH`. No tracker issue: research done in-session is planning work, not backlog.
- **Delegate a research spike** — standalone tracked research when the question is too large for this session. Run `⤵ workflows/research-spike.md [FEATURE] § 1-4` passing `auto_execute` explicitly: `true` has the researcher run it now, `false` leaves the issue ready for later pickup — never omit the value. Re-run `roadmap plan [FEATURE] @[RESEARCH_OUTPUT_PATH]` once findings exist.
- **Skip research** — set `RESEARCH_PATH` = null → § 2.

---

## 2. Consult Specialists

**Slicing mode (SPEC in hand):** when the spec already enumerates the workstreams, the parallel fan-out re-derives what is written down. Delegate one slicing pass per repo or domain the spec touches — at most one specialist each; the template's `Spec:` line carries the binding constraint, and they cut the spec's phases into PR-sized issues with real estimates and conflicts read from the code. Slicing delegates receive the same `<delegation_format>` below and answer in its table — `PROPOSED_ISSUES[]` is built from it either way.

Otherwise, match `FEATURE` keywords and component paths to domain agents (project-configurable) to get `RELEVANT_AGENTS[]`, then delegate to each in parallel:

<delegation_format>
Feature: [FEATURE]
Research: [RESEARCH_PATH or "None"]
Spec: [SPEC_PATH or "None"] — when set, its approach and workstreams are binding: do not re-litigate them; cut its phases into PR-sized issues

List implementation issues for your domain only. Reply as a table with these columns:

| Field | Description |
|-------|-------------|
| Title | Verb: outcome |
| Estimate | 1-5 points per PR unit — each child of a container bundle is its own PR; only a `(one PR)` parent estimates as one combined PR |
| Depends on (proposed) | Title reference to another proposed issue |
| Depends on (existing) | Leave blank unless you know a real [ISSUE_ID] — matching against the tracker is the TPM's job, never a guess here |
| Conflicts with | Existing code or patterns this would replace |
| Breaking changes | APIs or contracts affected |
| Skills/docs updates | Files needing updates |
| Labels | Full issue-label set if you know the project taxonomy, otherwise blank |

An issue only belongs on this list if it changes what a user or operator experiences, or blocks work that does. Do not list observations, hypotheticals, or edge cases no real input reaches.
</delegation_format>

Build `PROPOSED_ISSUES[]` per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md), keeping `agent` as the source field and carrying `labels[]` when the specialist supplied them.

---

## 3. TPM Analysis

Write the input file per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md) to `tmp/roadmap-input-YYYYMMDD-HHMMSS.json`, including `origin_issue`, `planner_handoff`, and `spec_path` (each null when absent — `spec_path` is set exactly when the artifact in hand — the `@[path]` input or the § 1 disk match — classified as a SPEC, so the TPM knows the plan's decisions are binding). Delegate to a one-shot `[TPM]` sub-agent:

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
Spec: [SPEC_PATH or "None"] — when set, the spec's phases bound the roadmap: report anything beyond them as out-of-spec, with why it is needed

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
6. Out-of-spec work (spec mode only): anything needed beyond the spec's phases — each entry names the work and whether the spec's own deliverables need it
</delegation_format>

Keep the result as `ARCH_FINDINGS` (`validated_findings[]`, `deprecated_code[]`, `breaking_changes[]`, `required_refactors[]`, `risk_assessment`, `out_of_spec[]`). Fold verified findings into the TPM JSON — scope additions into the issues they belong to, ordering fixes into relations — before presenting. In spec mode the fold stops at the spec's boundary, with the same exception the TPM applies: an `out_of_spec[]` entry the spec's own deliverables need is folded in as `include`; every other entry becomes an `architecture_gaps[]` row with `recommendation: out_of_scope` — never `defer` — naming the spec in `reason`, rendered under ARCHITECTURE GAPS in § 5.

For a major feature planned without an already-reviewed spec, also run the `second-opinion` skill (challenge mode; an optional dependency) on the plan here and fold verified findings in the same way — when the skill is not installed, or is installed but cannot complete (no eligible target, missing external CLI, timeout, nonzero exit), the § 5 report's `Cross-model review` field reads `unavailable — <reason>` and the workflow continues. A SPEC that already passed external review skips this.

---

## 5. Present and Approve

Render ISSUES from `organized_issues[]` entries with `action: "create"` only — `skip` entries (TPM duplicates, creation-bar failures, user removals) render under DECLINED, and `project: "Deferred"` entries under ARCHITECTURE GAPS with Recommendation `defer` — so the table is exactly the creation set the approval binds. Render every `cross_project_findings.conflicts[]` entry in the Conflicts table — a resolution the user has not seen cannot be carried.

<output_format>

### ROADMAP PLAN — [FEATURE]

Research: [RESEARCH_PATH or "None — less informed planning"] · Origin: [ORIGIN_ISSUE.id or "None"] · Hierarchy: [hierarchy_recommendation.type] · Risk: [risk_assessment.level] · Cross-model review: [verdict summary | unavailable | skipped — reviewed spec]

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

Ask: `Approve` | `Adjust` | `Cancel`. `Cancel` discards the plan and ends the workflow. **`Approve` authorizes the presented creation set** — the ISSUES table, which never contains `Deferred`-project entries (deferred gaps appear under ARCHITECTURE GAPS and are never created) — **and the EXISTING WORK AFFECTED actions as presented**: `roadmap create` carries this answer — its § 2 executes unchanged cancel/expand/descope actions and as-presented conflict resolutions without re-asking, and audit-issues § 6 re-asks only items that changed after it. `Adjust` takes free text, updates the in-memory TPM JSON, and re-presents:

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
