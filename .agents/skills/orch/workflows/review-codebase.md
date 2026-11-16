# Codebase Review Workflow

Run every reviewer over a whole repository and present what they find. There is no pull request, issue, diff or fix delegation. Always standalone: no managed lifecycle and no state file.

| Command | Behavior |
|---------|----------|
| `review-codebase` | Review the current repository root |
| `review-codebase [PATH]` | Review the repository or worktree at `[PATH]` |

## 1. Resolve The Worktree

```bash
.agents/skills/orch/scripts/git-context repo-root [PATH_OR_PWD]
```

Not a git worktree: report `review-codebase requires a git worktree` and **END**. Otherwise the output is `WT_PATH`; run `mkdir -p "$WT_PATH/tmp"`.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`, where `[DIR]` is the `[PATH_OR_PWD]` above.

## 2. Delegate

1. Apply [Delegation](../references/skill-rules.md#delegation) before selecting any stored reviewer session.
2. `[AGENTS]` is every `reviewer-*` agent this harness exposes: use the full list and filter by no path. With none available, report `No reviewer agents installed; cannot run codebase review` and **END**.
3. Resolve the reviewer mode per [skill-rules.md § Agent Lifecycle](../references/skill-rules.md#agent-lifecycle):

   ```bash
   .agents/skills/orch/scripts/orch-env REVIEWER_SLOT_BUDGET 0
   ```

4. `0` delegates to every reviewer in one parallel batch. A positive value smaller than the reviewer count runs bounded waves, retiring each finished session before the next wave. A thread-limit spawn failure under an unlimited budget continues in waves sized by the reviewers that did spawn. This workflow runs no re-review.
5. On Codex, take the spawn parameters for each canonical reviewer name from `.agents/skills/agent-runtime/scripts/agent-runtime subagent spawn --harness codex <reviewer-name>`, under [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse).

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/codebase-review.md

Worktree: [WT_PATH]
Scope: Whole codebase. Inspect tracked, non-generated project code, plus the tests, configs, and docs relevant to your review domain. Do not sample or restrict to changed files. No PR, no issue, no diff.
Exclusions: generated artifacts, dependency and vendor directories, build outputs, binary assets, harness mirrors, and lockfiles unless your domain specifically requires them.
</delegation_format>

## 3. Present Findings

Wait for every reviewer and read the returned JSON files. A reviewer that does not return the expected format is listed `unresponsive`, and the run continues. Never synthesize a finding. The overall verdict is `action_required` when any reviewer returned a blocker, else `pass`.

Output: [Lane Output](../references/skill-rules.md#lane-output).

<output_format>

### CODEBASE REVIEW COMPLETE

| Agent | Verdict | Path |
|-------|---------|------|
| **Overall** | `[pass\|action_required]` | |
| [AGENT] | `[pass\|action_required\|unresponsive]` | `[path or —]` |

## Blockers

| # | Agent | Location | Description | Pri |
|---|-------|----------|-------------|-----|
| 1 | [agent] | [location] | [description] | [priority] |

## Suggestions

| # | Agent | Location | Description | Pri | Est | Category |
|---|-------|----------|-------------|-----|-----|----------|
| 1 | [agent] | [location] | [description] | [priority] | [estimate] | [fix\|issue] |

</output_format>

Omit an empty Blockers or Suggestions section. Offer no automatic fix.
