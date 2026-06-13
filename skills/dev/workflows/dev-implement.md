# Issue Lifecycle

**The workflow for all dev/QA agents receiving work-item delegations.**

Skip issue tracker updates for ad-hoc requests (no issue reference).

## Delegation Types

| Type | Detection | Flow |
|------|-----------|------|
| Single | `Issue: [ISSUE_ID]`, `GitHub Issue: OWNER/REPO#N`, or ad-hoc task | § 1 → § 2 → § 4 → § 5 → § 6 → § 7 → § 8 → § 9 → § 10 → return |
| Bundled | `Parent: [ISSUE_ID]` + `Sub-Issues (tree): [...]` | § 1 → § 2 → [§ 4-10]×N → § 11 → return |

**If bundled**: Execute § 4-10 per **pending** sub-issue (one task each), then § 11 aggregates and returns.

**Nested sub-issues**: Sub-issues may have children (3-level hierarchy: parent → sub → nested). Blocking relations shown when present:
```
↳ [SUB_ISSUE_1]: [TITLE] | blocks: [SUB_ISSUE_2]
↳ [SUB_ISSUE_2]: [TITLE] | blocked by: [SUB_ISSUE_1]
   ↳ [SUB_ISSUE_3]: [TITLE]  ← child of [SUB_ISSUE_2]
   ↳ [SUB_ISSUE_4]: [TITLE]  ← child of [SUB_ISSUE_2]
```
Respect blocking order: complete blockers before blocked issues.

**Completed sub-issues**: Marked `(completed)` in delegation — context only, skip in § 4 loop.

---

## 1. Environment Setup

- Bash: `git -C [WORKTREE_PATH] ...`
- Read/Write/Edit/Grep/Glob: `[WORKTREE_PATH]/...`

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] fetch origin [BASE_BRANCH_FROM_PREVIOUS_COMMAND]
```

---

## 2. Activate Work Item

### 2.1 Claim & Get Context

Determine tracker:
- `Issue: ABC-123` or `Parent: ABC-123` → `TRACKER=linear`
- `GitHub Issue: OWNER/REPO#N` → `TRACKER=github`
- no tracker reference → `TRACKER=none`

Linear only:

```bash
# Activate issue (or parent if bundled), replace [AGENT_TYPE] with your agent type
.agents/skills/linear/scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT_TYPE]
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
```

GitHub only:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url
```

Ad-hoc: use delegation text as source of truth, skip tracker writes.

**If bundled**: Activate parent only. Sub-issues activated individually during § 4 loop.

**If bundled with completed siblings**: Also read completed sibling comments for handoff notes:
```bash
.agents/skills/linear/scripts/linear.sh cache comments list [COMPLETED_SIBLING_ID]
```

### 2.2 Check for Research Context

```bash
# Linear
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] | jq -r '.description'

# GitHub
gh issue view [N] --repo [OWNER/REPO] --json body --jq .body
```

**If bundled**: Also check each sub-issue for research refs. Aggregate unique paths.

**If sub-issue**: Also check the parent issue's description. Sub-issues inherit parent research context.

**If research/decision/context references found**: Read the cited files — mandatory context, not optional. Follow § 2.2.1, then continue.

#### 2.2.1 Research-Informed Implementation

You have domain context the orchestrator lacks. You decide how research applies.

1. **Read and evaluate**: Read project research documents. Consider how they apply to existing patterns and architecture docs.

2. **Check for existing decision** (decider skill): `.agents/skills/decider/scripts/decisions search --issue [RESEARCH_ISSUE_ID]`. If a prior research-complete already recorded a decision, reference it — don't duplicate. Only create new decisions for additional decisions revealed by your evaluation.

3. **Update architecture docs** if research changes documented patterns.

4. **Update `vstack.toml`** if research reveals project-specific context that should persist (under `[agent-launch-instructions]`, `[agent-additional-instructions]`, or `[skill-instructions]`).

### 2.3 Evaluate Feasibility

Before planning, check your domain's code (per your agent's Domain Setup):

- **Prior decisions?** `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` — read the full decision file, not just the index summary. Report back to orchestrator with decision reference if the description contradicts a decision — do not implement approaches a decision explicitly rejects.
- **Can you proceed?** Do required APIs/types exist?
- **Cross-domain dependency?** Need work in another domain first?
- **Blocked by existing issue?**
- **Optimization work without `baseline` label?** Add label now (before any code changes).

**If blocked** → **Jump to § 3**, then STOP.

**If clear** → continue to § 2.4.

### 2.4 Plan Approach

- Linear only: update estimate if scope differs: `.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --estimate N`
  - Estimates: 1=hours, 2=half-day, 3=day, 4=2-3 days, 5=week+
- **If bundled**: Plan sub-issue order based on dependencies/overlap.

### 2.5 Domain-Specific Setup

Follow your agent definition for architecture docs, code paths, skills to load.

### 2.6 Capture Baseline (if `baseline` label)

**Check labels** from § 2.1. If `baseline` label present:

1. Identify the affected component (backend, frontend, etc.)
2. **If a benchmarking skill is installed**, follow its baseline workflow to capture pre-implementation baselines.

The performance QA agent uses the baseline file during QA review.

---

## 3. Block Issue (if dependency discovered)

**Skip if** not blocked — § 2.3 routed to § 2.4.

### 3.1 Blocked by Existing Issue

Linear only:

```bash
.agents/skills/linear/scripts/linear.sh issues block [ISSUE_ID] --by [BLOCKER_ID] --reason "Cannot proceed until [REASON]"
```

GitHub/ad-hoc: report the blocker in the return message; do not invent tracker state.

### 3.2 Cross-Domain Dependency Discovery

When work in another domain must happen first (prerequisite issue doesn't exist):

1. **Add blocked label** (Linear only):
   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --labels "agent:[AGENT_TYPE],[COMPONENT],blocked"
   ```

2. **Post structured comment** (Linear only):
   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body "BLOCKED: Cross-domain prerequisite needed.

   **Required Domain**: [DOMAIN]
   **Suggested Labels**: agent:[DOMAIN], [COMPONENT]
   **Prerequisite Issue**: [One-line description]

   **Why Blocking**:
   [What this issue needs, why it can't proceed, what prerequisite must provide]

   **Suggested Scope**:
   - [Deliverable 1]
   - [Deliverable 2]

   Requesting orchestrator create prerequisite issue."
   ```

3. **Report to orchestrator**: Final message must state the blocker, domain and labels for the new issue, and that the issue description is ready for creation.

**Orchestrator**: Creates prerequisite, sets blocking relation, delegates.

### 3.3 Unblocked

When blocker resolves:
```bash
.agents/skills/linear/scripts/linear.sh issues unblock [ISSUE_ID]
```

GitHub/ad-hoc: skip.

---

## 4. Implement Solution

**If bundled**: Each sub-issue is a separate task (§ 4-10). Work only the sub-issue named in your current task.

### 4.1 Verify Branch

`git branch --show-current` — should be `[BRANCH_NAME]` (auto-links PR to issue tracker).

**If bundled**: Branch is parent's.

### 4.2 Implement

**If bundled**: Before implementing this sub-issue:
```bash
.agents/skills/linear/scripts/linear.sh issues activate [SUB_ISSUE_ID] --agent [AGENT_TYPE]
```

Implement per your agent's domain expertise. Run quality gates before completion.

**Scope growing?** Linear: create sub-issues with `linear.sh issues create --parent [PARENT_ID]`. GitHub/ad-hoc: report discovered scope in § 9; do not create issues without orchestrator approval.

**Found work outside scope?** Note in completion summary under "Discovered Work".

**Need deeper research?** Add "needs-research" label. Pause. Report to orchestrator.

### 4.3 Update Documentation

Update relevant docs if implementation changes documented APIs or architecture.

**If significant path choices made**, follow the decider skill's create-decision workflow:

1. Get next ID: `.agents/skills/decider/scripts/decisions next-id`
2. Select template from `templates/decision-entry.md` (minimal/standard/comprehensive)
3. Create decision file per `schemas/decision-format.md`
4. Add row to INDEX.md per `templates/index-row.md`
5. Use `// REVISIT(DXXX):` in code where applicable
6. Include decision ID in § 9 completion comment

**Skip decision recording if** no alternatives were considered or trade-offs made.

**If bundled**: Complete § 5-10 for this sub-issue before marking task done.

---

## 5. Validate

```bash
# Run the project's build/test/lint validation command
```

**On failure:**
- **First run**: Use `--fail-fast` to stop early, fix, then `--recheck`
- **Simple + related to your work** → fix it, `--recheck`
- **Complex or unrelated** → still commit your work, note failure in commit message, report in return
- **Stuck** (same failure 3+ times) → stop looping, commit, report details

Always report unresolved validation failures to orchestrator.

---

### 5.1 Visual QA

**Skip if** the issue does not have the `design` label.

Use visual QA skills to validate that UI changes render correctly. Focus on what your changes affect — not the full checklist. Do NOT capture golden baselines — that happens at submit-pr time.

---

## 6. Reflect & Update Documentation

**Skip if** implementation was straightforward with no repeated issues and no notable discoveries.

**Trigger**: Any of these during § 4-5:
- Fixed same problem 2+ times (lint, pattern, API usage, test approach)
- Discovered non-obvious gotcha worth remembering
- Spent multiple cycles on something a rule could prevent
- Discovered optimal approaches that differ from documented patterns

**Action**: Update the relevant documentation:

- **Architecture docs** → Update if patterns, APIs, or documented behavior changed.
- **Project config** → Add to `./vstack.toml` (`[skill-instructions]`, `[agent-additional-instructions]`, or `[agent-launch-instructions]`). Run `vstack refresh` to apply.

Criteria: Would this save 5+ minutes in a future session? If yes, update. One surgical addition per lesson. No verbose examples.

**If you can't update directly** (wrong domain, needs discussion): note in § 9 Discovered Work with type `[process]`.

---

## 7. Commit Changes

```bash
git -C [WORKTREE_PATH] add -A
git -C [WORKTREE_PATH] commit -m "[PREFIX]([ISSUE_ID]): [DESCRIPTION]"
```

**If bundled**: Use CURRENT sub-issue ID, not parent ID.

**Worktree caveat**: Never stage lock files listed in the project-specific gitignore. Stage specific files by name.

**If unresolved validation failures**: Append `[validate: FAILING_CHECK]` to commit message.

**Verify commit exists** before proceeding:
```bash
git -C [WORKTREE_PATH] log -1 --oneline
```

---

## 8. Apply QA Labels

Based on FINAL validated code:

| Trigger | Label |
|---------|-------|
| Unsafe code, atomics, lock-free | `needs-safety-audit` |
| Hot path, latency-sensitive, or shared/main-build perf risk | `needs-perf-test` |
| New module, public API | `needs-review` |

Full triggers: see the project label application guide.
Development-only feature exception: do not apply `needs-perf-test` for work isolated behind a development-only feature gate. Run the feature-gated checks locally and only add the label if shared or feature-off paths are affected.

---

## 9. Post Completion Summary

### 9.1 Completion Comment

**Always required** — documents the FINAL state after all validation passes.

**Target issue**: Linear posts to the issue you just implemented. GitHub/ad-hoc returns the same content to the orchestrator instead of posting a tracker comment.

Create `tmp/completion-summary-[ISSUE_ID].md` with:

```markdown
## Completion Summary

**Agent**: [AGENT_NAME]
**Branch**: `[BRANCH]`

### Files Created/Modified
- `path/to/file` - Description

### Key Decisions
1. Decision and rationale
2. DXXX recorded (if research-informed)

### Skills/Docs/Rules Updated
- `skill-name`: Updated X
(Skip if none)

### Domain Metrics
[Your agent-specific metrics: frame time, latency, etc.]
(Skip if not applicable)

### Discovered Work
- [Type]: Description (estimate: N)
Future work beyond current scope. NOT for the next agent — for backlog/orchestrator.
(Skip if none)

**Marker prefixes** — for bullets that belong to a later lifecycle stage of the current PR, not to the backlog. The orchestrator's `review-pr.md` § 9 audit drops these so they are not converted into new tracked issues. The marker MUST be the first token of the bullet text (before `[Type]`):

- `- handoff_to_submit_pr: [doc] Update CI wall-time table (estimate: 1)` — item the upcoming `submit-pr` step will produce (e.g., PR-body content). Belongs in the PR body, not in the issue tracker.
- `- handoff_to_merge_pr: [process] Verify cross-PR coordination at merge (estimate: 1)` — item the eventual `merge-pr` step will handle.
- `- current_workflow_action: [doc] Recompute coverage table for this review (estimate: 1)` — item the current `review-pr` cycle should handle itself.

Bullets without a marker prefix are treated as genuine new backlog work and routed through the TPM audit. Do not put the marker after `[Type]:` — the audit filter only matches the marker when it is the leading token.

### Handoff Notes
Context the next agent in this bundle needs to complete its current-scope work (e.g., struct changes, API contracts, file locations). Do NOT put aspirational suggestions or future work here — those belong in Discovered Work.
(Skip if none)
```

Then post it:

```bash
.agents/skills/linear/scripts/linear.sh comments create [ISSUE_ID] --body-file tmp/completion-summary-[ISSUE_ID].md
```

### 9.2 Downstream Handoff (selective)

**Skip if** tracker is not Linear, this issue does not block other issues, or unblocking by completion alone is sufficient.

Check blocking relations:
```bash
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] | jq '.blocks'
```

Post a handoff comment to each downstream issue **only if** this work changed an API, interface, file, or contract the downstream issue depends on:
```bash
.agents/skills/linear/scripts/linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body "Handoff from [ISSUE_ID]:
- [RELEVANT_CONTEXT: what changed, what downstream needs to know]"
```

Do NOT post handoff to the completed issue — that conflates audiences. Handoff Notes (§ 9.1) are for the next agent in this bundle. Downstream handoff is for agents working on issues this one unblocks.

---

## 10. Finalize Issue

**Verify complete:**

| Step | When | Ref |
|------|------|-----|
| Baseline captured | `baseline` label | § 2.6 |
| Research applied | Research in description | § 2.2.1 |
| Validation run | Always | § 5 |
| Docs/config updated | Repeated issues in § 4-5 | § 6 |
| Changes committed | Always | § 7 |
| QA labels applied | Triggers present | § 8 |
| Summary posted | Always | § 9.1 |
| Downstream handoff | Blocks + context needed | § 9.2 |

**If single**: Return now with:
```
Branch: [BRANCH_NAME]
Commit: [SHA]
QA Labels: [labels or "none"]
Validate: [pass or "FAILING: check1, check2"]
Summary: [ISSUE_ID] ✓
```

**If bundled**: Mark task completed. Next sub-issue is a separate task, or proceed to § 11 if none remain.

**Linear sub-issue of a parent** → mark issue Done (`.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --state "Done"`).
**Parent or standalone issue** → do NOT mark Done (handled by PR merge workflow and issue tracker sync).
**GitHub/ad-hoc** → do not close the issue here; PR body/merge handles closure when appropriate.

Do NOT push or submit PR — orchestrator handles after review passes.

---

## 11. Return to Orchestrator (If Bundled)

**Skip if** single issue — you returned at § 10.

1. **Update parent issue with aggregated QA labels** (Linear only):
   ```bash
   # Collect QA labels from all sub-issues (including nested), apply to parent
   .agents/skills/linear/scripts/linear.sh issues update [PARENT_ID] --labels "[EXISTING_LABELS],[AGGREGATED_QA_LABELS]"
   ```

2. **Post parent summary** (Linear only, tree format for sub-issues, blocking info shown):
   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [PARENT_ID] --body "## Bundle Complete
   **Agent**: [NAME] | **Branch**: [BRANCH]

   Sub-issues (tree):
   ↳ [SUB_ISSUE_1] ✓ | blocks: [SUB_ISSUE_2]
   ↳ [SUB_ISSUE_2] ✓ | blocked by: [SUB_ISSUE_1]
      ↳ [SUB_ISSUE_3] ✓  ← nested
   Files: N | Commits: N | QA: [LABELS]
   [Discovered work: ...]"
   ```

3. Send this result to the orchestrator as an agent-to-agent message. **Posting the parent summary comment is not a return** — the orchestrator does not poll the filesystem or issue tracker, and turn text is not visible across team boundaries. Send exactly one message with the body below, then go idle.

   **Return exactly**:

   <output_format>
   Parent: [ISSUE_ID]
   Sub-Issues: [tree format with ✓]
   Branch: [BRANCH]
   Commits: [COUNT] ([SHAS])
   QA Labels: [AGGREGATED]
   Summaries: [all issue IDs ✓]
   </output_format>
