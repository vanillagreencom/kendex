# Dev Fix Workflow

Delegate fix items to specialist dev agent. Works standalone (user-initiated) or managed (from review-pr).

## Inputs

| Command | Behavior |
|---------|----------|
| `dev-fix` | Fix items from conversation context |
| `dev-fix [ISSUE_ID]` | Fix items for specific issue |
| (from review-pr workflow) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`):
- `worktree`: worktree path
- `lifecycle` (optional): `"managed"` (return to caller at § 3) | `"self"` (default, standalone).
- `dev_agent` (optional): name of alive dev agent for fix delegation. If absent, determine from state/labels.
- `issue_id` (optional): Issue ID. If absent, extracted from branch.
- `items` (optional): formatted review items. If absent, build from conversation context.
- `source` (optional): `pr-review` | `qa-review` | `review`. Default: `conversation`.
- `qa_agent` (optional): QA agent name (for qa-review source).

**Standalone init** (`lifecycle: "self"` only):
```bash
ISSUE_ID=${ARG:-$(git rev-parse --abbrev-ref HEAD | grep -oiP "$GH_ISSUE_PATTERN")}
```

Apply [Worktree Scope](../SKILL.md#worktree-scope): if current dir is a worktree and `ISSUE_ID` ≠ the current branch's issue, ask the user before proceeding. Then resolve `WT_PATH`:
- Inside a worktree → `WT_PATH=$(pwd)`
- Main repo, worktree exists → `WT_PATH=$(.agents/skills/worktree/scripts/worktree path $ISSUE_ID)`
- Main repo, worktree missing → ask the user before creating

---

## 1. Build Fix Items

**If `items` provided** (managed): Use directly → § 2.

**If standalone**: Synthesize from conversation context.

1. **Gather context**: From the conversation, identify what needs fixing. Read relevant files if needed.

2. **Format each fix item**:
   ```
   ---
   #[N] | [conversation] | [location or "TBD"]
   Description: "[WHAT IS WRONG]"
   Recommendation: "[HOW TO FIX]"
   ---
   ```

3. **Present to user**:

   <output_format>

   ### Fix Items — [ISSUE_ID]

   | # | Location | Description | Recommendation |
   |---|----------|-------------|----------------|
   | 1 | [location] | [description] | [recommendation] |

   </output_format>

4. **Ask user**: `Fix all` | Multi-select: `#N: [TITLE]` | `Cancel`

   | Choice | Action |
   |--------|--------|
   | Cancel | → END |
   | Items selected | → § 2 |

---

## 2. Delegate

1. **Determine agent**:
   - If `dev_agent` provided → use it (already alive)
   - Otherwise: from workflow state or issue labels
     ```bash
     AGENT=$(.agents/skills/linear-orch/scripts/workflow-state get $ISSUE_ID '.agent // empty' 2>/dev/null)
     [[ -z "$AGENT" ]] && AGENT=$(.agents/skills/linear/scripts/linear.sh cache issues get $ISSUE_ID --format=compact | jq -r '[.labels[] | select(startswith("agent:"))] | first | split(":")[1] // empty')
     ```

2. **Group items by agent domain** if multi-domain. Sequential per [agent-sequencing.md](agent-sequencing.md).

3. **Detect team context**:
   ```bash
   TEAM=$(.agents/skills/linear-orch/scripts/workflow-state get $ISSUE_ID '.team_name // empty')
   ```

4. **Delegate** to `[AGENT_TYPE]` agent (reuse existing dev agent if available).

   ⚠ Fill placeholders only ([Format Tags Are Literal](../SKILL.md#format-tags-are-literal)). `Recommendation:` = technical fix, not procedure. The agent already owns validate/commit/return per `linear-dev/workflows/dev-fix.md`.
   - ✅ `"Read X from parent state and forward to child — fix in parent so descendants inherit."`
   - ❌ `"1. Apply fix. 2. Run validate. 3. Commit. 4. Let orchestrator handle linkage."`

   <delegation_format>
   Ultrathink.

   Follow workflow: .agents/skills/linear-dev/workflows/dev-fix.md

   Source: [SOURCE]
   Issue: [ISSUE_ID]
   Worktree: [WORKTREE_PATH]
   [If qa_agent:] QA: [QA_AGENT]

   Review items:
   [FORMATTED_ITEMS]
   </delegation_format>

5. **Wait for completion.** Parse return: item decisions (Applied/Skipped/Blocked), commits, validation status.

6. **Update state**:
   ```bash
   # For each applied item:
   .agents/skills/linear-orch/scripts/workflow-state append [ISSUE_ID] fixed_items '{"description":"[DESC]","location":"[LOC]","commit":"[SHA]","source":"[SOURCE]"}'

   # For each escalated/skipped item:
   .agents/skills/linear-orch/scripts/workflow-state append [ISSUE_ID] escalated_items '{"description":"[DESC]","location":"[LOC]","reason":"[REASON]","source":"[SOURCE]"}'

   .agents/skills/linear-orch/scripts/workflow-state increment [ISSUE_ID] cycles
   ```

---

## 3. Return

**If standalone**:

1. **Present results**:

   <output_format>

   ### Fix Results — [ISSUE_ID]

   | # | Decision | Reasoning |
   |---|----------|-----------|
   | N | Applied/Skipped/Blocked | [explanation] |

   Commits: [SHAs or "none"]
   Validate: [status]

   </output_format>

2. **END**

**If managed**: Return parsed results to caller (item decisions, commits, validation status), then return to parent workflow.
