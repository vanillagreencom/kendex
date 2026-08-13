# Issue Description Template

```markdown
**Research**: [RESEARCH_REF]
**Decision [DXXX]**: [DECISION_PATH]
**Source**: [ORIGIN_CONTEXT]

[DESCRIPTION — 1-3 sentences: the problem and its impact]

## Requirements

* [REQUIREMENT_1]
* [REQUIREMENT_2]

## Context

- **Location**: `[FILE_PATH]`
```

## Field Mapping

| Placeholder | Source | Notes |
|-------------|--------|-------|
| `[ORIGIN_CONTEXT]` | Caller — e.g. `PR review suggestion ([found_by])`, `architecture planning` | Always include provenance |
| `[DESCRIPTION]` | `items[].description` | Use as written |
| `[REQUIREMENT_*]` | `items[].recommendation` | Use as written — already a `* bullet` list |
| `[FILE_PATH]` | `items[].location` | Backticked path. **Never line numbers** — they go stale; name the function or struct instead |
| `[RESEARCH_REF]` / `[DXXX]` / `[DECISION_PATH]` | Input `research_ref` / `decision_ref`, else inherited from the parent's description | Top of the description; omit the line when absent |

## Rules

1. Drop any header line with no value.
2. Write the body to a file with the harness file-write tool and pass `--description-file` (Linear) or `--body-file` (GitHub). Never an inline string, never a heredoc or command substitution — under `never` approval those shapes are treated as approval-required and the description silently ends up empty. The same flags work on update.
3. Before creating, check the governing decision — `.agents/skills/decider/scripts/decisions search "[KEYWORDS]"` — and reference it at the top. A description must not contradict an active decision.
4. Every create passes the validated final `labels[]` from the label preflight.
