# Roadmap Plan Output Schema

Returned inline by `tpm-roadmap-plan.md` and written by the caller to `tmp/roadmap-plan-YYYYMMDD-HHMMSS.json`. `roadmap-create.md` consumes it as the plan's contract.

```json
{
  "feature": "Feature name",
  "research_path": "docs/research/[ISSUE_ID]/findings.md",
  "hierarchy_recommendation": {
    "type": "children_of_origin",
    "origin_issue": "[ISSUE_ID]",
    "rationale": "All proposed issues decompose the origin issue's scope"
  },
  "cross_project_findings": {"duplicates": [], "conflicts": []},
  "project_placement": {
    "recommendation": "new",
    "project_name": "Phase 3: API Layer",
    "project_description": "REST API endpoints and middleware",
    "relations": [
      {"type": "blocked-by", "project": "Phase 2: Infrastructure", "reason": "Requires the data layer"},
      {"type": "blocks", "project": "Phase 4: Frontend", "reason": "API enables frontend integration"}
    ]
  },
  "architecture_gaps": [],
  "organized_issues": [],
  "declined": [{"title": "...", "reason": "no user-visible effect"}],
  "context": {
    "source": "roadmap-create",
    "research_path": "docs/research/[ISSUE_ID]/findings.md",
    "origin_issue": "[ISSUE_ID]",
    "plan_path": "docs/roadmaps/roadmap-feature-name.md"
  },
  "summary": {"total_issues": 5, "bundles": 1, "critical_path_issues": 2, "gaps_to_include": 1,
              "duplicates_found": 0, "conflicts_found": 0, "declined": 0, "existing_closed": 0}
}
```

`context.plan_path` is filled by the caller when it saves the plan (null in the initial output). `declined[]` lists proposals that failed the creation bar, one line each.

## hierarchy_recommendation

Present only when `origin_issue` was supplied; absent or `type: "none"` means `parent_issue` defaults to null.

| Type | When | Effect |
|------|------|--------|
| `children_of_origin` | All issues decompose the origin's scope | `parent_issue` = origin issue ID |
| `new_project` | The work is a new capability beyond that scope | `parent_issue: null`, new project |
| `mixed` | Some in scope, some new | Split: children of origin plus standalone |
| `none` | No origin issue | No hierarchy guidance |

## cross_project_findings

```json
"duplicates": [
  {"proposed_title": "Add API rate limiting", "existing_id": "[ISSUE_ID]", "existing_title": "Implement request throttling",
   "existing_project": "Phase 2: Infrastructure", "match_type": "partial", "recommendation": "expand",
   "reason": "Existing issue covers basic throttling; expand it to include rate limiting"}
],
"conflicts": [
  {"proposed_title": "Refactor data pipeline", "conflicts_with": "[ISSUE_ID]", "conflict_type": "concurrent_work",
   "resolution": "Wait for [ISSUE_ID] to complete", "risk": "medium"}
]
```

`match_type`: `exact` (same title and scope — skip the proposal), `partial` (overlapping — expand the existing or descope the proposal), `supersedes` (the proposal replaces the existing entirely — cancel it). `recommendation` is `skip`, `expand`, `descope`, or `cancel`.

`conflict_type`: `breaks_existing`, `concurrent_work`, or `incompatible_approach`.

## project_placement

`recommendation` is `new` (create the project) or `existing` (`project_name` names it). Relations carry `type` (`blocked-by` / `blocks`), `project`, and `reason`.

## architecture_gaps

```json
{"component": "Request caching layer", "module_path": "src/cache/", "status": "missing|stubbed|partial",
 "evidence": "Module directory does not exist", "recommendation": "include|defer|out_of_scope",
 "reason": "Required for API response caching"}
```

`include` when the gap blocks proposed work or the feature needs it (also appears in `organized_issues[]`); `defer` for nice-to-have (in `organized_issues[]` with `project: "Deferred"`); `out_of_scope` when it is unrelated or fails the creation bar — recorded here only.

## organized_issues

```json
{
  "title": "Implement request router",
  "estimate": 3,
  "agent": "backend",
  "agent_label": "agent:backend",
  "labels": ["agent:[TYPE]", "[DOMAIN_LABEL]"],
  "priority": 1,
  "action": "create",
  "target": null,
  "reason": "L0 foundation issue, no duplicates found",
  "obsolete": null,
  "is_bundle_parent": false,
  "parent_title": null,
  "depends_on_proposed": [],
  "depends_on_existing": ["[ISSUE_ID]"],
  "blocked_by_proposed": [],
  "critical_path": true,
  "layer": 0,
  "position": -20,
  "conflicts_with": [],
  "breaking_changes": [],
  "doc_updates": ["docs/architecture/api.md"]
}
```

Sorted by `position = (layer x 100) + (enables_count x -10) + (estimate x 1)`; lower is earlier. `layer` runs L0 foundation → L1 infrastructure → L2 features → L3 integration → L4 testing and polish. Priority follows layer and impact: L0 on the critical path or L0/L1 enabling 2+ issues → P1, L1/L2 → P2, L3 → P3, L4 → P4, with P1 propagating transitively to anything blocking a P1. `critical_path: true` when the issue blocks 2+ others.

`action` is `create`, `skip`, `expand`, `supersede`, or `cancel`, with `target` naming the existing issue for `expand`/`supersede` and `reason` explaining the choice. `obsolete` carries `{evidence: {completed_by[], files_verified[]}, confidence}` or null.

A bundle parent sets `is_bundle_parent: true` with `estimate: null`; its children set `parent_title` to the parent's title. Blocking relations between bundles sit on the parents — children carry no external blocking relations. A parent takes the shared agent label, or the project's multi-agent label when children span 2+ agents.

`labels[]` is the full issue-label set required before `roadmap-create` mutates the tracker: issue labels only, all project-required categories present, no parent/group labels. `agent`/`agent_label` are derived fields and never sufficient. When a required category cannot be determined, flag it in `reason` rather than inventing a label.
