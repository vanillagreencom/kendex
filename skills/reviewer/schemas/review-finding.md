# Review Finding Schema

All review/QA agents output JSON to `[worktree-path]/tmp/review-{agent}-YYYYMMDD-HHMMSS.json`.

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
      "category": "fix|issue"
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

## Verdict Rules

- `action_required`: 1+ items in `blockers[]`
- `pass`: `blockers[]` empty (suggestions may exist)

## Arrays

- `blockers[]`: Items that block PR merge — dev must fix (may escalate to issues if unfixable)
- `suggestions[]`: Non-blocking improvements — categorized by review agent
- `questions[]`: Questions needing response (PR comment triage only)

## Item Fields (blockers/suggestions)

| Field | Required | Description |
|-------|----------|-------------|
| `id` | Yes | Sequential number within array |
| `title` | Yes | Concise issue title (5-10 words) — used if item becomes a tracked issue |
| `location` | Yes | File path with function/struct names for precision (no line numbers — they go stale) |
| `description` | Yes | Problem statement |
| `recommendation` | Yes | Actionable fix/improvement steps |
| `priority` | Yes | 1-4 (P1=Urgent, P2=High, P3=Normal, P4=Low) |
| `estimate` | Yes | 1-5 points (1=hours, 2=half-day, 3=day, 4=2-3 days, 5=week+) |
| `category` | Suggestions only | `fix` (apply in this PR) or `issue` (track separately) |

### Description Quality

`category: "issue"` items become tracked issues — write at issue quality.

| Field | Blockers / fix items | Issue items (`category: "issue"`) |
|-------|---------------------|-----------------------------------|
| `description` | Brief (1 sentence OK) | 2-3 sentences: what, why, impact |
| `recommendation` | Brief fix instruction | Bullet-list requirements (`* item`) |

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

## Priority

1=Urgent > 2=High > 3=Normal > 4=Low

## Estimate

Points (1-5): 1=hours, 2=half-day, 3=day, 4=2-3 days, 5=week+
