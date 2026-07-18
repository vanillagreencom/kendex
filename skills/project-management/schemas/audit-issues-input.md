# Audit Issues Input Schema

Input file for issue audit workflows — transforms review agent findings into tracked issues.

**Location**: `[worktree-path]/tmp/audit-{source}-YYYYMMDD-HHMMSS.json`

## Schema

```json
{
  "source": "review|pr-comments|research-complete|roadmap",
  "parent_issue": "PROJ-456",
  "tracker": {"type": "linear|github", "repository": "owner/repo"},
  "worktree": "/path/to/worktree",
  "blocked_issues": ["PROJ-456"],
  "research_ref": "docs/research/PROJ-123/findings.md",
  "decision_ref": "D017",
  "hierarchy_contract": {
    "mode": "decompose-under-parent",
    "parent_issue": "PROJ-456",
    "child_indexes": [1, 2],
    "sequencing": [
      {"blocker": 1, "blocked": 2, "reason": "core types before consumers"}
    ]
  },
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
| `tracker` | No | Execution tracker context — see § Tracker |
| `worktree` | Yes | Path to worktree for code analysis |
| `blocked_issues` | No | Issue IDs blocked by research |
| `research_ref` | No | Path to research findings |
| `decision_ref` | No | Decision document reference |
| `hierarchy_contract` | No | Binding decomposition directive — see § Hierarchy Contract. Required when research-complete decomposes a single blocked issue into per-domain sub-issues (research-complete § 6.5). |
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

## Tracker

`tracker` fixes the execution tracker for the whole audit: every inventory preflight, TPM context fetch, and approved mutation routes through it (audit-issues § 1.2, § 7). Callers that already resolved a tracker (e.g. orch `TRACKER`) must set it.

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes (when block present) | `linear` or `github`. |
| `repository` | github only | `owner/repo` the issues live in. |

When the block is absent, audit-issues infers the tracker from `parent_issue`: an `issue-N` form ID → `github` (repository resolved via `gh repo view` in the worktree); otherwise `linear`. GitHub mode must not require Linear sync, session status, project inventory, or Linear mutation commands.

## Hierarchy Contract

`hierarchy_contract` is a **binding directive, not a hint**. In
`decompose-under-parent` mode, `parent_issue` is normally the blocked
implementation issue itself — the same identifier appears in `blocked_issues`,
as in the example above — because research-complete § 6.5 converts that blocked
issue into the coordination-only parent of the new domain children. `parent_issue` and `blocked_issues` alone are hints the TPM may override with per-item analysis; when `hierarchy_contract` is present, placement for the covered items is fixed by the producer, and the TPM's ordinary duplicate/hierarchy inference is bypassed for those items (tpm-audit.md § 7.0 and § 10.2).

| Field | Required | Description |
|-------|----------|-------------|
| `mode` | Yes | Only `"decompose-under-parent"` is defined. |
| `parent_issue` | Yes | The blocked implementation issue that becomes the coordination-only parent. Never a research issue. |
| `child_indexes` | Yes | `items[].index` values covered by the contract — one per domain sub-issue. Items not listed (e.g. `origin: "discovered"` refactors) are audited normally. |
| `sequencing` | No | `{blocker, blocked, reason}` entries between covered items (by `index`). Emitted as `blocks` relations between the created children. |

**`decompose-under-parent` semantics** — for every item whose `index` is in `child_indexes`:

- MUST be created as a sub-issue of `hierarchy_contract.parent_issue`, in the parent's project: `action: "create"` with `hierarchy: {"action": "make_child", "parent": [hierarchy_contract.parent_issue]}`.
- MUST NOT be resolved to `skip`, `update`, `expand`, or `combine` by duplicate/overlap analysis. If an existing issue (including `parent_issue` itself) already carries scope belonging to a covered item, that scope moves into the new domain child — record it via the child's `supersedes[]` (full coverage) or a `related` relation (partial overlap), never by updating the existing issue in place of the child create.
- `parent_issue` is converted to a coordination-only parent by the producer (research-complete § 6.6) — it must not be treated as one domain's implementation leaf nor recommended as an `update`/`expand` target for covered-item scope.

## Building from Review Agent JSONs

Set top-level `tracker` from the caller's resolved `TRACKER` (plus `repository` for GitHub items) so the audit executes through the correct tracker — review-pr § 9 and review-pr-comments § 6.2 pass it through.

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

**Skip handoff markers first.** Before mapping a Discovered Work bullet into an audit item, drop any bullet whose text matches `^-\s+(handoff_to_submit_pr|handoff_to_merge_pr|current_workflow_action):\s` — those bullets are owned by a later step of the current PR workflow (submit-pr / merge-pr / review-pr), not by the backlog. The canonical marker-first bullet form is documented in `dev/workflows/dev-implement.md` § 9, and the filter itself runs in `orch/workflows/review-pr.md` § 9 step 2.
