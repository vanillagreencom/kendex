# Review Workflow

On-demand code review for the current session. Reviews recent commits, presents findings, and offers to fix selected items.

## Inputs

| Command | Behavior |
|---------|----------|
| `review` | Review uncommitted changes since last commit |
| `review all` | Review all branch changes vs base (committed + uncommitted) |
| `review last [N]` | Review last N commits |
| `review [HASH]` | Review changes in specific commit |

**Always standalone** — no managed lifecycle, no caller context parameters.

**Init:**
```bash
.agents/skills/orch/scripts/review-init
```

Use the JSON fields as `BRANCH`, `WT_PATH`, and `ISSUE_ID`. If `issue_id` is empty, skip workflow-state steps.

---

## 1. Determine Review Scope

```bash
.agents/skills/orch/scripts/resolve-base-branch .
```

Use the output as `BASE_BRANCH`.

**Diff range by argument:**

| Argument | `DIFF_RANGE` | Description |
|----------|-------------|-------------|
| (none) | `HEAD` | Uncommitted changes (staged + unstaged) vs last commit |
| `all` | `origin/[BASE_BRANCH]..` | All branch changes including uncommitted work |
| `last [N]` | `HEAD~[N]..HEAD` | Last N commits (committed only) |
| `[HASH]` | `[HASH]~1..[HASH]` | Single commit |

```bash
git diff $DIFF_RANGE --stat
```

**If no changes**: Report "No changes to review" and **END**.

### 1.1 Gather Decision Context

**Skip if** no `ISSUE_ID` extracted from branch.

```bash
.agents/skills/decider/scripts/decisions search --issue $ISSUE_ID
```

Collect decision IDs and summaries from JSON output.

## 2. Launch Review Agents

**Detect team context:**
```bash
.agents/skills/orch/scripts/workflow-state exists --json [ISSUE_ID]
.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.team_name // empty'
```
If state does not exist, use an empty `TEAM`.

**Determine agent list**:
```bash
.agents/skills/orch/scripts/list-review-agents
```
Use the output as `AGENTS`.

**Codex runtime agent type rule**: For each reviewer in `AGENTS`, first call the harness spawn API with `agent_type` equal to that reviewer name. Do not launch `worker` and simulate reviewer identity in the prompt unless the generated-agent spawn was attempted and the spawn API rejects or does not expose that generated `agent_type`. In that fallback, spawn `agent_type=worker` but keep the logical reviewer name in bootstrap/delegation text, reports, and workflow-state keys. If workflow state exists, persist the returned id under `review_agent_ids[reviewer-name]`, and record runtime metadata under `review_agent_runtime_types[reviewer-name]` with `agent_type="worker"` and a fallback reason. Report the fallback in status.

Delegate to each review agent in parallel:

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/review.md

Worktree: [WT_PATH]
Branch: [BRANCH]
Diff-range: [DIFF_RANGE]

Decisions:
[For each matching decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[If none: "- No linked decisions found."]
</delegation_format>

## 3. Collect & Present Results

Wait for all review agents to complete. Do NOT shutdown — agents needed for potential fix delegation in § 4.

Extract `Report` path and `Verdict` from each agent's return. If any agent fails to return the expected format, halt and report error.

Overall verdict: `action_required` if any agent has blockers; `pass` otherwise.

**Update state** (if `ISSUE_ID` exists):
```bash
# For each agent JSON path:
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] json_paths "[PATH]"
```

<output_format>

### CODE REVIEW COMPLETE

| Agent | Verdict | Path |
|-------|---------|------|
| **Overall** | `[pass\|action_required]` | |
| [For each agent:] |
| [AGENT] | `[verdict]` | `[path]` |
</output_format>

**Route by verdict + items:**

Read agent JSONs, check for items where `category == "fix"` or `category == "issue"`.

| verdict | items? | Next |
|---------|--------|------|
| any | yes (or `action_required`) | → § 4 |
| `pass` | none | → § 6 |

## 4. Present Review Items

**Collect items** from agent JSONs:
- **Blockers**: items from agents with `action_required` verdict
- **Fix suggestions**: items where `category == "fix"` from any agent
- **Issue suggestions**: items where `category == "issue"` from any agent

**If no items** → § 6.

**Present to user:**

<output_format>

### Review Items

**Blockers**

| # | Agent | Location | Description | Pri |
|---|-------|----------|-------------|-----|
| 1 | [agent] | [location] | [description] | 🔴 |

**Fix Suggestions**

| # | Agent | Location | Description | Pri | Est |
|---|-------|----------|-------------|-----|-----|
| 1 | [agent] | [location] | [description] | 🟤 | 1 |

**Issue Suggestions**

| # | Agent | Location | Description | Pri | Est |
|---|-------|----------|-------------|-----|-----|
| 1 | [agent] | [location] | [description] | 🟡 | 3 |

Pri: 🔴 P1  🟠 P2  🟡 P3  🟤 P4
Est: 1 (hours) | 2 (half-day) | 3 (day) | 4 (2-3d) | 5 (week+)

</output_format>

**Omit empty categories.**

Ask user (omit categories with no items):

| Category | Question | Type |
|----------|----------|------|
| Blockers + Fix suggestions | `Apply fixes?` | Multi-select: `#N: [TITLE]`, `All`, `None` |
| Issue suggestions | `Create issues for these?` | Multi-select: `#N: [TITLE]`, `All`, `None` |

| User Choice | Action |
|-------------|--------|
| Fix items selected | → § 4.1 (then § 5 with any issue selections) |
| Issue items only | → § 5 |
| No items selected | → § 6 |

### 4.1 Fix Delegation

**Never fix as main agent.**

1. **Capture pre-fix state** (if `ISSUE_ID` exists):
   ```bash
   .agents/skills/orch/scripts/workflow-state set-git-head [ISSUE_ID] pre_delegate_sha [WORKTREE_PATH]
   ```

2. **Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § 4.1 step 3` with context:
   - `worktree`: [WT_PATH]
   - `lifecycle`: `"managed"`
   - `dev_agent`: determine from state or labels (same as dev-fix standalone init)
   - `issue_id`: [ISSUE_ID] (if available)
   - `items`: [SELECTED_ITEMS — format each as `#[N] | [Agent] | [Location]` with Description + Recommendation]
   - `source`: `review`

3. **Present fix results** (state writes for fixed/escalated items are owned by `dev-fix.md` — do not re-append here):

   <output_format>

   ### Fix Results

   | # | Decision | Commit | Reasoning |
   |---|----------|--------|-----------|
   | N | Applied/Skipped/Blocked | [SHA] | [explanation] |

   </output_format>

→ § 5 (if issue items selected) or § 6

## 5. Create Issues

**Skip if** no issue suggestions selected AND no escalated items from § 4.1. → § 6

1. **Build audit-input file** from selected issue suggestions and escalated items per `.agents/skills/project-management/schemas/audit-issues-input.md`.
   - `source`: `"review"`
   - `parent_issue`: [ISSUE_ID] if available, else null
   - `worktree`: [WT_PATH]

2. **Write file**: `tmp/audit-review-YYYYMMDD-HHMMSS.json`

3. **Run Workflow**: `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6`

## 6. Summary

**Shutdown review agents.**

<output_format>

### ✅ REVIEW COMPLETE

| Metric | Value |
|--------|-------|
| Scope | [DIFF_RANGE description — e.g., "12 files, 3 commits vs main"] |
| Agents | [N] |
| Blockers | [N] |
| Fixes applied | [N] |
| Issues created | [N] |
| Escalated | [N] |

</output_format>

**Omit zero-value rows** (except Scope and Agents).

→ END
