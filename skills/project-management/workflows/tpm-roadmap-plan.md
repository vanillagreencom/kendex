# Roadmap Planning Analysis

Analyze proposed issues for cross-project conflicts, architecture coverage, and organization.

**Do NOT modify the tracker.** Return recommendations only.

**Hold the creation bar** ([filing.md](../references/filing.md) § Creation bar).

- A proposed issue survives only when it changes what a user or operator experiences (or blocks work that does), nothing open already covers it, and it is finishable as written.
- Everything else gets `action: "skip"` with a one-line reason.

## Input

`--input [file_path]` per [roadmap-plan-input.md](../schemas/roadmap-plan-input.md). Extract `FEATURE`, `RESEARCH_PATH`, `RESEARCH_READ_PATH`, `RESEARCH_SOURCE_ISSUE`, `SPEC_PATH`, `ORIGIN_ISSUE`, `PLANNER_HANDOFF`, `REMOVED_TERMS[]`, `TEAMS[]`, `PROPOSED_ISSUES[]`.

**Spec mode** (`SPEC_PATH` set): the plan's decisions are binding.

- Organize, dedupe, order, and bundle its work and check it against the tracker.
- Never change its approach, drop a workstream it names, or add scope beyond its phases.
- An architecture gap is `include` only when the spec's own deliverables need it.
- Anything outside the spec's phases is `out_of_scope`, never `defer`, with the spec named in `reason`.
- Disagreement with the spec is a `declined`/`reason` note for the caller, never a silent reorganization.

A `PLANNER_HANDOFF` is technical context, not a project-management decision.

- Preserve its plan path, proposed phases, and explicit TPM questions.
- Let it inform placement, grouping, dependency order, and the roadmap-vs-child-issue call.
- Verify every claim against current issue and project state.

---

## 1. Load Context

### 1.1 Team Scope

1. Resolve `TEAM` and `TEAM_PREFIX` per [tpm-audit](tpm-audit.md) § 1.1.1 before any Linear read. That one team is the scope of § 1.4 placement and the § 2 comparison, and roadmap-create files into it.
2. Pass `--team` on every comparison `issues list` to filter on the server.
3. Drop out-of-scope rows from the § 1.4 project list and the § 1.5 comparison set before comparison.
4. The removal scope starts as `TEAM`. When `REMOVED_TERMS[]` is nonempty, resolve each `TEAMS` entry with `.agents/skills/linear/scripts/linear.sh teams get [ENTRY]` first, and halt when one resolves none. Add its `name` and `key` only when that `key` differs from `TEAM_PREFIX` and from every key already in the removal scope. Only § 2.1 reads an added team's rows.

- § 2 proposes changes only to active rows. Closed rows remain historical comparison evidence per tpm-audit § 1.1.
- roadmap-create executes the recommendations.

### 1.2 Label Policy

```bash
.agents/skills/linear/scripts/linear.sh labels list --max --format=safe
```

- Load the project taxonomy and `PM_LABEL_RULES` alongside it ([labels.md § Preflight](../references/labels.md#preflight)).
- A failed Linear read on this or any later step halts the analysis with its diagnostic ([SKILL.md](../SKILL.md) § Execution Rules). Never work around it with a partial read.
- Every issue emitted must carry a `labels[]` set valid against that inventory.
- Select each issue's set by [labels.md § Creates Carry the Full Set](../references/labels.md#creates-carry-the-full-set), deriving the agent label when only `agent` was supplied.
- When a required category cannot be determined, flag the gap in `reason` rather than inventing a label.
- Never emit a parent/group label.

### 1.3 Origin Issue

**Skip if** `origin_issue` is null.

```bash
.agents/skills/linear/scripts/linear.sh issues get [ORIGIN_ISSUE_ID]
```

`issues get` returns three levels; walk a deeper tree per [dependencies.md](../references/dependencies.md) § Reading a Full Subtree.

Decide whether the proposed issues decompose the origin issue's scope (`children_of_origin`), reach beyond it (`new_project`), or split (`mixed`), and store `hierarchy_recommendation` with `type`, `origin_issue`, and `rationale`.

### 1.4 Projects

- Fetch every project in ONE command.
- `projects list --state` matches one state type exactly and never a comma list, so omit it and read each row's own `state`.
- Ignore `canceled` rows and every row § 1.1 scopes out.

```bash
.agents/skills/linear/scripts/linear.sh projects list --max
```

Store `id`, `name`, `state`, `description`, `content` per project.

### 1.5 Issues

Fetch each removal-scope team's active rows in one command; never loop `--project` per project:

```bash
.agents/skills/linear/scripts/linear.sh issues list --team "[TEAM]" --all-projects --state "Triage,Backlog,Todo,In Progress,In Review,Verifying" --max
```

Store `id`, `title`, `description`, `project`, `state`, `agent`, `labels[]`, `blocked_by[]`, `blocks[]` for each row whose `id` starts with its team's key and `-`. `TEAM`'s rows are the active comparison set.

For each proposed issue, read closed comparison evidence with its title, target, or component terms:

```bash
.agents/skills/linear/scripts/linear.sh issues list --team "[TEAM]" --all-projects --state "Done,Canceled" --search "[TERMS]"
```

Use the comparison and truncation rules in [tpm-audit](tpm-audit.md) § 1.5: no `--max` on closed searches, no whole-history read, and no disposition on closed rows.

- Retain closed results and any truncation notice per proposed issue.
- A truncated search limits that issue's findings to returned evidence and never proves no match.
- Verifying rows retain their live checks on the merged item (tpm-audit § 1.1).

Before § 2:

1. Select candidate duplicate, relation, and supersession rows from the fetched bodies.
2. Select active cancellation candidates, and the active rows whose bodies name a `REMOVED_TERMS[]` term.
3. Read comments once per tpm-audit § 1.4.1: one `comments bulk-list` for the existing input issues from § 1.3 and the candidate rows, including closed candidates and every active row proposed for cancellation.
   - When that set is empty, because § 1.3 was skipped and no row is a candidate, make no call, per the same section.
   - Do not read every comparison row's comments.
4. Use the comments to verify recommendations before assigning an action.

### 1.6 Research

**Skip if** `RESEARCH_PATH` is null.

1. Read `RESEARCH_READ_PATH` and extract the technical findings, recommendations, and constraints.
2. In spec mode, also extract its phases and per-phase deliverables, which bound § 3 and § 4.
3. Keep `RESEARCH_PATH` and `RESEARCH_SOURCE_ISSUE` for output under [planning-artifacts.md](../references/planning-artifacts.md).

---

## 2. Cross-Project Analysis

Compare each proposed issue against the active comparison set and its own closed search results.

- Same title and scope is an exact duplicate: `skip`, and reference the existing one.
- Overlapping scope with a different approach means `expand` an active existing issue or descope the proposal.
- A proposal that entirely replaces an active existing issue means `cancel` the old one.
- Done and Canceled rows are evidence only: never expand, cancel, or supersede them.
- Record in `cross_project_findings.duplicates[]`, and state any limit from that proposal's closed search.

For each `conflicts_with` entry:

1. Search existing issues and code for the target.
2. Assess whether the proposal breaks existing work, collides with work in progress, or can coexist with modification.
3. Record in `cross_project_findings.conflicts[]`.

Then place the roadmap:

- Use an existing planned or backlog project when its scope matches. Otherwise recommend a new one.
- For a new project, set relations from dependency direction: consuming another project's output is `blocked-by`, enabling one is `blocks`, no dependency means no relation:

```bash
.agents/skills/linear/scripts/linear.sh projects list-dependencies [PROJECT_ID]
```

- Store in `project_placement`.
- Retain each proposal's comparison result and actual title, target and component terms for its `organized_issues[].supersession` record, as [roadmap-plan-output.md](../schemas/roadmap-plan-output.md) § organized_issues defines.
- Use the rows and searches already read in § 1.5.
- Write no tracker disposition here.

### 2.1 Removal Review

**Skip if** `REMOVED_TERMS[]` is null or empty.

Review every active row of every removal-scope team from § 1.5 against `REMOVED_TERMS[]`. A row rests on a term when its title, its description or the comments § 1.5 read name the term, or its work needs the removed thing to exist. Give each row one action:

- `cancel`: its whole need rests on a removed term, or the term's replacement covers it.
- `rewrite`: its need stands, but its text or approach rests on a removed or replaced term. The reason names the `replaced_by` it is rewritten against.
- `keep`: it rests on no removed term. The reason says why.

Where a § 2 `cross_project_findings` action already names the row, its action here follows that action, and its reason names that finding:

- A cancel or supersede gives `cancel`.
- An expand gives `rewrite`.
- A skip or descope leaves the row to the term test above.

Where the term test gives a skip or descope finding's row `cancel`, turn that finding into a supersede before § 4:

1. Set its `match_type` to `supersedes` and its `recommendation` to `cancel`, and add the removed term to its `reason`.
2. Keep the proposal at its full scope. § 5 gives it `supersede` with that row as `target`.
3. The row then takes `cancel` by the first rule above, as that supersede.

Store each team's rows in `removal_review[]` per [roadmap-plan-output.md](../schemas/roadmap-plan-output.md) § removal_review. Its `checked` count is that team's § 1.5 active row count. Write no tracker disposition here.

---

## 3. Architecture Coverage

1. Read the architecture docs relevant to `FEATURE` and the proposed agents.
2. Extract module paths, named components, interfaces, and performance targets.
3. For each in-scope component, check whether a proposed issue covers it, an existing issue covers it, or it is already implemented:

```bash
ls "[MODULE_PATH]"
rg -n "pub struct|pub fn|pub trait|export class|export function" "[MODULE_PATH]"
rg -n "TODO|unimplemented|todo|FIXME" "[MODULE_PATH]"
```

Record uncovered components in `architecture_gaps[]`:

- `include` when the gap blocks proposed work or the feature needs it. Add it to `organized_issues[]`.
- `defer` when it is nice-to-have. Add it with `project: "Deferred"`.
- `out_of_scope` when unrelated to the feature. Record the gap only.
- A gap that clears none of the creation-bar tests is `out_of_scope`, not a deferred issue.

---

## 4. Organize

1. **Dependencies.**
   - Map `depends_on_proposed` title references to concrete issues.
   - Identify chains.
   - Error on a cycle.

2. **Bundles.**
   - Related items share the roadmap's project, or one label where no project says what they share, under the grouping rule of [filing.md § Group by project or label, never by parent](../references/filing.md#group-by-project-or-label-never-by-parent).
   - Give a bundle a parent only when its items are the parts of one deliverable accepted as one thing, titled for that deliverable and built from [parent-issue-template.md](../templates/parent-issue-template.md).
   - Work that would naturally be one PR/CI run is one leaf item with an internal checklist, not a parent.
   - The parent takes the shared agent label, or the project's multi-agent label when children span 2+ agents, plus a full `labels[]` set that passes the label policy.

3. **Relation level.**
   - Keep each valid relation under linear references/writes.md § Blocked Label vs Issue Relations.
   - Repair only a relation that rule refuses; see [dependencies.md](../references/dependencies.md).

4. **Order.**
   - Assign a layer (L0 foundation → L1 infrastructure → L2 features → L3 integration → L4 testing and polish).
   - Compute `position = (layer x 100) + (enables_count x -10) + (estimate x 1)`. Lower is earlier.

5. **Priority.**
   - L0 on the critical path, or L0/L1 enabling 2+ issues → P1; L1/L2 → P2; L3 → P3; L4 → P4.
   - An issue blocking a P1 becomes P1. Apply transitively until stable.
   - `critical_path: true` when an issue blocks 2+ others.

Store in `organized_issues[]` sorted by `position`, each with `priority`, full `labels[]`, and `agent_label` for bundle parents. Include the comparison record on generated bundle parents and architecture-gap entries too:

1. Compare their scope and actual title/component terms against the same already-read rows before finalizing their action.
2. Make no new search or inventory read.

---

## 5. Validate

For each organized issue:

1. Use its § 1.5 closed search results to find Done-state work covering the same scope.
2. Match on title similarity plus description overlap.
3. Verify against the code that the implementation exists.
4. Mark the proposal `obsolete` only at ≥90% confidence with evidence `{completed_by[], files_verified[]}`.
5. Keep each finding within that issue's returned evidence and record any truncation.

The completed issue takes no disposition.

Assign the action:

- Obsolete → `cancel`.
- Exact duplicate → `skip`.
- Partial overlap recommending expansion → `expand`.
- Replaces an existing issue, a supersede § 2.1 turned from a skip or descope included → `supersede`.
- Fails the creation bar → `skip` with the failing test named.
- Otherwise `create`.

Store `action`, `target` (the existing issue for `expand`/`supersede` or an exact-duplicate `skip`, else null), `reason`, and the matching `supersession` record per [roadmap-plan-output.md](../schemas/roadmap-plan-output.md) § organized_issues. The returned JSON retains this record on every entry so a later session needs no inferred search provenance.

---

## 6. Return Output

1. Build the JSON per [roadmap-plan-output.md](../schemas/roadmap-plan-output.md).
2. Return it inline. Do not write the file.

<output_format>
File: tmp/roadmap-plan-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>
