# Issue Lifecycle

The workflow for a dev or QA agent receiving a work-item delegation. Skip every tracker update for ad-hoc requests (no issue reference).

Run `pwd -P` before the first repo-relative command; it must print the delegation's `Worktree:` path. On any other path, stop and report where the shell started.

| Delegation | Detection | Flow |
|------|-----------|------|
| Single | `Issue: [ISSUE_ID]`, `GitHub Issue: OWNER/REPO#N`, or ad-hoc | § 1 → § 2 → § 4-10 → return |
| Bundled | `Parent: [ISSUE_ID]` + `Sub-Issues: [...]` | § 1 → § 2 → [§ 4-10]×N → § 11 |

**A bundle needs an explicit single-PR marker.** A parent with children is a CONTAINER unless one of exactly three markers is present: `(one PR)` in its title, `Audit Bundle: yes` in the delegation, or a leaf issue carrying an internal checklist. The title marker outranks an `agent:multi` label. With none present, stop and report the mis-delegation. Check the marker against the delegation's `Parent Title:` line; when a bundled delegation omits that line, read the title first — never classify from labels and children alone:

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh cache issues get [PARENT_ID]
```

In the sub-issue tree, complete blockers before the issues they block; entries marked `(completed)` are context only and are skipped in the § 4 loop.

---

## 1. Environment Setup

Every path is worktree-scoped: `git -C [WORKTREE_PATH] ...` for Bash, `[WORKTREE_PATH]/...` for file tools, once the working-directory check at the top of this file has passed.

Verify possession before reading or writing anything else. **Skip if** the delegation carries no `Worktree Lease:` line.

```bash
.agents/skills/worktree/scripts/worktree-session-guard refresh [WORKTREE_PATH] --owner [ARTIFACT_KEY]
```

Any non-zero exit ends the round here: change nothing in the worktree and return the command's stderr verbatim.

```bash
.agents/skills/orch/scripts/resolve-base-branch [WORKTREE_PATH]
git -C [WORKTREE_PATH] fetch origin [BASE_BRANCH_FROM_PREVIOUS_COMMAND]
```

---

## 2. Activate Work Item

### 2.1 Claim And Read Context

Determine the tracker: `Issue:`/`Parent: ABC-123` → Linear; `GitHub Issue: OWNER/REPO#N` → GitHub; no reference → ad-hoc (delegation text is the source of truth; skip every tracker write).

Linear only — activate the issue, or the parent alone if bundled (sub-issues activate individually in § 4):

```bash
.agents/skills/linear/scripts/linear.sh sync --reconcile
.agents/skills/linear/scripts/linear.sh issues activate [ISSUE_ID] --agent [AGENT_TYPE]
.agents/skills/linear/scripts/linear.sh cache issues get [ISSUE_ID]
.agents/skills/linear/scripts/linear.sh cache comments list [ISSUE_ID]
```

The sync must succeed before activation or any cache read. A missing cache before that command is expected in a fresh worktree. If the sync fails, stop and preserve its exact diagnostic: that is a sync/auth/API/config failure, not a missing-cache result. If a mandatory cache read reports `No cache found` after sync succeeded, stop and report a cache-initialization defect. Never run this Linear preflight for GitHub-tracked or ad-hoc work.

GitHub only:

```bash
gh issue view [N] --repo [OWNER/REPO] --json number,title,body,comments,labels,url
```

Ad-hoc: no tracker reads.

**If bundled with completed siblings**, read their comments too (`linear.sh cache comments list [COMPLETED_SIBLING_ID]`) for handoff notes.

### 2.2 Research Context

Read the issue description — `.description` from the cache read above, or `gh issue view [N] --repo [OWNER/REPO] --json body --jq .body`. For a sub-issue, read the parent's description too; for a bundle, read the unique paths across its sub-issues.

Cited research, decision, and context files are mandatory reading; how the research applies is yours to decide. Evaluate it against existing patterns and architecture docs, updating those docs when it changes documented patterns, and add anything project-specific worth persisting to `kendex.toml`. Reference an already-recorded decision (`.agents/skills/decider/scripts/decisions search --issue [RESEARCH_ISSUE_ID]`) rather than duplicating it; record a new one only for a decision your evaluation newly reveals.

### 2.3 Evaluate Feasibility

Check your domain's code before planning: do the required APIs and types exist, is another domain's work a prerequisite, is an existing issue blocking? Search prior decisions with `.agents/skills/decider/scripts/decisions search "[RELEVANT_KEYWORDS]"` and read the full decision file rather than the index summary — never implement an approach a decision explicitly rejects, and report back with the reference if the issue description contradicts one. Optimization work with no `baseline` label takes the label now, before any code change.

Blocked → **§ 3**, then STOP. Clear → § 2.4.

### 2.4 Plan Approach

- Linear only, when scope differs from the estimate: `.agents/skills/linear/scripts/linear.sh issues update [ISSUE_ID] --estimate N` (1=hours, 2=half-day, 3=day, 4=2-3 days, 5=week+).
- **If bundled**: order sub-issues by dependency and overlap.
- A required command written as `VAR=value cmd args` is normalized here into an ambient-environment precondition plus the bare `cmd args` (orch SKILL.md § Harness-Safe Shell). An unsatisfiable precondition is a blocker to report, never a license to run under the wrong environment.

### 2.5 Domain Setup

Follow your agent definition for architecture docs, code paths, and skills to load.

### 2.6 Capture Baseline

**Skip if** the issue has no `baseline` label. Otherwise identify the affected component and, when a benchmarking skill is installed, follow its baseline workflow.

---

## 3. Block Issue

**Skip if** § 2.3 routed you to § 2.4. GitHub and ad-hoc work reports the blocker in the return message instead of writing tracker state.

Linear only, when an existing issue blocks this one:

```bash
.agents/skills/linear/scripts/linear.sh issues block [ISSUE_ID] --by [BLOCKER_ID] --reason "Cannot proceed until [REASON]"
```

When the prerequisite issue does not exist yet, label the issue `blocked` (`linear.sh issues update [ISSUE_ID] --labels "agent:[AGENT_TYPE],[COMPONENT],blocked"`), then write `tmp/blocked-[ISSUE_ID].md` and post it with `linear.sh comments create [ISSUE_ID] --body-file tmp/blocked-[ISSUE_ID].md`:

```markdown
BLOCKED: Cross-domain prerequisite needed.

**Required Domain**: [DOMAIN]
**Suggested Labels**: agent:[DOMAIN], [COMPONENT]
**Prerequisite Issue**: [One-line description]

**Why Blocking**:
[What this issue needs, why it cannot proceed, what the prerequisite must provide]

**Suggested Scope**:
- [Deliverable 1]

Requesting orchestrator create prerequisite issue.
```

Your return states the blocker, the domain and labels for the new issue, and that the description is ready for creation. When a blocker later resolves: `linear.sh issues unblock [ISSUE_ID]`.

---

## 4. Implement

**If bundled**: each sub-issue is its own task through § 4-10. Work only the sub-issue named in the current task, activating it first with `linear.sh issues activate [SUB_ISSUE_ID] --agent [AGENT_TYPE]`.

### 4.1 Verify Branch

`git branch --show-current` must report `[BRANCH_NAME]` — the parent's branch when bundled.

### 4.2 Implement

Implement per your domain expertise and run quality gates before completion.

Before writing a refusal, a validator, a lock, a retry, or a test, read [dev SKILL.md § Engineering Rules](../SKILL.md#engineering-rules).

- **Scope growing?** Linear: `linear.sh issues create --state "Backlog" --project "[PARENT_PROJECT]" --parent [PARENT_ID] --labels "[VALIDATED_LABELS]" --description-file [BODY_FILE]` — the parent's project, `Backlog`, and the complete label set (your own `agent:*` label plus every category the project requires) validated against the live inventory. The body follows project-management's [issue-description-template.md](../../project-management/templates/issue-description-template.md), whose `Reached by:` line names what in this implementation run arrives at the discovered work. GitHub and ad-hoc report the discovered scope in § 9 instead; never create issues without orchestrator approval.
- **Work outside scope?** Note it under Discovered Work in § 9.
- **Need deeper research?** Add the `needs-research` label, pause, report.

### 4.3 Update Documentation And Decisions

Update docs when the implementation changes a documented API or architecture.

**Skip decision recording if** no alternatives were considered and no trade-offs made. Otherwise follow the decider skill's create-decision workflow: `.agents/skills/decider/scripts/decisions next-id`, a template from `templates/decision-entry.md`, the file per `schemas/decision-format.md`, the INDEX.md row per `templates/index-row.md`, `// REVISIT(DXXX):` markers in code where applicable, and the decision ID cited in the § 9 summary.

---

## 5. Validate

Before deterministic validation, run `git grep -n -F --untracked --exclude-standard -e <callee> --` for every callee whose call the change deletes, then apply [code-quality § Cleanup](../../code-quality/SKILL.md#cleanup); the build and tests below validate every deletion.

Deterministic gates first — every finding is fixed here, never carried into review. Preflight runs when installed (`test -x .agents/skills/preflight/scripts/preflight`); the size-ratchet gate runs in a repo where a baseline exists:

```bash
.agents/skills/preflight/scripts/preflight --repo [WORKTREE_PATH]
```
```bash
.agents/skills/size-ratchet/scripts/size-ratchet
```

Then the project's validation command — the one `.agents/skills/orch/scripts/orch-env DEV_VALIDATE_CMD ""` prints (empty → the project's documented build/test/lint command), run from the worktree root — plus the delegation's required verification commands in their § 2.4 normalized form. Failure handling and long-running runs: [dev SKILL.md § Validation](../SKILL.md#validation).

A script written only to produce a number for the issue is not committed; put its result in the PR body. Every check, guard, assertion, or test this change adds or modifies must have a must-fail control that runs red once ([code-quality § Prove Your Guards](../../code-quality/SKILL.md#prove-your-guards)); an uncommitted measurement is not a check the change adds or modifies.

**Visual QA** — **skip if** the issue has no `design` label. Otherwise use the project's visual QA skills to confirm what your change affects renders correctly, not the full checklist. Do NOT capture golden baselines.

---

## 6. Reflect

Follow [dev SKILL.md § Reflect](../SKILL.md#reflect).

---

## 7. Commit

```bash
git -C [WORKTREE_PATH] add -A
git -C [WORKTREE_PATH] commit -m "[PREFIX]([ISSUE_ID]): [DESCRIPTION]"
git -C [WORKTREE_PATH] log -1 --oneline
```

Use the CURRENT sub-issue ID when bundled, not the parent's. Never stage lock files the project gitignores — stage specific files by name. Append `[validate: FAILING_CHECK]` when validation failures remain.

---

## 8. Record QA Signals

Based on the FINAL validated code, decide which extra QA passes the change needs. Record them in the completion artifact (§ 10 `--qa-label`, one per signal), not a tracker mutation.

| Trigger | Signal |
|---------|--------|
| Unsafe code, atomics, lock-free | `needs-safety-audit` |
| Hot path, latency-sensitive, or shared/main-build perf risk | `needs-perf-test` |
| New module, public API | `needs-review` |

Work isolated behind a development-only feature gate does not take `needs-perf-test`: run the feature-gated checks locally and signal only if shared or feature-off paths are affected.

A signal is never silently dropped: every triggered row appears in the artifact and in the return's `QA:` line, and `none` is an explicit answer, not a default.

---

## 9. Post Completion Summary

### 9.1 Completion Comment

Always required. Linear posts it to the issue you implemented: write `tmp/completion-summary-[ISSUE_ID].md`, then `linear.sh comments create [ISSUE_ID] --body-file tmp/completion-summary-[ISSUE_ID].md`. GitHub and ad-hoc rounds return the same content to the orchestrator instead and ALSO carry it in the artifact via `--summary-file` (§ 10).

```markdown
## Completion Summary

**Agent**: [AGENT_NAME]
**Branch**: `[BRANCH]`

### Files Created/Modified
- `path/to/file` - Description

### Key Decisions
1. Decision and reasoning (DXXX if recorded)

### Skills/Docs/Rules Updated
- `skill-name`: Updated X

### Domain Metrics
[Agent-specific: frame time, latency, etc.]

### Discovered Work
- [Type]: Description (estimate: N)

### Handoff Notes
[What the next agent in this bundle needs for its current-scope work: struct changes, API contracts, file locations]
```

Omit any section that has nothing in it. Discovered Work is backlog work beyond this scope; Handoff Notes are for the next agent only, with no aspirational suggestions.

**Discovered Work marker prefixes.** A bullet belonging to a later stage of THIS PR rather than to the backlog carries a marker as the first token of the bullet text, before `[Type]`. Unmarked bullets go through the TPM audit as backlog work.

- `handoff_to_submit_pr:` — content the upcoming submit-pr step produces, e.g. PR-body material.
- `handoff_to_merge_pr:` — something the eventual merge-pr step handles.
- `current_workflow_action:` — something the current review-pr cycle should handle itself.

### 9.2 Downstream Handoff

**Skip if** the tracker is not Linear, this issue blocks nothing, or completion alone unblocks the downstream work.

Read `.blocks` from `linear.sh cache issues get [ISSUE_ID]`. Post to a downstream issue **only if** this work changed an API, interface, file, or contract it depends on: write `tmp/downstream-handoff-[ISSUE_ID]-to-[DOWNSTREAM_ISSUE_ID].md` naming what changed and what downstream needs to know, then post it with `linear.sh comments create [DOWNSTREAM_ISSUE_ID] --body-file [THAT_FILE]`. Never post it to the completed issue.

---

## 10. Finalize

With every applicable section above complete, write the artifact per [dev SKILL.md § Round Contract](../SKILL.md#round-contract):

```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [HEAD_SHA_AFTER_COMMIT] --validate [pass|"FAILING: check1,check2"] [--validate-note [TEXT]] [--qa-label [LABEL]]...
```

One `--qa-label` per § 8 signal, none if nothing triggered. GitHub and ad-hoc rounds append `--no-summary --summary-file tmp/completion-summary-[ISSUE_ID].md`. Bundled rounds add `--bundled` and one `--item` per sub-issue — § 11.

**A read-only analysis round**: § 5, § 7, and § 8 do not apply. Pass the recommendation inline or as a file — exactly one of the two:

```bash
# Single-quote inline text so dollars and double quotes pass literally; keep it
# plain (no backticks) and spell an embedded apostrophe as '\''.
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind analysis --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --summary '[RECOMMENDATION_TEXT]' [--no-summary]
```
```bash
.agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind analysis --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --summary-file tmp/analysis-[ARTIFACT_KEY].md [--no-summary]
```

Then return the recommendation in place of the block below.

**Issue state.** A bundled Linear sub-issue is marked Done (`linear.sh issues update [ISSUE_ID] --state "Done"`) and aggregated by the parent session in § 11. The worktree's top-level managed issue is NOT — it stays In Progress or In Review until the PR merges. GitHub and ad-hoc issues close through the PR body or merge, never here.

**If single**, return now:

<output_format>
Branch: [BRANCH_NAME]
Commit: [SHA]
QA: [signals or "none"]
Validate: [pass or "FAILING: check1, check2"]
Summary: [ISSUE_ID] ✓
</output_format>

**If bundled**, mark the task completed and take the next sub-issue as a separate task, or go to § 11 when none remain.

---

## 11. Return (Bundled)

**Skip if** single — you returned at § 10.

1. **Aggregate QA signals across sub-issues** (including nested ones) into the bundle artifact's `--qa-label` flags — the union of every sub-issue's § 8 signals. No tracker mutation.

2. **Post the parent summary** (Linear only): write `tmp/bundle-summary-[PARENT_ID].md`, then `linear.sh comments create [PARENT_ID] --body-file tmp/bundle-summary-[PARENT_ID].md`.

   ```markdown
   ## Bundle Complete
   **Agent**: [NAME] | **Branch**: [BRANCH]

   Sub-issues (tree):
   ↳ [SUB_ISSUE_1] ✓ | blocks: [SUB_ISSUE_2]
   ↳ [SUB_ISSUE_2] ✓ | blocked by: [SUB_ISSUE_1]
      ↳ [SUB_ISSUE_3] ✓  ← nested
   Files: N | Commits: N | QA: [LABELS]
   ```

3. **Write the artifact**, keyed to the Parent ID, with that group's `Round ID:` when the bundle was delegated in groups:

   ```bash
   .agents/skills/orch/scripts/dev-return-write --worktree [WORKTREE_PATH] --kind implement --issue [ARTIFACT_KEY] --round-id [DEV_ROUND_ID] --branch [BRANCH] --commit [LAST_SUBISSUE_HEAD_SHA] --validate [pass|"FAILING: check1,check2"] [--validate-note [TEXT]] --bundled --item [N] [DECISION] [REASONING] [--item ...] [--qa-label [LABEL]]...
   ```

   `--bundled` requires one `--item` per sub-issue result — `DECISION` is Applied, Skipped, or Blocked and `REASONING` non-empty plain text with no backticks — populated from the sub-issue tree. `--commit` is the last sub-issue's HEAD.

4. **Return.** Posting the parent summary is not a return.

   <output_format>
   Parent: [ISSUE_ID]
   Sub-Issues: [tree format with ✓]
   Branch: [BRANCH]
   Commits: [COUNT] ([SHAS])
   QA: [AGGREGATED_SIGNALS or "none"]
   Summaries: [all issue IDs ✓]
   </output_format>
