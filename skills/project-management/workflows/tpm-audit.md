# Audit Analysis

Analyze issues and projects for relations, labels, hierarchy, placement, duplicates, and obsolete work; recommend what to create and what to close.

**Do NOT modify the tracker.** Return recommendations only.

**Hold the creation bar** ([SKILL.md](../SKILL.md) § Disposition). An observation that clears it is a `create`; everything else is `skip` with a one-line reason. Every run that reads an issue backlog also completes the § 6 cancellation sweep. A `single` run reads open titles, not the backlog, and does not sweep (§ 14).

## Inputs

| Arg | MODE | Input set |
|-----|------|-----------|
| `--project <name>` / `--project` | `project` | Every issue in the named or active project |
| `--team` | `team` | Every Backlog/Todo/In Progress/In Review issue on the team |
| `--issues <file>` | `issues` | Items from [audit-issues-input.md](../schemas/audit-issues-input.md) |
| `--single <file>` | `single` | The one item in an [audit-issues-input.md](../schemas/audit-issues-input.md) file |
| `--project-order` | `project-order` | All projects and initiatives |

---

## 1. Mode and Context

### 1.1 Determine Mode

`single` → § 14, which names the sections it runs. `project-order` → § 1.1.1, then § 11 (§§ 2-10 and § 12 do not apply). An ordering-only run reads no issue backlog, so the § 6 cancellation sweep is not among its obligations — exemption from the sweep is never exemption from scope, and § 11 reads and reorders projects.

**project**: store `WORKTREE` from the delegation prompt (default `.`). Linear only — this mode audits Linear projects.

**team**: store `WORKTREE` the same way. The input set is every Backlog/Todo/In Progress/In Review issue on the team, in whatever project each sits and including the rows carrying none.

**Team mode reads as project mode.** Every rule, `Skip if`, and output field this workflow states for `project` applies unchanged to `team`, a rule added later included; only a rule naming `team` overrides one. The two differences are the input set above and `project: null` in the output ([audit-output.md](../schemas/audit-output.md)).

**issues**: read the JSON file and extract `TRACKER` (plus `REPOSITORY` for github) from the delegation's `Tracker:` line or the file's `tracker` field, following [audit-issues-input.md § Tracker](../schemas/audit-issues-input.md#tracker) for required context and inference. Extract `WORKTREE`, `PARENT_ISSUE`, `SOURCE`, `INPUT_ITEMS` from `items[]`, the optional `in_pr_bundle` (§ 7.1), and the optional research-complete fields `blocked_issues`, `research_issue`, `research_ref`, `decision_ref`, and `hierarchy_contract` (binding — § 7.0).

**Verifying issues retain live checks on the same merged item.** Keep them out of development candidate sets. Read them in the comparison inventory for relation and duplicate analysis.

**Done and Canceled issues are historical records.** Never recommend a change to their labels, agent, priority, or state — whichever set they arrive in, they take no disposition. They participate in relation analysis, duplicate detection, and supersession analysis as § 1.5 comparison evidence, and in parent child counts through § 7.3. Only Backlog, Todo, In Progress, and In Review issues are candidates for development fixes. Verifying issues retain their post-merge checks and deadlines on the same item. The overseer handles them through the orch verification route.

For an existing-issue entry in `INPUT_ITEMS`, use its `identifier` as the requested ID in § 1.4. Analyze the resolved tracker issue, not a proposed creation; preserve its input `index` and `identifier` in the issue-mode output. Proposed entries use their supplied fields.

### 1.1.1 Resolve Team Scope

**Skip if** TRACKER=github — a repository is one scope. Otherwise resolve the scope ([SKILL.md](../SKILL.md) § Execution Rules) before any Linear read:

```bash
.agents/skills/linear/scripts/linear.sh auth-check
.agents/skills/linear/scripts/linear.sh teams get [TEAM]
```

`TEAM` is `auth-check`'s `team`, a name; `TEAM_PREFIX` is that team's `key`. `teams get` looks up by name and needs no issue, so a team with none yet resolves and the audit proceeds. Halt when `auth-check` reports no team and when `teams get` resolves none — an audit that cannot resolve its own scope must not run unscoped. With the scope resolved, a row whose `id` does not start with `TEAM_PREFIX-`, and a project row whose `teams[]` omits `TEAM`, is out of scope in every mode. Which path resolves and filters: [SKILL.md](../SKILL.md) § Scope by Path.

### 1.2 Load Label Policy

```bash
.agents/skills/linear/scripts/linear.sh labels list --max --format=safe   # TRACKER=linear
gh label list --repo [REPOSITORY] --limit 200 --json name,description     # TRACKER=github
```

`--limit 200` is a stated cap, not a page: a repository reaching it is analyzed against a truncated inventory, which the analysis notes in `analysis[]` and scopes itself to.

Load the project taxonomy and `PM_LABEL_RULES` alongside it ([labels.md § Preflight](../references/labels.md#preflight)). A failed Linear read on this or any later step halts the analysis with its diagnostic ([SKILL.md](../SKILL.md) § Execution Rules) — never work around it with a partial read. Every `agent_mismatch`, `label_cooccurrence`, `recommended_issue.labels[]`, and `create_fields.labels[]` recommendation must be expressible against this live inventory. Issue labels only.

### 1.3 Fetch Projects

Fetch every project in ONE command. `projects list --state` matches one state type exactly and never a comma list, so omit it and read each row's own `state`; ignore `canceled` rows and every row § 1.1.1 scopes out.

```bash
.agents/skills/linear/scripts/linear.sh projects list --max
```

**GitHub — explicit degradation**: record an empty project set and leave every project-placement field (`recommended_project`, `wrong_project`, project moves) null or omitted with reason `github: no project inventory`. Never invent a placement; scope fit checks to the repository backlog from § 1.5.

### 1.4 Fetch Input Issues

```bash
.agents/skills/linear/scripts/linear.sh issues list --team "[TEAM]" --project "[PROJECT]" --state "Backlog,Todo,In Progress,In Review,Verifying" --max   # project mode
.agents/skills/linear/scripts/linear.sh issues list --team "[TEAM]" --all-projects --state "Backlog,Todo,In Progress,In Review" --max               # team mode
.agents/skills/linear/scripts/linear.sh issues bulk-get [ISSUE_ID_1] [ISSUE_ID_2] --format=safe                                     # issues mode, one call
gh issue view [N] --repo [REPOSITORY] --json number,title,body,labels,state,url                                                           # issues mode, github
```

Pass `--team` on every `issues list` in this workflow to filter on the server; retain the § 1.1.1 scope check on returned rows. Issues mode fetches the whole input set in one `bulk-get`, never one call per issue; a lone input issue is `issues get [ISSUE_ID]`. With no existing-issue entry in `INPUT_ITEMS`, the input set holds no identifier and issues mode makes no § 1.4 read. `issues bulk-get` fails the whole read when an identifier names no issue, and compare the returned `id` values against every requested identifier besides: halt naming any input that is missing, which `issues get` on each input names. An unmatched target is a mistyped or deleted issue, never an absent one, and auditing the remainder would report a complete result over a subset. An input issue the caller named that resolves outside the § 1.1.1 scope halts the same way — Linear returns it, and auditing another team's issue is not the caller's to authorize.

The Linear issue payload carries `blocks`, `blocked_by`, `blocked_by_open`, and `related`. `blocked_by_open` decides whether an issue is blocked now; `blocked_by` remains the full relation history used by § 4. GitHub: read relations from body links (`Blocks: #N`, `Blocked by: #N`, `Related: #N`, `Parent: #N`). Proposed items use their provided fields directly.

### 1.4.1 Read Comments

Comments carry scope changes, supersession notes, and partial-completion reports. After § 1.5 returns, use its rows and the candidate signals in § 4 to select duplicate, relation, and supersession candidates. Read the active rows' bodies against § 6.2 to select cancellation candidates. Form one set of identifiers: the § 1.4 input set, every comparison row named as a duplicate, relation, or supersession candidate, and every active row § 6.2 proposes to cancel. Include closed candidates; their comments can explain supersession or cancellation. Read comments for this set before analysis assigns any disposition. Read no other comparison row's comments.

On Linear deduplicate the identifiers. When the set is empty, as in issues mode with only proposed entries and no candidate, make no `comments bulk-list` call: no selected issue has comments to read. Otherwise use one `comments bulk-list` call for the whole set. Never use one call per issue or parallel readers. The result is one object keyed by identifier. An issue with no comments reads as an empty list. A refusal carrying `missing` names identifiers Linear has no issue for, and halts as an unmatched § 1.4 target does; a failed read never reads as an issue with no comments. Dispositions stay active-only (§ 1.1).

```bash
.agents/skills/linear/scripts/linear.sh comments bulk-list [ISSUE_ID_1] [ISSUE_ID_2]   # TRACKER=linear
.agents/skills/linear/scripts/linear.sh comments bulk-list --stdin < [ID_FILE]         # TRACKER=linear, a large set, one identifier per line
gh issue view [N] --repo [REPOSITORY] --json body,comments                                    # TRACKER=github
```

### 1.5 Fetch Comparison Set

Fetch active comparison rows in one command:

```bash
.agents/skills/linear/scripts/linear.sh issues list --team "[TEAM]" --all-projects --state "Backlog,Todo,In Progress,In Review,Verifying" --max
```

Each row carries its own `project` name, empty for an issue with none. Discard every row outside the § 1.1.1 team scope before comparison. Never loop `--project` over the projects from § 1.3. Use the active set for duplicates, relations, supersessions, and the § 6 cancellation sweep. Verifying rows remain comparison evidence (§ 1.1).

For each input item, search closed rows by its title, target, or component terms:

```bash
.agents/skills/linear/scripts/linear.sh issues list --team "[TEAM]" --all-projects --state "Done,Canceled" --search "[TERMS]"
```

Do not add `--max` to a closed-row search or fetch the team's whole closed history. Retain the rows and any `linear-list: truncated` notice per input item. A truncated read limits that item's closed-row findings to the returned evidence; it never establishes that no match exists. Closed rows serve only as comparison evidence for duplicates, relations, and supersessions (§ 1.1); they take no disposition. A parent's child counts use § 7.3, not these search results. Read comments for the selected set per § 1.4.1 before proceeding.

**GitHub**:

```bash
gh issue list --repo [REPOSITORY] --state all --limit 200 --json number,title,state,labels
```

The same stated cap applies: past 200 issues the comparison set is partial, and every duplicate, supersession, and obsolescence finding is scoped to what it holds.

### 1.6 Extract Project Definitions

**Skip if** TRACKER=github — treat the repository as one scope.

Read the project map: `.agents/skills/linear/scripts/linear.sh projects audit --team "[TEAM]"`, kept for § 3 and § 6.3. A map repository's project definitions are the entries of the `### Project map` block rendered in this skill's project instructions, each with its `kind`, `admits`, and `ends_when` or `role` ([project-map.md § Declaration](../references/project-map.md#declaration)); each entry's Linear id is the audit's `projects[].id`. A run whose audit returns `map-absent` has no map: for each project from § 1.3, extract from name, description, and content its **purpose** (implementation, testing, refactoring, validation), the **work type** that belongs in it, and the **components** it owns.

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

Map every finding of the § 1.6 audit that this mode keeps, map or no map, to output per [project-map.md § Audit](../references/project-map.md#audit), with each `to` from [§ Routing](../references/project-map.md#routing). With no map that is the one `map-absent` finding, which goes to `map_findings[]`. With no map, also verify each issue matches the target project's definition from § 1.6 — wrong work type, wrong scope, or content contradicting the project's stated purpose all go to `wrong_project[]`. In team mode the target is the project named on the issue's own row; a row with project `""` gets a `wrong_project[]` entry with `from: null` recommending the project its scope fits, or an `analysis[]` note when nothing fits.

Then trace what depends on this project's output: list what it modifies, find which projects build on or test those modifications, and record any missing project relation in `project_dependency_issues[]` as `{from_project, to_project, current_relation, should_be, reason}`. Project relations come from this scope analysis only, never bottom-up from individual issue relations.

---

## 4. Identify Candidate Pairs

Do not compare every pair. Build candidates from signals: same target component, same parent, one issue naming another's ID, creates-consumes overlap, same file path in the location field, and any existing tracker relation (which must be verified). When two issues share a file path, grep for the shared structs or functions.

### 4.1 Verify Existing Relations

A relation on a Done issue is a valid historical record. Flag it for removal only when the dependency itself is wrong (no creates-consumes), not for the source being Done.

**Completed-blocker relations are auto-satisfied, never stale** (the owning rule: linear SKILL.md § Blocked Label vs Issue Relations). Do NOT add such relations to `remove_relations[]` except as a § 4.2 `Violation:` removal, and do NOT report them under any stale-metadata heading. When `blocked_by` is non-empty and `blocked_by_open` is empty, emit the one legitimate finding: `ready_to_schedule[]` in project mode, or "gates cleared, ready to schedule" in the issue's `reason` in issues mode.

### 4.2 Scan Relation Violations

Iterate every `blocks`/`blocked_by` on the input issues and their children. A relation is misplaced only when linear SKILL.md § Blocked Label vs Issue Relations refuses it.

**Preserve blocking relations by fixing the structure**, never by deleting them. For each violation: add the child relation to `remove_relations[]` with reason `"Violation: [TYPE] — [FROM] [REL] [TO]"`, which the apply step removes with `issues remove-relation --peer-rule-violation` (the one route past the completed-blocker refusal, linear SKILL.md § Blocked Label vs Issue Relations), add the lifted parent-level relation to `add_relations[]`, and add `related` between the original children. See [dependencies.md](../references/dependencies.md) for the level rule.

---

## 5. Analyze Candidate Pairs

### 5.1 Dependencies

Merge four sources: creates-consumes analysis (does B consume what A creates?), caller hints in `blocks_items`/`blocked_by_items`/`blocks_issues`/`blocked_by_issues`, text-named prerequisites (each issue a proposed item's text names as work it builds on or waits for, a `blocked_by` hint), and cross-domain sequencing between siblings with different agent domains (a relation only when data flow is confirmed). Validate both kinds of hint against the contracts: carry valid hints, drop contradictions.

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
| Routed agent | Apply [labels § Label drift check](../references/labels.md#label-drift-check) against the repository's effective install | Stop and return its installation evidence to the caller. An installation failure alone is not `agent_mismatch[]` |
| Label co-occurrence | An issue missing a required taxonomy category whose title or description matches 2+ detection signals for it | `label_cooccurrence[]`: `{id, title, present, missing, reason}` |

Validate every recommended replacement against the § 1.2 inventory first. If the desired label does not exist or is a parent/group label, state the failure in `reason` and recommend no mutation.

---

## 6. Duplicates, Supersession, and Obsolete

This is the cancellation sweep. No mode that reaches this section skips it.

### 6.1 Duplicates and Supersession

Compare each input issue against the § 1.5 active set and its own closed search results. Same problem plus same approach is a duplicate (`duplicates[]`) whatever project it lives in; same problem with a genuinely different approach keeps both with a `related` link. When title and keyword matching finds nothing, extract the module or component name from the location field and search on that. Keep closed-row conclusions within that item's returned evidence and report any truncation; a truncated search is not proof of no match. Closed rows take no disposition (§ 1.1).

When an input item's scope **fully covers** an existing issue, that is `supersedes[]` on the input item, not `duplicates[]`, subject to § 7.0's contract-parent scope transfer. Signals: the item's `decision_ref` supersedes the existing issue's governing decision, the item's `creates[]` is a superset of the existing deliverables, or the existing issue references a superseded decision.

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

1. Re-read every Backlog, Todo, In Progress, and In Review issue in the § 1.5 active set against the creation bar's first and third tests as they stand today (the second, coverage by other work, is not reapplied: an issue always covers itself). Verifying rows keep their live checks (§ 1.1). A parent with an open child is never a below-bar cancel: the bar does not apply to a container, which stays open while a child is open (§ 7.3).
2. One that fails (the bar's own list, not restated here) is a cancellation with confidence 100 and evidence `{below_bar: true, test, who_hits_it}`: `test` names the failed test, `who_hits_it` is the one-line user story and how often a user meets it, written after reading the issue's body and its § 1.4.1 comments (on GitHub, `gh issue view [N] --repo [REPOSITORY] --json body,comments`; the § 1.5 list carries neither).
3. In project mode it is an `obsolete[]` entry; in issue mode it is the issue's own `issues[]` entry with `action: "cancel"` and that evidence in its `obsolete` field.
4. The bar's two exceptions (a shipped-path security or data-loss defect; a critical-harm or financial-loss edge case) never go here on likelihood; the third test still applies to them.
5. The code-verification rule above is for implementation-obsolete entries; a `below_bar` entry is verified by reading the body and, where it names a path, producer, or regression, checking that claim in the repository before the entry is written.

### 6.3 Project Fit

Compare each input issue against every project definition. A scope matching another project better, or a child sitting in a different project from its parent, goes to `wrong_project[]`. A dependency on work in another project is recorded as a relation, not a move. The current assignment is not evidence. In a map repository the project an item belongs in is the one [project-map.md § Routing](../references/project-map.md#routing) names, and an item it routes to none is a `project_needed[]` entry. With no map, a team-mode row with project `""` carries no assignment to weigh — recommend the project its scope fits.

---

## 7. Hierarchy

### 7.0 Hierarchy Contract (Binding)

**Skip if** the input has no `hierarchy_contract`.

`HIERARCHY_CONTRACT` is a directive, not a hint. For every item whose `index` is in `HIERARCHY_CONTRACT.child_indexes`:

- Ordinary hierarchy inference (§§ 7.1-7.2) and the duplicate/overlap action downgrades of § 6.1 are BYPASSED for the item's action and placement. § 6.1 still runs for evidence — it populates `supersedes[]` and `related` — but never changes the action.
- The output MUST be `action: "create"` with `hierarchy: {"action": "make_child", "parent": [HIERARCHY_CONTRACT.parent_issue]}` and `project.recommended` equal to the contract parent's project.
- The item MUST NOT resolve to `skip`, `expand`, `update`, `combine`, or `cancel`. When the contract parent carries scope belonging to the item, move that scope into the new domain child with a `related` relation and note the transfer in `reason`, even for full coverage. Remove the contract parent from `supersedes[]`, including confirmed input entries: transferring its implementation scope never authorizes its cancellation. For another existing issue, record `supersedes[]` on the child for full coverage or a `related` relation for partial overlap. Never emit an update of the existing issue in place of the child create.
- The contract parent becomes coordination-only (the caller converts it). It is never one domain's implementation leaf and never an `update`/`expand` target for covered scope.
- Apply `HIERARCHY_CONTRACT.sequencing[]` as `blocks` relations between the created children, using `#N` batch references.

Items outside `child_indexes` — `origin: "discovered"` refactors, for instance — are audited normally.

### 7.1 Identify Candidates

`parent_issue` and `blocked_issues` are hints the analysis may override; `hierarchy_contract` is binding per § 7.0. A research issue never appears in `parent_issue`.

Look for: an input item whose scope is a strict subset of a tracked effort (child candidate); and a parent candidate under [SKILL.md § Disposition](../SKILL.md#disposition)'s rework-parent rule. Group on outcome or mechanism, not size.

This run is itself an audit. When it proposes more than one create, it files one rework parent for its subject first: a `create` with `create_fields.is_bundle_parent: true` built from [parent-issue-template.md](../templates/parent-issue-template.md), and every other create a `make_child` whose `parent` is that row's `#N`. The rework parent is `hierarchy.action: none`, with a `related` relation to the input's `parent_issue` when one exists. When the input's `parent_issue` names the rework parent already, every create is a `make_child` with `parent: null` instead. Two exceptions:

- **The review audit's in-PR bundle.** With the input's `in_pr_bundle` true, each child candidate of its `parent_issue`, the issue being worked, is a `make_child` with `parent: null`: the caller marks that issue its in-PR bundle root and works the child in that issue's own PR. These children count toward no rework parent; only the remaining creates do.
- **A hierarchy contract.** With `hierarchy_contract`, its parent is the run's rework parent: each `child_indexes` item is its child per § 7.0, and the run files no second rework parent.

Outside these two exceptions and a `parent_issue` that names the rework parent already, no create is a `make_child` under the input's `parent_issue`, whatever the `source`: an issue being worked that gains a child becomes a container. A child candidate of it joins the run's rework parent, or as the run's one create is `hierarchy.action: none` with a `related` relation to it.

Parent and child must share a project. If they cannot, record `wrong_project[]` or keep the issue standalone with a relation. Under a project map, [project-map.md § Routing](../references/project-map.md#routing) says which.

### 7.2 Evaluate Coherence

Ask: **would these ship together in one PR?** Yes means one leaf work item with an internal checklist, never a parent: a `combine` (§ 8). No means a container with sibling child-blocks-child relations for ordering.

Lean sub-issue for tests of the feature being implemented, hardening for the component being built, and platform work under a same-platform parent. Lean independent for platform-specific work under a cross-platform parent, tooling or methodology under a feature parent, and anything that could ship before or after the parent. When uncertain, prefer independent with a blocking relation.

### 7.3 Parent Scope Coverage

**Skip if** MODE = issues.

For each parent with children: implementation scope left in the parent (`## Requirements` rather than `## Sub-Issues`) is an `analysis[]` note; a `## Sub-Issues` list that disagrees with the actual children is a `hierarchy[]` entry with action `update_parent_desc`; children spanning 2+ agent domains under a parent lacking the project's multi-agent label is an `agent_mismatch[]` entry, recorded only after validating the replacement label exists.

Read each parent's actual direct children with `issues children [PARENT_ISSUE_ID] --format=safe`, without `--pending`. Count its Done and Canceled children from that read. Neither the § 1.5 active set nor an input item's closed search results establishes a parent's full child set. Closed children remain historical evidence and take no disposition (§ 1.1). A parent with an open child is kept. A non-terminal parent whose children are all Done or Canceled is a `hierarchy[]` `close_parent` entry, unless its `issues get --format=safe` read reports `in_pr_bundle`: the review audit's in-PR bundle root is a work item its own PR completes.

Record findings as `findings.hierarchy[]` in project mode — `make_parent` (`issue`, `children[]`), `make_child` (`issue`, `parent`), `bundle` (`issues[]`, `new_parent_title`), `update_parent_desc` (`issue`), `close_parent` (`issue`) — or as each issue's `hierarchy` field in issues mode per [audit-output.md](../schemas/audit-output.md). Include the coherence reasoning in `reason`.

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

Recommend a new project in `project_recommendations[]` for architecture gaps only when 3+ related gaps form a subsystem larger than 8 points with no existing fit (an item that fits no map project is `project_needed`, § 6.3); recommend reopening a completed project only when a gap matches its scope and blocks active work or leaves its deliverables incomplete.

---

## 10. Determine Actions

**Skip if** MODE = project.

### 10.1 Apply the Creation Bar

For every source, including `oversee`, proposal-sweep, and audits, apply reviewer/references/finding-disposition.md § Decision flow Step 0 before the creation bar. Each proposed item then passes only if it clears all three tests in [SKILL.md](../SKILL.md) § Disposition and has clear scope, testable criteria, and defined deliverables. Preserve that section's security, data-loss, critical-harm and financial-loss exceptions. A reproducible anomaly with evidence attached passes as an investigation issue whose deliverable is the diagnosis. A failure is `skip` with a one-line reason naming the test it failed: `"refactor with no behaviour change or user-visible work unblocked"`, `"size or ceiling warning"`, `"hypothetical no run reached"`, `"no user-visible effect"`, `"covered by [ISSUE_ID]"`, `"no evidence to start from"`, or `"too vague — [missing criterion]"`. Carry that reason into the report; a no-behaviour-change refactor filed through `--single` returns `skip`, not `create`.

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

For every `create`: populate `create_fields` per [audit-output.md](../schemas/audit-output.md) with the full `labels[]` [labels.md § Creates Carry the Full Set](../references/labels.md#creates-carry-the-full-set) selects from § 1.2 — an action that can only supply `agent`/`agent_label` is left blocked with a clear `reason`. Its `add_relations` carries every relation § 5.1 keeps for the item; in single mode, which skips § 5, it carries the ones § 14 step 4 confirms. audit-issues § 7.2 persists them with the create. `reach` is the producer the input item's `impact` names — the same line the filing bar reads, never re-derived from the finding. `review_born` is true when `SOURCE` is `review`, `pr-comments`, or `local-review`, false otherwise; a `review_born` create at priority 2 also carries `symptom` from the input item, and is left blocked with a `reason` when the item states none. `regressed_by` is the input item's, copied as written and omitted when the item has none. Preserve confirmed input `supersedes[]` entries and their `when`, subject to § 7.0's contract-parent scope transfer; verify entries carry `identifier`, `title`, and `reason`, and set `summary.superseded` to the total. When `SOURCE == "research-complete"` and `RESEARCH_ISSUE` is set, add it to `add_relations.related[]` on every `create`.

---

## 11. Project Order Mode

Entered from § 1.1 after § 1.1.1; §§ 2-10 do not apply. Every project, initiative, and issue read below is filtered to the § 1.1.1 scope first: an initiative naming another team's projects contributes none of them, and a project whose `teams[]` omits `TEAM` is neither ordered nor recommended.

1. **Fetch** initiatives (`initiatives list --max`) and projects in every state (§ 1.3), recording `id`, `name`, `state`, `progress`, `sort_order`, `blocked_by[]`, `blocks[]`, `description`, `content`, plus each initiative's project names. Build the name→initiative map that fills each project's `initiative` field. Read the project map as § 1.6 does, kept for step 5.

2. **Assign a layer** to each `planned` and `backlog` project (never `started` or `completed`) from its scope: what it delivers, what it consumes, and what its issues touch (`issues list --team "[TEAM]" --project "[PROJECT_NAME]" --state "Backlog,Todo,In Progress" --max`). Verify against the architecture docs that deliverables do not depend on unbuilt code. L0 foundation (no project dependencies) → L1 core infrastructure → L2 features → L3 integration and testing → L4 polish and release.

3. **Order** by topological sort on layer, then dependency edges (A's deliverables consumed by B means A precedes B), then priority.

4. **Compare to current, per state column.** `sortOrder` is relative **within one column only**. Execution order is started → planned top-to-bottom → backlog top-to-bottom. Current position: started = 0, then planned by `sortOrder`, then backlog by `sortOrder`. For each mismatch, decide whether the project is in the wrong state (recommend a state change) or the wrong position within its state (recommend a reorder), and compute `new_sort_order` with spacing per state column.

5. **Detect transitions**: read each `started` project's open items by its recorded `id`, the read [project-map.md § Project kinds](../references/project-map.md#project-kinds) defines; `progress` is no such read. A `started` project with no open item left that § Project kinds lets complete is a `complete_candidates[]` entry noting what it unblocks, with the `ends_when` evidence for a map deliverable; a map deliverable that rule holds open is a `complete_held[]` entry; assuming reorders applied, the first `planned`/`backlog` project with no incomplete blockers is `recommended_next` — null with a `rationale` listing each candidate's blockers when nothing is ready. Its `blocked_by_active` names the started project that holds activation by [§ Project kinds](../references/project-map.md#project-kinds): one that counts as active and is no `complete_candidates[]` entry, a `complete_held[]` deliverable included; null when none does.

Return per § 13 with the `tmp/audit-project-order-YYYYMMDD-HHMMSS.json` hint and the project-order schema in [audit-output.md](../schemas/audit-output.md).

---

## 12. Pre-Output Verification

**Skip if** MODE = project-order — §§ 2-10 built none of these (§ 1.1). MODE = single checks the team-prefix and proposed-item rows only.

Any invariant failing sends you back before the JSON is built.

- [ ] Every input issue has its own `VERIFICATION_CONTEXTS[ISSUE_KEY]` — no PR, branch, or resolved path set reused across issues, docs-only handled explicitly (§ 1.7, § 2.1)
- [ ] No completed-blocker relation appears in `remove_relations[]` outside a § 4.2 `Violation:` entry, or under any stale-metadata framing (§ 4.1)
- [ ] The § 6 cancellation sweep ran against the § 1.5 active set; closed rows took no disposition, and each input item's closed-row findings report and respect any search truncation
- [ ] TRACKER=linear: when the § 1.4.1 set is non-empty, one comments read covered the input set, candidate duplicate/relation/supersession rows, and every active cancellation candidate; an empty set made no read
- [ ] TRACKER=linear: every issue named anywhere in the output carries the § 1.1.1 team prefix, except an `add_relations.related` entry, which the linear skill's Blocked Label vs Issue Relations section lets name an issue in another team
- [ ] Every proposed item carries an assigned action, with a one-line reason naming the failed creation-bar test on each `skip`, and on each `create` a complete `create_fields.labels[]`, a `reach`, a `review_born`, and a `symptom` where `review_born` is true at priority 2 (§ 10)
- [ ] Every `hierarchy_contract.child_indexes` item is `action: create` + `hierarchy.action: make_child` + `hierarchy.parent` = the contract parent, none downgraded (§ 7.0, § 10.2)
- [ ] More than one create follows § 7.1's rework-parent rule: its placement, its children and its two exceptions; no create is a `make_child` under the input's `parent_issue` outside § 7.1's cases; no parent with an open child is cancelled, and every parent whose children are all Done or Canceled is a `close_parent` entry unless its safe read reports `in_pr_bundle` (§ 6.2, § 7.3)

---

## 13. Return Output

Build the JSON per [audit-output.md](../schemas/audit-output.md) and set the destination hint to `tmp/audit-project-YYYYMMDD-HHMMSS.json`, `tmp/audit-team-YYYYMMDD-HHMMSS.json`, `tmp/audit-issues-YYYYMMDD-HHMMSS.json`, `tmp/audit-single-YYYYMMDD-HHMMSS.json`, or `tmp/audit-project-order-YYYYMMDD-HHMMSS.json` for the mode.

Return the JSON inline. Do not write the artifact yourself.

<output_format>
File: tmp/audit-[MODE]-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>

---

## 14. Single-Item Mode

One filing: the creation bar, a title-level duplicate check, explicit supersession and relation confirmation, the label set and the placement, then § 12 and § 13. No other section runs: no contracts, no inferred relation or hierarchy analysis, no comparison-set bodies, and no § 6 cancellation sweep.

1. **Input.** Read the file as § 1.1 reads `issues` mode. It holds exactly one `items[]` entry and no `hierarchy_contract`; any other shape halts naming the item count, and the caller runs `--issues`.
2. **Scope and labels.** § 1.1.1, then § 1.2.
3. **Placement.** Linear: the § 1.3 command, then the project whose name and description fit the item's `location`; in a map repository, the § 1.6 map read and [project-map.md § Routing](../references/project-map.md#routing), with `project_needed` when it routes to none. GitHub: § 1.3's degradation.
4. **Duplicates by title, explicit supersession and relation confirmation.** One read of the open titles; keep only rows § 1.1.1 scopes in:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues list --team "[TEAM]" --all-projects --state "Backlog,Todo,In Progress,In Review,Verifying" --max --format=compact   # TRACKER=linear
   gh issue list --repo [REPOSITORY] --state open --limit 200 --json number,title                                                                                     # TRACKER=github
   ```

   Read `id` and `title` from each row, `number` and `title` on GitHub; neither read takes a pipe, under orch's one-simple-command rule ([orch SKILL.md § Harness-Safe Shell](../../orch/SKILL.md#harness-safe-shell)). Check every input `supersedes[].identifier`, every `blocks_issues` and `blocked_by_issues` identifier, and every issue the item's text names as work it builds on or waits for against this same read, with no second tracker list. A Verifying row confirms a relation, never a supersession. Echo each confirmed `supersedes[]` identifier, its title, reason and `when` into the create row's `supersedes[]`. Echo each confirmed `blocks_issues` identifier into its `add_relations.blocks`, and each confirmed `blocked_by_issues` identifier or text-named prerequisite into `add_relations.blocked_by`. Report each absent identifier in the row's `reason` as not touched and omit it from `supersedes[]` and `add_relations`. A confirmed explicit supersession is disposed by its `when`, not treated as a duplicate title. Another title naming the item's problem makes the item `skip` with that issue as `target` and reason `covered by [ISSUE_ID]`. Read a matched issue's body (`issues get [ISSUE_ID]`, or `gh issue view [N] --repo [REPOSITORY] --json body`) only when its title alone leaves the match open; read no other body.

5. **Action.** § 10.1, then `create` or `skip`; no other action. A `create` fills `create_fields` per § 10.2, with `hierarchy: {"action": "make_child", "parent": null}` when the input's `parent_issue` names a rework parent, else `{"action": "none", "parent": null}`.

Return per § 13: `mode: "single"` in the issue-mode shape of [audit-output.md](../schemas/audit-output.md), one `issues[]` row.
