# Review

Code review of pending changes via external model. The script auto-generates the review prompt (embedded schema, review lenses, the repo's own instruction files); no custom prompt is needed.

With no `--target` and no `SECOND_OPINION_TARGET`, the script takes the first eligible entry of `SECOND_OPINION_MODELS` that is not this session's model (`SECOND_OPINION_COUNT` of 2 or more runs that many distinct models in parallel and writes one union artifact) — do not pass `--target` unless the user asked for a specific model. A refusal (exit 1, "no eligible cross-model target") is reported as-is, never worked around by forcing the same model.

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

If user specifies a PR number → resolve the worktree path first, then pass `--cwd`.

## 2. Run Script

Run `second-opinion …`; it backgrounds itself and prints when to check.

```bash
.agents/skills/second-opinion/scripts/second-opinion review \
  [--range RANGE] \
  --cwd [PROJECT_PATH] \
  --output [PROJECT_PATH]/tmp/review-external-YYYYMMDD-HHMMSS.json \
  --foreground
```

Execute the exact command printed after `wait:`. Exit 75 means completion is still recoverable; do other event checks, then rerun the same command. Exit 124 is terminal: the run reached its deadline, and its processes are stopped when they can still be identified as belonging to it. Continue until terminal before reading or validating the artifact.

## 3. Present Results

Standard review-finding JSON — same schema used by all internal review agents:

```json
{
  "agent": "external-[TARGET]",
  "verdict": "pass|action_required",
  "summary": "1-2 sentence summary",
  "blockers": [],
  "suggestions": [],
  "questions": [],
  "qa_metadata": {}
}
```

When multiple lanes ran, the artifact is a union — field meanings, merge rules, and lane-artifact placement: [../references/multi-lane.md](../references/multi-lane.md). When `qa_metadata.coverage` is `"degraded"`, say so when presenting. `qa_metadata.reviewed_head` records the head commit the review covered — budget review passes per head, not per submission.

`questions` is always empty (no PR comment context).

The script never writes an artifact for a review that did not happen (empty diff, response unusable after its one retry, CLI never answered — each exits non-zero). **On any non-zero exit, report what failed instead of presenting a verdict**; the codes and their sidecar files are in `second-opinion --help`.

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

Omit empty sections. If `action_required` → ask user which items to address.
