# Review

Code review of pending changes via external model. The script auto-generates the review prompt with an embedded schema — no custom prompt needed.

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

`questions` is always empty (no PR comment context). Every key is required: `verdict` and the `blockers`/`suggestions`/`questions` arrays must all be present (empty `[]` is fine) — a first response missing any of them is retried once with the full original request, and a still-incomplete retry is preserved as `<output>.incomplete.json` with exit 4 instead of being written. `qa_metadata` is required — empty (`{}`) for a performed review; if the model instead self-reports `{"review_performed": false, "reason": ...}` or omits `qa_metadata` entirely, the script refuses to write the artifact, preserves the response as `<output>.noreview.json`, and exits 4.

The script derives the review scope itself (branch, diff range, diffstat, changed files) and embeds it in the prompt. If the requested or default range yields an empty diff, it exits 3 without invoking the external CLI — report "nothing to review" instead of presenting a verdict.

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
