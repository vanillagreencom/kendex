# Audit Issues Input Schema

Input file for `audit-issues --issues`, written by the caller at `[worktree-path]/tmp/audit-{source}-YYYYMMDD-HHMMSS.json`.

```json
{
  "source": "review|pr-comments|local-review|research-complete|roadmap-create",
  "parent_issue": "PROJ-456",
  "tracker": {"type": "linear|github", "repository": "owner/repo"},
  "worktree": "/path/to/worktree",
  "blocked_issues": ["PROJ-456"],
  "research_issue": "PROJ-123",
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
      "description": "2-3 sentences: what and why",
      "impact": "who hits this, on what real path",
      "symptom": "the run, user, or red check that already showed it",
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
| `source` | Yes | Calling workflow name, one of the values above. Which are review-born, and what that sets, is [tpm-audit](../workflows/tpm-audit.md) § 10 |
| `parent_issue` | Yes | The issue being worked on — a hierarchy hint |
| `tracker` | No | Execution tracker context — see § Tracker |
| `worktree` | Yes | Worktree path for code analysis |
| `blocked_issues` | No | Issue IDs the research unblocks |
| `research_issue` | No | The research issue itself — every `create` gets a `related` relation back to it |
| `research_ref`, `decision_ref` | No | Findings path and decision reference |
| `hierarchy_contract` | No | Binding decomposition directive — see § Hierarchy Contract |
| `items[]` | Yes | Items to audit |

### Item Fields

| Field | Required | Description |
|-------|----------|-------------|
| `index` | Yes | Sequential, 1-based |
| `title` | Yes | Concise title |
| `location` | Yes | File path — **never line numbers**; name the function or struct |
| `description` | Yes | 2-3 sentences: what and why. Becomes the issue body |
| `impact` | Before create | Who hits this, on what real path. The reviewer skill's `review-finding` field on a `category: "issue"` suggestion; on a blocker, an escalated item, or a Discovered Work bullet no artifact carries it and the caller writes it from the finding |
| `symptom` | P2 review items | The run, user, or red check that already showed it. No artifact carries it, so the caller writes it from the finding. Required where a review-born source files at priority 2 |
| `recommendation` | Yes | Bullet-list requirements. Becomes the requirements section |
| `priority` | Yes | 1-4 |
| `estimate` | Yes | 1-5 points |
| `labels` | Before create | Full issue-label set, validated against live inventory and project taxonomy before creation |
| `category` | Yes | Always `issue` — fix items never reach the audit |
| `found_by` | Yes | Agent that identified it |
| `origin` | Yes | `suggestion`, `escalated` (items no dev round resolved: blockers dev could not fix, plus items outstanding at the review cycle cap), `skipped` (items dev deliberately skipped), `planned`, or `discovered` |
| `blocks_items` / `blocked_by_items` | No | Indexes of other items in this batch |
| `blocks_issues` / `blocked_by_issues` | No | Existing issue IDs |

## Tracker

`tracker` fixes the execution tracker for the whole audit. A caller that already resolved one must set it.

| Field | Required | Description |
|-------|----------|-------------|
| `type` | Yes when the block is present | `linear` or `github` |
| `repository` | github only | `owner/repo` |

Without the block, audit-issues infers the tracker from `parent_issue`: an `issue-N` form ID means `github` (repository resolved with `gh repo view` in the worktree), otherwise `linear`. GitHub mode must not require Linear sync, session status, project inventory, or Linear mutation commands.

## Hierarchy Contract

`hierarchy_contract` is a **binding directive, not a hint**: placement for the covered items is fixed by the producer and the TPM's duplicate and hierarchy inference is bypassed for them. `parent_issue` and `blocked_issues` alone are hints.

| Field | Required | Description |
|-------|----------|-------------|
| `mode` | Yes | Only `"decompose-under-parent"` is defined |
| `parent_issue` | Yes | The blocked implementation issue that becomes the coordination-only parent. Never a research issue |
| `child_indexes` | Yes | The `items[].index` values covered — one per domain sub-issue. Unlisted items (`origin: "discovered"` refactors) are audited normally |
| `sequencing` | No | `{blocker, blocked, reason}` between covered items, by index. Emitted as `blocks` relations between the created children |

In `decompose-under-parent` mode, `parent_issue` is the blocked implementation issue (also listed in `blocked_issues`), converted into the coordination-only parent of the new domain children. For every item in `child_indexes`:

- MUST be created as a sub-issue of `hierarchy_contract.parent_issue`, in the parent's project: `action: "create"` with `hierarchy: {"action": "make_child", "parent": [hierarchy_contract.parent_issue]}`.
- MUST NOT be resolved to `skip`, `update`, `expand`, or `combine` by duplicate or overlap analysis.
- `parent_issue` is coordination-only.

What the analysis must do to satisfy these: [tpm-audit.md](../workflows/tpm-audit.md) § 7.0.

## Building from Review Findings

Set top-level `tracker` from the caller's resolved tracker (plus `repository` for GitHub).

**Suggestions** (`category=issue`) map field for field: `title`, `location`, `description`, `recommendation`, `priority`, `estimate`, and `labels` when provided (otherwise completed through the taxonomy before create). `found_by` is the reporting agent; `origin` is `"suggestion"`.

**Escalated and skipped items** from the orchestrator's workflow state use the same mapping, with the entry's `outcome` field deciding the origin:

| `outcome` | `origin` |
|---|---|
| `"blocked"` | `"escalated"` |
| absent | `"escalated"` |
| `"skipped"` | `"skipped"` |

**Discovered work** from dev completion summaries maps the bullet text to `title` and `description`, `estimate: N` to `estimate` (default 2), and infers `priority` from the type (bug 2, tech-debt 3, enhancement 4) and `labels` from the taxonomy and source context. Set `origin: "discovered"`.

**Drop handoff markers first.** A Discovered Work bullet matching `^-\s+(handoff_to_submit_pr|handoff_to_merge_pr|current_workflow_action):\s` belongs to a later step of the current PR workflow; never map one into an item.

Every item still faces the creation bar in `tpm-audit.md` § 10.1.
