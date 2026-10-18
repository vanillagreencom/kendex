# Audit Output Schema

Returned inline by `tpm-audit.md` and written by the caller to `tmp/audit-project-YYYYMMDD-HHMMSS.json`, `tmp/audit-team-YYYYMMDD-HHMMSS.json`, `tmp/audit-issues-YYYYMMDD-HHMMSS.json`, `tmp/audit-single-YYYYMMDD-HHMMSS.json`, or `tmp/audit-project-order-YYYYMMDD-HHMMSS.json`. The fleet proposal sweep returns issue-mode output inline, and the overseer writes it under `tmp/`.

## Common Fields

```json
{
  "mode": "project|team|issue|single|project-order",
  "generated": "ISO timestamp",
  "worktree": "path",
  "tracker": {"type": "linear|github", "repository": "owner/repo"},
  "projects_analyzed": [{"id": "uuid", "name": "string", "scope": "summary"}],
  "contracts": [{"id": "[ISSUE_ID]", "target": "...", "creates": [], "consumes": [], "problem": "..."}]
}
```

`tracker` echoes the resolved execution tracker; `repository` is github-only. In github mode `projects_analyzed` is empty and every project-placement field is null or omitted.

## Label Contract

`create_fields.labels[]` is the complete set to pass to create after preflight; a label finding on an existing issue names its operation (`add`, `replace_category`, or explicit full replacement). `agent` and `agent_label` are derived fields, never sufficient for mutation. All labels are issue labels. `create_fields.reach` and `create_fields.review_born` are required on every `create`, and `create_fields.symptom` on a `review_born` create at priority 2 — an output missing one is invalid. A proposal-backed create also requires `create_fields.source`, which must agree with `review_born`. Where each value comes from is [tpm-audit](../workflows/tpm-audit.md) § 10 or [proposal-sweep](../workflows/proposal-sweep.md) § 2.

## PROJECT Mode

Mode `team` uses this same shape with `project: null` — its input set is the whole team rather than one project. A per-issue findings row carries its issue and no project. The project-scoped arrays name their own: `wrong_project[]` in `from`/`to`, `project_dependency_issues[]` in `from_project`/`to_project`, `project_recommendations[]` in its project fields, and `architecture_gaps[].project_placement` for a gap. A consumer needing a project for a per-issue finding reads it from the issue.

```json
{
  "mode": "project",
  "project": {"id": "uuid", "name": "string"},
  "summary": {"total_issues": 0, "created": 0, "closed": 0, "relations_to_add": 0, "relations_to_remove": 0,
              "priority_misalignment": 0, "agent_mismatch": 0, "label_cooccurrence": 0, "duplicates": 0,
              "obsolete": 0, "hierarchy_changes": 0, "wrong_project": 0, "combinations": 0,
              "ready_to_schedule": 0, "declined": 0, "project_needed": 0, "map_findings": 0,
              "architecture_gaps": {"critical": 0, "required": 0, "research": 0},
              "project_recommendations": {"new_projects": 0, "reopen_projects": 0}},
  "findings": {"project_dependency_issues": [], "add_relations": [], "remove_relations": [],
               "priority_misalignment": [], "agent_mismatch": [], "label_cooccurrence": [],
               "duplicates": [], "obsolete": [], "wrong_project": [], "hierarchy": [], "combine": [],
               "ready_to_schedule": [], "architecture_gaps": [], "project_recommendations": [], "declined": [],
               "project_needed": [], "map_findings": []},
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
| `obsolete[]` | `issue`, `reason`, `confidence`, `evidence` = `{completed_by[], files_verified[], deliverables_checked[]}` or `{decision_eliminated: true, decision_ref, eliminated_pattern}` or `{below_bar: true, test, who_hits_it}` |
| `wrong_project[]` | `issue`, `title`, `from`, `to`, `to_id`, `reason` |
| `hierarchy[]` | `action` (`make_parent`\|`make_child`\|`bundle`\|`update_parent_desc`), `issue`\|`issues[]`, `parent`\|`children[]`\|`new_parent_title`, optional `retitle`, `reason` |
| `combine[]` | `target`, `absorb[]`, `reason` |
| `ready_to_schedule[]` | `id`, `title`, `cleared_blockers[]`, `reason` |
| `declined[]` | `title`, `reason` — one line naming the creation-bar test it failed |
| `project_dependency_issues[]` | `from_project`, `to_project`, `current_relation`, `should_be`, `reason` |
| `project_needed[]` | `issue`\|`index`, `title`, `name`, `kind`, `initiative`, `ends_when`\|`role`, `reason` — the project an item needs when [project-map.md § Routing](../references/project-map.md#routing) routes it to none |
| `map_findings[]` | A `projects audit` finding, as that command prints it, that maps to no other array ([project-map.md § Audit](../references/project-map.md#audit)) |

In a map repository, `wrong_project[].to` is a map project and `to_id` its id from `projects audit`'s `projects[]`; a `from` of null is an item with no project.

**`ready_to_schedule[]`** is a scheduling signal only — an active issue whose blockers are all Done or Cancelled. A completed-blocker relation is satisfied history, never stale metadata (the owning rule: linear SKILL.md § Blocked Label vs Issue Relations).

**`analysis[]`** holds non-actionable observations only; anything actionable must use a structured field.

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

Mode `single` uses this same shape with `"mode": "single"` and one `issues[]` row, whose action is `create` or `skip` ([tpm-audit](../workflows/tpm-audit.md) § 14). A `create` populates `supersedes[]` with the filing's confirmed entries; an identifier absent from the open-titles read is reported as not touched in `reason` and omitted from that array.

```json
{
  "mode": "issue",
  "approved_at_plan_gate": false,
  "proposal_sources": [{"index": 1, "tracker": "linear|github", "repository": "owner/repo|null", "issue": "PROJ-123|issue-123", "comment_id": "id", "comment_url": "url|null", "comment_author": "login", "source": "review", "source_repository": "owner/repo", "source_pr": "owner/repo#123", "source_commit": null}],
  "summary": {"total_input": 0, "create": 0, "valid": 0, "skip": 0, "expand": 0, "update": 0,
              "supersede": 0, "superseded": 0, "combine": 0, "cancel": 0},
  "issues": [
    {
      "index": 1,
      "identifier": "[ISSUE_ID] or null",
      "title": "Issue title",
      "action": "valid|create|skip|expand|update|supersede|combine|cancel",
      "reapprove": false,
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
        "source": "required for proposal-backed creates",
        "description": "Issue body summary",
        "recommendation": "* Requirements bullets",
        "reach": "the user action, run, check, or shipped producer that arrives at the defect — the producer the item's impact names, or the run that produced a structural entry",
        "review_born": false,
        "symptom": "review_born at priority 2 only — the run, user, or red check that already showed it",
        "regressed_by": [123],
        "location": "path or component",
        "estimate": 3,
        "priority": 2,
        "agent_label": "agent:[TYPE]",
        "labels": ["agent:[TYPE]", "[DOMAIN_LABEL]", "[WORKFLOW_LABEL]"],
        "is_bundle_parent": false,
        "source_path": "tmp/roadmaps/roadmap-feature.md"
      },
      "supersedes": [{"identifier": "[ISSUE_ID]", "title": "...", "reason": "Scope fully covered by this issue", "when": "now"}],
      "obsolete": {"evidence": {}, "confidence": 100},
      "reason": "Summary explanation"
    }
  ]
}
```

`supersedes[].when` is `now`, `partial`, or `at-completion`, with execution owned by [audit-issues § 7.2](../workflows/audit-issues.md#72-execute-approved-creations-and-cancellations). An entry without `when` retains the existing full-supersession behavior (`now`). A partial entry's `reason` names the scope transferred and the remainder to retain.

`proposal_sources[]` is present only for [proposal-sweep](../workflows/proposal-sweep.md) output. It maps each proposal row to its authorized tracker comment, preserved author, original `Source:` value, and merged source PR or landed source commit. `source` must match `create_fields.source`. `repository` and `comment_url` are required for GitHub and null for Linear. Linear receives a parent reply. GitHub receives a new issue comment that cites `comment_url`. Cancellation-sweep rows have no proposal source.

`source_repository` is required for both trackers and echoes the brief's `Source repository`. Each entry carries exactly one non-null source reference: `source_pr` from `Source PR:` for a merged PR, or `source_commit` from `Source commit:` for a commit verified on the fetched base branch. The other field is null or omitted. The source PR or commit belongs to `source_repository`.

| Action | Meaning |
|--------|---------|
| `valid` | Correctly configured; relation corrections only |
| `create` | Create a new issue |
| `skip` | Do not create — a duplicate exists, the scope is covered, or it failed the creation bar |
| `expand` / `update` | Widen or correct an existing issue |
| `supersede` | Cancel the existing issue, create a replacement |
| `combine` | Absorb into an existing issue |
| `cancel` | Cancel — obsolete |

In a map repository a `create` whose item routes to no map project has `project.recommended: null` and a top-level `project_needed[]` row, in the PROJECT mode shape, keyed by its `index`; audit-issues holds that create.

`approved_at_plan_gate` and `reapprove` travel together (roadmap-create § 4.2, audit-issues § 6): the top-level flag binds the file to a same-session plan-gate approval, and `reapprove: true` marks an entry changed since; a normalizer that drops one must drop both. Both default false/absent outside roadmap-create. Every `skip` carries a one-line `reason` naming the duplicate, the covering issue, or the creation-bar test it failed. `create_fields.labels[]` is required for `create`; `label_updates[].final_labels[]` is required when `mode` is `replace_all`. A `label_cooccurrence.missing` with no `label_updates[]` entry is treated as `mode: add` for that label's category.

A `Post-merge:` box in `create_fields.description` follows [SKILL.md](../SKILL.md) § Disposition and writes its deadline as `Deadline: +Nh`, the form both `issues create` and `issues complete` accept.

### Hierarchy Field

| `hierarchy.action` | `hierarchy.parent` | Meaning |
|--------------------|--------------------|---------|
| `none` | null | Independent issue |
| `make_child` | `[ISSUE_ID]` | Sub-issue of an existing issue |
| `make_child` | `#N` | Sub-issue of issue #N in this batch |
| `make_child` | null | Sub-issue of the input's `parent_issue` |

A parent created or promoted this way is a container by default. `(one PR)` marks the opt-in single-PR exception — in the title at creation for a new parent, and in `hierarchy.retitle: "[current title] (one PR)"` for an existing issue promoted via `make_parent`, applied alongside the reparenting.

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
  "complete_candidates": [{"id": "uuid", "name": "string", "unblocks": ["Project X"], "ends_when_evidence": "string|null"}],
  "complete_held": [{"id": "uuid", "name": "string", "ends_when": "string|null"}],
  "recommended_next": {"id": "uuid or null", "name": "string or null", "rationale": "...", "blocked_by_active": {"id": "uuid", "name": "string"} | null},
  "summary": {"projects_analyzed": 0, "reorder_needed": 0, "projects_to_complete": 0, "projects_ready": 0}
}
```

`layer` is the architectural position: 0 foundation (no dependencies), 1 core infrastructure, 2 features, 3 integration and testing, 4 polish and release. `sort_order` is relative **within one state column only**; compute positions and spacing per column.

`recommended_order[]` is diagnostic: it records the § 11 step 3 ordering in full. The caller executes `reorder[]`, `complete_candidates[]`, and `recommended_next` — never this array.

`ends_when_evidence` states what shows a map deliverable's `ends_when` holds, and is null for a project off the map or under `map-absent`. `complete_candidates[]` and `complete_held[]` hold started projects with no open item left ([project-map.md § Project kinds](../references/project-map.md#project-kinds)). `complete_held[]` lists each such map deliverable without that evidence, with the map's `ends_when` (null when the map states none); the caller reports it and never completes it ([project-map.md § Project kinds](../references/project-map.md#project-kinds)).

`recommended_next.blocked_by_active` is the started project that holds activation, the active project of [project-map.md § Project kinds](../references/project-map.md#project-kinds) that this run does not complete, and null when none does. A standing map project is never in it. The caller activates `recommended_next` only when this field is null.
