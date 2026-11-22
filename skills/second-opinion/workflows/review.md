# Review

Code review of pending changes via external model. The script builds the review prompt, so no custom prompt is needed.

## 1. Interpret Scope

Translate the user's request into a `--range` value. The script passes it directly to `git diff`:

| User says | `--range` value | What it reviews |
|-----------|-----------------|-----------------|
| `review` (no qualifier) | (omit — default) | Full branch diff vs base (`origin/main...HEAD`) |
| "review this branch" / "review the PR" | (omit — default) | Same — all commits on this branch |
| "review uncommitted work" / "review staged changes" | `HEAD` | Uncommitted changes only |
| "review last commit" | `HEAD~1..HEAD` | Most recent commit |
| "review last 3 commits" | `HEAD~3..HEAD` | Last N commits |
| "review since yesterday" | `@{yesterday}..HEAD` | Commits since a time |
| "review abc123..def456" | `abc123..def456` | Explicit range (pass through) |

If the user names a PR number, resolve its worktree path first, then pass it as `--cwd`.

## 2. Run Script

Run `second-opinion …`; it backgrounds itself and prints when to check.

```bash
.agents/skills/second-opinion/scripts/second-opinion review \
  [--range RANGE] \
  --cwd [PROJECT_PATH] \
  --output [PROJECT_PATH]/tmp/review-external-YYYYMMDD-HHMMSS.json \
  --foreground
```

1. Execute the exact command printed after `wait:`.
2. Follow its exit handling in `second-opinion --help` until terminal.
3. Then read and validate the artifact.

## 3. Present Results

The artifact is review-finding JSON, the schema every internal review agent uses.

- When multiple lanes ran, the artifact is a union. Field meanings, merge rules and lane-artifact placement: [../references/multi-lane.md](../references/multi-lane.md).
- When `qa_metadata.coverage` is `"degraded"`, say so when presenting.
- `qa_metadata.reviewed_head` records the head commit the review covered. Budget review passes per head, not per submission.
- **On any non-zero exit, report what failed instead of presenting a verdict.** The codes and their sidecar files are in `second-opinion --help`.

<output_format>

### External Review — [TARGET]

| Verdict | Agent | Summary |
|---------|-------|---------|
| ✅ pass / ⚠️ action_required | external-[TARGET] | [SUMMARY] |

**Blockers**

| # | Location | Description | Pri |
|---|----------|-------------|-----|
| [id] | [location] | [description] | 🔴 |

**Suggestions**

| # | Location | Description | Cat | Pri |
|---|----------|-------------|-----|-----|
| [id] | [location] | [description] | fix/issue | 🟡 |

</output_format>

- Omit empty sections.
- If the verdict is `action_required`, ask the user which items to address.
