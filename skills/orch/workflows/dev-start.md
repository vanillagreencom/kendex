# Dev Implementation Workflow

Delegate development work to specialist agent(s). Handles single issues and bundled multi-agent work.

## Inputs

| Command | Behavior |
|---------|----------|
| `dev-start` | Implement current branch's issue |
| `dev-start [ISSUE_ID]` | Implement specific issue (or sub-issue from start-new session) |
| (from start-worktree / review-pr workflows) | Managed lifecycle with caller context |

**Caller context parameters** (via `⤵`):
- `worktree`: worktree path
- `lifecycle` (optional): `"managed"` (return to caller at § 4) | `"self"` (default, standalone).
- `issue_id` (optional): Issue ID. If absent, extracted from branch.

**Standalone init** (`lifecycle: "self"` only):
```bash
ISSUE_ID=${ARG:-$(git rev-parse --abbrev-ref HEAD | grep -oiP "$GH_ISSUE_PATTERN")}
```

Apply [Worktree Scope](../SKILL.md#worktree-scope): if in a worktree and `ISSUE_ID` ≠ the current branch's issue, ask the user before proceeding. Resolve `WT_PATH`:
- Inside a worktree → `WT_PATH=$(pwd)`
- Main repo, worktree exists → `WT_PATH=$(.agents/skills/worktree/scripts/worktree path $ISSUE_ID)`
- Main repo, worktree missing → ask the user before creating

```bash
TRACKER=$(.agents/skills/orch/scripts/tracker-for-issue "$ISSUE_ID")
```

If workflow state already exists, skip initialization:

```bash
.agents/skills/orch/scripts/workflow-state exists --json "$ISSUE_ID"
```

If `.exists` is `false`, initialize workflow state. Linear only: first check for parent context from a start-new sub-issue:

```bash
PARENT_ID=$(.agents/skills/linear/scripts/linear.sh cache issues get $ISSUE_ID --format=compact | jq -r '.parent.identifier // empty')
```

If `PARENT_ID` is non-empty, check whether the parent workflow state exists:

```bash
.agents/skills/orch/scripts/workflow-state exists --json "$PARENT_ID"
```

If `.exists` is `true`, read the parent team and worktree:

```bash
TEAM=$(.agents/skills/orch/scripts/workflow-state get $PARENT_ID '.team_name // empty')
WT_PATH=$(.agents/skills/orch/scripts/workflow-state get $PARENT_ID '.worktree // empty')
```

Then initialize child state with the inherited context:

```bash
.agents/skills/orch/scripts/workflow-state init $ISSUE_ID --worktree "$WT_PATH" --branch "$(git rev-parse --abbrev-ref HEAD)" --team "$TEAM"
```

Otherwise, initialize state with the current worktree:

```bash
.agents/skills/orch/scripts/workflow-state init $ISSUE_ID --worktree "$WT_PATH" --branch "$(git rev-parse --abbrev-ref HEAD)"
```

## 1. Determine Agent

`agent:X` label → X | No label → infer from component paths.

```bash
# Linear
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID] --format=compact | jq -r '.labels[]'

# GitHub
gh issue view ${ISSUE_ID#issue-} --json labels --jq '.labels[].name'
```

---

## 2. Delegate to Specialist Agent(s)

**Dev agents persist for the entire session.** Never shutdown dev agents — they stay alive for fix cycles, pending children, and PR review fixes. Only the caller's finalization step shuts them down.

Before each implementation delegation, capture the current `HEAD`:

```bash
.agents/skills/orch/scripts/workflow-state set [ISSUE_ID] pre_delegate_sha "$(git -C [WORKTREE_PATH] rev-parse HEAD)"
```

**After each spawn**, persist the agent session:
```bash
.agents/skills/orch/scripts/workflow-state update [ISSUE_ID] '.child_sessions["[AGENT_TYPE]"] = {"agent_id": "[AGENT_OR_TASK_ID]"}'
```

### If Single Issue

Delegate to a `[AGENT_TYPE]` agent. Wait for completion. Parse: Branch, Commit, QA Labels, Summary.

**Single issue delegation prompt:**

<delegation_format>
Ultrathink.

Follow workflow: .agents/skills/dev/workflows/dev-implement.md

Issue: [ISSUE_ID]
Worktree: [WORKTREE_PATH]
Labels: [LABELS]
Blocks: [BLOCKED_ISSUE_IDS or "none"]
</delegation_format>

**GitHub items**: replace the `Issue:` line with `GitHub Issue: [OWNER/REPO]#[N]`.

### If Bundled Issue

**Agent grouping**: Group pending sub-issues by `agent:[TYPE]` label. See [agent-sequencing.md](agent-sequencing.md) for ordering. Process sequentially: first group → wait for completion → validate (§ 3) → collect handoff notes → next group.

**Handoff collection** (between agent groups): After each group returns and passes § 3 validation, before delegating the next group:

a. For each sub-issue completed by any prior agent group (cumulative):
   ```bash
   .agents/skills/linear/scripts/linear.sh cache comments list [COMPLETED_ISSUE_ID] | jq -r '.[] | select(.body | contains("Handoff Notes")) | .body'
   ```
b. Extract "Handoff Notes" sections. Combine into a single block.
c. Include in next delegation as `Handoff from prior agents:` (see below). Omit if none found.

Delegate to a `[AGENT_TYPE]` agent. Wait for completion. Parse: Branch, Commit, QA Labels, Summary.

**Bundled issue delegation prompt:**

<delegation_format>
Ultrathink.

Follow workflow: .agents/skills/dev/workflows/dev-implement.md

Parent: [ISSUE_ID]
Sub-Issues:
[For completed sub-issues:]
↳ [SUB_ISSUE_1] (completed): [TITLE]
[For pending sub-issues assigned to this agent:]
↳ [SUB_ISSUE_2]: [TITLE] | blocks: [SUB_ISSUE_3]
↳ [SUB_ISSUE_3]: [TITLE] | blocked by: [SUB_ISSUE_2]
   ↳ [SUB_ISSUE_4]: [TITLE]  ← nested child of [SUB_ISSUE_3]

Worktree: [WORKTREE_PATH]
Labels: [parent labels]
Blocks: [blocked-issue-ids or "none"]

**Work pending issues only** (completed listed for context). Respect blocking order: complete blockers before blocked issues.

**Scope**: Implement YOUR assigned sub-issues only. You may fix/connect prior agents' code if needed, but do not implement work belonging to other agents' pending sub-issues.

Current status of issue bundle: [Brief summary of what was already done from other agents.]

[If handoff notes collected from prior agent groups:]
Handoff from prior agents:
[[ISSUE_ID] (agent:[TYPE])]:
- [extracted handoff notes]
</delegation_format>

## 3. Validate Agent Return

**Expected format**: `Branch: ... | Commit: [SHA] | QA Labels: ... | Summary: Posted ✓`

1. **Run ALL checks** — do not proceed if ANY fails:
   ```bash
   PRE_SHA=$(.agents/skills/orch/scripts/workflow-state get [ISSUE_ID] '.pre_delegate_sha // empty')
   HEAD_SHA=$(git -C "[WORKTREE_PATH]" rev-parse HEAD)

   # Check the implementation produced committed work.
   git -C "[WORKTREE_PATH]" log -1 --oneline
   test -z "$PRE_SHA" || test "$HEAD_SHA" != "$PRE_SHA"

   # Check no implemented files were left outside the commit.
   test -z "$(git -C "[WORKTREE_PATH]" status --porcelain)"

   # Linear only: check state + summary (auto-includes pending children from bundle)
   .agents/skills/linear/scripts/linear.sh issues validate-completion [ISSUE_ID] --include-children-of [ISSUE_ID]
   ```

   **GitHub/ad-hoc**: no tracker validation — require a new commit, a clean worktree, and a return message with Branch, Commit, QA Labels, and Summary content.

2. **Evaluate results** (Linear):

   | Field | Expected | Failure Action |
   |-------|----------|----------------|
   | commit | `HEAD` advanced from `pre_delegate_sha` | Re-delegate § 2 with retry instructions |
   | worktree | `git status --porcelain` empty | Re-delegate § 2: commit or revert leftover files |
   | `.all_ok` | `true` | Check `.results[]` below |
   | `.results[].state_ok` | `true` | Re-delegate § 2 |
   | `.results[].has_summary` | `true` | Re-delegate § 2 with retry instructions |

3. **On failure**: Do NOT proceed. Re-delegate to the same agent with retry instructions specifying the missing step(s). Never proceed with "may have a different format" or similar excuses.

4. **Store QA state**:
   ```bash
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] qa_labels '[QA_LABELS_ARRAY]'
   .agents/skills/orch/scripts/workflow-state set [ISSUE_ID] sub_issues '[SUB_ISSUE_IDS_ARRAY]'
   ```

5. **If validate failures reported**: Investigate, suggest sub-issue (summary, steps, agent). Ask user before creating.

---

## 4. Return State

**If managed**: Return to the parent workflow's next section.

**If standalone**: Session complete — dev implementation complete.
