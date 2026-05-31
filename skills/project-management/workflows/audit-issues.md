# Issue Audit Workflow

Audit tracked issues and projects for relations, hierarchy, project placement, duplicates, and obsolete items. Delegate analysis to TPM, present findings, confirm changes, execute approved actions.

## Inputs

| Command | Mode | Target |
|---------|------|--------|
| `audit-issues project-order` | `project-order` | Project ordering & transitions only |
| `audit-issues project` | `project` | Active project (default) |
| `audit-issues project "Name"` | `project` | Specified project |
| `audit-issues issue [ISSUE_ID] [...]` | `issue` | Specific issue(s) |
| `audit-issues --issues [file_path]` | `issue` | Proposed issues from JSON file |
| `audit-issues --analyzed [file_path]` | `analyzed` | Pre-analyzed audit-output JSON (skips TPM) |

**When called by parent workflow** (start, research-complete, review-pr-comments):

`--issues [file_path]` -- JSON file with all context. Schema: [audit-issues-input.md](../schemas/audit-issues-input.md)

**Hierarchy**: TPM determines final placement using `parent_issue` from file + per-item analysis.

**Note**: Research issues should NEVER appear in `parent_issue`.

---

## 1. Determine Mode

### 1.1 Parse Arguments

Set MODE and TARGET from input:

| Input | Set |
|-------|-----|
| `project-order` | MODE=project-order, TARGET=null |
| `project` (no name) | MODE=project, TARGET=null |
| `project "Name"` | MODE=project, TARGET=Name |
| `issue [ISSUE_ID] [...]` | MODE=issue, TARGET=issue IDs |
| `--issues [file_path]` | MODE=issue, TARGET=file_path |
| `--analyzed [file_path]` | MODE=analyzed, TARGET=file_path |

**File mode**: Read JSON file, extract `source`, `parent_issue`, `worktree`, `items[]`.

**Analyzed mode**: Read pre-analyzed audit output (project-management skill schemas audit-output ISSUE mode format with embedded `create_fields` per issue and top-level `source`, `parent_issue`, `research_ref`, `plan_path`).

### 1.2 Ensure Cache Fresh & Query Status

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh session-status
.agents/skills/linear/scripts/linear.sh cache labels list --format=safe
```

Extract `project` field for fallback resolution. Store the issue-label inventory for all create/update preflights. Load project taxonomy/application rules from project configuration/docs (for example `vstack.toml` `[skill-instructions]`). Use issue labels only; never validate issue creates against project labels.

### 1.3 Route by Mode

| MODE | Next |
|------|------|
| `project-order` | § 2 |
| `project` | § 3 |
| `issue` | § 4 |
| `analyzed` | § 5 (skip § 2-4, TPM already ran) |

**Analyzed mode**: Treated as `issue` mode for all §§ 5-9 skip conditions. Where a section says "Skip if MODE = issue", also skip for MODE = analyzed.

---

## 2. Project Order Audit

**Skip if** MODE = project OR MODE = issue.

### 2.1 Delegate to TPM

Spawn sub-agent: type=[TPM] (NOT teammate -- one-shot analysis, no re-delegation):

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-audit-project-order.md

Arguments: (none)
</delegation_format>

### 2.2 Present Results

1. **Collect JSON path**: Agent returns `.JSON` file. If missing, halt.

2. **Read file**: Use Read tool to get structured findings.

3. **Present findings** using this format. Omit empty sections.

   <output_format>

   ### PROJECT ORDER AUDIT

   **Architectural Analysis**:

   | Initiative | Project | State | Layer | Domain | Pos | Rationale |
   |------------|---------|-------|-------|--------|-----|-----------|
   | Platform MVP | Phase 1: Foundation | ✅ done | L0 | infra | — | Foundation, no deps |
   | Platform MVP | Phase 2: Core Services | 📋 plan | L1 | data | 1→1 ✓ | Builds on L0, enables UI |
   | Platform MVP | Phase 2.5: Test Infra | 📋 plan | L1 | testing | 2→2 ✓ | Parallel to Core |
   | Platform MVP | Phase 3: Features | 🗃️ back | L2 | ui | 2→3 ⚠ | Depends on Phase 2 |

   State: ✅ done | ▶️ start | 📋 plan | 🗃️ back
   Pos: position within state column (current→recommended)

   **Proposed Order** (if changes needed):
   ```
   ▶️ Started:
     1. Phase 2: Data Layer (Platform MVP)

   📋 Planned:
     1. Phase 2.5: Test Foundation (Platform MVP)

   🗃️ Backlog:
     1. Phase 2.6: Adv Test Infra (Platform MVP)
     2. Phase 3: Features (Platform MVP)
     3. Phase 4: Charting (Platform MVP)
     ...
   ```

   **Complete** (100%, needs state transition):

   | Project | Unblocks |
   |---------|----------|
   | Revisit | Phase 2: Data Layer, Phase 2.5: Test Foundation |

   **Recommended Next**: Phase 2: Data Layer
   → Position 1 in planned, unblocked once Revisit completes

   *Or if no projects ready:*
   **Recommended Next**: None
   → All candidates blocked: [list blockers]

   </output_format>

### 2.3 Confirm and Execute

**Skip if** all of: no reorders needed AND no complete_candidates AND (recommended_next is null OR already a started project exists).

Output: "Project order verified. No changes needed." → **END**

**Otherwise**:

1. **Ask user** with multi-select. Only show categories with items:

   | Category | Question | Options |
   |----------|----------|---------|
   | reorder | "Apply reorder?" | `All`, `None`, individual items |
   | complete | "Mark complete?" | `[PROJECT]: 100% → Done`, `All`, `None` |
   | activate | "Activate next?" | `[RECOMMENDED]`, other ready projects, `None` |

2. **Execute approved changes** in order:
   1. Reorders: `.agents/skills/linear/scripts/linear.sh projects set-sort-order [PROJECT_ID] --position [NEW_SORT_ORDER]`
   2. Complete: `.agents/skills/linear/scripts/linear.sh projects update [PROJECT_ID] --state completed`
   3. Activate: `.agents/skills/linear/scripts/linear.sh projects update [PROJECT_ID] --state started`

### 2.4 Continue to Full Audit

**If project activated**:

→ Ask user: "Continue to full audit of [PROJECT]?" | `Yes` | `No`

- Yes → set MODE=project, TARGET=[activated project] → § 4
- No → **END**

**If no project activated** → **END**

---

## 3. Resolve Target

**Skip if** MODE = issue.

### 3.1 Resolve Project Target

**If TARGET specified**: Use TARGET → § 4

**If TARGET is null**:
1. If `session-status.projects` has entries with `has_active_work` → use first such project → § 4
2. Otherwise → § 3.2

### 3.2 Present Project Selection

1. **Present available projects**. Omit blocked projects if many ready options exist.

   <output_format>

   ### NO ACTIVE PROJECT

   | # | Project | Status | Blocked By |
   |---|---------|--------|------------|
   | 1 | Phase 2: Features | ✅ | — |
   | 2 | Phase 3: Backend Services | 🚫 | Phase 2 |
   | 3 | Testing Infrastructure | ✅ | — |

   ---
   Status: ✅ ready  🚫 blocked

   Recommended: Phase 2: Features (position 1, no blockers)

   </output_format>

2. **Ask user**: `Activate [RECOMMENDED]` | other ready projects | `Skip`

3. **Route based on selection**:

   | Selection | Action |
   |-----------|--------|
   | Activate | `.agents/skills/linear/scripts/linear.sh projects update [PROJECT_ID] --state started` → § 4 |
   | Skip | **END** |

---

## 4. Delegate Full Audit to TPM

### 4.1 Delegate to TPM

Spawn sub-agent: type=[TPM] (NOT teammate -- one-shot analysis, no re-delegation):

**PROJECT mode**:

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-audit.md

Arguments: --project "[PROJECT_NAME]"
Worktree: [WORKTREE_PATH] (empty if main repo)
</delegation_format>

**ISSUE mode** (from file):

<delegation_format>
Follow workflow: .agents/skills/project-management/workflows/tpm-audit.md

Arguments: --issues [FILE_PATH]
</delegation_format>

TPM reads JSON file directly -- schema: [audit-issues-input.md](../schemas/audit-issues-input.md)

### 4.2 Process Audit Results

1. **Collect JSON path**: Agent returns `.JSON` file. If missing, halt.

2. **Read file**: Use Read tool to get structured findings.

---

## 5. Present Audit Results

### 5.1 Present Project Findings

**Skip if** MODE = issue.

**Display each category table**. Omit empty categories.

<output_format>

### ISSUE AUDIT — [Project Name]

---

### 🔧 FIXES

**Agent Mismatch**

| # | Issue | Title | Current | Should Be |
|---|-------|-------|---------|-----------|
| 1 | [ISSUE_ID] | Add order validation | [AGENT_TYPE] | [AGENT_TYPE] |

**Label Co-occurrence**

| # | Issue | Title | Present | Missing |
|---|-------|-------|---------|---------|
| 1 | [ISSUE_ID] | Create Market Panel | agent:[TYPE] | design |

**Priority Misalignment**

| # | Issue | Title | Current | Should Be | Reason |
|---|-------|-------|---------|-----------|--------|
| 1 | [ISSUE_ID] | Fix memory leak | P3 | P1 | Blocks release; causes crashes |

---

### 🕸️ RELATIONS

**Add**

| # | From | Rel | To | Reason |
|---|------|-----|-----|--------|
| 1 | [ISSUE_ID] | 🙅 | [ISSUE_ID] | blocks; wrapper consumes dispose seam |

**Remove**

| # | From | Rel | To | Reason |
|---|------|-----|-----|--------|
| 1 | [ISSUE_ID] | 🔗 | [ISSUE_ID] | No longer related after refactor |

**Violations** (structural -- must fix)

| # | Issue | Current | Fix | Reason |
|---|-------|---------|-----|--------|
| 1 | [ISSUE_ID] 🚫 [ISSUE_ID] | cross-project block | Relocate + preserve | Phase 2.5 vs Phase 2.6 |
| 2 | [ISSUE_ID] 🙅 [ISSUE_ID] | cross-bundle child block | Lift to parent level | Children of different parents |

---

### 🧱 STRUCTURE

**Hierarchy**

| # | Issue | Change | Reason |
|---|-------|--------|--------|
| 1 | [ISSUE_ID] | 👶[ISSUE_ID] | Should be child of order flow bundle |

**Wrong Project**

| # | Issue | Title | Current | Should Be | Reason |
|---|-------|-------|---------|-----------|--------|
| 1 | [ISSUE_ID] | Update docs | Phase 1 | Phase 2 | Depends on Phase 2 APIs |

---

### 🗑️ CLEANUP

**Duplicates**

| # | Keep | Remove | Reason |
|---|------|--------|--------|
| 1 | [ISSUE_ID] | [ISSUE_ID] | Subset of scope |

**Combine**

| # | Into | Absorb | Reason |
|---|------|--------|--------|
| 1 | [ISSUE_ID] | [ISSUE_ID] | Scope fits within; merge descriptions |

**Obsolete**

| # | Issue | Confidence | Reason |
|---|-------|------------|--------|
| 1 | [ISSUE_ID] | 90% | Implemented in [ISSUE_ID] |

---

### 👾 GAPS

| # | Severity | Component | Reason | Blocks | Project |
|---|----------|-----------|--------|--------|---------|
| 1 | 🔴 | Error handling | No error propagation in execution | [ISSUE_ID] | Phase 1 |

---

---
Legend:
Relations: 🚫 blk_by  🙅 blocks  🔗 related
Structure: 👶 child  👵🏻 parent  📦 bundle  🚚 move  📝 sync desc
Severity: 🔴 critical  🟡 required  🟣 research

</output_format>

Truncate `Reason` to ~200 chars. Full reasoning in JSON.

### 5.2 Present Issue Findings

**Skip if** MODE = project.

Display findings table. Omit empty sections.

<output_format>

### ISSUE AUDIT — [N] item(s) from [SOURCE]

### ✨ CREATE

| # | Title | Project | Labels | Relations | Structure | Reason |
|---|-------|---------|--------|-----------|-----------|--------|
| 1 | Add ring buffer tests | Phase 2.5 | agent:[TYPE], [domain] | — | — | New tests needed |

### 🔄 SUPERSEDE (via CREATE above)

| # | Cancel | Children | Replaced By | Reason |
|---|--------|----------|-------------|--------|
| 1 | [ISSUE_ID] | 2 children | #1 | D018 → D026 |
| 2 | [ISSUE_ID] | — | #1 | D018 → D026 |

---

### ⏭️ SKIP

| # | Title | Why | Reason |
|---|-------|-----|--------|
| 1 | Fix dispose race | 👯[ISSUE_ID] | Same race condition; has implementation plan |

---

### 🔄 MODIFY

| # | Issue | Title | Action | Project | Agent | Structure | Reason |
|---|-------|-------|--------|---------|-------|-----------|--------|
| 1 | [ISSUE_ID] | Fix memory layout | Update | 🚚Phase 2 | [AGENT_TYPE] | — | Update description with new findings; move to Phase 2 |

---

### ❌ CANCEL

| # | Issue | Confidence | Reason |
|---|-------|------------|--------|
| 1 | [ISSUE_ID] | 85% | Implemented in [ISSUE_ID] |

---
Legend:
Project: [Name] = target project | 🚚[Name] = move to project
Relations: 🚫 blk_by  🙅 blocks  🔗 related
Structure: 👶 child  👵🏻 parent  📦 bundle
Skip: 👯 dup  🎯 scope

Action:
- Expand (add scope)
- Update (edit metadata/desc)
- Supersede (cancel+replace)
- Combine (merge into)

</output_format>

**Reason column**: 2-3 sentences explaining why this action, what evidence supports it, and impact.

---

## 6. Confirm Changes with User

Ask user with multi-select. Only show categories with findings.

### 6.1 Confirm Issue Changes

| Category | Question | Options |
|----------|----------|---------|
| priority_misalignment | "Fix priorities?" | `#N: [ID] → P[N]`, `All`, `None` |
| agent_mismatch | "Fix agent labels?" | `#N: [ID]: [CURRENT] → [SHOULD_BE]`, `All`, `None` |
| label_cooccurrence | "Fix missing labels?" | `#N: [ID]: add [MISSING]`, `All`, `None` |
| remove_relations | "Remove incorrect relations?" | `#N: [ID] [REL] [ID]`, `All`, `None` |
| relation_violations | "Fix relation violations?" | `#N: [DESCRIPTION]`, `All`, `None` |
| add_relations | "Add relations?" | `#N: [ID] [REL] [ID]`, `All`, `None` |
| hierarchy | "Apply hierarchy changes?" | `#N: [CHANGE]`, `All`, `None` |
| duplicates | "Merge duplicates?" | `#N: Keep [ID], remove [ID]`, `All`, `None` |
| combine | "Combine issues?" | `#N: Absorb [ID] into [ID]`, `All`, `None` |
| obsolete | "Cancel obsolete?" | `#N: [ID] (N% confidence)`, `All`, `None` |
| wrong_project | "Move to project?" | `#N: [ID] → [Project]`, `All`, `None` |

### 6.2 Additional Categories

**Skip if** MODE = issue.

| Category | Question | Options |
|----------|----------|---------|
| project_dependency_issues | "Fix project dependencies?" | `#N: [FROM] → [TO]`, `All`, `None` |
| architecture_gaps | "Create gap issues?" | `#N: [SEVERITY]: [COMPONENT] → [PROJECT]`, `All`, `None` |
| project_recommendations | "Apply project changes?" | `#N: [ACTION] [NAME]`, `All`, `None` |

### 6.3 Additional Categories

**Skip if** MODE = project.

| Category | Question | Options |
|----------|----------|---------|
| create | "Create new issues?" | `#N: [TITLE]`, `All`, `None` |
| expand/update | "Expand/update existing?" | `#N: [ACTION] [ISSUE_ID]`, `All`, `None` |
| supersede | "Supersede (cancel+create)?" | `#N: Replace [ISSUE_ID]`, `All`, `None` |
| superseded | "Cancel superseded issues?" | `#N: [ISSUE_ID] + N children (replaced by #M)`, `All`, `None` |
| skip | "Override skip?" | `#N: Create anyway`, `Keep skipped` |
| research_refs | "Add research reference?" | `[ISSUE_ID]: [TITLE]`, `All`, `None` |

**research_refs**: Only show when `research_ref` context provided. Include issues with `related` relation, duplicates/overlapping issues, issues in same domain.

---

## 7. Execute Approved Changes

### 7.0 Strict Label Preflight

Before any approved mutation that creates an issue or changes labels:

1. **Build intended label operations** from approved findings:
   - `create` and architecture/research gap issues: final `labels[]` from `create_fields.labels[]` or recommended issue labels.
   - `agent_mismatch`: `replace_category` for taxonomy category `agent`.
   - `label_cooccurrence`: `add` the missing label/category label.
   - Any `set_labels[]`/metadata update: use its explicit mode (`add`, `replace_category`, or `replace_all`) and target category when present.
2. **For existing issues**, fetch current labels and compute the full final set:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
   ```
   Preserve unrelated labels. Replace only labels in the target taxonomy category unless the action explicitly says `replace_all_labels: true`.
3. **Validate final labels** with the inventory/taxonomy loaded in § 1.2 per [labels.md](../references/labels.md).
4. **Halt before mutation** on unknown labels, parent/group labels, missing required categories, or exclusivity violations. Report the failing label set and ask the user. If a required taxonomy label is missing from Linear, request explicit authorization before creating it; never create labels automatically.
5. **Use only validated final labels** in `issues create --labels` or `issues update --labels`.

Unknown labels, parent/group labels, missing required categories, or exclusivity violations halt before mutation.

Do not run `issues update --labels "agent:new"` or any other partial label replacement unless the validated final label set really contains only that label.

For each approved change:

1. **Read the referenced section** from the issue tracker CLI's workflow-actions patterns.

2. **Execute the pattern** exactly as documented.

### 7.1 Execute Project Actions

**Skip if** MODE = issue.

| Finding | Reference |
|---------|-----------|
| project_dependency_issues | workflow-actions § Project Relations |
| priority_misalignment | workflow-actions § Priority Updates |
| agent_mismatch | workflow-actions § Agent Label Updates |
| label_cooccurrence | workflow-actions § Label Co-occurrence Fixes |
| add_relations, remove_relations | workflow-actions § Relations |
| relation_violations | workflow-actions § Fix Relation Violations |
| duplicates, combine | workflow-actions § Cancel / Merge / Combine |
| obsolete | workflow-actions § Cancel Obsolete Issues |
| wrong_project | workflow-actions § Scope Changes |
| hierarchy | workflow-actions § Hierarchy Changes (includes § Sync Parent Description after every change) |
| architecture_gaps (critical/required) | workflow-actions § Create Gap Issues |
| architecture_gaps (research) | workflow-actions § Create Research Gap |
| project_recommendations | workflow-actions § Project State Changes |

### 7.2 Execute Issue Actions

**Skip if** MODE = project.

Process `create` actions first -- use created IDs to resolve `#N` references in subsequent actions.

| Action | Reference |
|--------|-----------|
| create | See **Create template** below -- use `--parent` per `hierarchy` field. Child must be in same project as parent; if not, create standalone with `related`. If `hierarchy.parent` is null and action is `make_child`, resolve to `parent_issue` from audit input file. |
| skip | No action required |
| valid | No action required (relation corrections via add/remove_relations) |
| expand, update, project move | workflow-actions § Scope Changes |
| supersede, combine | workflow-actions § Cancel / Merge / Combine |
| cancel | workflow-actions § Cancel Obsolete Issues |

**Create template**: Use project-level templates issue-description-template for `--description`. For parent/bundle issues, use project-level templates parent-issue-template. Always heredoc, never inline strings. Every create command must include `--labels "[VALIDATED_FINAL_LABELS]"` from § 7.0.

**Analyzed mode**: When MODE = analyzed, issue creation fields (description, recommendation, location, estimate, priority, agent_label, labels, source_path) come from `issues[].create_fields`. `create_fields.labels[]` is authoritative and required for create; `agent_label` is derived/backward-compatible only. Use `source_path` for `[ORIGIN_CONTEXT]` in issue-description-template. For bundle parents (`create_fields.is_bundle_parent: true`), use parent-issue-template. Top-level `parent_issue` and `research_ref` available for hierarchy fallback and description refs.

**Inherit parent refs**: When creating a child issue (`hierarchy.action: "make_child"`), check parent's description for `**Research**:` and `**Decision**:` lines. Include them at the top of the child's description (before `**Source**:`). This ensures sub-issues inherit research/decision context even when `research_ref`/`decision_ref` are not in the audit input.

**Superseded issues**: After creating issues (which resolves `#N` → `[ISSUE_ID]`), for each approved supersession from `supersedes[]`:

1. **Fetch children**: `.agents/skills/linear/scripts/linear.sh cache issues children [SUPERSEDED_ID]`
2. **Detach** any children with independent scope (not covered by replacement): `.agents/skills/linear/scripts/linear.sh issues update [CHILD_ID] --remove-parent`
3. **Comment** on superseded issue: `"Superseded by [ISSUE_ID] (DXXX). Scope fully covered."`
4. **Cancel**: `.agents/skills/linear/scripts/linear.sh issues update [SUPERSEDED_ID] --state "Canceled"` -- remaining children cascade-canceled by issue tracker

#### 7.2.1 Position in Active Project

After each `create` action, determine whether the new issue should be moved to Todo with a sort position.

**Skip positioning if any**:
- Issue's project state is not `started`
- Issue has `blocked_by` relations to non-Done issues in other projects
- Issue priority is P4 with no blocking relations

**Steps**:

1. Check project state:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache projects get [PROJECT_ID] | jq -r '.state'
   ```

2. If `started`, query existing Todo issues:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues list --project "[PROJECT]" --state "Todo" --format=safe | jq 'sort_by(.sort_order)'
   ```

3. Calculate sort_order:
   - Find first existing Todo with equal or lower priority (higher number) → new issue's `sort_order` = that issue's `sort_order - 1000`
   - If new issue has lowest priority → `sort_order` = last issue's `sort_order + 1000`
   - If new issue blocks an existing Todo at position X → `sort_order` = `X - 1000`
   - Blocking relations take precedence over priority ordering

4. Set state and position:
   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [NEW_ID] --state "Todo" --sort-order [CALCULATED]
   ```

**Adding relations**: Use workflow-actions § Relations. CLI enforces same-project constraint for `blocks`/`blocked_by` -- use `related` for cross-project links.

### 7.3 Add Research References

**Skip if** no `research_ref` context provided.

For each approved `research_refs` issue:

1. **Get current description**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] | jq -r '.description'
   ```

2. **Check existing**: If `[RESEARCH_REF]` path already exists, skip.

3. **Prepend research reference**:
   - If no `**Research**:` line exists: Add `**Research**: [RESEARCH_REF]` at top
   - If `**Research**:` line exists: Convert to list format and append

4. **Add Decision** if `decision_ref` present AND not already in description:
   - Add `**Decision [DECISION_ID]**: [project decision documents]/[DECISION_ID]-[DESCRIPTOR].md` after Research block

5. **Propagate to children**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues children [ISSUE_ID] --recursive --format=safe | jq -r '.[].id'
   ```
   For each child: repeat steps 1-4. Skip if reference already present.

### 7.4 Post-Cancellation Cleanup

For each issue canceled during § 7.1 or § 7.2 (superseded, obsolete, or duplicate):

**Relations**:

1. **Fetch relations**: `.agents/skills/linear/scripts/linear.sh issues list-relations [CANCELED_ID]`
2. **Remove `blocks` relations** to non-canceled issues:
   ```bash
   .agents/skills/linear/scripts/linear.sh issues remove-relation [CANCELED_ID] --blocks [TARGET_ID]
   ```
3. **Check unblocked targets**: If a target issue now has no remaining `blocked_by`, and new issues were created during this audit that cover the same domain -- present: "[ISSUE_ID] unblocked by cancellation of [ISSUE_ID]. Add blocker?" with created issue options. Execute approved additions.

`related` relations are preserved as historical record.

**Stale references** (decision-eliminated or superseded cancellations only):

1. **Identify old pattern**: From `obsolete[].evidence.eliminated_pattern` or `supersedes[].reason`
2. **Check parent and siblings**:
   ```bash
   .agents/skills/linear/scripts/linear.sh cache issues get [PARENT_ID]
   .agents/skills/linear/scripts/linear.sh cache issues children [PARENT_ID]
   ```
3. **Flag matches**: Non-canceled issues where title or description references the old pattern
4. **Present**: "Update stale references? #N: [ISSUE_ID]: [OLD] → [NEW]"
5. **Execute approved**:
   - Title: `.agents/skills/linear/scripts/linear.sh issues update [ID] --title "[UPDATED]"`
   - Description: `.agents/skills/linear/scripts/linear.sh issues update [ID] --description "[UPDATED]"`
   - Comment: `"Updated: [OLD] → [NEW] per [DECISION_ID]"`

### 7.5 Relation Direction Reference

**Project mode**: `from` → relation → `to` (from `findings.add_relations[]`)

**Issue mode** ([ISSUE_ID] is analyzed issue):
- `blocked_by[]`: blocker --blocks→ [ISSUE_ID]
- `blocks[]`: [ISSUE_ID] --blocks→ target
- `related[]`: [ISSUE_ID] --related→ target

---

## 8. Present Results

<output_format>

### ✅ AUDIT COMPLETE

**Issues**:
- ✨ Created: N ([ISSUE_ID], ...)
- 🔄 Modified: N (expand/update/supersede/combine)
- ❌ Canceled: N (N obsolete, N superseded)
- 🧱 Structure: N (hierarchy, project moves)
- 🕸️ Relations: +N added, -N removed
- 🔧 Fixes: N (agent labels, priorities)
- 📚 Research refs: N
- 👾 Gap issues created: N
- ⏭️ Skipped: N

</output_format>

---

## 9. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — audit results presented in § 8.
