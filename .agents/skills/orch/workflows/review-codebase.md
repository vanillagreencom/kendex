# Codebase Review Workflow

Run every reviewer over a whole repository and present the findings. This workflow has no pull request, issue, diff or fix delegation. It always runs standalone, with no managed lifecycle and no state file.

| Command | Behavior |
|---------|----------|
| `review-codebase` | Review the current repository root |
| `review-codebase [PATH]` | Review the repository or worktree at `[PATH]` |

## 1. Resolve The Worktree

```bash
.agents/skills/orch/scripts/git-context repo-root [PATH_OR_PWD]
```

1. Not a git worktree: report `review-codebase requires a git worktree` and **END**.
2. Otherwise the output is `WT_PATH`. Run `mkdir -p "$WT_PATH/tmp"`.
3. Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`, where `[DIR]` is `[PATH_OR_PWD]`.

## 2. Delegate

1. Apply [Delegation](../references/skill-rules.md#delegation) before you select any stored reviewer session.
2. `[AGENTS]` is every `reviewer-*` agent this harness exposes, with no path filter. With none, report `No reviewer agents installed; cannot run codebase review` and **END**.
3. Resolve the reviewer mode per [skill-rules.md § Agent Lifecycle](../references/skill-rules.md#agent-lifecycle):

   ```bash
   .agents/skills/orch/scripts/orch-env REVIEWER_SLOT_BUDGET 0
   ```

4. Launch by the budget:
   - `0` delegates to every reviewer in one parallel batch.
   - A positive value below the reviewer count runs bounded waves: retire each finished session before the next wave.
   - A thread-limit spawn failure under an unlimited budget continues in waves the size of the reviewers that spawned.
   - This workflow runs no re-review.
5. On Codex, spawn each canonical reviewer name by [codex-runtime.md § Spawning Codex collaboration agents](../references/codex-runtime.md#spawning-codex-collaboration-agents), under [Codex thread reuse](../references/skill-rules.md#codex-thread-reuse).

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/codebase-review.md

Worktree: [WT_PATH]
Scope: Whole codebase. Inspect tracked, non-generated project code, plus the tests, configs, and docs relevant to your review domain. Do not sample or restrict to changed files. No PR, no issue, no diff.
Exclusions: generated artifacts, dependency and vendor directories, build outputs, binary assets, harness mirrors, and lockfiles unless your domain specifically requires them.
</delegation_format>

## 3. Present Findings

1. Wait for every reviewer, then read the returned JSON files.
2. List a reviewer that returns another format as `unresponsive`, and continue.
3. Never synthesize a finding.
4. The overall verdict is `action_required` when any reviewer returned a blocker, else `pass`.

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

- Omit an empty Blockers or Suggestions section.
- Offer no automatic fix.
