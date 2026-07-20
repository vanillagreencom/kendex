# Audit Workflow

Analyze issues for proper configuration: relations, agent labels, hierarchy, project placement, duplicates, obsolete items, and combinations.

**Additional for PROJECT mode**: Project scope validation, inter-project dependencies, architecture gap analysis, project recommendations.

**Do NOT** modify the issue tracker. Return recommendations only.

## Inputs

| Arg | Mode | Input Set |
|-----|------|-----------|
| `--project <name>` | PROJECT | All issues in named project |
| `--project` (no name) | PROJECT | All issues in active project |
| `--issues <file_path>` | ISSUES | Proposed issues from JSON file |

**ISSUE mode file schema**: Defined in `schemas/audit-issues-input.md` (this skill).

File contains all context — read with Read tool. Optional fields for research-complete: `blocked_issues`, `research_ref`, `decision_ref`, `hierarchy_contract` (binding — § 7.0).

---

## 1. Initialize Mode & Fetch Context

### 1.1 Determine Mode

Parse arguments → set `MODE` (project | issues).

**PROJECT mode**: Store `WORKTREE` from delegation prompt (default: `.`). PROJECT mode audits Linear projects and is Linear-only (`TRACKER=linear`).

**ISSUES mode**: Read JSON file with Read tool, extract:
- `TRACKER` (and `REPOSITORY` for github) from the delegation prompt `Tracker:` line or the file's `tracker` field; when absent, infer: `parent_issue` starting with `issue-` → `github`, otherwise `linear`
- `WORKTREE` from `worktree` field
- `PARENT_ISSUE` from `parent_issue` field
- `SOURCE` from `source` field
- `INPUT_ITEMS` from `items[]` array
- `BLOCKED_ISSUES` from `blocked_issues` field (optional, research-complete only)
- `RESEARCH_ISSUE` from `research_issue` field (optional, research-complete only)
- `RESEARCH_REF` from `research_ref` field (optional, research-complete only)
- `DECISION_REF` from `decision_ref` field (optional, research-complete only)
- `HIERARCHY_CONTRACT` from `hierarchy_contract` field (optional, research-complete only — a binding directive, not a hint; enforced in § 7.0 and § 10.2)

### 1.2 Load Issue Label Policy

Load live issue-label inventory and project taxonomy/application rules before validating agent/domain/workflow labels or recommending label changes.

**Linear (TRACKER=linear)**:
```bash
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

If the label cache is missing/stale, report that the caller must run `sync --reconcile` before mutation.

**GitHub (TRACKER=github)** — live repository labels; no cache or sync involved:
```bash
gh label list --repo [REPOSITORY] --limit 200 --json name,description
```

TPM does not mutate labels, but all `agent_mismatch`, `label_cooccurrence`, `recommended_issue.labels[]`, and `create_fields.labels[]` recommendations must be expressible against the tracker's live issue labels and project taxonomy. Use issue labels only; project labels are separate.

### 1.3 Fetch All Projects

**Linear (TRACKER=linear)** — query ALL project states:
```bash
.agents/skills/linear/scripts/linear.sh cache projects list --state started
.agents/skills/linear/scripts/linear.sh cache projects list --state planned
.agents/skills/linear/scripts/linear.sh cache projects list --state backlog
.agents/skills/linear/scripts/linear.sh cache projects list --state completed
.agents/skills/linear/scripts/linear.sh cache projects list --state paused
```

Store project IDs and metadata for cross-project analysis.

**GitHub (TRACKER=github)** — explicit degradation: no project inventory exists in this workflow. Record an empty project set. Project-placement fields (`recommended_project`, `wrong_project`, project moves) must be `null`/omitted with reason "github: no project inventory" — never invent a placement. Duplicate/fit checks scope to the repository backlog from § 1.5 instead.

### 1.4 Fetch Input Issues

**PROJECT**: Fetch all issues in target project (all states):
```bash
.agents/skills/linear/scripts/linear.sh cache issues list --project "[PROJECT]" --state "Backlog,Todo,In Progress,In Review,Done" --max
```

**ISSUES**: For existing issues, fetch each.

Linear:
```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
```
Use the returned issue JSON for relation analysis. The supported cache payload includes `blocks`, `blocked_by`, and `related`; do not call a separate relation cache subcommand.

GitHub:
```bash
gh issue view [N] --repo [REPOSITORY] --json number,title,body,labels,state,url
```
There is no relation payload — relation analysis uses body-link references (`Blocks: #N`, `Blocked by: #N`, `Related: #N`, `Parent: #N`).

For proposed issues, use provided fields directly.

### 1.5 Fetch Comparison Set

**Linear (TRACKER=linear)** — fetch issues from ALL projects for duplicate/obsolete/fit checking in ONE command:
```bash
.agents/skills/linear/scripts/linear.sh cache issues list --all-projects --state "Backlog,Todo,In Progress,In Review,Done" --max
```

Each row carries its `project` name. Never loop `--project` over the projects from 1.3 — restricted harness approval policies reject loop-shaped commands, and the single `--all-projects` call returns the same rows. Store all issues for comparison in 6.

**Why all projects**: Cross-project duplicate detection, obsolete checking against completed work, and project fit evaluation all require visibility into the full backlog.

**GitHub (TRACKER=github)** — fetch the repository backlog, open and closed, for the same duplicate/obsolete checks:
```bash
gh issue list --repo [REPOSITORY] --state all --limit 200 --json number,title,state,labels
```

### 1.6 Extract Project Definitions

**GitHub (TRACKER=github)**: skip — there are no project definitions; treat the repository as the single scope for fit evaluation.

For EACH project from 1.3, extract from name + description + content:

| Field | Question |
|-------|----------|
| **Purpose** | What is this project for? (implementation, testing, refactoring, validation) |
| **Work Type** | What kind of issues belong here? |
| **Scope** | What components/modules does this project own? |

**[PROJECT only]** For the target project, note constants/APIs it modifies and
verify them after resolving the owning issue's scope in § 2.1 (or the separate
project scope in § 9.2). Search only the resolved paths, starting with the most
specific target path:
```bash
rg -n "[CONSTANT_NAME]|[API_NAME]" "[WORKTREE]/[TARGET_PATH]"
```

### 1.7 Collect Verification Evidence

For EACH input issue, independently record any linked PR and its changed files,
known implementation branch/base ref, concrete paths, and documentation-only
signals. Key this evidence by the issue identifier; for a proposed item, use its
stable input index.

A linked PR or branch belongs only to the issue that identifies it (or is
explicitly documented as implementing it). Do not infer that association from
another input issue. Do not establish one global `VERIFICATION_CONTEXT`; scope
resolution happens per extracted contract in § 2.1.

---

**Done/Cancelled issue rule**: Done and Cancelled issues are historical records. Never modify their labels, agent assignments, priorities, or state. They may appear in relation analysis (as sources/targets of valid historical links) and cross-project comparison (to detect duplicates of completed work), but all fix recommendations must exclude them. Only active issues (Backlog, Todo, In Progress, In Review) are candidates for changes.

---

## 2. Extract Contracts

For each INPUT issue, extract from title + description:

| Field | Extract |
|-------|---------|
| **Target** | Component/file being modified |
| **Creates** | New APIs, seams, types, tests this introduces |
| **Consumes** | Existing APIs, seams, types this uses or extends |
| **Problem** | What bug/gap/feature it addresses |
| **Decisions** | Use decider skill: `.agents/skills/decider/scripts/decisions search "[TARGET_KEYWORDS]"` for decisions governing the target area. Flag if proposed approach contradicts an active decision |

**Build** contract table: `ID | Target | Creates | Consumes | Problem | Decision Conflict`

### 2.1 Resolve Verification Scope Per Contract

For EACH contract row, set `ISSUE_KEY` to its issue identifier or proposed-item
index and resolve one repository-aware context. A repository-root `src/` is
never assumed.

Choose the narrowest trustworthy input for that issue only, in this order:

1. **PR changed files** when this issue directly links to the PR or the PR is
   explicitly documented as implementing this issue. Read that PR's file list,
   then pass each repository-relative path as `--changed-file`.
2. **Branch diff** when the branch is known to implement this issue and its base
   ref is known.
3. **Concrete issue paths** from this contract's target/location fields when
   they cover its complete implementation scope.
4. **Repository discovery** as this issue's fallback when no reliable change
   set exists. The resolver discovers every tracked source root; this supports
   monorepos and multi-crate workspaces such as `crate-a/src` and `crate-b/src`.
5. **Documentation-only scope** when this issue's deliverables and changed paths
   are all documentation. Use `--docs-only` when no concrete change set exists.

Changed-file example (repeat `--changed-file` as needed):
```bash
.agents/skills/project-management/scripts/verification-scope --worktree "[WORKTREE]" --changed-file "[PATH_1]" --changed-file "[PATH_2]"
```

Branch-diff example:
```bash
.agents/skills/project-management/scripts/verification-scope --worktree "[WORKTREE]" --base-ref "[BASE_REF]"
```

Repository-discovery example:
```bash
.agents/skills/project-management/scripts/verification-scope --worktree "[WORKTREE]"
```

Documentation-only example:
```bash
.agents/skills/project-management/scripts/verification-scope --worktree "[WORKTREE]" --docs-only --changed-file "[DOC_PATH]"
```

Store each result independently as `VERIFICATION_CONTEXTS[ISSUE_KEY]`. Never
reuse another issue's linked PR, branch diff, or resolved context. During later
checks, `ISSUE_VERIFICATION_CONTEXT` means only the map entry for the issue
currently being checked. Extract:

- `mode`: `changed`, `repository`, or `docs-only`
- `changed_files[]`: the explicit or diff-derived paths
- `source_roots[]`: affected or repository-discovered source roots
- `verification_paths[]`: exact paths later searches for this issue must use
- `code_verification_required`: whether code-path checks apply

All returned paths are repository-relative. Resolve them against the returned
absolute `worktree` before `rg`, `ls`, or file reads.

Rules:

- In `changed` mode, search this issue's exact changed/contract target first.
  Expand only when its creates-consumes contract or an architecture reference
  proves a second path is relevant.
- In `repository` mode, search the returned tracked source roots. Never replace
  them with `[WORKTREE]/src`.
- In `docs-only` mode, skip code-path checks. Read the resolved documentation
  paths and verify documentation deliverables directly; do not treat the lack
  of code evidence as a mismatch or obsolete-work signal.
- If code verification is required but `verification_paths[]` is empty, halt
  with a clear scope-resolution error. Do not continue with a guessed path.
- For a creates-consumes pair, load both issues' contexts independently. An
  explicitly shared seam may be inspected for both contracts, but neither
  issue's context replaces the other's.

---

## 3. Validate Project Scope

**Skip if** MODE = issue.

### 3.1 Validate Issue Fit

For each issue, verify it matches the target project definition from 1.6.

| Mismatch | Example | Action |
|----------|---------|--------|
| Wrong work type | "Add tests" in implementation project | Add to `wrong_project[]` |
| Wrong scope | New feature in "Tech Debt" project | Add to `wrong_project[]` |
| Name vs content | Project says "refactoring" but issue is new feature | Add to `wrong_project[]` |

### 3.2 Analyze Project Dependencies

Trace what depends on this project's modifications:

1. **List what this project modifies** (constants, APIs, patterns)

2. **Find dependents**: Which projects build on or test those modifications?

3. **Validate blocking**: If Project A modifies code that Project B uses → A should block B

Add to `project_dependency_issues[]`:
```json
{
  "from_project": "string",
  "to_project": "string",
  "current_relation": "none|blocks|blocked_by",
  "should_be": "blocks|blocked_by|none",
  "reason": "A modifies [X] which B depends on"
}
```

---

## 4. Identify Candidate Pairs

**Do not compare every pair.** Build candidate pairs from signals:

| Signal | Why |
|--------|-----|
| Same target component | Likely related |
| Same parent issue | Sibling order dependency |
| Issue mentions another issue ID | Explicit connection |
| Creates-Consumes overlap | Potential dependency |
| Existing issue tracker relation | Must verify correctness |

### 4.1 Group by Target and Parent

Group input issues by target component and by parent. Same-group issues are candidates for relation analysis.

### 4.2 Scan Cross-Target Dependencies

Scan for Creates-Consumes matches across different targets:
- Issue A (target X) creates `FooService`
- Issue B (target Y) consumes `FooService`
- → Candidate pair despite different targets

### 4.3 Include Comparison Set Matches

Compare input issues against comparison set (1.5) for:
- Same target component
- Same file path in location field — issues modifying the same file are always candidates
- Creates-Consumes overlap
- Same problem description

**File-path overlap**: When two issues share a file path, grep for shared structs/functions to detect implicit dependencies that aren't visible from title/description alone.

### 4.4 Verify Existing Relations

For input issues with existing relations, add to candidate pairs for verification.

**Done issue relations are valid historical records.** Flag removal only for wrong dependencies (no creates-consumes), never because source is Done.

**Completed-blocker relations are auto-satisfied, never stale.** A `blocked_by` relation whose blocker is Done/Cancelled is satisfied history — the tracker already treats the issue as unblocked, and the relation stays for provenance/traceability. Do NOT add such relations to `remove_relations[]`, and do NOT report them under any stale-metadata heading (a prior audit emitted a "STALE blocked_by METADATA" section listing issues whose blockers were Done — that framing is wrong and invites destructive cleanup). The only legitimate finding for an active issue whose blockers have all completed is a scheduling signal: add it to `ready_to_schedule[]` (PROJECT mode) or note "gates cleared, ready to schedule" in the issue's `reason` (ISSUE mode).

### 4.5 Scan for Relation Violations

**Iterate** ALL `blocks`/`blocked_by` relations on input issues (and their children if bundled).

**Violation types**:

| Violation | Detection |
|-----------|-----------|
| Cross-project blocking | A.project != B.project |
| Cross-bundle child blocking | A.parent != B.parent (both have parents) |
| Child blocks standalone | A has parent, B has no parent (or vice versa) |

**Remediation principle**: Blocking relations are valuable — always preserve them by relocating issues to the same project. Never remove a valid blocking relation.

**Decision tree**:

1. **Cross-project blocking**:
   - If issue-level blocking aligns with project ordering (3.2) → skip (redundant specificity)
   - Otherwise → move one issue to the other's project
   - **Check** 1.6 scope definitions to determine which issue to move
   - If issue is a child, it must move with its parent (or be detached first)
   - **Add** to `wrong_project[]` with target project and reason referencing the blocking relation
   - **Do NOT create project-level dependencies from individual issue relations** — project deps come from project-order audit scope analysis, not bottom-up from 1-2 issue crossings

2. **Cross-bundle child blocking** (same project): Lift to parent level.
   - **Add** child relation to `remove_relations[]`
   - **Add** parent-level relation to `add_relations[]`
   - **Add** `related` between original children for traceability

3. **Cross-bundle child blocking** (different projects): Relocate first (step 1), then lift to parent level (step 2).

For each violation, record: `remove_relations[]` reason: `"Violation: [TYPE] — [FROM] [REL] [TO]"`

---

## 5. Analyze Candidate Pairs

For each candidate pair (A, B):

### 5.1 Check Dependencies

**Three sources of blocking relations** (check all, merge results):

1. **Creates-Consumes**: Does B consume what A creates? Standard dependency analysis.

2. **Caller hints**: If input items have `blocks_items`/`blocked_by_items`/`blocks_issues`/`blocked_by_issues` fields, validate them against contracts. Carry forward valid hints; drop contradictions.

3. **Agent-sequencing**: Apply cross-domain blocking rules to same-project sibling issues with different agent domains.

**Same-project constraint**: `blocks`/`blocked_by` relations must be within the same project. See [dependencies.md](../references/dependencies.md).

| Dependency Found | Same Project? | Recommendation |
|------------------|---------------|----------------|
| A creates → B consumes | Yes | `blocks` relation |
| A creates → B consumes | No | `related` only |
| Agent-sequencing candidate + data flow confirmed | Yes | `blocks` relation |
| Agent-sequencing candidate, no data flow | Either | No relation |
| No dependency | Either | `related` only if informational link useful |

**Default to `blocks` when dependency exists AND same project.**

**Blocking level rule**: Blocking relations go on bundle parents, not children. A child issue must not block an issue under a different parent. If A is bundled under parent P1 and B is under parent P2 (or standalone), then P1 blocks P2 — never A blocks B.

### 5.2 Verify Against Repository State

For each issue in the pair, load only its
`ISSUE_VERIFICATION_CONTEXT = VERIFICATION_CONTEXTS[ISSUE_KEY]`.

**Skip that issue's code-path checks if**
`ISSUE_VERIFICATION_CONTEXT.mode == "docs-only"`. Verify its documentation
contract against its resolved documentation paths instead.

Otherwise, verify contracts against actual code when target files exist. Use
the most specific contract target first:
```bash
rg -n "consumedThing" "[WORKTREE]/[TARGET_PATH]"
```

If the contract names no concrete target, search the resolved paths explicitly:
```bash
rg -n "consumedThing" "[WORKTREE]/[VERIFICATION_PATH_1]" "[WORKTREE]/[VERIFICATION_PATH_2]"
```

- Contract matches code → confidence high
- Contract doesn't match → update understanding, re-evaluate relation

**Record**: `Pair | Current Relation | Should Be | Reason`

### 5.3 Check Priority Alignment

**Skip** Done/Cancelled issues — their priorities are historical.

For each blocking relationship (A blocks B) where both are active:
- If A.priority > B.priority (lower urgency number = higher priority) → misaligned
- If A has `critical-path` label and priority != 1 (Urgent) → misaligned

**For proposed issues**: Skip if no priority assigned yet.

**Add** to `priority_misalignment[]`:
```json
{"id": "[ISSUE_ID]", "current": 3, "should_be": 1, "reason": "Blocks critical path issue [OTHER_ISSUE_ID]"}
```

### 5.4 Verify Agent Labels

**Skip** Done/Cancelled issues — their labels are historical.

**Check** each active issue's taxonomy `agent` category label against its content. Validate recommended replacement labels against § 1.2 inventory/taxonomy before adding `agent_mismatch[]`; if the desired `agent:*` label does not exist or is a parent/group label, report the validation failure in `reason` and do not recommend a mutating fix without user/taxonomy action.

**Code verification** (when target exists):
```bash
# Check if target is in specific directory
ls "[WORKTREE]/[TARGET_PATH]"

# Check for public function signatures
rg -n "pub fn|export function|def " "[WORKTREE]/[TARGET_PATH]"
```

Load the current issue's `ISSUE_VERIFICATION_CONTEXT`. If its mode is
`docs-only`, infer ownership from that issue's contract, project definition,
and documented paths; do not manufacture a code path merely to validate an
agent label.

**Add** to `agent_mismatch[]`:
```json
{"id": "[ISSUE_ID]", "current": "frontend", "should_be": "backend", "reason": "Target is backend module", "signals": ["module in src/backend", "pub fn signature"]}
```

### 5.5 Verify Label Co-occurrence

**Skip** Done/Cancelled issues — their labels are historical.

**Step 1 — Heuristic**: For each active issue, if it lacks a required taxonomy label/category, check title/description against detection signals. If 2+ signals match → add finding with `present: "[signals]"`.

Only recommend `missing` labels that exist in live issue-label inventory and are assignable issue labels. If taxonomy requires a label that is absent from Linear, record that the label is missing from inventory and requires explicit user authorization to create; do not silently substitute another label.

**Add** to `label_cooccurrence[]`:
```json
{"id": "[ISSUE_ID]", "title": "...", "present": "[signals]", "missing": "design", "reason": "Design signals detected but design label missing"}
```

---

## 6. Cross-Project Analysis

### 6.1 Check for Duplicates

**Compare** input issues against ALL issues from comparison set (1.5):

**Same-project duplicates**:
- Same problem + same approach = duplicate → add to `duplicates[]`

**Cross-project duplicates**:
- Same problem + same approach in different project = duplicate → add to `duplicates[]` with consolidation recommendation
- Same problem + different approach = keep both, add `related`

**Module-name fallback**: When title/keyword matching finds no duplicates for a proposed issue, extract the module or component name from its location field and search existing issues for that module name in title or description. Different terminology for the same component won't match on keywords but will match on shared module name.

**Supersession detection**: When input item's scope FULLY COVERS an existing issue's scope, add to input item's `supersedes[]` (not `duplicates[]`).

Signals:
- Input item's `decision_ref` supersedes existing issue's governing decision
- Input item's `creates[]` is superset of existing issue's deliverables
- Existing issue references a superseded decision

### 6.2 Check for Obsolete

Detect issues that should be canceled because work is complete.

**Deep verification (REQUIRED)** — Do NOT add to `obsolete[]` without code verification:

1. **Extract deliverables** from issue description

2. **Verify EACH deliverable** in its resolved target path. For code-bearing
   audits, search the specific implementation path first:
   ```bash
   rg -n "pub fn [FUNCTION]|pub struct [TYPE]|export class [TYPE]|export function [FUNCTION]" "[WORKTREE]/[TARGET_PATH]"
   ```

   If no concrete target exists, search the current issue's explicit
   `ISSUE_VERIFICATION_CONTEXT.verification_paths[]`. For `docs-only`, read
   that issue's documentation paths and verify every documentation deliverable
   instead of running code-symbol searches. For a comparison-set issue not yet
   in `VERIFICATION_CONTEXTS`, first extract its contract and resolve a new map
   entry under that issue's identifier; never borrow an input issue's entry.

3. **Read resolved deliverable files** — check implementation files for stubs
   versus complete code, or documentation files for the promised content

4. **Calculate confidence**:

| Evidence | Confidence |
|----------|------------|
| All deliverables implemented + tests | 100% |
| All deliverables implemented, no tests | 90% |
| Most deliverables, some stubs | 50% — Do NOT add |
| Partial implementation | 0% — Keep issue |

**>=90% confidence required** to add to `obsolete[]`.

**Decision-eliminated issues**: When `DECISION_REF` is present, also detect issues made unnecessary by the decision changing approach (not scope). Use decider skill's `.agents/skills/decider/scripts/decisions get [DECISION_REF]` to locate the file.

1. **Read decision** document (path from decider CLI output)
2. **Extract eliminated patterns**: From Context/Decision, identify approaches explicitly replaced
3. **Search comparison set** for issues implementing eliminated patterns — match title, description, deliverables referencing old pattern
4. **Exclude** issues already in `supersedes[]` (replaced by new issues, not eliminated)
5. **Add** to `obsolete[]`: confidence 100%, evidence `{decision_eliminated: true, decision_ref: "[REF]", eliminated_pattern: "..."}`, reason `"[REF] eliminates: [OLD] → [NEW]"`

### 6.3 Check Project Fit

For each input issue, compare against ALL project definitions from 1.6:

| Check | Action |
|-------|--------|
| Issue scope matches different project better | Add to `wrong_project[]` with target project |
| Issue is child but in different project than parent | Add to `wrong_project[]` — detach from parent, move or re-parent |
| Issue depends on work tracked in different project | Add cross-project `related` to `add_relations[]` |
| Issue duplicates work in different project | Add to `duplicates[]` |

**Evaluate objectively** — do not assume current project assignment is correct.

---

## 7. Hierarchy Analysis

### 7.0 Hierarchy Contract (Binding)

**Skip if** input has no `hierarchy_contract`.

`HIERARCHY_CONTRACT` is a directive, not a hint. For every item whose `index` is in `HIERARCHY_CONTRACT.child_indexes`:

- Ordinary hierarchy inference (§§ 7.1-7.2) and duplicate/overlap action downgrades (§ 6.1) are BYPASSED for the item's action and placement. Still run § 6.1 for evidence — it populates `supersedes[]`/`related` — but it never changes the action.
- The output MUST be `action: "create"` with `hierarchy: {"action": "make_child", "parent": [HIERARCHY_CONTRACT.parent_issue]}` and `project.recommended` = the contract parent's project.
- The item MUST NOT resolve to `skip`, `expand`, `update`, `combine`, or `cancel`. If an existing issue (including the contract parent) already carries scope belonging to the item, move that scope into the new domain child: record `supersedes[]` on the created child (full coverage) or a `related` relation (partial overlap), and note the move in `reason` — never emit an update of the existing issue in place of the child create.
- The contract parent becomes a coordination-only parent (the caller converts it per research-complete § 6.6) — never treat it as one domain's implementation leaf or recommend it as an `update`/`expand` target for covered-item scope.
- Apply `HIERARCHY_CONTRACT.sequencing[]` as `blocks` relations between the corresponding created children (`add_relations.blocks` with `#N` batch references).

Items NOT listed in `child_indexes` (e.g. `origin: "discovered"` refactors) are audited normally per §§ 6-7 and § 10.

### 7.1 Identify Candidates

**From caller context** (hints, not directives — except `hierarchy_contract`, which is binding per § 7.0):
- `parent_issue`: Issue being worked on — in-scope items become children
- `blocked_issues`: Hierarchy hints (research-complete only) — consider if scope is strict subset

**Parent candidates** (when no `parent_issue` context):
- 2+ input issues with same target → one could be parent
- Large issue (estimate >=4) with implicit sub-tasks → breakdown candidate
- From `blocked_issues` context: parent candidates for issues that are subsets of their scope

**Child candidates**:
- Input issue is small piece of larger tracked effort
- Explicit "step N" or phased work pattern
- Issue scope is strict subset of a `blocked_issues` entry's scope

**Bundle candidates** — 2+ input issues share:
- Same `agent:X` label + same project + same work type
- Same refactor/migration pattern applied to sibling components
- Related targets in same domain

**Note**: Do not gate bundles on estimate size. Two estimate-3 issues with identical patterns are a stronger bundle than two estimate-1 issues with unrelated targets.

**Note**: Research issues should NEVER appear in `parent_issue`. Use `blocked_issues` for research-complete flows.

**Same-project constraint**: Parent and child must be in the same project. If projects differ, add to `wrong_project[]` or keep standalone with `related`. See [dependencies.md](../references/dependencies.md).

### 7.2 Evaluate Coherence

For each candidate, ask: **Would these naturally ship together in one PR?**

| Signal | Lean sub-issue | Lean independent |
|--------|----------------|------------------|
| **Scope alignment** | Same scope as parent | Subset or superset of parent's scope |
| **Domain match** | Same concerns as parent | Introduces orthogonal concerns |
| **Review coherence** | Reviewer expects both | Would distract from parent's review |

**Lean independent when**:
- Platform-specific work under cross-platform parent
- Tooling/methodology under feature parent
- Work could ship before or after parent

**Lean sub-issue when**:
- Platform-specific under same-platform parent
- Tests for the feature being implemented
- Hardening for the component being built

**When uncertain**: Prefer independent with blocking relation. Easier to merge later than to split.

### 7.3 Validate Scope Coverage

**Skip if** MODE = issue.

For each parent issue with children:

1. **Check description format**: parent has `## Requirements` (implementation scope) vs `## Sub-Issues` (coordination summary)

2. **If parent has implementation scope** not mapped to children → add to `analysis[]`: "Parent [ISSUE_ID] has `## Requirements` not decomposed into sub-issues."

3. **Check agent labels**: if children have 2+ distinct taxonomy `agent` labels but parent lacks the project-configured multi-agent label (for example `agent:multi` when present in inventory/taxonomy) → add to `agent_mismatch[]` only after validating that replacement label exists and is assignable.

4. **Check `## Sub-Issues` list matches actual children**: Compare issue IDs listed in parent description vs actual `children[]` from API. If mismatched (missing or extra entries), add to `hierarchy[]` with action `update_parent_desc` and reason noting the stale entries.

### 7.4 Record Hierarchy Findings

**PROJECT mode**: Add to `findings.hierarchy[]`:

| Action | Fields | Meaning |
|--------|--------|---------|
| `make_parent` | `issue`, `children[]` | Issue becomes parent of listed issues |
| `make_child` | `issue`, `parent` | Issue becomes sub-issue of parent |
| `bundle` | `issues[]`, `new_parent_title` | Create new parent, group issues under it |
| `update_parent_desc` | `issue` | Parent's `## Sub-Issues` is stale — sync with actual children |

**ISSUE mode**: Set `hierarchy` on each issue per [audit-output.md](../schemas/audit-output.md) Hierarchy Field.

Include `reason` explaining the coherence evaluation.

---

## 8. Combination Candidates

**Add** to `combine[]` when issues should merge:
- Small scope issues that together form logical unit
- Overlapping creates/consumes causing unnecessary fragmentation
- Near-duplicate scope where one subsumes the other

**Include** `target` (issue to keep) and `absorb[]` (issues to merge into it).

---

## 9. Architecture Gap Analysis

**Skip if** MODE = issue.

### 9.1 Fetch Architecture Documentation

Read architecture docs relevant to project scope.

Extract:
- **Module paths**: Directory structure
- **Components**: Named subsystems
- **Interfaces**: Traits, message types, subscriptions
- **Performance targets**: Latency budgets, throughput requirements

### 9.2 Analyze Implementation State

For each repository-relative module path from 9.1, inspect that exact path. A
module referenced by architecture documentation may extend beyond a PR's
changed paths; inspect that concrete architecture path without adding it to an
unrelated issue's context or falling back to a repository-root `src/`:
```bash
ls -la "[WORKTREE]/[MODULE_PATH]"
rg -n "pub struct|pub fn|pub trait|export class|export function" "[WORKTREE]/[MODULE_PATH]"
rg -n "TODO|unimplemented|todo|FIXME" "[WORKTREE]/[MODULE_PATH]"
```

Do not use an issue's linked PR or `ISSUE_VERIFICATION_CONTEXT` as the scope for
the whole project. When architecture-gap analysis lacks concrete module paths,
resolve repository discovery separately as `PROJECT_VERIFICATION_CONTEXT` and
use it only for § 9. If an issue-specific context is `docs-only`, do not
reinterpret that documentation-only change set as evidence that architecture
modules are missing.

Classify:

| Status | Evidence |
|--------|----------|
| **Implemented** | Module exists, functions present, no major TODOs |
| **Stubbed** | Module exists, functions return placeholders |
| **Missing** | Module/directory doesn't exist |

### 9.3 Compare Architecture vs Backlog

For each architecture component:

1. **Search ALL project backlogs** (from 1.5) for matching issues

2. **Check implementation state** from 9.2

3. **Mark as GAP** if: architecture requires it + no issue exists + not implemented

**Project placement for gaps**:
- Gap matches completed project scope → evaluate reopening (9.5)
- Gap matches different active project → assign to that project
- Gap doesn't fit any project → evaluate new project (9.5)

### 9.4 Classify and Record Gaps

**Add** to `architecture_gaps[]` with category:

| Category | Criteria | Action |
|----------|----------|--------|
| **Critical** | Blocks 2+ existing issues | Implementation issue, P1 |
| **Required** | Architecture-specified, no blockers | Implementation issue, P2 |
| **Research** | Optional/future, needs investigation | Research issue |

**Include** `reasoning` (2-4 sentences), `evidence`, `blocked_issues[]`, `project_placement`, `recommended_issue`.

### 9.5 Evaluate Project-Level Changes

**New project** — Add to `project_recommendations[]` when:
- 3+ related gaps form subsystem
- Scope >8 pts
- No existing project fit

**Reopen project** — Add when:
- Gap matches completed project scope
- AND: blocks active work OR deliverables incomplete

---

## 10. Determine Actions

**Skip if** MODE = project.

### 10.1 Validate Actionability

For each proposed issue, check actionability — ensure it has clear scope, testable criteria, and defined deliverables.

**Actionability determination:**
- All criteria pass → 10.2
- Any criterion fails → `skip` with reason: `"Too vague — [missing criterion]"`

**Hierarchy-contract items** (§ 7.0) are never `skip`: if actionability fails for a `child_indexes` item, keep `action: "create"` per the contract and flag the gap in `reason` for the caller to resolve.

### 10.2 Assign Actions

For each input issue, assign action based on analysis:

| Action | Meaning | `target` field |
|--------|---------|----------------|
| `valid` | Correctly configured, relation corrections only | null |
| `create` | Create new issue | null |
| `skip` | Don't create — duplicate, vague, or observation | reason string |
| `expand` | Expand existing issue to include this work | issue to expand |
| `update` | Update existing issue description | issue to update |
| `supersede` | Cancel existing, create new (scope changed) | issue to cancel |
| `combine` | Absorb into existing issue | issue to absorb into |
| `cancel` | Cancel — obsolete | null |

**Hierarchy contract override (MUST)**: If the item's `index` is in `HIERARCHY_CONTRACT.child_indexes`, assign `create` with `hierarchy: {"action": "make_child", "parent": [HIERARCHY_CONTRACT.parent_issue]}` per § 7.0 and skip steps 1-6 below — a contract item never resolves to `skip`, `expand`, `update`, `combine`, or `cancel`, regardless of duplicate/overlap findings.

**Action determination logic**:
1. If actionability check failed (10.1) → `skip` (reason = vague description)
2. If `obsolete[]` contains issue → `cancel`
3. If `duplicates[]` contains issue as `remove` → `skip` (target = `keep` issue)
4. If `combine[]` contains issue in `absorb[]` AND target issue state is not Done/Cancelled → `combine` (target = `target` issue)
5. If proposed issue overlaps existing AND existing issue state is not Done/Cancelled → `expand` or `update` based on scope delta
6. Otherwise → `create` (proposed) or `valid` (existing)

**Completed issue guard**: Steps 4-5 exclude Done/Cancelled issues as targets. Completed work is a historical record — new scope belongs in new issues. If overlap is detected with a completed issue, fall through to step 6 (`create`) and add a `related` relation to the completed issue for traceability.

**Supersedes population**:

1. **Verify**: For each `create` action, check `supersedes[]` populated from 6.1 findings
2. **Validate entries**: Each must have `identifier`, `title`, `reason`
3. **Update summary**: Set `summary.superseded` to total count across all issues

**Research traceability**: If `SOURCE == "research-complete"` and `RESEARCH_ISSUE` is set, add `RESEARCH_ISSUE` to `add_relations.related[]` for all `create` actions. This ensures created issues link back to the research that spawned them.

**Create fields**: For every `create` action, populate `create_fields` per [audit-output.md](../schemas/audit-output.md). Include full `create_fields.labels[]` from input `items[].labels[]` when present or complete it from § 1.2 taxonomy/inventory. If required labels cannot be determined or do not exist in live issue-label inventory, leave the action blocked with a clear `reason`; do not emit a create action that relies only on `agent`/`agent_label`.

---

## 11. Pre-Output Verification

**Before writing report, verify each check was applied to EVERY input issue.**

### 11.1 Core Checks (All Issues)

- [ ] 1.7/2.1: Verification evidence collected and a distinct `VERIFICATION_CONTEXTS[ISSUE_KEY]` entry resolved for every input issue/contract; no linked PR, branch, or scope reused across issues; docs-only handled explicitly
- [ ] 2: Contract extracted (target, creates, consumes, problem)
- [ ] 4.4: Completed-blocker relations preserved (surfaced only as ready-to-schedule signals, never flagged as stale or removed)
- [ ] 4.5: Relation violations scanned (cross-project, cross-bundle, child→standalone)
- [ ] 5.1-5.2: Relations analyzed against the resolved code or documentation paths
- [ ] 5.3: Priority alignment checked (skip if proposed without priority)
- [ ] 5.4: Agent label verified
- [ ] 5.5: Label co-occurrence checked
- [ ] 10.2: Create actions include full `create_fields.labels[]`; label update recommendations have mode/category semantics
- [ ] 6.1: Duplicates and supersession checked (same-project AND cross-project)
- [ ] 6.2: Obsolete checked with deep verification
- [ ] 6.3: Project fit evaluated against ALL projects
- [ ] 7: Hierarchy evaluated (candidates identified, coherence checked)
- [ ] 8: Combination candidates checked

### 11.2 Additional Checks

**Skip if** MODE = issue.

- [ ] 3.1: Issue fit validated against project definition
- [ ] 3.2: Project dependencies analyzed
- [ ] 9: Architecture gaps identified with evidence

### 11.3 Additional Checks

**Skip if** MODE = project.

- [ ] 10.1: Actionability validated for every proposed issue
- [ ] 10.2: Action assigned to every input issue
- [ ] 7.0/10.2: Every `hierarchy_contract.child_indexes` item has `action: create` + `hierarchy.action: make_child` + `hierarchy.parent` = the contract parent, and no contract item was downgraded to `skip`/`expand`/`update`/`combine`/`cancel`

**If any check was skipped, go back and complete it now.**

---

## 12. Return Output

1. **Build JSON** per [audit-output.md](../schemas/audit-output.md). Set the destination hint to `tmp/audit-project-YYYYMMDD-HHMMSS.json` (PROJECT) or `tmp/audit-issues-YYYYMMDD-HHMMSS.json` (ISSUES).

2. **Return the JSON inline** in your response. Do not write the artifact yourself; the calling agent writes the file in its worktree using the returned `File:` hint.

   <output_format>
   File: tmp/audit-[MODE]-YYYYMMDD-HHMMSS.json
   ```json
   {complete JSON object}
   ```
   </output_format>

---

**END**: Audit complete.
