# Audit Issues Input Schema

Input file for issue audit workflows — transforms review agent findings into tracked issues.

**Location**: `[worktree-path]/tmp/audit-{source}-YYYYMMDD-HHMMSS.json`

## Schema

```json
{
  "source": "review|pr-comments|research|roadmap",
  "parent_issue": "PROJ-123",
  "worktree": "/path/to/worktree",
  "blocked_issues": ["PROJ-456"],
  "research_ref": "docs/research/PROJ-123/findings.md",
  "decision_ref": "D017",
  "items": [
    {
      "index": 1,
      "title": "Issue title (5-10 words)",
      "location": "file.rs (`fn_name`)",
      "description": "2-3 sentences: what, why, impact",
      "recommendation": "* Bullet-list requirements, each actionable",
      "priority": 2,
      "estimate": 2,
      "labels": ["agent:[TYPE]", "[DOMAIN_LABEL]", "[WORKFLOW_LABEL]"],
      "category": "issue",
      "found_by": "agent-name",
      "origin": "suggestion|escalated|planned|discovered",
      "blocks_items": [2],
      "blocked_by_items": [],
      "blocks_issues": ["PROJ-301"],
      "blocked_by_issues": []
    }
  ]
}
```

## Field Definitions

| Field | Required | Description |
|-------|----------|-------------|
| `source` | Yes | Caller workflow name |
| `parent_issue` | Yes | Issue being worked on (hierarchy hint) |
| `worktree` | Yes | Path to worktree for code analysis |
| `blocked_issues` | No | Issue IDs blocked by research |
| `research_ref` | No | Path to research findings |
| `decision_ref` | No | Decision document reference |
| `items[]` | Yes | Array of items to audit |

### Item Fields

| Field | Required | Description |
|-------|----------|-------------|
| `index` | Yes | Sequential number (1-based) |
| `title` | Yes | Concise issue title from review agent |
| `location` | Yes | File path — no line numbers (use function/struct names) |
| `description` | Yes | 2-3 sentences: what, why, impact. Becomes issue body. |
| `recommendation` | Yes | Bullet-list requirements. Becomes requirements section. |
| `priority` | Yes | 1-4 |
| `estimate` | Yes | 1-5 points |
| `labels` | No for legacy callers; required before create | Full issue-label set. Callers/workflows must complete and validate this against live issue-label inventory + project taxonomy before issue creation. |
| `category` | Yes | Always `issue` (fix items don't reach audit) |
| `found_by` | Yes | Agent that identified the item |
| `origin` | Yes | `suggestion`, `escalated`, `planned`, or `discovered` |
| `blocks_items` | No | Indexes of items in this batch that this item blocks |
| `blocked_by_items` | No | Indexes of items that block this item |
| `blocks_issues` | No | Existing issue IDs this item blocks |
| `blocked_by_issues` | No | Existing issue IDs that block this item |

## Building from Review Agent JSONs

### Suggestions (category=issue)

```
suggestions[].title → title
suggestions[].location → location
suggestions[].description → description
suggestions[].recommendation → recommendation
suggestions[].priority → priority
suggestions[].estimate → estimate
suggestions[].labels → labels[] when provided; otherwise complete through project taxonomy before create
category: "issue"
found_by: agent (from parent JSON)
origin: "suggestion"
```

### Escalated Blockers

Blockers that dev couldn't fix:

```
Same field mapping as suggestions
origin: "escalated"
```

### Discovered Work

From dev agent completion summaries:

```
bullet text → title + description
estimate: N → estimate (default 2 if absent)
priority: infer from type (bug=2, tech-debt=3, enhancement=4)
labels: infer from project taxonomy + source context before create
origin: "discovered"
```

**Skip handoff markers first.** Before mapping a Discovered Work bullet into an audit item, drop any bullet whose text matches `^-\s+(handoff_to_submit_pr|handoff_to_merge_pr|current_workflow_action):\s` — those bullets are owned by a later step of the current PR workflow (submit-pr / merge-pr / review-pr), not by the backlog. The canonical marker-first bullet form is documented in `linear-dev/workflows/dev-implement.md` § 9, and the filter itself runs in `linear-orch/workflows/review-pr.md` § 9 step 2.
