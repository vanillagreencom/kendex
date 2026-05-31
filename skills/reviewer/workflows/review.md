# Code Review Lifecycle

**The workflow for review agents — project-configured review specialists (e.g., correctness-review, quality-review, security-review, test-review, doc-review).**

Review agents are code reviewers. They run in parallel, each reviewing the same changes from their specialist perspective.

**Ownership**: You review the specified changes. Return verdict to orchestrator. No issue tracker state changes.

---

## 1. Review Changes

Extract from delegation message:
- `Worktree` path
- `Branch` name
- `Diff-range` (optional) for computing diff
- `Decisions` to respect
- Re-review context (if any)

### 1.1 Diff

```bash
# Use Diff-range from delegation if provided, otherwise diff full branch
if [[ -n "$DIFF_RANGE" ]]; then
  git -C [WORKTREE_PATH] diff $DIFF_RANGE
else
  BASE_BRANCH=${WORKTREE_DEFAULT_BRANCH:-$(git -C [WORKTREE_PATH] symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')}
  [ -n "$BASE_BRANCH" ] || BASE_BRANCH=main
  git -C [WORKTREE_PATH] diff "origin/$BASE_BRANCH"...HEAD
fi
```

Review for noteworthy findings only — skip minor style issues. Exclude research documents.
Apply the reviewer skill's General Review Ethos and Reviewer Scope Boundaries. Stay within this agent's domain; do not duplicate another specialist unless your domain adds distinct evidence, impact, or remediation.
Read changed files and directly affected call paths from the worktree as needed before reporting non-trivial findings; the delegating agent does not need to inline full file contents.
If a changed path was deleted, inspect it from the git diff or git history; do not try to `Read` the deleted working-tree path directly.

### 1.2 Read Decisions

Read decision files listed in delegation. Do NOT suggest changes that contradict them.

### 1.3 Classify Findings

Read the linear-orch skill's recommendation-bias patterns. Apply its decision flow to ALL findings — a finding must pass actionability and relatedness checks before entering `blockers[]` or `suggestions[]`. Then use size to categorize suggestions as `fix` or `issue`.

### 1.4 Handle Re-Review

**Skip if** no "Re-review" section in delegation message.

Items listed as fixed or escalated are already resolved — do NOT re-report them. Only report NEW issues or regressions introduced by the fixes.

### 1.5 Return JSON Report

Build JSON per [`../schemas/review-finding.md`](../schemas/review-finding.md). Save to `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json`.

**Verdict rules:**
- `action_required`: 1+ items in `blockers[]`
- `pass`: `blockers[]` empty

### 1.6 Return

Send this result to the orchestrator as an agent-to-agent message. **Writing the JSON to disk is not a return** — the orchestrator does not poll the filesystem, and turn text is not visible across team boundaries. Send exactly one message with the body below, then go idle.

**Return exactly** (return to orchestrator):

<output_format>
Verdict: [pass|action_required]
File: [WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json
```json
{complete JSON object}
```
</output_format>

---

## Constraints

**Do NOT**:
- Modify issue tracker state (labels, status)
- Create commits or push changes
- Call other subagents

**Orchestrator handles**: All issue tracker updates, routing items back to dev agent, merging JSONs, presentation.
