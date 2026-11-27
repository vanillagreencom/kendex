# Roadmap Planning Workflow

Plan a roadmap: research gate, specialist consultation, TPM analysis, architecture review, user approval, plan file.

## Inputs

| Invocation | Effect |
|------------|--------|
| `roadmap plan [feature]` | Plan from scratch |
| `roadmap plan [feature] @[path]` | Plan with existing research — or with a **finished plan (spec)** |
| `... --source-issue [ISSUE_ID]` | Identify the issue holding the cited artifact before reading it |
| `... --origin-issue [ISSUE_ID]` | Supply origin-issue context for the hierarchy decision |
| `... --planner-handoff @[plan-file]` | Consume a plan from a scout → planner chain |

1. Extract `FEATURE`, `RESEARCH_PATH`, `SOURCE_ISSUE`, `ORIGIN_ISSUE`, and `PLANNER_HANDOFF` (each null when absent). `SOURCE_ISSUE` comes from `--source-issue` or source context passed by the caller.

2. Resolve the `@[path]` input under [planning-artifacts.md](../references/planning-artifacts.md), using `SOURCE_ISSUE` for attachment lookup.
   1. Keep `RESEARCH_PATH` as its repository reference and `RESEARCH_READ_PATH` as the readable file in this checkout.
   2. Read that file and classify it:
      - Research findings inform planning.
      - A **finished plan**, a design document the user has reviewed that already settles approach and workstreams, is the SPEC.
   3. When it is a SPEC, `SPEC_PATH` is the same reference and `SPEC_READ_PATH` is the same readable file.

3. With a SPEC:
   - § 1 is satisfied.
   - § 2 runs in slicing mode.
   - The § 5 report presents the derived issues against it.
   - The spec's path travels as `RESEARCH_PATH` → `research_ref`, which the issue template writes as the `**Research**` line on every created issue, unconditionally. The § 6 research question offers the reference to pre-existing issues only.
   - Read from the spec `REMOVED_TERMS[]`, each route, file, rule or mechanism it removes or replaces, with its replacement.
   - Read from the spec `TEAMS[]`, the tracker teams it names. Null when it names none.
   - The spec skips no approval and no creation gate.

4. With `--origin-issue`, fetch it and keep `id`, `title`, `project`, `description`, `children`:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues get [ORIGIN_ISSUE_ID]
   ```

5. With `--planner-handoff`:
   - Read the file and keep its plan path, recommended approach, proposed phases or issue candidates, any TPM handoff recommendation, and referenced issue or project names.
   - Never run `planner` from here.
   - A handoff skips no gate, no TPM step, no approval, and no creation confirmation.

---

## 1. Research Gate

**Skip if** `RESEARCH_PATH` was provided.

1. Search existing artifacts first — the tracker's issues and their attachments, and this session's `tmp/plans/` and `tmp/roadmaps/`, by `FEATURE` keywords.

2. Then classify a match with the Inputs rule (research vs SPEC) exactly as an `@[path]` argument.
   - When several match, ask the user which applies.
   - A selected artifact ends this gate → § 2.
   - Only when the disk search finds nothing, query the tracker:
     1. Resolve `RESEARCH_WORKFLOW_LABEL` from the project taxonomy and the live inventory (`labels list --max --format=safe`).
     2. Then query it.
     3. If no unambiguous assignable label exists, skip the lookup and continue to § 2. Do not query a hard-coded fallback label.

   ```bash
   .agents/skills/linear/scripts/linear.sh issues list --label "[RESEARCH_WORKFLOW_LABEL]" --state "Done" --max
   ```

3. Filter for `FEATURE` keywords.
   - A match supplies `RESEARCH_PATH` and its issue ID as `SOURCE_ISSUE`.
   - Resolve and classify it under the Inputs rule before § 2.
   - An inline or local-disk selection uses the same rule to set the readable path.
   - Skipped research leaves the path fields null.

With no match, ask the user:

- **Research inline (recommended)**:
  1. Gather what the plan needs now (code, vendor docs, web).
  2. Write findings to `tmp/plans/[FEATURE]-research.md`.
  3. Continue with it as `RESEARCH_PATH`.
  - No tracker issue. The file reaches the issues the plan creates under [planning-artifacts.md](../references/planning-artifacts.md).
- **Delegate a research spike**, standalone tracked research:
  1. Run `⤵ workflows/research-spike.md [FEATURE] § 1-4` passing `auto_execute` explicitly: `true` has the researcher run it now, `false` leaves the issue ready for later pickup. Never omit the value.
  2. Capture the returned `RESEARCH_ISSUE_ID`.
  3. Re-run `roadmap plan [FEATURE] @[RESEARCH_OUTPUT_PATH] --source-issue [RESEARCH_ISSUE_ID]` once findings exist.
- **Skip research** — set `RESEARCH_PATH` = null → § 2.

---

## 2. Consult Specialists

**Slicing mode (SPEC in hand):**

- Delegate one slicing pass per repo or domain the spec touches, at most one specialist each.
- The template's `Spec:` line carries the binding constraint. They cut the spec's phases into PR-sized issues with real estimates and conflicts read from the code.
- Slicing delegates receive the same `<delegation_format>` below and answer in its table.

Otherwise:

1. Match `FEATURE` keywords and component paths to domain agents (project-configurable) to get `RELEVANT_AGENTS[]`.
2. Delegate to each in parallel.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`. `[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Feature: [FEATURE]
Research: [RESEARCH_READ_PATH or "None"]
Research reference: [RESEARCH_PATH or "None"]
Source issue: [SOURCE_ISSUE or "None"]
Spec: [SPEC_READ_PATH or "None"] — when set, its approach and workstreams are binding: do not re-litigate them; cut its phases into PR-sized issues
Worktree: [WORKTREE_PATH]

List implementation issues for your domain only. Reply as a table with these columns:

| Field | Description |
|-------|-------------|
| Title | Verb: outcome |
| Estimate | 1-5 points per PR unit — each child of a container is its own PR; a container carries no estimate |
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

1. Write the input file per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md) to `tmp/roadmap-input-YYYYMMDD-HHMMSS.json`, including `research_read_path` from `RESEARCH_READ_PATH`, `research_source_issue` from `SOURCE_ISSUE`, `origin_issue`, `planner_handoff`, `spec_path`, `removed_terms` from `REMOVED_TERMS[]` and `teams` from `TEAMS[]`.
   - Each is null when absent.
   - `spec_path` is set exactly when the artifact in hand, the `@[path]` input or the § 1 disk match, classified as a SPEC.
2. Delegate to a one-shot `[TPM]` sub-agent.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`. `[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-roadmap-plan.md

Arguments: --input [INPUT_FILE_PATH]
Worktree: [WORKTREE_PATH]
</delegation_format>

1. Materialize the returned artifact the same way as audit-issues § 4.2.
2. Read `hierarchy_recommendation`, `cross_project_findings`, `removal_review[]`, `architecture_gaps[]`, `organized_issues[]`, and `project_placement`.

---

## 4. Architecture Review

Delegate to the architecture review agent.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`. `[DIR]` is the caller's own checkout, main checkout included.

<delegation_format>
Review proposed roadmap for: [FEATURE]

Proposed project: [project_placement.project_name]
Spec: [SPEC_READ_PATH or "None"] — when set, the spec's phases bound the roadmap: report anything beyond them as out-of-spec, with why it is needed
Spec reference: [SPEC_PATH or "None"]
Source issue: [SOURCE_ISSUE or "None"]
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

2. Fold verified findings into the TPM JSON before presenting:
   - Scope additions go into the issues they belong to.
   - Ordering fixes go into relations.
   - Any standalone addition, a `required_refactors[]` prerequisite, a second-opinion finding, or a needed `out_of_spec[]` entry, re-enters § 2's delegation table for its domain and § 3.
   - The fold never invents issue fields.

3. In spec mode the fold stops at the spec's boundary, with the same exception the TPM applies:
   - An `out_of_spec[]` entry the spec's own deliverables need re-enters planning like any standalone addition.
   - Every other entry becomes an `architecture_gaps[]` row with `recommendation: out_of_scope`, never `defer`, naming the spec in `reason`, rendered under ARCHITECTURE GAPS in § 5.

4. For a major feature planned without an already-reviewed spec, also run the `second-opinion` skill (challenge mode) on the plan here and fold verified findings in the same way.
   - A major feature is any of: ten or more creation entries, entries spanning two or more `agent:*` domains, a listed breaking change, or `risk_assessment.level: high`.
   - When the skill is not installed, or is installed but cannot complete (no eligible target, missing external CLI, timeout, nonzero exit), the § 5 report's `Cross-model review` field reads `unavailable — <reason>` and the workflow continues.
   - A SPEC that already passed external review skips this (`skipped — reviewed spec`).
   - A non-major plan records `skipped — not required`.

---

## 5. Present and Approve

- Render ISSUES from `organized_issues[]` creation-bearing entries only: `action: "create"` and `"supersede"` (the replacement; its cancellation also appears under EXISTING WORK AFFECTED).
- Render `skip` entries (TPM duplicates, creation-bar failures, user removals) under DECLINED.
- Render `project: "Deferred"` entries under ARCHITECTURE GAPS with Recommendation `defer`.
- Render every `cross_project_findings.conflicts[]` entry in the Conflicts table.
- Render each `removal_review[]` team as one OPEN ITEMS CHECKED row, and each of its `cancel` and `rewrite` items under EXISTING WORK AFFECTED. Its `keep` items stay in the plan JSON.
- A removal item whose row a `cross_project_findings` cancel, supersede or expand also names takes that action's row, with both reasons folded into one Why, so that issue renders once under EXISTING WORK AFFECTED.
- A row a descope finding names keeps its removal action as its own EXISTING WORK AFFECTED row.

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
| [ISSUE_ID] | cancel \| expand \| descope \| rewrite | [REASON] |

**Conflicts** ([N])

| # | New issue | Conflicts with | Resolution |
|---|-----------|----------------|------------|

### OPEN ITEMS CHECKED (omit when `removal_review[]` is empty)

| Team | Checked | Cancel | Rewrite | Keep |
|------|---------|--------|---------|------|

### ARCHITECTURE GAPS

| Component | Status | Recommendation |
|-----------|--------|----------------|

### BREAKING CHANGES

| Boundary | Impact | Migration |
|----------|--------|-----------|

### DECLINED ([N]) — proposed but not filed

- [TITLE] — [which creation-bar test it fails]
</output_format>

Ask: `Approve` | `Adjust` | `Cancel`.

- `Cancel` discards the plan and ends the workflow.
- **`Approve` authorizes the presented creation set** (the ISSUES table, which never contains `Deferred`-project entries) **and the EXISTING WORK AFFECTED actions as presented**:
  - `roadmap create` § 2 executes unchanged actions and as-presented conflict resolutions without re-asking.
  - audit-issues § 6 re-asks only items that changed after it.
- `Adjust` takes free text, updates the in-memory TPM JSON, and re-presents. The JSON update per adjustment:
  - **Remove an issue:**
    1. Set `action: "skip"`.
    2. Recompute dependent priorities.
  - **Change priority / estimate:** update the field.
  - **Change agent:**
    1. Update `agent`.
    2. Recompute the bundle parent's agent label.
    3. Recompute affected `labels[]` through the taxonomy.
  - **Add an issue:** re-run `roadmap plan`.

---

## 6. Save the Plan

Write both files.

- Keep a set `context.research_source_issue`: the research/spec input already sits on that issue.
- When the plan is published to an origin issue and the field is null, the input is uploaded there with the plan: set the field to the origin issue before saving.

The two files:

- `tmp/roadmaps/roadmap-[FEATURE].json` — the TPM JSON with § 5 adjustments applied and `context.plan_path` set to the markdown path.
- `tmp/roadmaps/roadmap-[FEATURE].md` — the § 5 report, plus a `**Plan data**: tmp/roadmaps/roadmap-[FEATURE].json` line and the creation date.

1. Set `CREATE_COMMAND` to `roadmap create @tmp/roadmaps/roadmap-[FEATURE].md`.
2. Apply [publish-artifacts.md](publish-artifacts.md) to both files and the research/spec inputs.
   - With an origin issue:
     1. Reconcile and publish both files there.
     2. Upload a research/spec input only when its `context.research_source_issue` was null. Otherwise link the `url` that [linear patterns/workflow-actions.md § Resolve a cited artifact](../../linear/patterns/workflow-actions.md#resolve-a-cited-artifact) selects for its path on its source issue.
     3. Only after success, append `--source-issue [ORIGIN_ISSUE.id]`.
   - Without one, carry the repository files and command into roadmap-create, whose § 5 publishes them.
3. Return `CREATE_COMMAND` unchanged in the report and to the managed caller.

<output_format>

### PLAN SAVED

**Plan**: tmp/roadmaps/roadmap-[FEATURE].md
**Data**: tmp/roadmaps/roadmap-[FEATURE].json

**Next**: `[CREATE_COMMAND]`
</output_format>

## 7. Return State

- **If managed**: return to the parent workflow's next section.
- **If standalone**: session complete.
