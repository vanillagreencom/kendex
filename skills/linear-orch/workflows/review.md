# Review Workflow

On-demand code review for the current working session. Reviews recent commits, presents findings, and offers to fix selected items. Designed for agile sessions where the user is directly involved.

## Inputs

| Command | Behavior |
|---------|----------|
| `review` | Review uncommitted changes since last commit |
| `review all` | Review all branch changes vs base (committed + uncommitted) |
| `review last [N]` | Review last N commits |
| `review [HASH]` | Review changes in specific commit |

**Always standalone** — no managed lifecycle. No caller context parameters.

**Init:**
```bash
ISSUE_ID=$(git rev-parse --abbrev-ref HEAD | grep -oiP "$GH_ISSUE_PATTERN") || true
WT_PATH=$(pwd)

if [[ -n "$ISSUE_ID" ]] && ! .agents/skills/linear-orch/scripts/workflow-state exists $ISSUE_ID; then
  .agents/skills/linear-orch/scripts/workflow-state init $ISSUE_ID --worktree "$WT_PATH" --branch "$(git rev-parse --abbrev-ref HEAD)"
fi
```

---

## 1. Determine Review Scope

```bash
BASE_BRANCH=${WORKTREE_DEFAULT_BRANCH:-$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}
[ -n "$BASE_BRANCH" ] || BASE_BRANCH=main
```

**Compute diff range based on arguments:**

| Argument | `DIFF_RANGE` | Description |
|----------|-------------|-------------|
| (none) | `HEAD` | Uncommitted changes (staged + unstaged) vs last commit |
| `all` | `origin/$BASE_BRANCH..` | All branch changes including uncommitted work |
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

---

## 2. Launch Review Agents

**Detect team context:**
```bash
TEAM=$(.agents/skills/linear-orch/scripts/workflow-state get $ISSUE_ID '.team_name // empty' 2>/dev/null) || true
```

**Determine agent list**: All configured review agents.

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

---

## 3. Collect & Present Results

Wait for all review agents to complete. Do NOT shutdown — agents needed for potential fix delegation in § 4.

Extract `Report` path and `Verdict` from each agent's return. If any agent fails to return expected format, halt and report error.

Overall verdict: `action_required` if any agent has blockers, `pass` otherwise.

**Update state** (if `ISSUE_ID` exists):
```bash
# For each agent JSON path:
.agents/skills/linear-orch/scripts/workflow-state append [ISSUE_ID] json_paths "[PATH]"
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

---

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

→ Ask user (omit categories with no items):

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
   .agents/skills/linear-orch/scripts/workflow-state set [ISSUE_ID] pre_delegate_sha "$(git rev-parse HEAD)"
   ```

2. **Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § 4.1 step 3` with context:
   - `worktree`: [WT_PATH]
   - `lifecycle`: `"managed"`
   - `dev_agent`: determine from state or labels (same as dev-fix standalone init)
   - `issue_id`: [ISSUE_ID] (if available)
   - `items`: [SELECTED_ITEMS — format each as `#[N] | [Agent] | [Location]` with Description + Recommendation]
   - `source`: `review`

3. **Update state** (if `ISSUE_ID` exists):
   ```bash
   # For each applied item:
   .agents/skills/linear-orch/scripts/workflow-state append [ISSUE_ID] fixed_items '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"review"}'

   # For each escalated/skipped item:
   .agents/skills/linear-orch/scripts/workflow-state append [ISSUE_ID] escalated_items '{"description":"[DESC]","location":"[LOC]","reason":"[REASON]","source":"review"}'
   ```

4. **Present fix results**:

   <output_format>

   ### Fix Results

   | # | Decision | Commit | Reasoning |
   |---|----------|--------|-----------|
   | N | Applied/Skipped/Blocked | [SHA] | [explanation] |

   </output_format>

→ § 5 (if issue items selected) or § 6

---

## 5. Create Issues

**Skip if** no issue suggestions selected AND no escalated items from § 4.1. → § 6

1. **Build audit-input file** from selected issue suggestions and escalated items per `.agents/skills/project-management/schemas/audit-issues-input.md`.
   - `source`: `"review"`
   - `parent_issue`: [ISSUE_ID] if available, else null
   - `worktree`: [WT_PATH]

2. **Write file**: `tmp/audit-review-YYYYMMDD-HHMMSS.json`

3. **Run Workflow**: `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 6`

---

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

**Omit rows with zero values** (except Scope and Agents).

→ END
