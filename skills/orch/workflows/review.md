# Review Workflow

Review local changes on demand. Run every reviewer, present the findings, and fix what survives disposition. This workflow always runs standalone, with no managed lifecycle and no caller context.

| Command | Behavior |
|---------|----------|
| `review` | Uncommitted changes since the last commit |
| `review all` | All branch changes against the base, committed and uncommitted |
| `review last [N]` | The last N commits |
| `review [HASH]` | A single commit |

## 1. Scope

```bash
.agents/skills/orch/scripts/git-context branch .
.agents/skills/orch/scripts/git-context issue-from-branch .
.agents/skills/orch/scripts/resolve-base-branch .
```

The outputs are `BRANCH`, `ISSUE_ID` and `BASE_BRANCH`. An empty `ISSUE_ID` means § 2 mints a local key. `WT_PATH` is `git-context repo-root .`. Fill `Worktree:` from `git -C . rev-parse --show-toplevel`.

| Argument | `DIFF_RANGE` |
|----------|-------------|
| (none) | `HEAD` — uncommitted, staged and unstaged |
| `all` | `origin/[BASE_BRANCH]..` |
| `last [N]` | `HEAD~[N]..HEAD` |
| `[HASH]` | `[HASH]~1..[HASH]` |

```bash
git -C . diff [DIFF_RANGE] --stat
```

No changes: report "No changes to review" and **END**.

**Decision context.** Skip it with no `ISSUE_ID`. Otherwise run [review-pr.md § 1.1 Decision Context](review-pr.md#11-decision-context); its results fill the delegation's `Decisions:` block.

## 2. Launch Reviewers

1. **State key.** With no `ISSUE_ID`, mint a local key with `orch-runtime state new-local-key` and take `LOCAL_KEY` from the reply's `result.key`. Initialize it with `orch-runtime state init --item [LOCAL_KEY] --worktree [WT_PATH] --branch [BRANCH]`, and use it as `ISSUE_ID` from here; § 5 removes it. Initialize an issue key with no state the same way.
2. **Admission.** This run is one [Record verified findings](../schemas/workflow-state.md#record-verified-findings) batch with state writes enabled. Admit it before any reviewer starts. § 3 is its acceptance; § 4 is its disposition and completion.
3. Apply [Delegation](../references/skill-rules.md#delegation) for the target worktree before you select any stored reviewer session.
4. `[AGENTS]` is every `reviewer-*` agent this harness exposes. Resolve the reviewer mode per [skill-rules.md § Agent Lifecycle](../references/skill-rules.md#agent-lifecycle):

   ```bash
   .agents/skills/orch/scripts/orch-env REVIEWER_SLOT_BUDGET 0
   ```

5. `0` delegates to every reviewer in one parallel batch. A positive value below the reviewer count runs bounded waves: launch up to the available slots, wait for each return, retire the finished session, then launch the next wave. When a spawn fails with the runtime's thread-limit error under an unlimited budget, continue in waves the size of the reviewers that spawned. Recommend that observed budget to the user.
6. On Codex, spawn each canonical reviewer name by [codex-runtime.md § Spawning Codex collaboration agents](../references/codex-runtime.md#spawning-codex-collaboration-agents), under [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse).

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/review.md

Worktree: [WT_PATH]
Branch: [BRANCH]
Diff-range: [DIFF_RANGE]

Decisions:
[For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
[If none: "- No linked decisions found."]
</delegation_format>

## 3. Collect Results

Wait for every reviewer. Under an unlimited budget, keep the sessions alive until § 4. Wave mode has already retired them.

1. Take the report path and verdict from each return. A return with neither halts the run: report it.
2. Accept each returned file by the contract's acceptance step.
3. Record each accepted path:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-agents","step":"returned","artifact":"[PATH]"}'
   ```

4. The overall verdict is `action_required` when any reviewer reported a blocker, else `pass`.

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### CODE REVIEW COMPLETE

| Agent | Verdict | Path |
|-------|---------|------|
| **Overall** | `[pass\|action_required]` | |
| [AGENT] | `[verdict]` | `[path]` |

</output_format>

A blocker, or any `fix` or `issue` suggestion: § 4. Otherwise complete the contract with the empty finding set, then § 5.

## 4. Present And Fix

1. Collect the blockers, the `category == "fix"` suggestions and the `category == "issue"` suggestions.
2. Read `patched_causes` and `frozen_causes` first, with the command [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence) states. A finding that shares a cause there takes that section's disposition, never another patch.
3. Decline, with a one-line reason, anything that cannot affect real usage ([SKILL.md § The Cycle](../SKILL.md#the-cycle)).
4. Nothing left: complete the contract, then § 5.

Output: [Lane Output](../references/skill-rules.md#lane-output).

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

Omit empty categories.

**Disposition is by rule, not by prompt.** Present no selection menu over the findings, whatever `ORCH_DECISION_MODE` reads. The ask set in [communication-modes.md](../references/communication-modes.md) § Ask set still applies. Disposition every finding by [finding-disposition.md § Decision flow](../../reviewer/references/finding-disposition.md#decision-flow), Step 0 first. Only what survives enters the fix set. Fix every surviving blocker and `category == "fix"` suggestion; § 5 reports the declines.

**Never fix as the main agent.**

1. Complete [Record verified findings](../schemas/workflow-state.md#record-verified-findings) for this batch.
2. An empty fix set goes to the filing step below, or to § 5. Otherwise record the round's base under either key:

   ```bash
   .agents/skills/orch/scripts/orch-runtime op --item [ISSUE_ID] --request-json '{"op":"record-round","step":"base","worktree":"[WT_PATH]"}'
   ```

3. **Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § 4 step 4` with context `worktree`, `lifecycle: "managed"`, `dev_agent` (from state or labels), `issue_id`, `items` (every surviving blocker and `category == "fix"` suggestion, each formatted per [dev-round.md § Item text](../schemas/dev-round.md#item-text)), and `source: review`. Dev-fix writes the state of the fixed and escalated items; write none of it here.
4. Present the fix results.

   Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### Fix Results

| # | Decision | Commit | Reasoning |
|---|----------|--------|-----------|
| N | Applied/Skipped/Blocked | [SHA] | [explanation] |

</output_format>

**Filing.** Apply [finding-disposition.md § Filing bar](../../reviewer/references/finding-disposition.md#filing-bar) to every candidate: the `category == "issue"` suggestions and the fix round's escalated items.

1. Build an audit-input file from what clears the bar at `tmp/audit-review-YYYYMMDD-HHMMSS.json`, per `.agents/skills/project-management/schemas/audit-issues-input.md`. Set `source: "review"`, `parent_issue: [ISSUE_ID]` (null for a minted local key) and `worktree: [WT_PATH]`. Each escalated item's `outcome` sets its `origin`: `"skipped"` gives `origin: "skipped"`; `"blocked"` or no `outcome` gives `origin: "escalated"`.
2. Apply [skill-rules.md § Coordination](../references/skill-rules.md#coordination), then `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 5`. A non-delegated primary session runs this wrapper itself. Only the `tpm-audit.md` analysis delegates, and audit-issues spawns it.

## 5. Summary

Shut the review agents down. Wave runs already did.

**Remove the local key.** **Skip if** § 2 minted no `LOCAL_KEY`. The close-out archives and removes the key's files ([workflow-state.md § Item close-out](../schemas/workflow-state.md#item-close-out)):

```bash
.agents/skills/orch/scripts/orch-runtime state remove --item [LOCAL_KEY]
```

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### ✅ REVIEW COMPLETE

| Metric | Value |
|--------|-------|
| Scope | [DIFF_RANGE description — e.g. "12 files, 3 commits vs main"] |
| Agents | [N] |
| Blockers | [N] |
| Fixes applied | [N] |
| Declined | [N] |
| Issues created | [N] |
| Escalated | [N] |

### Declined

| # | Agent | Location | Description | Reason |
|---|-------|----------|-------------|--------|
| 1 | [agent] | [location] | [description] | [one line] |

</output_format>

Omit zero-value rows except Scope and Agents, and omit the Declined table when nothing was declined.
