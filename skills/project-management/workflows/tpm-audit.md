# Audit Analysis

Analyze issues and projects for relations, labels, hierarchy, placement, duplicates, and obsolete work; recommend what to create and what to close.

**Do NOT modify the tracker.** Return recommendations only.

**Hold the creation bar** ([SKILL.md](../SKILL.md) § Disposition). An observation that clears it is a `create`; everything else is `skip` with a one-line reason. Every run that reads an issue backlog also completes the § 6 cancellation sweep.

## Inputs

| Arg | MODE | Input set |
|-----|------|-----------|
| `--project <name>` / `--project` | `project` | Every issue in the named or active project |
| `--team` | `team` | Every Backlog/Todo/In Progress/In Review issue on the team |
| `--issues <file>` | `issues` | Items from [audit-issues-input.md](../schemas/audit-issues-input.md) |
| `--project-order` | `project-order` | All projects and initiatives |

---

## 1. Mode and Context

### 1.1 Determine Mode

`project-order` → § 1.1.1, then § 11 (§§ 2-10 and § 12 do not apply). An ordering-only run reads no issue backlog, so the § 6 cancellation sweep is not among its obligations — exemption from the sweep is never exemption from scope, and § 11 reads and reorders projects.

**project**: store `WORKTREE` from the delegation prompt (default `.`). Linear only — this mode audits Linear projects.

**team**: store `WORKTREE` the same way. The input set is every Backlog/Todo/In Progress/In Review issue on the team, in whatever project each sits and including the rows carrying none.

**Team mode reads as project mode.** Every rule, `Skip if`, and output field this workflow states for `project` applies unchanged to `team`, a rule added later included; only a rule naming `team` overrides one. The two differences are the input set above and `project: null` in the output ([audit-output.md](../schemas/audit-output.md)).

**issues**: read the JSON file and extract `TRACKER` (plus `REPOSITORY` for github) from the delegation's `Tracker:` line or the file's `tracker` field — absent both, infer `github` from a `parent_issue` starting with `issue-`, else `linear` — along with `WORKTREE`, `PARENT_ISSUE`, `SOURCE`, `INPUT_ITEMS` from `items[]`, and the optional research-complete fields `blocked_issues`, `research_issue`, `research_ref`, `decision_ref`, and `hierarchy_contract` (binding — § 7.0).

**Done and Canceled issues are historical records.** Never recommend a change to their labels, agent, priority, or state — whichever set they arrive in, they take no disposition. They participate in relation analysis and duplicate detection as § 1.5 comparison evidence, which is the only way a Canceled issue reaches the analysis at all. Only Backlog, Todo, In Progress, and In Review issues are candidates for fixes.

### 1.1.1 Resolve Team Scope

**Skip if** TRACKER=github — a repository is one scope. Otherwise refresh the cache and resolve the scope ([SKILL.md](../SKILL.md) § Execution Rules) before any cached read:

```bash
.agents/skills/linear/scripts/linear.sh sync --if-stale 15
.agents/skills/linear/scripts/linear.sh auth-check
.agents/skills/linear/scripts/linear.sh teams get [TEAM]
```

`TEAM` is `auth-check`'s `team`, a name; `TEAM_PREFIX` is that team's `key`. `teams get` looks up by name and needs no issue, so a team with none yet resolves and the audit proceeds. Halt when `auth-check` reports no team and when `teams get` resolves none — an audit that cannot resolve its own scope must not run unscoped. With the scope resolved, a row whose `id` does not start with `TEAM_PREFIX-`, and a project row whose `teams[]` omits `TEAM`, is out of scope in every mode. Which path resolves and filters: [SKILL.md](../SKILL.md) § Scope by Path.

### 1.2 Load Label Policy

```bash
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe   # TRACKER=linear
gh label list --repo [REPOSITORY] --limit 200 --json name,description     # TRACKER=github
```

`--limit 200` is a stated cap, not a page: a repository reaching it is analyzed against a truncated inventory, which the analysis notes in `analysis[]` and scopes itself to.

Load the project taxonomy alongside it. Freshness is the § 1.1.1 refresh's job; what a cached read itself enforces is presence, so a missing Linear cache on this or any later read halts the analysis and reports that the caller must run `sync --reconcile` first ([SKILL.md](../SKILL.md) § Execution Rules) — never work around it with a partial or live-only read. Every `agent_mismatch`, `label_cooccurrence`, `recommended_issue.labels[]`, and `create_fields.labels[]` recommendation must be expressible against this live inventory. Issue labels only.

### 1.3 Fetch Projects

Fetch every project in ONE command. `cache projects list --state` matches one state exactly and never a comma list, so omit it and read each row's own `state`; ignore `canceled` rows and every row § 1.1.1 scopes out.

```bash
.agents/skills/linear/scripts/linear.sh cache projects list
```

**GitHub — explicit degradation**: record an empty project set and leave every project-placement field (`recommended_project`, `wrong_project`, project moves) null or omitted with reason `github: no project inventory`. Never invent a placement; scope fit checks to the repository backlog from § 1.5.

### 1.4 Fetch Input Issues

```bash
.agents/skills/linear/scripts/linear.sh cache issues list --project "[PROJECT]" --state "Backlog,Todo,In Progress,In Review,Done" --max   # project mode
.agents/skills/linear/scripts/linear.sh cache issues list --all-projects --state "Backlog,Todo,In Progress,In Review" --max               # team mode
.agents/skills/linear/scripts/linear.sh cache issues bulk-get [ISSUE_ID_1] [ISSUE_ID_2] --format=safe                                     # issues mode, one call
gh issue view [N] --repo [REPOSITORY] --json number,title,body,labels,state,url                                                           # issues mode, github
```

Both `--all-projects` fetches return every team; keep only the rows § 1.1.1 scopes in. Issues mode fetches the whole input set in one `bulk-get`, never one call per issue; a lone input issue is `cache issues get [ISSUE_ID]`. `cache issues bulk-get` returns the rows it matched and exits 0 whether or not it matched them all, so compare the returned `id` values against every requested identifier and halt naming any that came back missing. An unmatched target is a mistyped, deleted, or unsynced issue, never an absent one, and auditing the remainder would report a complete result over a subset. An input issue the caller named that resolves outside the § 1.1.1 scope halts the same way — the cache holds it, and auditing another team's issue is not the caller's to authorize.

The cached Linear issue payload carries `blocks`, `blocked_by`, `blocked_by_open`, and `related`. `blocked_by_open` decides whether an issue is blocked now; `blocked_by` remains the full relation history used by § 4. GitHub: read relations from body links (`Blocks: #N`, `Blocked by: #N`, `Related: #N`, `Parent: #N`). Proposed items use their provided fields directly.

### 1.4.1 Read Comments

Comments carry what no listing does: an issue's scope changes, its supersession notes, and its partial-completion reports. `sync` writes them per issue (`.cache/linear/comments/[ISSUE_ID].json`) and this is the workflow's only read of them. Read them for the § 1.4 input set here, and for every in-scope row of the § 1.5 comparison set as soon as that fetch returns, closed rows included: a supersession note, or the reason a row was canceled, is what makes a closed row worth comparing against. Dispositions stay active-only (§ 1.1). An issue with no comments reads as an empty list, and a disposition written before its issue's comments were read rests on unsupported evidence, whatever the body says.

```bash
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]   # one call per issue, TRACKER=linear
gh issue view [N] --repo [REPOSITORY] --json body,comments               # TRACKER=github
```

### 1.5 Fetch Comparison Set

Fetch the full backlog in ONE command:

```bash
.agents/skills/linear/scripts/linear.sh cache issues list --all-projects --state "Backlog,Todo,In Progress,In Review,Done,Canceled" --max
```

Each row carries its own `project` name, empty for an issue with none. Discard every row outside the § 1.1.1 team scope before comparing anything against it. Never loop `--project` over the projects from § 1.3. In team mode this is the § 1.4 input fetch with `Done` and `Canceled` added. `Canceled` is here as comparison evidence and nowhere else — a duplicate an issue already has, a relation it already carries, a child § 7.3 must count — never as an audit input. Neither state takes a disposition (§ 1.1), and the § 6 sweep proposes cancellations only from this set's active rows.

**GitHub**:

```bash
gh issue list --repo [REPOSITORY] --state all --limit 200 --json number,title,state,labels
```

The same stated cap applies: past 200 issues the comparison set is partial, and every duplicate, supersession, and obsolescence finding is scoped to what it holds.

### 1.6 Extract Project Definitions

**Skip if** TRACKER=github — treat the repository as one scope.

For each project from § 1.3, extract from name, description, and content: its **purpose** (implementation, testing, refactoring, validation), the **work type** that belongs in it, and the **components** it owns.

### 1.7 Collect Verification Evidence

Per input issue, record its own linked PR and changed files, known implementation branch and base ref, concrete paths, and documentation-only signals, keyed by issue identifier (or stable input index for a proposed item). A PR or branch belongs only to the issue that identifies it or is documented as implementing it — never inferred from a sibling input issue.

---

## 2. Extract Contracts

Per input issue, extract from title and description: **target** (component or file), **creates** (new APIs, seams, types, tests), **consumes** (existing APIs it uses or extends), **problem** (the bug, gap, or feature), and **decisions** — search with `.agents/skills/decider/scripts/decisions search "[TARGET_KEYWORDS]"` and flag any proposed approach contradicting an active decision.

### 2.1 Resolve Verification Scope Per Contract

For each contract row, set `ISSUE_KEY` to its identifier or index and resolve one repository-aware context. A repository-root `src/` is never assumed. Choose the narrowest trustworthy input for that issue alone:

```bash
# PR changed files (this issue's PR only), or the issue's own concrete target paths
.agents/skills/project-management/scripts/verification-scope --worktree "[WORKTREE]" --changed-file "[PATH_1]" --changed-file "[PATH_2]"

# Branch known to implement this issue, base ref known
.agents/skills/project-management/scripts/verification-scope --worktree "[WORKTREE]" --base-ref "[BASE_REF]"

# Fallback: discover every tracked source root (monorepos, multi-crate workspaces)
.agents/skills/project-management/scripts/verification-scope --worktree "[WORKTREE]"

# Deliverables and changed paths are all documentation
.agents/skills/project-management/scripts/verification-scope --worktree "[WORKTREE]" --docs-only --changed-file "[DOC_PATH]"
```

Store each result as `VERIFICATION_CONTEXTS[ISSUE_KEY]` — the output fields and path-resolution rule are in `verification-scope --help`. Never reuse another issue's linked PR, branch diff, or resolved context; `ISSUE_VERIFICATION_CONTEXT` always means the entry for the issue currently being checked.

- `changed` mode: search this issue's exact changed or contract target first. Expand only when its creates-consumes contract or an architecture reference proves another path is relevant.
- `repository` mode: search the returned source roots — discovery skips the vendored `.agents/` render tree. Never substitute `[WORKTREE]/src`.
- `docs-only` mode: skip code-path checks; verify documentation deliverables against the resolved documentation paths. Absent code evidence is not a mismatch or an obsolete signal.
- Code verification required but `verification_paths[]` empty: halt with a scope-resolution error rather than guessing a path.
- A creates-consumes pair loads both contexts independently; neither context replaces the other.

---

## 3. Validate Project Scope

**Skip if** MODE = issues.

Verify each issue matches the target project's definition from § 1.6 — wrong work type, wrong scope, or content contradicting the project's stated purpose all go to `wrong_project[]`. In team mode the target is the project named on the issue's own row; a row with project `""` gets a `wrong_project[]` entry with `from: null` recommending the project its scope fits, or an `analysis[]` note when nothing fits.

Then trace what depends on this project's output: list what it modifies, find which projects build on or test those modifications, and record any missing project relation in `project_dependency_issues[]` as `{from_project, to_project, current_relation, should_be, reason}`. Project relations come from this scope analysis only, never bottom-up from individual issue relations.

---

## 4. Identify Candidate Pairs

Do not compare every pair. Build candidates from signals: same target component, same parent, one issue naming another's ID, creates-consumes overlap, same file path in the location field, and any existing tracker relation (which must be verified). When two issues share a file path, grep for the shared structs or functions.

### 4.1 Verify Existing Relations

A relation on a Done issue is a valid historical record. Flag it for removal only when the dependency itself is wrong (no creates-consumes), not for the source being Done.

**Completed-blocker relations are auto-satisfied, never stale** (the owning rule: linear SKILL.md § Blocked Label vs Issue Relations). Do NOT add such relations to `remove_relations[]`, and do NOT report them under any stale-metadata heading. When `blocked_by` is non-empty and `blocked_by_open` is empty, emit the one legitimate finding: `ready_to_schedule[]` in project mode, or "gates cleared, ready to schedule" in the issue's `reason` in issues mode.

### 4.2 Scan Relation Violations

Iterate every `blocks`/`blocked_by` on the input issues and their children. A relation is misplaced when it crosses bundles (`A.parent != B.parent`, both parented) or joins a child to a standalone issue.

**Preserve blocking relations by fixing the structure**, never by deleting them. For each violation: add the child relation to `remove_relations[]` with reason `"Violation: [TYPE] — [FROM] [REL] [TO]"`, add the lifted parent-level relation to `add_relations[]`, and add `related` between the original children. See [dependencies.md](../references/dependencies.md) for the level rule.

---

## 5. Analyze Candidate Pairs

### 5.1 Dependencies

Merge three sources: creates-consumes analysis (does B consume what A creates?), caller hints in `blocks_items`/`blocked_by_items`/`blocks_issues`/`blocked_by_issues` (validate against the contracts — carry valid hints, drop contradictions), and cross-domain sequencing between siblings with different agent domains (a relation only when data flow is confirmed).

Default to `blocks` when a dependency exists; use `related` only for a genuinely informational link. Record `Pair | Current | Should be | Reason`.

### 5.2 Verify Against the Repository

Load only this issue's `ISSUE_VERIFICATION_CONTEXT`. In `docs-only` mode, verify its documentation contract against its resolved documentation paths and skip code checks. Otherwise search the most specific contract target first, falling back to the resolved paths:

```bash
rg -n "consumedThing" "[WORKTREE]/[TARGET_PATH]"
rg -n "consumedThing" "[WORKTREE]/[VERIFICATION_PATH_1]" "[WORKTREE]/[VERIFICATION_PATH_2]"
```

A contract that does not match the code: re-evaluate the relation rather than recording it.

### 5.3 Metadata Checks

Skip Done and Canceled issues throughout; their metadata is historical.

| Check | Rule | Output |
|-------|------|--------|
| Priority | In `A blocks B` with both active, A's priority must not be lower-urgency than B's; a `critical-path` label demands P1. Proposed issues with no priority are skipped | `priority_misalignment[]`: `{id, current, should_be, reason}` |
| Agent label | Compare the issue's `agent` category label against its content and resolved target path (`ls`, `rg -n "pub fn\|export function\|def "`). In `docs-only` mode infer ownership from the contract, project definition, and documented paths | `agent_mismatch[]`: `{id, current, should_be, reason, signals[]}` |
| Label co-occurrence | An issue missing a required taxonomy category whose title or description matches 2+ detection signals for it | `label_cooccurrence[]`: `{id, title, present, missing, reason}` |

Validate every recommended replacement against the § 1.2 inventory first. If the desired label does not exist or is a parent/group label, state the failure in `reason` and recommend no mutation.

---

## 6. Duplicates, Supersession, and Obsolete

This is the cancellation sweep. No mode that reaches this section skips it.

### 6.1 Duplicates and Supersession

Compare input issues against the whole § 1.5 comparison set. Same problem plus same approach is a duplicate (`duplicates[]`) whatever project it lives in; same problem with a genuinely different approach keeps both with a `related` link. When title and keyword matching finds nothing, extract the module or component name from the location field and search on that.

When an input item's scope **fully covers** an existing issue, that is `supersedes[]` on the input item, not `duplicates[]`. Signals: the item's `decision_ref` supersedes the existing issue's governing decision, the item's `creates[]` is a superset of the existing deliverables, or the existing issue references a superseded decision.

### 6.2 Obsolete

Never add to `obsolete[]` without code verification.

1. Extract the deliverables from the issue description.
2. Verify each one in its resolved target path, or in this issue's `ISSUE_VERIFICATION_CONTEXT.verification_paths[]` when no concrete target exists. For a comparison-set issue with no entry yet, extract its contract and resolve its own entry — never borrow an input issue's. In `docs-only` mode read the documentation paths and verify documentation deliverables instead of running symbol searches.

   ```bash
   rg -n "pub fn [FUNCTION]|pub struct [TYPE]|export class [TYPE]|export function [FUNCTION]" "[WORKTREE]/[TARGET_PATH]"
   ```

3. Read the files — distinguish complete implementations from stubs, and promised documentation content from a heading.
4. Score: everything implemented with tests = 100%; everything implemented without tests = 90%; most deliverables with some stubs = 50%; partial = 0%. **≥90% is required** to add to `obsolete[]`.

With `DECISION_REF` present, also detect issues the decision made unnecessary by changing the approach (not the scope): read the decision (`.agents/skills/decider/scripts/decisions get [DECISION_REF]`), extract the patterns it explicitly replaced, search the comparison set for issues implementing them, exclude anything already in `supersedes[]`, and record confidence 100 with evidence `{decision_eliminated: true, decision_ref, eliminated_pattern}`.

**Below the bar.**

1. Re-read every active issue in the comparison set as § 1.5 fetched it against the creation bar's first and third tests as they stand today (the second, coverage by other work, is not reapplied: an issue always covers itself).
2. One that fails (the bar's own list, not restated here) is a cancellation with confidence 100 and evidence `{below_bar: true, test, who_hits_it}`: `test` names the failed test, `who_hits_it` is the one-line user story and how often a user meets it, written after reading the issue's body and its § 1.4.1 comments (on GitHub, `gh issue view <n> --json body,comments`; the § 1.5 list carries neither).
3. In project mode it is an `obsolete[]` entry; in issue mode it is the issue's own `issues[]` entry with `action: "cancel"` and that evidence in its `obsolete` field.
4. The bar's two exceptions (a shipped-path security or data-loss defect; a critical-harm or financial-loss edge case) never go here on likelihood; the third test still applies to them.
5. The code-verification rule above is for implementation-obsolete entries; a `below_bar` entry is verified by reading the body and, where it names a path, producer, or regression, checking that claim in the repository before the entry is written.

### 6.3 Project Fit

Compare each input issue against every project definition. A scope matching another project better, or a child sitting in a different project from its parent, goes to `wrong_project[]`. A dependency on work in another project is recorded as a relation, not a move. The current assignment is not evidence. A team-mode row with project `""` carries no assignment to weigh — recommend the project its scope fits.

---

## 7. Hierarchy

### 7.0 Hierarchy Contract (Binding)

**Skip if** the input has no `hierarchy_contract`.

`HIERARCHY_CONTRACT` is a directive, not a hint. For every item whose `index` is in `HIERARCHY_CONTRACT.child_indexes`:

- Ordinary hierarchy inference (§§ 7.1-7.2) and the duplicate/overlap action downgrades of § 6.1 are BYPASSED for the item's action and placement. § 6.1 still runs for evidence — it populates `supersedes[]` and `related` — but never changes the action.
- The output MUST be `action: "create"` with `hierarchy: {"action": "make_child", "parent": [HIERARCHY_CONTRACT.parent_issue]}` and `project.recommended` equal to the contract parent's project.
- The item MUST NOT resolve to `skip`, `expand`, `update`, `combine`, or `cancel`. When an existing issue — the contract parent included — already carries scope belonging to the item, move that scope into the new domain child: record `supersedes[]` on the child for full coverage or a `related` relation for partial overlap, and note the move in `reason`. Never emit an update of the existing issue in place of the child create.
- The contract parent becomes coordination-only (the caller converts it). It is never one domain's implementation leaf and never an `update`/`expand` target for covered scope.
- Apply `HIERARCHY_CONTRACT.sequencing[]` as `blocks` relations between the created children, using `#N` batch references.

Items outside `child_indexes` — `origin: "discovered"` refactors, for instance — are audited normally.

### 7.1 Identify Candidates

`parent_issue` and `blocked_issues` are hints the analysis may override; `hierarchy_contract` is binding per § 7.0. A research issue never appears in `parent_issue`.

Look for: an input item whose scope is a strict subset of a tracked effort (child candidate); two or more input issues on the same target, or a large issue with implicit sub-tasks (parent candidate); and two or more issues sharing an agent label, project, and work type, or applying one refactor pattern across sibling components (bundle candidate). Bundle on pattern, not size.

Parent and child must share a project. If they cannot, record `wrong_project[]` or keep the issue standalone with a relation.

### 7.2 Evaluate Coherence

Ask: **would these ship together in one PR?** Yes means an explicit single-PR bundle — the parent's title takes the `(one PR)` marker. No means a container: no marker, sibling child-blocks-child relations for ordering.

Lean sub-issue for tests of the feature being implemented, hardening for the component being built, and platform work under a same-platform parent. Lean independent for platform-specific work under a cross-platform parent, tooling or methodology under a feature parent, and anything that could ship before or after the parent. When uncertain, prefer independent with a blocking relation.

### 7.3 Parent Scope Coverage

**Skip if** MODE = issues.

For each parent with children: implementation scope left in the parent (`## Requirements` rather than `## Sub-Issues`) is an `analysis[]` note; a `## Sub-Issues` list that disagrees with the actual children is a `hierarchy[]` entry with action `update_parent_desc`; children spanning 2+ agent domains under a parent lacking the project's multi-agent label is an `agent_mismatch[]` entry, recorded only after validating the replacement label exists.

Record findings as `findings.hierarchy[]` in project mode — `make_parent` (`issue`, `children[]`, and `retitle: "[current title] (one PR)"` only when § 7.2 answered yes), `make_child` (`issue`, `parent`), `bundle` (`issues[]`, `new_parent_title`), `update_parent_desc` (`issue`) — or as each issue's `hierarchy` field in issues mode per [audit-output.md](../schemas/audit-output.md). Include the coherence reasoning in `reason`.

---

## 8. Combination Candidates

Add to `combine[]` — with `target` (kept) and `absorb[]` (merged in) — when small issues together form one logical unit, when overlapping creates/consumes fragment one change across issues, or when one scope subsumes the other.

---

## 9. Architecture Gaps

**Skip if** MODE = issues.

In team mode the scope is every `started` project from § 1.3, read one project at a time; a gap is filed once, against the project whose definition owns it.

Read the architecture docs for the project scope and extract module paths, named components, interfaces, and performance targets. For each documented module path, inspect that exact path:

```bash
ls -la "[WORKTREE]/[MODULE_PATH]"
rg -n "pub struct|pub fn|pub trait|export class|export function" "[WORKTREE]/[MODULE_PATH]"
rg -n "TODO|unimplemented|todo|FIXME" "[WORKTREE]/[MODULE_PATH]"
```

An architecture module may extend beyond any PR's changed paths. Never scope § 9 with an issue's `ISSUE_VERIFICATION_CONTEXT` or fall back to a repository-root `src/`; when concrete module paths are missing, resolve repository discovery separately as `PROJECT_VERIFICATION_CONTEXT` and use it here only. A `docs-only` issue context is never evidence that architecture modules are missing.

Classify each component as implemented (exists, functions present, no major TODOs), stubbed (returns placeholders), or missing. A component is a gap when the architecture requires it, no issue covers it in any backlog, and it is not implemented.

**A gap is still an issue, so it still clears the creation bar.** Critical (blocks 2+ existing issues) becomes a P1 implementation issue; required (architecture-specified, unblocked) a P2; optional or future work needing investigation becomes a research issue. A gap that nothing depends on and no user would notice is declined with one line, not filed. Record `reasoning` (2-4 sentences), `evidence`, `blocked_issues[]`, `project_placement`, and `recommended_issue` with its full `labels[]`.

Recommend a new project in `project_recommendations[]` only when 3+ related gaps form a subsystem larger than 8 points with no existing fit; recommend reopening a completed project only when a gap matches its scope and blocks active work or leaves its deliverables incomplete.

---

## 10. Determine Actions

**Skip if** MODE = project.

### 10.1 Apply the Creation Bar

Each proposed item passes only if it clears all three tests in [SKILL.md](../SKILL.md) § Disposition and has clear scope, testable criteria, and defined deliverables. A reproducible anomaly with evidence attached passes as an investigation issue whose deliverable is the diagnosis. A failure is `skip` with a one-line reason naming the test it failed — `"no user-visible effect"`, `"covered by [ISSUE_ID]"`, `"no evidence to start from"`, `"too vague — [missing criterion]"`.

Hierarchy-contract items (§ 7.0) are never `skip`: keep `action: "create"` and flag any actionability gap in `reason` for the caller.

### 10.2 Assign Actions

| Action | Meaning | `target` |
|--------|---------|----------|
| `valid` | Correctly configured; relation corrections only | null |
| `create` | Create new issue | null |
| `skip` | Do not create — duplicate, covered, or below the bar | reason string |
| `expand` / `update` | Widen or correct an existing issue | that issue |
| `supersede` | Cancel existing, create replacement | issue to cancel |
| `combine` | Absorb into an existing issue | issue to absorb into |
| `cancel` | Cancel — obsolete | null |

**Hierarchy contract override (MUST)**: an item whose `index` is in `HIERARCHY_CONTRACT.child_indexes` is assigned `create` with `hierarchy: {"action": "make_child", "parent": [HIERARCHY_CONTRACT.parent_issue]}` per § 7.0, skipping the order below — it never resolves to `skip`, `expand`, `update`, `combine`, or `cancel`, regardless of duplicate/overlap findings.

Otherwise, first match wins: creation bar failed → `skip` for a proposed item, `cancel` for an existing issue (§ 6.2 below the bar); in `obsolete[]` → `cancel`; the `remove` side of a `duplicates[]` pair → `skip` with the kept issue as target; in a `combine[]` `absorb[]` → `combine`; overlaps an existing issue → `expand` or `update` by scope delta; else `create` (proposed) or `valid` (existing).

**Completed-issue guard**: `combine`, `expand`, and `update` never target a Done or Canceled issue; new scope goes in a new issue with a `related` relation to the completed one.

For every `create`: populate `create_fields` per [audit-output.md](../schemas/audit-output.md) with the full `labels[]` from the input item or completed from § 1.2 taxonomy — an action that can only supply `agent`/`agent_label` is left blocked with a clear `reason`. `reach` is the producer the input item's `impact` names — the same line the filing bar reads, never re-derived from the finding. `review_born` is true when `SOURCE` is `review`, `pr-comments`, or `local-review`, false otherwise; a `review_born` create at priority 2 also carries `symptom` from the input item, and is left blocked with a `reason` when the item states none. Verify `supersedes[]` entries carry `identifier`, `title`, and `reason`, and set `summary.superseded` to the total. When `SOURCE == "research-complete"` and `RESEARCH_ISSUE` is set, add it to `add_relations.related[]` on every `create`.

---

## 11. Project Order Mode

Entered from § 1.1 after § 1.1.1; §§ 2-10 do not apply. Every project, initiative, and issue read below is filtered to the § 1.1.1 scope first: an initiative naming another team's projects contributes none of them, and a project whose `teams[]` omits `TEAM` is neither ordered nor recommended.

1. **Fetch** initiatives (`cache initiatives list`) and projects in every state (§ 1.3), recording `id`, `name`, `state`, `progress`, `sort_order`, `blocked_by[]`, `blocks[]`, `description`, `content`, plus each initiative's project names. Build the name→initiative map that fills each project's `initiative` field.

2. **Assign a layer** to each `planned` and `backlog` project (never `started` or `completed`) from its scope: what it delivers, what it consumes, and what its issues touch (`cache issues list --project "[PROJECT_NAME]" --state "Backlog,Todo,In Progress" --max`). Verify against the architecture docs that deliverables do not depend on unbuilt code. L0 foundation (no project dependencies) → L1 core infrastructure → L2 features → L3 integration and testing → L4 polish and release.

3. **Order** by topological sort on layer, then dependency edges (A's deliverables consumed by B means A precedes B), then priority.

4. **Compare to current, per state column.** `sortOrder` is relative **within one column only**. Execution order is started → planned top-to-bottom → backlog top-to-bottom. Current position: started = 0, then planned by `sortOrder`, then backlog by `sortOrder`. For each mismatch, decide whether the project is in the wrong state (recommend a state change) or the wrong position within its state (recommend a reorder), and compute `new_sort_order` with spacing per state column.

5. **Detect transitions**: a `started` project at `progress == 1.0` is a `complete_candidates[]` entry noting what it unblocks; assuming reorders applied, the first `planned`/`backlog` project with no incomplete blockers is `recommended_next` — null with a `rationale` listing each candidate's blockers when nothing is ready.

Return per § 13 with the `tmp/audit-project-order-YYYYMMDD-HHMMSS.json` hint and the project-order schema in [audit-output.md](../schemas/audit-output.md).

---

## 12. Pre-Output Verification

**Skip if** MODE = project-order — §§ 2-10 built none of these (§ 1.1).

Any invariant failing sends you back before the JSON is built.

- [ ] Every input issue has its own `VERIFICATION_CONTEXTS[ISSUE_KEY]` — no PR, branch, or resolved path set reused across issues, docs-only handled explicitly (§ 1.7, § 2.1)
- [ ] No completed-blocker relation appears in `remove_relations[]` or under any stale-metadata framing (§ 4.1)
- [ ] The § 6 cancellation sweep ran against the full comparison set
- [ ] TRACKER=linear: every issue named anywhere in the output carries the § 1.1.1 team prefix
- [ ] Every proposed item carries an assigned action, with a one-line reason naming the failed creation-bar test on each `skip`, and on each `create` a complete `create_fields.labels[]`, a `reach`, a `review_born`, and a `symptom` where `review_born` is true at priority 2 (§ 10)
- [ ] Every `hierarchy_contract.child_indexes` item is `action: create` + `hierarchy.action: make_child` + `hierarchy.parent` = the contract parent, none downgraded (§ 7.0, § 10.2)

---

## 13. Return Output

Build the JSON per [audit-output.md](../schemas/audit-output.md) and set the destination hint to `tmp/audit-project-YYYYMMDD-HHMMSS.json`, `tmp/audit-team-YYYYMMDD-HHMMSS.json`, `tmp/audit-issues-YYYYMMDD-HHMMSS.json`, or `tmp/audit-project-order-YYYYMMDD-HHMMSS.json` for the mode.

Return the JSON inline. Do not write the artifact yourself.

<output_format>
File: tmp/audit-[MODE]-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>
