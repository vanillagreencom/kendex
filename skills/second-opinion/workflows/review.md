# Review

Code review of pending changes via external model. The script auto-generates the review prompt — embedded schema, the review lenses, and the repo's own instruction files (both listed in SKILL.md) — so no custom prompt is needed.

With no `--target` and no `SECOND_OPINION_TARGET`, the script runs **every available lane** in `SECOND_OPINION_REVIEW_TARGETS` (default: codex + claude) in parallel and writes one union artifact — do not pass `--target` unless the user asked for a specific model.

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

```bash
.agents/skills/second-opinion/scripts/second-opinion review \
  [--range RANGE] \
  --cwd [PROJECT_PATH] \
  --output [PROJECT_PATH]/tmp/review-external-YYYYMMDD-HHMMSS.json
```

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

When multiple lanes ran, the artifact is a union: `agent` is `external-union(<lane>+<lane>)`, each finding carries `sources` (the lanes that reported it, deduplicated by location), `qa_metadata.lanes` records every lane's outcome, and `qa_metadata.coverage` is `"full"` or `"degraded"` (a lane failed — say so when presenting). Lane artifacts sit beside the union as `<output>.<target>.json`. `qa_metadata.reviewed_head` records the head commit the review covered — callers budgeting review passes should count per head (a new push resets the round), not per submission.

`questions` is always empty (no PR comment context).

The script derives the review scope itself (branch, diff range, diffstat, changed files) and embeds it in the prompt, and it never writes an artifact for a review that did not happen — an empty diff, a response that stayed unusable after its one retry, and a CLI that never answered each exit non-zero with the response preserved beside the artifact. **On any non-zero exit, report what failed instead of presenting a verdict**; the codes and their sidecar files are in SKILL.md § Error Handling.

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
