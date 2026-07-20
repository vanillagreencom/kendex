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

If the delegation provided a `Diff-range`, compute the diff directly:

```bash
git -C [WORKTREE_PATH] diff [DIFF_RANGE]
```

Otherwise resolve the base branch, then diff the branch against it (two separate commands, no shell composition):

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] diff "origin/[BASE_BRANCH_FROM_PREVIOUS_COMMAND]"...HEAD
```

Review for noteworthy findings only — skip minor style issues. Exclude research documents.
Apply the reviewer skill's General Review Ethos and Reviewer Scope Boundaries. Stay within this agent's domain; do not duplicate another specialist unless your domain adds distinct evidence, impact, or remediation.
Read changed files and directly affected call paths from the worktree as needed before reporting non-trivial findings; the delegating agent does not need to inline full file contents.
When running read-only checks to verify a finding, follow the reviewer skill's Harness-Safe Shell rule: one command per check, no compound or composed shells.
If a changed path was deleted, inspect it from the git diff or git history; do not try to `Read` the deleted working-tree path directly.

### 1.2 Read Decisions

Read decision files listed in delegation. Do NOT suggest changes that contradict them.

If a listed decision file does not exist (`test -f [PATH]` fails), the delegation broke the orchestrator's decision-path provenance rule (vstack#696) — do not hunt for the intended file. Note the broken reference in your returned report and recover decision context directly with `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` (decider skill), reading the full files at the paths its JSON output returns.

### 1.3 Classify Findings

Read the orch skill's recommendation-bias patterns. Apply its decision flow to ALL findings — a finding must pass actionability and relatedness checks before entering `blockers[]` or `suggestions[]`. Then use size to categorize suggestions as `fix` or `issue`.

### 1.4 Handle Re-Review

**Skip if** no "Re-review" section in delegation message.

Items listed as fixed or escalated are already resolved — do NOT re-report them. Only report NEW issues or regressions introduced by the fixes.

### 1.5 Return JSON Report

Build JSON per [`../schemas/review-finding.md`](../schemas/review-finding.md). Target artifact path: `[WORKTREE_PATH]/tmp/review-[AGENT]-YYYYMMDD-HHMMSS.json`.

`[AGENT]` is your FULL agent name, including its `reviewer-` prefix. For `reviewer-security` the file is `review-reviewer-security-20260720-141530.json`. The doubled `review-reviewer-` is correct — do not shorten or de-duplicate it to `review-security-…`; orch's `review-artifact-check` globs the literal full agent name and reports the artifact `missing` otherwise.

Artifact write path:
- Create `[WORKTREE_PATH]/tmp` with `mkdir -p [WORKTREE_PATH]/tmp` if it does not exist.
- Write the JSON with the harness file-write/edit tool. In Codex, use `apply_patch` to add or update the exact artifact path.
- Do not use shell redirection, heredocs, `tee`, `echo >`, command substitution, or redirected `cat` writes to create the JSON.

**Verdict rules:**
- `action_required`: 1+ items in `blockers[]`
- `pass`: `blockers[]` empty

### 1.6 Return

Send this result to the orchestrator as an agent-to-agent message. **Writing the JSON to disk is not a return** — the orchestrator does not poll the filesystem, and turn text is not visible across team boundaries. Send exactly one message with the body below, then go idle.

**Return exactly** (return to orchestrator; `[AGENT]` is your full agent name including the `reviewer-` prefix, e.g. `review-reviewer-security-20260720-141530.json`):

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
