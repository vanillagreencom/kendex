# Codebase Review Workflow

Ad-hoc whole-codebase reviewer fanout. No PR, no issue, no diff, no fix delegation. Always standalone — no managed lifecycle and no workflow-state file.

| Command | Behavior |
|---------|----------|
| `review-codebase` | Review the current repository root |
| `review-codebase [PATH]` | Review the repository or worktree at `[PATH]` |

## 1. Resolve The Worktree

```bash
.agents/skills/orch/scripts/git-context repo-root [PATH_OR_PWD]
```

Not a git worktree → report `review-codebase requires a git worktree` and **END**. Otherwise use the output as `WT_PATH` and `mkdir -p "$WT_PATH/tmp"`.

Fill `Worktree:` from `git -C "[DIR]" rev-parse --show-toplevel`.
`[DIR]` is the `[PATH_OR_PWD]` § 1 resolves `WT_PATH` from.

## 2. Delegate

`[AGENTS]` is every `reviewer-*` agent this harness exposes; use the full list and do not path-filter. None available → report `No reviewer agents installed; cannot run codebase review` and **END**.

Resolve the reviewer mode per [references/skill-rules.md § Agent Lifecycle](../references/skill-rules.md#agent-lifecycle):

```bash
.agents/skills/orch/scripts/orch-env REVIEWER_SLOT_BUDGET 0
```

`0` delegates to every reviewer in one parallel batch; a positive value smaller than the reviewer count runs bounded sequential waves, retiring each completed session before launching the next. A thread-limit spawn failure under an unlimited budget continues in waves sized by the reviewers that did spawn. No re-review cycles here. On Codex, resolve spawn parameters with `scripts/spawn-adapter spawn <reviewer-name>`.

<delegation_format>
Follow workflow: .agents/skills/reviewer/workflows/codebase-review.md

Worktree: [WT_PATH]
Scope: Whole codebase. Inspect tracked, non-generated project code, plus the tests, configs, and docs relevant to your review domain. Do not sample or restrict to changed files. No PR, no issue, no diff.
Exclusions: generated artifacts, dependency and vendor directories, build outputs, binary assets, harness mirrors, and lockfiles unless your domain specifically requires them.
</delegation_format>

## 3. Present Findings

Wait for every reviewer and read the returned JSONs. A reviewer that does not return the expected format is listed `unresponsive` and the run continues. Do not synthesize findings. Overall verdict is `action_required` when any reviewer returned blockers, else `pass`.

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

Omit an empty Blockers or Suggestions section. Do not offer to fix items automatically.
