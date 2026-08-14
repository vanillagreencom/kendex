# Review Finding Schema

Canonical JSON output shape for every review/QA verdict. Artifact path: `[worktree-path]/tmp/review-{agent}-YYYYMMDD-HHMMSS.json`, where `{agent}` is the FULL agent name including its `reviewer-` prefix (`reviewer-security` → `review-reviewer-security-20260720-141530.json`). Codebase reviews insert `-codebase` before the timestamp.

Write the artifact with the harness file-write/edit tool (Codex: `apply_patch`) — never shell redirection, heredocs, `tee`, or command substitution. The validating authority is orch's `review-artifact-check`; self-validate with it before returning (reviewer SKILL.md § Output Contract).

## Schema

```json
{
  "agent": "agent-name",
  "timestamp": "2026-01-14T03:30:00Z",
  "verdict": "pass|action_required",
  "summary": "1-2 sentence summary",
  "blockers": [
    {
      "id": 1,
      "title": "Concise issue title (5-10 words)",
      "location": "src/auth/token.rs (`refresh_token`)",
      "description": "What the issue is",
      "recommendation": "How to fix it",
      "priority": 1,
      "estimate": 2
    }
  ],
  "suggestions": [
    {
      "id": 1,
      "title": "Concise issue title (5-10 words)",
      "location": "src/ipc/ring_buffer.rs (`RingBuffer::grow`)",
      "description": "What could be improved (2-3 sentences for category:issue)",
      "recommendation": "How to improve it (bullet-list for category:issue)",
      "priority": 3,
      "estimate": 2,
      "category": "fix|issue",
      "impact": "category:issue only — who hits this, on what real path"
    }
  ],
  "questions": [
    {
      "id": 1,
      "location": "src/auth/token.rs",
      "question": "Why is this async?",
      "draft_response": "Performance optimization for...",
      "source": "@reviewer",
      "source_id": "PRRT_kwDO...",
      "source_type": "inline"
    }
  ],
  "qa_metadata": {}
}
```

## Verdict

`action_required` when `blockers[]` is non-empty; `pass` when it is empty (suggestions may exist).

## Arrays

- `blockers[]`: block PR merge — dev must fix (may escalate to issues if unfixable)
- `suggestions[]`: non-blocking improvements, categorized by the review agent
- `questions[]`: PR-comment triage only — questions needing a response

## Item Fields (blockers/suggestions)

Every item requires all of these; one missing field rejects the whole artifact.

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Sequential number within its array |
| `title` | Yes | Concise title (5-10 words) — used if the item becomes a tracked issue |
| `location` | Yes | One string: stable path plus symbol, no line numbers (they go stale) — line/hunk evidence belongs in `description` |
| `description` | Yes | Problem statement |
| `recommendation` | Yes | Actionable fix/improvement steps |
| `priority` | Yes | Integer 1-4 (P1 Urgent, P2 High, P3 Normal, P4 Low). There is no P5 — a finding below P4 is not worth reporting |
| `estimate` | Yes | 1-5 points (1=hours, 2=half-day, 3=day, 4=2-3 days, 5=week+) |
| `category` | Suggestions only | `fix` (apply in this PR) or `issue` (track separately) — the orchestrator routes on this field |

`category: "issue"` items become tracked issue candidates — write at issue quality: `description` 2-3 sentences; `recommendation` as bullet-list requirements; `impact` (required) one line naming who hits this on what real path. An impact that needs "could", "might", or "in theory" is a decline, not an issue — say so in the review summary instead.

## Question Fields (PR comment triage only)

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Sequential number |
| `location` | Yes | File path (or "general") |
| `question` | Yes | The question being asked |
| `draft_response` | Yes | Suggested response to post |
| `source` | Yes | Comment author |
| `source_id` | Yes | Thread or comment ID for reply routing |
| `source_type` | Yes | `inline` or `pr-level` |

## qa_metadata

Per-agent QA payload (`workflows/qa-review.md`); `{}` when there is none. A reviewer that could not actually perform its review must set `{"review_performed": false, "reason": "<snake_case_reason>"}` instead of a bare pass — `review-artifact-check` rejects such artifacts (`no_review`) regardless of verdict.

Declaring a `qa_metadata` object also commits the artifact to usable findings: `review-artifact-check` rejects it (`incomplete`) when `blockers[]`/`suggestions[]` are missing or not arrays, or when a present item omits a required field above (`questions[]` is exempt). Artifacts without `qa_metadata` keep the tolerant existence + `verdict` validation. Full rejection semantics: `review-artifact-check --help`.

Example per-agent payloads:

| Agent | qa_metadata key | Required fields |
|-------|-----------------|-----------------|
| safety audit | `safety` | `tool_results`, `unsafe_block_count`, `violations[]` |
| performance QA | `perf_qa` | `percentiles`, `regression_pct`, `regressions[]`, `platform`, `baseline_sha` |
| architecture review | `arch_review` | `dimension_scores`, `overall_score`, `pass` |
