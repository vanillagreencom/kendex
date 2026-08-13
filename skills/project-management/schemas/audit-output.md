# Audit Output Schema

Returned inline by `tpm-audit.md` and written by the caller to `tmp/audit-project-YYYYMMDD-HHMMSS.json`, `tmp/audit-issues-YYYYMMDD-HHMMSS.json`, or `tmp/audit-project-order-YYYYMMDD-HHMMSS.json`.

## Common Fields

```json
{
  "mode": "project|issue|project-order",
  "generated": "ISO timestamp",
  "worktree": "path",
  "tracker": {"type": "linear|github", "repository": "owner/repo"},
  "projects_analyzed": [{"id": "uuid", "name": "string", "scope": "summary"}],
  "contracts": [{"id": "[ISSUE_ID]", "target": "...", "creates": [], "consumes": [], "problem": "..."}]
}
```

`tracker` echoes the resolved execution tracker so analyzed-mode consumers route mutations without re-inference; `repository` is github-only. In github mode `projects_analyzed` is empty and every project-placement field is null or omitted.

## Label Contract

Any output that can create an issue or change labels carries full label intent. `create_fields.labels[]` is the complete set to pass to create after preflight; a label finding on an existing issue names its operation (`add`, `replace_category`, or explicit full replacement) so the caller preserves unrelated labels. `agent` and `agent_label` are derived fields, never sufficient for mutation. All labels are issue labels.

## PROJECT Mode

```json
{
  "mode": "project",
  "project": {"id": "uuid", "name": "string"},
  "summary": {"total_issues": 0, "created": 0, "closed": 0, "relations_to_add": 0, "relations_to_remove": 0,
              "priority_misalignment": 0, "agent_mismatch": 0, "label_cooccurrence": 0, "duplicates": 0,
              "obsolete": 0, "hierarchy_changes": 0, "wrong_project": 0, "combinations": 0,
              "relation_violations": 0, "ready_to_schedule": 0, "declined": 0,
              "architecture_gaps": {"critical": 0, "required": 0, "research": 0},
              "project_recommendations": {"new_projects": 0, "reopen_projects": 0}},
  "findings": {"project_dependency_issues": [], "add_relations": [], "remove_relations": [],
               "priority_misalignment": [], "agent_mismatch": [], "label_cooccurrence": [],
               "duplicates": [], "obsolete": [], "wrong_project": [], "hierarchy": [], "combine": [],
               "ready_to_schedule": [], "architecture_gaps": [], "project_recommendations": [], "declined": []},
  "analysis": ["markdown notes"]
}
```

| Array | Fields |
|-------|--------|
| `add_relations[]` | `from`, `rel`, `to`, `reason` |
| `remove_relations[]` | `from`, `rel`, `to`, `uuid`, `reason` |
| `priority_misalignment[]` | `id`, `title`, `current`, `should_be`, `reason` |
| `agent_mismatch[]` | `id`, `title`, `current`, `should_be`, `reason`, `signals[]` (`replace_category: agent` implied) |
| `label_cooccurrence[]` | `id`, `title`, `present`, `missing`, `reason` (`add` implied) |
| `duplicates[]` | `keep`, `remove`, `reason` |
| `obsolete[]` | `issue`, `reason`, `confidence`, `evidence` = `{completed_by[], files_verified[], deliverables_checked[]}` or `{decision_eliminated: true, decision_ref, eliminated_pattern}` |
| `wrong_project[]` | `issue`, `title`, `from`, `to`, `to_id`, `reason` |
| `hierarchy[]` | `action` (`make_parent`\|`make_child`\|`bundle`\|`update_parent_desc`), `issue`\|`issues[]`, `parent`\|`children[]`\|`new_parent_title`, optional `retitle`, `reason` |
| `combine[]` | `target`, `absorb[]`, `reason` |
| `ready_to_schedule[]` | `id`, `title`, `cleared_blockers[]`, `reason` |
| `declined[]` | `title`, `reason` — one line naming the creation-bar test it failed |
| `project_dependency_issues[]` | `from_project`, `to_project`, `current_relation`, `should_be`, `reason` |

**`ready_to_schedule[]`** is a scheduling signal only — an active issue whose blockers are all Done or Cancelled. Completed-blocker relations are satisfied history, never stale metadata: they never appear in `remove_relations[]` or under any stale-metadata framing.

**`analysis[]`** holds non-actionable observations only. Anything actionable must use a structured field; recommendations left in `analysis[]` are not processed.

**`architecture_gaps[]`**:

```json
{
  "component": "string",
  "category": "critical|required|research",
  "reasoning": "2-4 sentences",
  "architecture_ref": "file:lines",
  "module_path": "path",
  "implementation_status": "missing|stubbed|partial",
  "evidence": {"struct_exists": false, "functions_stubbed": [], "todos_found": []},
  "blocked_issues": ["[ISSUE_ID]"],
  "project_placement": {"target_project": "string", "target_project_id": "uuid|null", "rationale": "string", "requires_reopen": false},
  "recommended_issue": {"title": "...", "priority": "1-4", "estimate": "1-5", "blocks": [], "labels": ["agent:[TYPE]", "[DOMAIN_LABEL]"]}
}
```

`recommended_issue.labels[]` is the full issue-label set, not just an agent label.

**`project_recommendations[]`**: `create_project` with `name`, `description`, `rationale`, `gaps_to_include[]`, `suggested_state`, `priority`, `initiative{}`, `dependencies{}`; or `reopen_project` with `project`, `project_id`, `current_state`, `target_state`, `rationale`, `gaps_requiring_reopen[]`.

## ISSUE Mode

```json
{
  "mode": "issue",
  "summary": {"total_input": 0, "create": 0, "valid": 0, "skip": 0, "expand": 0, "update": 0,
              "supersede": 0, "superseded": 0, "combine": 0, "cancel": 0},
  "issues": [
    {
      "index": 1,
      "identifier": "[ISSUE_ID] or null",
      "title": "Issue title",
      "action": "valid|create|skip|expand|update|supersede|combine|cancel",
      "target": "[OTHER_ISSUE_ID] or null",
      "project": {"current": "Name or null", "recommended": "Name", "recommended_id": "uuid"},
      "contract": {"target": "...", "creates": [], "consumes": [], "problem": "..."},
      "add_relations": {"blocks": [], "blocked_by": [], "related": []},
      "remove_relations": [{"rel": "...", "target": "[ISSUE_ID]", "uuid": "...", "reason": "..."}],
      "priority_misalignment": {"current": 3, "should_be": 1, "reason": "..."},
      "agent_mismatch": {"current": "...", "should_be": "...", "signals": [], "reason": "..."},
      "label_cooccurrence": {"present": "[signals]", "missing": "design", "reason": "..."},
      "label_updates": [{"mode": "add", "category": "domain", "labels": ["design"], "reason": "..."}],
      "hierarchy": {"action": "none|make_child", "parent": "[ISSUE_ID]|#N|null"},
      "create_fields": {
        "description": "Issue body summary",
        "recommendation": "* Requirements bullets",
        "location": "path or component",
        "estimate": 3,
        "priority": 2,
        "agent_label": "agent:[TYPE]",
        "labels": ["agent:[TYPE]", "[DOMAIN_LABEL]", "[WORKFLOW_LABEL]"],
        "is_bundle_parent": false,
        "source_path": "docs/roadmaps/roadmap-feature.md"
      },
      "supersedes": [{"identifier": "[ISSUE_ID]", "title": "...", "reason": "Scope fully covered by this issue"}],
      "obsolete": {"evidence": {}, "confidence": 100},
      "reason": "Summary explanation"
    }
  ]
}
```

| Action | Meaning |
|--------|---------|
| `valid` | Correctly configured; relation corrections only |
| `create` | Create a new issue |
| `skip` | Do not create — a duplicate exists, the scope is covered, or it failed the creation bar |
| `expand` / `update` | Widen or correct an existing issue |
| `supersede` | Cancel the existing issue, create a replacement |
| `combine` | Absorb into an existing issue |
| `cancel` | Cancel — obsolete |

Every `skip` carries a one-line `reason` naming the duplicate, the covering issue, or the creation-bar test it failed. `create_fields.labels[]` is required for `create`; `label_updates[].final_labels[]` is required when `mode` is `replace_all`. A `label_cooccurrence.missing` with no `label_updates[]` entry is treated as `mode: add` for that label's category.

### Hierarchy Field

| `hierarchy.action` | `hierarchy.parent` | Meaning |
|--------------------|--------------------|---------|
| `none` | null | Independent issue |
| `make_child` | `[ISSUE_ID]` | Sub-issue of an existing issue |
| `make_child` | `#N` | Sub-issue of issue #N in this batch |
| `make_child` | null | Sub-issue of the input's `parent_issue` |

A parent created or promoted this way is a container by default: each child ships as its own PR and the parent closes last. `(one PR)` marks the opt-in single-PR exception — carried in the title at creation for a new parent, and in `hierarchy.retitle: "[current title] (one PR)"` for an existing issue promoted via `make_parent`, applied alongside the reparenting. Without the retitle, a promoted parent reads as a container and splits work the audit decided to keep whole.

## PROJECT-ORDER Mode

```json
{
  "mode": "project-order",
  "generated": "ISO timestamp",
  "initiatives": [{"id": "uuid", "name": "Platform MVP"}],
  "projects_analyzed": [
    {
      "id": "uuid", "name": "string",
      "state": "backlog|planned|started|completed|paused",
      "initiative": "Platform MVP",
      "current_sort_order": -5000,
      "current_position_in_state": 3,
      "layer": 1,
      "deliverables": ["Message queue"],
      "consumes": ["Foundation types"],
      "analysis": "2-3 sentence architectural rationale"
    }
  ],
  "recommended_order": [{"position": 1, "project_id": "uuid", "name": "string", "initiative": "...", "layer": 0, "target_state": "planned", "new_sort_order": -10000}],
  "reorder": [{"project_id": "uuid", "name": "string", "current_state": "backlog", "target_state": "backlog",
               "current_position_in_state": 3, "recommended_position_in_state": 1,
               "current_sort_order": -5000, "new_sort_order": -10000, "rationale": "..."}],
  "complete_candidates": [{"id": "uuid", "name": "string", "progress": 1.0, "unblocks": ["Project X"]}],
  "recommended_next": {"id": "uuid or null", "name": "string or null", "rationale": "..."},
  "summary": {"projects_analyzed": 0, "reorder_needed": 0, "projects_to_complete": 0, "projects_ready": 0}
}
```

`layer` is the architectural position: 0 foundation (no dependencies), 1 core infrastructure, 2 features, 3 integration and testing, 4 polish and release. `sort_order` is relative **within one state column only** — positions and spacing are computed per column, never across the whole project list.
