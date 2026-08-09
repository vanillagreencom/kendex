# Review

Code review of pending changes via external model. The script auto-generates the review prompt with an embedded schema — no custom prompt needed. The prompt reviews through holistic lenses (correctness, security/fail-open, adversarial inputs, portability, repo-rule adherence, docs-vs-code drift, test adequacy) and embeds the repo's own instruction files when present.

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

`questions` is always empty (no PR comment context). Every key is required: `verdict` and the `blockers`/`suggestions`/`questions` arrays must all be present (empty `[]` is fine) — a first response missing any of them is retried once with the full original request, and a still-incomplete retry is preserved as `<output>.incomplete.json` with exit 4 instead of being written. `qa_metadata` is required — empty (`{}`) for a performed review; if the model instead self-reports `{"review_performed": false, "reason": ...}` or omits `qa_metadata` entirely, the script refuses to write the artifact, preserves the response as `<output>.noreview.json`, and exits 4. If the external CLI never produces a review at all — a non-zero exit (quota, auth, network), a timeout, or an empty response on a zero exit — the script preserves whatever partial output existed as `<output>.failed.json`, echoes the CLI's own error text on stderr, and exits 5.

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
