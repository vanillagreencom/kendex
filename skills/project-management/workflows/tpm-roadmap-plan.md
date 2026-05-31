# Roadmap Planning Analysis

Analyze proposed issues for cross-project conflicts, architecture coverage, and organization.

**Do NOT** modify the issue tracker. Return recommendations only.

## Inputs

| Arg | Description |
|-----|-------------|
| `--input [file_path]` | JSON file with proposed issues |

**Input schema**: Defined in `schemas/roadmap-plan-input.md` (this skill).

---

## 1. Load Input and Context

### 1.1 Parse Input

Read input file with Read tool. Extract `FEATURE`, `RESEARCH_PATH`, `ORIGIN_ISSUE` (may be null), `PLANNER_HANDOFF` (may be null), `PROPOSED_ISSUES[]`.

If `PLANNER_HANDOFF` is present, treat it as high-signal technical context from the scout → planner chain, not as a project-management decision. Preserve its plan path, proposed phases/issues, and explicit TPM questions through analysis. Use it to inform project placement, issue grouping, dependency ordering, and roadmap-vs-child-issue recommendations, but still verify against current issue/project state.

### 1.2 Load Issue Label Policy

Load live issue-label inventory and project taxonomy/application rules before organizing issue output:

```bash
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

If label cache is missing/stale, ask the caller/orchestrator to refresh via `sync --reconcile` before mutation. TPM does not mutate labels, but it must output full `labels[]` sets that are valid against the loaded issue-label inventory and project taxonomy where possible. Use issue labels only; project labels are separate.

For each proposed issue:
- Preserve input `labels[]` when present.
- If input has only `agent`, derive the agent label and complete other required labels from project taxonomy and issue context.
- If required category labels cannot be determined, mark the issue as needing taxonomy/user input in `reason` and do not invent labels.
- Reject parent/group labels from output.

### 1.3 Analyze Origin Issue

**Skip if** `origin_issue` is null in input.

1. **Fetch origin issue** details:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues get [ORIGIN_ISSUE_ID]
   .agents/skills/linear/scripts/linear.sh cache issues children [ORIGIN_ISSUE_ID] --recursive --format=safe
   ```

2. **Assess scope relationship**: Do proposed issues decompose the origin issue's scope, or extend beyond it?

   | Research outcome | Recommendation |
   |---------|-------------|
   | All proposed issues decompose origin issue scope | `children_of_origin` — issues become children |
   | New capability beyond origin issue scope | `new_project` — standalone issues in new project |
   | Some in-scope, some new | `mixed` — children of origin + new standalone/project |

3. **Store** `hierarchy_recommendation` with `type`, `origin_issue`, and `rationale`.

### 1.4 Fetch All Projects

1. **Query ALL project states** for cross-project analysis:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache projects list --state started
   .agents/skills/linear/scripts/linear.sh cache projects list --state planned
   .agents/skills/linear/scripts/linear.sh cache projects list --state backlog
   .agents/skills/linear/scripts/linear.sh cache projects list --state completed
   ```

2. **Store** project metadata: `id`, `name`, `state`, `description`, `content`.

### 1.5 Fetch All Issues

1. **Fetch issues** for each project:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --project "[PROJECT_NAME]" --state "Backlog,Todo,In Progress,In Review,Done" --max
   ```

2. **Store** for comparison: `id`, `title`, `description`, `project`, `state`, `agent`, `labels[]`, `blocked_by[]`, `blocks[]`.

### 1.6 Read Research Context

**Skip if** `RESEARCH_PATH` is null.

1. **Read** research file with Read tool.

2. **Extract**:
   - Technical findings
   - Recommendations
   - Constraints identified

---

## 2. Cross-Project Analysis

### 2.1 Detect Duplicates

For each proposed issue, compare against ALL fetched issues:

| Match Type | Evidence | Recommendation |
|------------|----------|----------------|
| Exact duplicate | Same title + same scope | `skip` — reference existing |
| Partial overlap | Similar scope, different approach | `expand` existing OR `descope` new |
| Supersedes | New replaces old entirely | `cancel` existing |

Add to `cross_project_findings.duplicates[]` per schema.

### 2.2 Detect Conflicts

For each `conflicts_with` entry in proposed issues:

1. **Search existing issues/code** for the conflict target

2. **Assess impact**:
   - Would proposed change break existing?
   - Is existing work in progress?
   - Can both coexist with modifications?

Add to `cross_project_findings.conflicts[]` per schema.

### 2.3 Analyze Project Fit

Determine best project placement for the roadmap:

1. **Existing project fit**: Does an existing planned/backlog project match scope?

2. **New project needed**: No existing fit → recommend new project

For new project, determine relations:

```bash
.agents/skills/linear/scripts/linear.sh cache projects list-dependencies [PROJECT_ID]
```

| Check | Relation |
|-------|----------|
| Proposed work consumes existing project output | `blocked-by` |
| Proposed work enables existing project | `blocks` |
| No dependency | No relation |

Store in `project_placement` per schema.

---

## 3. Architecture Coverage Analysis

### 3.1 Identify Relevant Architecture

Based on `FEATURE` and proposed issue agents, read relevant architecture docs for the project.

### 3.2 Extract Components

From architecture docs, extract:
- **Module paths**: Directory structure
- **Components**: Named subsystems
- **Interfaces**: Traits, message types, subscriptions
- **Performance targets**: Latency budgets, throughput requirements

### 3.3 Check Coverage

For each architecture component in scope:

1. **Check** if a proposed issue covers it
2. **Check** if an existing issue covers it
3. **Check** if already implemented

Verify implementation state:
```bash
ls src/[MODULE]/
grep -rn "pub struct\|pub fn\|pub trait\|export class\|export function" src/[MODULE]/
grep -rn "TODO\|unimplemented\|todo\|FIXME" src/[MODULE]/
```

### 3.4 Record Gaps

Add to `architecture_gaps[]` per schema.

| Recommendation | When | Action |
|----------------|------|--------|
| `include` | Blocks proposed work or critical | Add to `organized_issues[]` |
| `defer` | Nice-to-have, not blocking | Add to `organized_issues[]` with `project: "Deferred"` |
| `out_of_scope` | Unrelated to feature | Record in `architecture_gaps[]` only |

---

## 4. Organize Issues

### 4.1 Resolve Internal Dependencies

Build dependency graph from `depends_on_proposed`:

1. **Map title references** to concrete issues

2. **Identify chains**: A → B → C

3. **Detect cycles** (error if found)

### 4.2 Identify Bundles

1. **Group issues** for parent/child structure when 2+ share:
   - Same agent + small estimates (1-2)
   - Same work type (all tests, all config, all docs)
   - Related targets forming single deliverable
   - Would naturally be one PR/CI run

2. **For each bundle**:
   - Create parent title describing the deliverable
   - Mark component issues as children
   - **Compute labels**: If all children have same agent → parent gets that agent label. If 2+ distinct agents → parent gets the project-configured multi-agent label (for example `agent:multi`, if present in taxonomy/inventory). Store as `agent_label` for backward compatibility and include the full parent `labels[]` set. Parent labels must also pass label policy; do not assign parent/group labels.

3. **Lift inter-bundle relations**: Move `blocks`/`blocked_by` between bundled issues up to their respective bundle parents. Children within a bundle retain no external blocking relations — only the parent carries cross-bundle dependencies.

### 4.3 Set Issue Order

Compute architecture order for each issue:

| Layer | Criteria |
|-------|----------|
| L0 | Foundation — no dependencies, enables others |
| L1 | Infrastructure — depends on L0, enables L2+ |
| L2 | Features — depends on L0-L1 |
| L3 | Integration — depends on features |
| L4 | Testing/polish — depends on everything |

Position = `(layer x 100) + (enables_count x -10) + (estimate x 1)`

Lower position = earlier in order.

### 4.4 Mark Critical Path

Issues that block 2+ other issues → `critical_path: true`

### 4.5 Compute Priorities

Assign priority (1-4) to each issue based on layer and impact:

| Condition | Priority |
|-----------|----------|
| L0 + `critical_path` | P1 |
| L0/L1 + enables 2+ issues | P1 |
| L1/L2 | P2 |
| L3 | P3 |
| L4 | P4 |

**Propagation**: If an issue blocks a P1 issue, it becomes P1. Apply transitively until stable.

### 4.6 Build Organized List

Store in `organized_issues[]` per schema. Sort by `position`. Include `priority`, full `labels[]`, and `agent_label` (for bundle parents/backward compatibility) per schema.

---

## 5. Validate

### 5.1 Obsolete Detection

For each organized issue, search fetched issues for Done-state issues covering same scope:

1. **Match criteria**: Title similarity + description scope overlap with Done issues
2. **Verify against code** when match found (check if implementation exists)
3. **Mark obsolete** only at >= 90% confidence with evidence

Store per issue: `obsolete: {evidence: {completed_by: [], files_verified: []}, confidence: N}` or `null`.

### 5.2 Action Assignment

| Condition | Action |
|-----------|--------|
| Obsolete (5.1) | `cancel` |
| Exact duplicate (2.1) | `skip` |
| Partial overlap, recommendation=expand | `expand` |
| Supersedes existing | `supersede` |
| All others | `create` |

Store per issue: `action`, `target` (existing issue ID for expand/supersede, null otherwise), `reason`.

---

## 6. Return Output

1. **Build JSON** per [roadmap-plan-output.md](../schemas/roadmap-plan-output.md), filename `tmp/roadmap-plan-YYYYMMDD-HHMMSS.json`.

2. **Return the JSON** in your response (the calling agent writes the file):

   <output_format>
   File: tmp/roadmap-plan-YYYYMMDD-HHMMSS.json
   ```json
   {complete JSON object}
   ```
   </output_format>

---

**END**: Analysis complete.
