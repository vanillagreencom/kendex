# Audit Output Schema

Output path: `tmp/audit-project-YYYYMMDD-HHMMSS.json` or `tmp/audit-issues-YYYYMMDD-HHMMSS.json`

## Common Fields

```json
{
  "mode": "project|issue",
  "generated": "ISO timestamp",
  "worktree": "path",
  "projects_analyzed": [{"id": "uuid", "name": "string", "scope": "summary"}],
  "contracts": [{"id": "[ISSUE_ID]", "target": "...", "creates": [], "consumes": [], "problem": "..."}]
}
```

## Label Contract

Any output that can create an issue or update issue labels must carry full label intent:

- New issues: `create_fields.labels[]` is the complete issue-label set to pass to `issues create --labels` after preflight.
- Existing issue updates: label findings specify intended operation (`add`, `replace_category`, or explicit full replacement) so callers preserve unrelated labels.
- `agent_label` and `agent` are derived/backward-compatible fields only; they are not sufficient for mutation.
- All labels refer to **issue labels**, never project labels.

## PROJECT Mode Finding Arrays

Located at `findings.*`:

| Array | Fields |
|-------|--------|
| `add_relations[]` | `from`, `rel`, `to`, `reason` |
| `remove_relations[]` | `from`, `rel`, `to`, `uuid`, `reason` |
| `priority_misalignment[]` | `id`, `title`, `current`, `should_be`, `reason` |
| `agent_mismatch[]` | `id`, `title`, `current`, `should_be`, `reason`, `signals[]` (`replace_category: agent` implied) |
| `label_cooccurrence[]` | `id`, `title`, `present`, `missing`, `reason` (`add` missing label implied) |
| `duplicates[]` | `keep`, `remove`, `reason` |
| `obsolete[]` | `issue`, `reason`, `evidence{}`, `confidence` |
| `wrong_project[]` | `issue`, `title`, `from`, `to`, `to_id`, `reason` |
| `hierarchy[]` | `action`(`make_parent`\|`make_child`\|`bundle`\|`update_parent_desc`), `issue`\|`issues[]`, `parent`\|`children[]`\|`new_parent_title`, `reason` |
| `combine[]` | `target`, `absorb[]`, `reason` |

**`obsolete[].evidence`**: `{completed_by[], files_verified[], deliverables_checked[]}` — OR for decision-eliminated: `{decision_eliminated: true, decision_ref: "[REF]", eliminated_pattern: "..."}`

## PROJECT Mode

```json
{
  "mode": "project",
  "project": {"id": "uuid", "name": "string"},
  "summary": {
    "total_issues": 0,
    "project_definition_mismatches": 0,
    "project_dependency_issues": 0,
    "relations_to_add": 0,
    "relations_to_remove": 0,
    "priority_misalignment": 0,
    "agent_mismatch": 0,
    "label_cooccurrence": 0,
    "duplicates": 0,
    "obsolete": 0,
    "hierarchy_changes": 0,
    "bundles": 0,
    "wrong_project": 0,
    "combinations": 0,
    "relation_violations": 0,
    "architecture_gaps": {"critical": 0, "required": 0, "research": 0},
    "project_recommendations": {"new_projects": 0, "reopen_projects": 0}
  },
  "findings": {
    "project_dependency_issues": [],
    "add_relations": [],
    "remove_relations": [],
    "priority_misalignment": [],
    "agent_mismatch": [],
    "label_cooccurrence": [],
    "duplicates": [],
    "obsolete": [],
    "wrong_project": [],
    "hierarchy": [],
    "combine": [],
    "architecture_gaps": [],
    "project_recommendations": []
  },
  "analysis": ["markdown notes"]
}
```

**`analysis[]`**: Non-actionable observations only. All actionable findings MUST use structured fields. Recommendations in `analysis[]` will not be processed.

### PROJECT-Only Finding Types

**`project_dependency_issues[]`**:
```json
{"from_project": "...", "to_project": "...", "current_relation": "none|blocks|blocked_by", "should_be": "...", "reason": "..."}
```

**`architecture_gaps[]`**:
```json
{
  "component": "string",
  "category": "critical|required|research",
  "reasoning": "2-4 sentences",
  "architecture_ref": "file:lines",
  "module_path": "path",
  "implementation_status": "missing|stubbed|partial",
  "evidence": {"struct_exists": "bool", "functions_stubbed": [], "todos_found": []},
  "blocked_issues": ["[ISSUE_ID]"],
  "project_placement": {
    "target_project": "string",
    "target_project_id": "uuid|null",
    "rationale": "string",
    "requires_reopen": false
  },
  "recommended_issue": {"title": "...", "agent": "...", "priority": "1-4", "estimate": "1-5", "blocks": [], "labels": ["agent:[TYPE]", "[DOMAIN_LABEL]"]}
}
```

`recommended_issue.labels[]` must be the full issue-label set for the gap issue, not only an agent label.

**`project_recommendations[]`**:

| Action | Fields |
|--------|--------|
| `create_project` | `name`, `description`, `rationale`, `gaps_to_include[]`, `suggested_state`, `priority`, `initiative{}`, `dependencies{}` |
| `reopen_project` | `project`, `project_id`, `current_state`, `target_state`, `rationale`, `gaps_requiring_reopen[]` |

## ISSUE Mode

```json
{
  "mode": "issue",
  "summary": {
    "total_input": 0,
    "create": 0,
    "valid": 0,
    "skip": 0,
    "expand": 0,
    "update": 0,
    "supersede": 0,
    "superseded": 0,
    "combine": 0,
    "cancel": 0
  },
  "issues": [
    {
      "index": 1,
      "identifier": "[ISSUE_ID] or null",
      "title": "Issue title",
      "action": "valid|create|skip|expand|update|supersede|combine|cancel",
      "target": "[OTHER_ISSUE_ID] or null",
      "project": {
        "current": "Project Name or null",
        "recommended": "Project Name",
        "recommended_id": "uuid"
      },
      "contract": {"target": "...", "creates": [], "consumes": [], "problem": "..."},
      "add_relations": {"blocks": [], "blocked_by": [], "related": []},
      "remove_relations": [{"rel": "...", "target": "[ISSUE_ID]", "uuid": "...", "reason": "..."}],
      "priority_misalignment": {"current": 3, "should_be": 1, "reason": "..."},
      "agent_mismatch": {"current": "...", "should_be": "...", "signals": [], "reason": "..."},
      "label_cooccurrence": {"present": "[signals]", "missing": "design", "reason": "..."},
      "label_updates": [
        {"mode": "add", "category": "domain", "labels": ["design"], "reason": "..."}
      ],
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
      "supersedes": [
        {"identifier": "[ISSUE_ID]", "title": "Issue title", "reason": "Scope fully covered by this issue"}
      ],
      "obsolete": {"evidence": {}, "confidence": 100},
      "reason": "Summary explanation"
    }
  ]
}
```

### ISSUE Mode Label Fields

| Field | Meaning |
|-------|---------|
| `create_fields.labels[]` | Required for `action=create`; full validated issue-label set. |
| `create_fields.agent_label` | Optional derived/backward-compatible agent label; do not use alone for create. |
| `label_updates[].mode` | `add`, `replace_category`, or `replace_all`. |
| `label_updates[].category` | Taxonomy category affected when `mode=replace_category` or category-aware add. |
| `label_updates[].labels[]` | Labels being added/replaced. Caller computes final labels from current issue labels and preflights. |
| `label_updates[].final_labels[]` | Optional explicit final full label set. Required when `mode=replace_all`. |

When `label_cooccurrence.missing` is present without `label_updates[]`, callers treat it as `mode=add` for the taxonomy category that contains the missing label.

## Action Values

| Action | Meaning |
|--------|---------|
| `valid` | Correctly configured, relation corrections only |
| `create` | Create new issue |
| `skip` | Don't create — duplicate exists |
| `expand` | Expand existing issue scope |
| `update` | Update existing issue metadata/description |
| `supersede` | Cancel existing, create replacement |
| `combine` | Absorb into existing issue |
| `cancel` | Cancel — obsolete |

## ISSUE Mode: Hierarchy Field

| `hierarchy.action` | `hierarchy.parent` | Meaning |
|--------------------|-------------------|---------|
| `none` | null | Independent issue, no parent |
| `make_child` | `[ISSUE_ID]` | Create as sub-issue of existing issue |
| `make_child` | `#N` | Create as sub-issue of issue #N in this batch |
| `make_child` | null | Create as sub-issue of `parent_issue` context |
