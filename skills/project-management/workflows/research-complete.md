# Research Complete Workflow

Link completed research to blocked issues, analyze impact, create follow-up work.

## Inputs

| Command | Flow |
|---------|------|
| `research-complete [ISSUE_ID]` | § 1 → § 2 → § 3 → § 4 → § 5 → § 6 |

## 1. Get Research Details

### 1.1 Ensure Researcher Findings Committed

1. **Check for uncommitted files** in project research docs for `[ISSUE_ID]/`.

2. **If uncommitted**: The findings may have been written by `agent:researcher`. Ask user whether to commit now, then run `git add [RESEARCH_DOCS_PATH]/[ISSUE_ID]/ && git commit -m "chore([ISSUE_ID]): Add research findings"`.

### 1.2 Fetch Issue Details

1. **Fetch issue**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
   ```

2. **Read findings**: project research docs `[ISSUE_ID]/findings.md`. Briefly summarize key findings. If missing, route back to `research-issue.md § 4 Delegate to Researcher` instead of asking the user to execute research externally.

3. **Capture researcher metadata**: Prefer `[RESEARCH_DOCS_PATH]/[ISSUE_ID]/raw-exa.json`; fallback to `[RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.raw.json`. Parse JSON `.metadata` for `researchMode`, `type`, `queryCount`, `sourceCount`, `uniqueSourceCount`, `elapsedMs`, and `rawOutputPath`. Treat `agent:researcher` as the producer unless issue history says otherwise. `findings.md` should only contain a compact `Research Metadata` section, never raw JSON.

## 2. Ensure Domain Labels

Load issue-label inventory and project taxonomy before inspecting or updating labels:

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

Use issue labels only. Domain/stack labels, `agent:*`, and workflow/classification labels must be validated against [labels.md](../references/labels.md) before any update.

Unknown labels, parent/group labels, missing required categories, or exclusivity violations halt before mutation.

**Two distinct concepts**:

| Concept | Purpose | Example |
|---------|---------|---------|
| **Domain labels** (issue tracker) | Agent routing, type detection (1 = Targeted, 2+ = Pervasive) | domain-specific labels |
| **`## Affected Domains` section** (description) | Documents *why* each domain is affected | `- [domain]: [REASON]` |

Domain labels are always required and determine routing. The description section is documentation only (appears for Pervasive/Strategic).

From § 1 response, check `.labels` array for domain/stack labels.

**If no domain labels present** (common for research spikes):

1. **Analyze `findings.md`** content for domain indicators -- infer from component paths (project-configurable).

2. **Update labels** (must include existing + new): compute `FINAL_LABELS = EXISTING_LABELS + INFERRED_LABELS`, preserve unrelated labels, preflight final labels, then update.
   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --labels "[FINAL_LABELS]"
   ```

3. **If unclear or multi-domain** → add all likely domains; routing handles escalation

## 3. Determine Research Type

From § 1 response, count domain labels and check description for Strategic indicator:

| Condition | Type | Flow |
|-----------|------|------|
| Has `## Creates Roadmap` | Strategic | § 5.3 |
| 2+ domain labels | Pervasive | § 5.2 |
| 1 domain label | Targeted | § 5.1 |

**Note**: `## Affected Domains` section in description is documentation only; routing uses label count.

## 4. Link Research to Blocked Issues

**Skip if** no blocking relations (self-initiated spike).

From § 1 response, check the `.blocks` array for blocked issue identifiers.

For each blocked issue:

1. **Get current description**: `.agents/skills/linear/scripts/linear.sh cache issues get [BLOCKED_ISSUE_ID]`

2. **Check existing**: If path to findings already exists in description (single-line OR list format) -- skip if present.

3. **Update description** with research reference at top (see format below).

4. **Propagate to children**: Get sub-issues and apply same update:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues children [BLOCKED_ISSUE_ID] --recursive --format=safe | jq -r '.[].id'
   ```
   For each child: repeat steps 1-3 (skip if reference already present)

**Format** (always at top of description):
```
**Research**: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md

[rest of description...]
```

**Multiple references** (convert to list, keep at top):
```
**Research**:
- [RESEARCH_DOCS_PATH]/[issue-1]/findings.md (brief topic)
- [RESEARCH_DOCS_PATH]/[issue-2]/findings.md (brief topic)

[rest of description...]
```

## 5. Route to Workflow

Execute ONE flow based on § 3 unless meets escalation criteria as defined.

### 5.1 Targeted Flow

1. **Identify domain agent** -- infer from component paths (project-configurable).

2. **Delegate to domain agent** from step 1. Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

   <delegation_format>
   Analyze impact of research findings on your domain.

   Read: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md

   Analyze:
   1. Existing code/patterns that must change (paths, components)
   2. Breaking changes to APIs or contracts you own
   3. Cross-domain impact (does this affect OTHER domains? yes/no + which)

   Report with tables:
   - Decision content: summary, rationale, revisit conditions
   - Technical changes: | Type | Description | Est | Paths | QA Triggers |
   - Supersedes: topics/patterns this replaces
   - Refactors: existing code referencing superseded patterns, independent of new implementation | Path | Old → New |
   - Doc/config updates: | Path | Change |
   - Cross-domain impact: yes/no + which domains
   - Scope: refactor-level or initiative-level?
   </delegation_format>

3. **Check for escalation**
   - If cross-domain impact reported:
     - Add domain labels from agent report: compute `FINAL_LABELS = EXISTING_LABELS + NEW_DOMAINS`, preflight against § 2 inventory/taxonomy, then `.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --labels "[FINAL_LABELS]"`
     - Update issue description -- append `## Affected Domains` section with domains from agent report
     - **Switch to § 5.2**. Do not assess severity--let each affected domain analyze its own impact.
   - If initiative-level scope (10+ issues, needs phasing):
     - Ask user: "Research scope suggests a new initiative. Escalate to /roadmap create?"
     - If yes:
       - Update issue description -- append `## Creates Roadmap` section
       - **Switch to § 5.3**

4. **→ Jump to § 6**

### 5.2 Pervasive Flow

1. **Delegate to each affected domain agent** from issue labels (parallel sub-agent calls). Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

   <delegation_format>
   Analyze impact of research findings on your domain.

   Read: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md

   Analyze:
   1. Existing code/patterns in your domain that must change
   2. Breaking changes to APIs or contracts you own

   Report with tables:
   - Decision content: summary, rationale, revisit conditions
   - Technical changes: | Type | Description | Est | Paths | QA Triggers |
   - Supersedes: topics/patterns this replaces
   - Refactors: existing code referencing superseded patterns, independent of new implementation | Path | Old → New |
   - Doc/config updates: | Path | Change |
   </delegation_format>

2. **Delegate to architecture review agent** for cross-cutting synthesis. Follow exactly, fill placeholders, add nothing else. Omit lines/sections with empty placeholders.

   <delegation_format>
   Synthesize domain agent reports into cross-cutting impact analysis.

   Read: [RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md

   Domain reports:
   [summaries from step 1]

   Report with tables:
   1. Unified decision content: summary, rationale, revisit conditions
   2. Documentation drift: | File | Issue | Severity |
   3. Conflicting issues: | Issue | Conflict | Resolution |
   4. Cross-module dependencies (diagram or bullets)
   5. Breaking changes at module boundaries
   6. Prioritized issues: | # | Description | Est | Dependencies | Domain |
   7. Scope: refactor-level or initiative-level?
   </delegation_format>

3. **Check for escalation to Strategic**
   - If architecture review agent reports initiative-level scope (10+ issues, needs phasing):
     - Ask user: "Research scope suggests a new initiative. Escalate to /roadmap create?"
     - If yes:
       - Update issue description -- append `## Creates Roadmap` section
       - **Switch to § 5.3**

4. **→ Jump to § 6**

### 5.3 Strategic Flow

1. **Determine feature name and origin context**

   Extract `$FEATURE_NAME` from research topic (issue title without "Research:" prefix).

   **Identify origin issue**: From § 1 `.blocks` array, if there is a single blocked issue, it is the origin issue for hierarchy analysis. Fetch its details:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues get [BLOCKED_ISSUE_ID]
   ```
   Store as `$ORIGIN_ISSUE` (id, title, project). If multiple blocked issues or none, set `$ORIGIN_ISSUE` = null.

2. **Run roadmap planning**

   Run Workflow: `⤵ workflows/roadmap-plan.md $FEATURE_NAME @[RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md --origin-issue $ORIGIN_ISSUE § 1-8 → § 5.3`

   The `--origin-issue` flag passes blocked issue context so the TPM can determine whether created issues should be children of the origin issue or standalone. Creates plan file at project roadmap docs path. User approves plan.

3. **Run roadmap creation**

   Run Workflow: `⤵ workflows/roadmap-create.md @[PLAN_PATH] § 1-9 → § 6`

   Creates initiative/project/issues in issue tracker. Uses TPM's `hierarchy_recommendation` to set parent/child structure.

4. **→ Jump to § 6**

   Note: For Strategic, issue creation happens in `workflows/roadmap-create.md`. § 6 handles DXXX recording and doc/config updates only.

## 6. Complete (Common Steps)

All flows converge here. Orchestrator executes these steps using agent reports.

### 6.1 Record Decision

Follow the decider skill's create-decision workflow:

1. **Get next ID**: `.agents/skills/decider/scripts/decisions next-id`

2. **Select template** from the decider skill's `templates/decision-entry.md` based on scope:
   - Minimal (15-30 lines): single technology choice, clear winner
   - Standard (80-200 lines): multiple alternatives, patterns to document
   - Comprehensive (200-600 lines): architecture-level, multi-concern

3. **Create file** `[project decision documents]/[DECISION_ID]-[DESCRIPTOR].md` per selected template.

   Keep tight — reference research for details.
   - **Research**: `[RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md`
   - **Summary**: 1-2 sentences
   - **Rationale**: Key reasons, bullets preferred
   - **Impact**: Key impacts from this research on existing/future work
   - **Revisit**: When to reconsider

   See the decider skill's `schemas/decision-format.md` for required elements and formatting rules.

4. **Add row** to project decision documents INDEX.md table per the decider skill's `templates/index-row.md`.

5. **Update partially superseded decisions** per the decider skill's update-decision workflow: If the new decision's Context references other active decisions as partially affected (e.g., "D011 specified ThreadBound..."):
   - Read referenced decision file
   - If new decision replaces specific components but not the whole: update status to `Active ([COMPONENTS] → [NEW_DECISION_ID])` in both the decision file and INDEX.md row

### 6.2 Append Decision to Blocked Issues

**Skip if** no blocking relations.

Update blocked issues (from § 1 `.blocks` array) to append DXXX to existing Research lines added in § 4.

For each blocked issue:

1. **Get current description**: `.agents/skills/linear/scripts/linear.sh cache issues get [BLOCKED_ISSUE_ID] | jq -r '.description'`

2. **Check if** `**Decision**: [DECISION_ID]` already exists -- skip if present

3. **Find research path** in description (single-line OR list format)

4. **Add decision reference** `**Decision [DECISION_ID]**: [project decision documents]/[DECISION_ID]-[DESCRIPTOR].md` after the Research block (after list if multiple refs)

5. **Update**: `.agents/skills/linear/scripts/linear.sh issues update [BLOCKED_ISSUE_ID] --description "..."`

6. **Propagate to children**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues children [BLOCKED_ISSUE_ID] --recursive --format=safe | jq -r '.[].id'
   ```
   For each child: repeat steps 1-5

### 6.3 Apply Doc/Config Updates

**Implement changes** from agent reports:
- Update architecture docs as described
- Add DXXX references to affected files
- If agents reported reusable rules or project-specific insights, add to `./vstack.toml` (`[skill-instructions]` for skill-level context, `[agent-additional-instructions]` for persistent agent rules, `[agent-launch-instructions]` for launch/startup instructions)
- Run `vstack refresh` to apply config
- For Pervasive: combine updates from all domain agents

### 6.4 Extract Requirements

**Skip if** Strategic type (roadmap creation handles issues).

For each blocked issue (from § 1 `.blocks` array), build complete requirements list by merging:
- **Existing**: Parse blocked issue's current `## Requirements` section
- **Research**: New/refined requirements from decision (§ 6.1) + agent reports (§ 5.1/5.2)
- **Superseded**: Drop existing requirements that the decision explicitly replaces

Each requirement = one bullet with: description, domain, and estimate.

**Separate refactors**: Agent-reported refactors (independent cleanup of superseded patterns) are NOT merged into blocked issue requirements. These go to the audit input as standalone items in § 6.5.

### 6.5 Decompose into Sub-Issues

**Skip if** single domain -- write requirements into issue description (§ 6.6) instead.

Count distinct domains across merged requirements from § 6.4. If 2+ domains, decompose ALL requirements (existing + research-derived) into sub-issues -- parent becomes coordination-only:

1. **Group ALL requirements by domain** → one sub-issue per domain (including domains from original scope). Sub-issues must be in parent's project.
2. **Title format**: `[Domain verb]: [scope] for [DECISION_ID]` (e.g., "Implement GBM tick generator for D012", "Add order panel view for D012")
3. **Set labels**: full validated `labels[]` per sub-issue (`agent:[TYPE]` per domain plus required domain/stack/workflow/classification labels). Validate with § 2 inventory/taxonomy before writing the audit-input file.
4. **Determine blocking order**: Read [agent-sequencing.md](../../linear-orch/workflows/agent-sequencing.md). Record as `blocks_items`/`blocked_by_items` for step 6.
5. **Include supplementary findings** from agent reports as requirements in the appropriate domain sub-issue -- don't create separate issues for small supplementary items that belong to the same domain
6. **Build audit-input file** with formatted titles:
   - Schema: [audit-issues-input.md](../schemas/audit-issues-input.md)
   - `source`: "research-complete"
   - `parent_issue`: first entry from `blocked_issues` (if single), else null
   - `worktree`: current directory
   - `blocked_issues`: from § 1 `.blocks` array (for hierarchy hints)
   - `research_issue`: `[ISSUE_ID]` (the research issue being completed)
   - `research_ref`: `[RESEARCH_DOCS_PATH]/[ISSUE_ID]/findings.md`
   - `decision_ref`: `[DECISION_ID]`
   - Each `items[]` entry includes `labels[]` with the full validated issue-label set.
7. **Include refactors**: Add agent-reported refactors as additional items with `origin: "discovered"`, no `blocks_items`/`blocked_by_items`. TPM routes to appropriate project (typically Tech Debt) via § 6.3.
8. **Write file**: `tmp/audit-research-YYYYMMDD-HHMMSS.json`
9. **Run Workflow**: `⤵ workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6.6`

### 6.6 Update Blocked Issues

Update each blocked issue (from § 1 `.blocks` array) to reflect research outcomes:

1. **Get current description**: `.agents/skills/linear/scripts/linear.sh cache issues get [BLOCKED_ISSUE_ID] | jq -r '.description'`

2. **If children created (§ 6.5)** -- apply project-level templates parent-issue-template:
   - **Keep**: Research/Decision refs, Effort (rollup), Dependencies
   - **Replace `## Requirements`** with `## Sub-Issues` and `## Context` per template
   - **Remove** all implementation-level requirements (those now live in children)

3. **If no children (single issue)** -- write full requirements into description:
   - **Keep**: Research/Decision refs, Effort, Dependencies lines
   - **Replace**: vague summary with concrete scope from decision (1-2 sentences)
   - **Add `## Requirements`**: One bullet per deliverable from decision
   - **Add `## Context`**: Key constraints, cross-references

4. **Set parent label** to the project-configured multi-agent label (for example `agent:multi` when present) if children span 2+ distinct taxonomy `agent` domains. Compute final parent labels from current labels, replace only the `agent` category, preserve unrelated labels, preflight, then update.

5. **Update metadata** if research changed scope:
   - **Labels**: Add domain labels if cross-domain work discovered. Compute final labels from current labels + additions, preserve unrelated labels, preflight, then update.
   - **Estimate**: Adjust if research revealed significantly more/less work

6. **Invalidate parallel groups**: Description rewrites change issue scope, invalidating cached parallel-check results.
   ```bash
   for BLOCKED_ISSUE in [BLOCKED_ISSUES]; do
     .agents/skills/flightdeck/scripts/parallel-groups lookup $BLOCKED_ISSUE
   done
   ```
   For each group found, clear it: `.agents/skills/flightdeck/scripts/parallel-groups clear --group [GROUP_ID]`

### 6.7 Post Research Summary Comment

Post a comment on the research issue documenting completion:

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body "## Research Complete

### Decision
[DECISION_ID] - [SUMMARY]
- **Researcher**: agent:researcher
- **Deep Research Metadata**: mode=[researchMode], type=[type], queries=[queryCount], sources=[uniqueSourceCount/sourceCount], raw=[raw metadata path]
- **Rationale**: [BRIEF_RATIONALE]
- **Revisit**: [CONDITIONS]

### Created Issues
- [CREATED_ISSUE_ID]: [TITLE] (Pn) — [parent: [ISSUE_ID] | project if different]

### Doc Updates
- [PATH]: [CHANGE]

### Skipped
- [ITEM]: [REASON]"
```

**Omit empty sections.** If no decision recorded (informational research), replace Decision section with:
```
### Key Findings
- [2-3 bullet summary]

### Outcome
[what was learned/decided/no action needed]
```

### 6.8 Mark Research Done

```bash
.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --state "Done"
```

---

## 7. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — research completion processed.
