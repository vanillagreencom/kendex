# Review Workflow

On-demand review of local changes: review, present findings, and offer to fix the selected ones. Always standalone — no managed lifecycle, no caller context.

| Command | Behavior |
|---------|----------|
| `review` | Uncommitted changes since the last commit |
| `review all` | All branch changes vs the base, committed and uncommitted |
| `review last [N]` | The last N commits |
| `review [HASH]` | A single commit |

## 1. Scope

```bash
.agents/skills/orch/scripts/git-context branch .
.agents/skills/orch/scripts/git-context issue-from-branch .
.agents/skills/orch/scripts/resolve-base-branch .
```

Use the outputs as `BRANCH`, `ISSUE_ID` (empty means skip every workflow-state step), and `BASE_BRANCH`; `WT_PATH` is `git-context repo-root .`.

Fill `Worktree:` and `Worktree Check:` from `git -C "[DIR]" rev-parse --show-toplevel`.
`[DIR]` is the `.` the line above resolves `WT_PATH` from.

| Argument | `DIFF_RANGE` |
|----------|-------------|
| (none) | `HEAD` — uncommitted, staged and unstaged |
| `all` | `origin/[BASE_BRANCH]..` |
| `last [N]` | `HEAD~[N]..HEAD` |
| `[HASH]` | `[HASH]~1..[HASH]` |

```bash
git -C . diff [DIFF_RANGE] --stat
```

No changes → report "No changes to review" and **END**.

**Decision context** — skip when no `ISSUE_ID`:

```bash
.agents/skills/decider/scripts/decisions search --issue [ISSUE_ID]
```

The `path` fields in that JSON are the ONLY authorized source for decision file paths — never compose or recall one from memory. Verify each before injecting it, one command per path:

```bash
test -f [DECISION_FILE_PATH]
```

A failed check omits the path and carries `- decision index lookup failed for [DECISION_ID]` instead.

## 2. Launch Reviewers

`[AGENTS]` is every `reviewer-*` agent this harness exposes. Resolve the reviewer mode per [SKILL.md § Agent Lifecycle](../SKILL.md#agent-lifecycle):

```bash
.agents/skills/orch/scripts/orch-env REVIEWER_SLOT_BUDGET 0
```

`0` delegates to every reviewer in one parallel batch. A positive value smaller than the reviewer count runs bounded sequential waves — launch up to the available slots, wait for each return, retire the completed session, launch the next wave. If a spawn fails with the runtime's thread-limit error despite an unlimited budget, continue in waves sized by the reviewers that did spawn and recommend the observed budget to the user. Review state lives in the returned artifacts, never in reviewer session memory. On Codex, resolve spawn parameters with `scripts/spawn-adapter spawn <reviewer-name>`.

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/review.md

Worktree: [WT_PATH]
Worktree Check: `pwd -P` before any repo-relative command; it must print [WT_PATH]. On any other path, stop and report where the shell started.
Branch: [BRANCH]
Diff-range: [DIFF_RANGE]

Decisions:
[For each verified decision: "- [DECISION_ID]: [ONE_LINE_SUMMARY] — [DECISION_FILE_PATH]"]
[For each decision whose path failed verification: "- decision index lookup failed for [DECISION_ID]"]
[If none: "- No linked decisions found."]
</delegation_format>

## 3. Collect Results

Wait for every reviewer. Under an unlimited budget do NOT shut them down before § 4; in wave mode they are already retired.

Extract the report path and verdict from each return; halt and report if any return does not carry them. Overall verdict is `action_required` when any reviewer has blockers, else `pass`. With an `ISSUE_ID`, append each path:

```bash
.agents/skills/orch/scripts/workflow-state append [ISSUE_ID] json_paths "[PATH]"
```

<output_format>

### CODE REVIEW COMPLETE

| Agent | Verdict | Path |
|-------|---------|------|
| **Overall** | `[pass\|action_required]` | |
| [AGENT] | `[verdict]` | `[path]` |

</output_format>

Blockers or any `fix`/`issue` suggestion → § 4. Otherwise → § 5.

## 4. Present And Fix

Collect the blockers, the `category == "fix"` suggestions, and the `category == "issue"` suggestions. Decline anything that cannot affect real usage with a one-line reason, per [SKILL.md § The Cycle](../SKILL.md#the-cycle). Nothing left → § 5.

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

Omit empty categories. **Disposition is by rule, not by prompt** — never present a selection menu over the findings. Disposition every finding per [references/finding-disposition.md](../references/finding-disposition.md) § Decision flow, Step 0 first, and only what survives it enters the fix set. Every surviving blocker and `category == "fix"` suggestion is fixed; declines are reported in § 5. `ORCH_DECISION_MODE` does not reintroduce the menu; the always-ask set in [SKILL.md § The Cycle](../SKILL.md#the-cycle) still applies.

**Never fix as the main agent.**

```bash
.agents/skills/orch/scripts/workflow-state set-git-head [ISSUE_ID] pre_delegate_sha [WT_PATH]
```

**Run Workflow**: `⤵ workflows/dev-fix.md § 1-3 → § 4 tail` with context `worktree`, `lifecycle: "managed"`, `dev_agent` (from state or labels), `issue_id`, `items` (every blocker plus every `category == "fix"` suggestion, each formatted `#[N] | [Agent] | [Location]` with Description and Recommendation), `source: review`. State writes for fixed and escalated items belong to dev-fix — do not repeat them here.

<output_format>

### Fix Results

| # | Decision | Commit | Reasoning |
|---|----------|--------|-----------|
| N | Applied/Skipped/Blocked | [SHA] | [explanation] |

</output_format>

Apply [references/finding-disposition.md](../references/finding-disposition.md) § Filing bar to every candidate: `category == "issue"` suggestions and the escalated items from the fix round alike. What clears it builds an audit-input file at `tmp/audit-review-YYYYMMDD-HHMMSS.json` per `.agents/skills/project-management/schemas/audit-issues-input.md` with `source: "review"`, `parent_issue: [ISSUE_ID]` (or null), and `worktree: [WT_PATH]`. Each escalated item's `origin` comes from its `outcome`: `"skipped"` → `origin: "skipped"`; `"blocked"` or no `outcome` field → `origin: "escalated"`. Then `⤵ .agents/skills/project-management/workflows/audit-issues.md --issues [FILE_PATH] § 1-9 → § 5`.

audit-issues is a primary-session wrapper holding the interactive approval gate: run it in this session, never delegated to a subagent; the only delegable part is the `tpm-audit.md` analysis, which audit-issues spawns itself.

## 5. Summary

Shut the review agents down (wave runs already did).

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
