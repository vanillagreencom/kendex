# Audit Issues Input Schema

Input file for `audit-issues --issues`, written by the caller at `[worktree-path]/tmp/audit-{source}-YYYYMMDD-HHMMSS.json`.

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
    "sequencing": [{"blocker": 1, "blocked": 2, "reason": "core types before consumers"}]
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
      "origin": "suggestion|escalated|skipped|planned|discovered",
      "blocks_items": [2],
      "blocked_by_items": [],
      "blocks_issues": ["PROJ-301"],
      "blocked_by_issues": []
    }
  ]
}
```

## Fields

| Field | Required | Description |
|-------|----------|-------------|
| `source` | Yes | Calling workflow name |
| `parent_issue` | Yes | The issue being worked on — a hierarchy hint |
| `tracker` | No | Execution tracker context — see § Tracker |
| `worktree` | Yes | Worktree path for code analysis |
| `blocked_issues` | No | Issue IDs the research unblocks |
| `research_ref`, `decision_ref` | No | Findings path and decision reference |
| `hierarchy_contract` | No | Binding decomposition directive — see § Hierarchy Contract |
| `items[]` | Yes | Items to audit |

### Item Fields

| Field | Required | Description |
|-------|----------|-------------|
| `index` | Yes | Sequential, 1-based |
| `title` | Yes | Concise title |
| `location` | Yes | File path — **never line numbers**; name the function or struct |
| `description` | Yes | 2-3 sentences: what, why, impact. Becomes the issue body |
| `recommendation` | Yes | Bullet-list requirements. Becomes the requirements section |
| `priority` | Yes | 1-4 |
| `estimate` | Yes | 1-5 points |
| `labels` | Before create | Full issue-label set, validated against live inventory and project taxonomy before creation |
| `category` | Yes | Always `issue` — fix items never reach the audit |
| `found_by` | Yes | Agent that identified it |
| `origin` | Yes | `suggestion`, `escalated` (blockers dev could not fix), `skipped` (items dev deliberately skipped), `planned`, or `discovered` |
| `blocks_items` / `blocked_by_items` | No | Indexes of other items in this batch |
| `blocks_issues` / `blocked_by_issues` | No | Existing issue IDs |

## Tracker

`tracker` fixes the execution tracker for the whole audit: every inventory preflight, TPM fetch, and approved mutation routes through it. A caller that already resolved one must set it.

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes when the block is present | `linear` or `github` |
| `repository` | github only | `owner/repo` |

Without the block, audit-issues infers the tracker from `parent_issue`: an `issue-N` form ID means `github` (repository resolved with `gh repo view` in the worktree), otherwise `linear`. GitHub mode must not require Linear sync, session status, project inventory, or Linear mutation commands.

## Hierarchy Contract

`hierarchy_contract` is a **binding directive, not a hint**. `parent_issue` and `blocked_issues` alone are hints the TPM may override with per-item analysis; when this block is present, placement for the covered items is fixed by the producer and the TPM's duplicate and hierarchy inference is bypassed for them.

| Field | Required | Description |
|-------|----------|-------------|
| `mode` | Yes | Only `"decompose-under-parent"` is defined |
| `parent_issue` | Yes | The blocked implementation issue that becomes the coordination-only parent. Never a research issue |
| `child_indexes` | Yes | The `items[].index` values covered — one per domain sub-issue. Unlisted items (`origin: "discovered"` refactors) are audited normally |
| `sequencing` | No | `{blocker, blocked, reason}` between covered items, by index. Emitted as `blocks` relations between the created children |

In `decompose-under-parent` mode, `parent_issue` is normally the blocked implementation issue itself — the same identifier appears in `blocked_issues` — because the producer converts it into the coordination-only parent of the new domain children. For every item in `child_indexes`:

- MUST be created as a sub-issue of `hierarchy_contract.parent_issue`, in the parent's project: `action: "create"` with `hierarchy: {"action": "make_child", "parent": [hierarchy_contract.parent_issue]}`.
- MUST NOT be resolved to `skip`, `update`, `expand`, or `combine` by duplicate or overlap analysis. When an existing issue — including `parent_issue` — already carries scope belonging to a covered item, that scope moves into the new domain child via the child's `supersedes[]` (full coverage) or a `related` relation (partial overlap), never by updating the existing issue in place of the child create.
- `parent_issue` is coordination-only. It is never one domain's implementation leaf, and never an `update`/`expand` target for covered scope.

## Building from Review Findings

Set top-level `tracker` from the caller's resolved tracker (plus `repository` for GitHub) so the audit executes through the right one.

**Suggestions** (`category=issue`) map field for field: `title`, `location`, `description`, `recommendation`, `priority`, `estimate`, and `labels` when provided (otherwise completed through the taxonomy before create). `found_by` is the reporting agent; `origin` is `"suggestion"`.

**Escalated and skipped items** from the orchestrator's workflow state use the same mapping, with the entry's `outcome` field deciding the origin: outcome "blocked" (or no outcome field — legacy state) → origin: "escalated"; outcome "skipped" → origin: "skipped".

**Discovered work** from dev completion summaries maps the bullet text to `title` and `description`, `estimate: N` to `estimate` (default 2), and infers `priority` from the type (bug 2, tech-debt 3, enhancement 4) and `labels` from the taxonomy and source context. Set `origin: "discovered"`.

**Drop handoff markers first.** A Discovered Work bullet matching `^-\s+(handoff_to_submit_pr|handoff_to_merge_pr|current_workflow_action):\s` belongs to a later step of the current PR workflow, not to the backlog. The orchestrator filters these before building the audit input; never map one into an item.

Every item still faces the creation bar in `tpm-audit.md` § 10.1 — an entry in this file is a candidate, not a decision to file.
