# Roadmap Plan Output Schema

Output from TPM roadmap analysis, consumed by orchestrator for presentation and plan file generation.

**Location**: `tmp/roadmap-plan-YYYYMMDD-HHMMSS.json`

## Schema

```json
{
  "feature": "Feature name",
  "research_path": "docs/research/[ISSUE_ID]/findings.md",
  "hierarchy_recommendation": {
    "type": "children_of_origin",
    "origin_issue": "[ISSUE_ID]",
    "rationale": "All proposed issues decompose origin issue scope"
  },
  "cross_project_findings": {
    "duplicates": [],
    "conflicts": []
  },
  "project_placement": {
    "recommendation": "new",
    "project_name": "Phase 3: API Layer",
    "project_description": "REST API endpoints and middleware",
    "relations": []
  },
  "architecture_gaps": [],
  "organized_issues": [],
  "context": {
    "source": "roadmap-create",
    "research_path": "docs/research/[ISSUE_ID]/findings.md",
    "origin_issue": "[ISSUE_ID]",
    "plan_path": "docs/roadmaps/roadmap-feature-name.md"
  },
  "summary": {
    "total_issues": 5,
    "bundles": 1,
    "critical_path_issues": 2,
    "gaps_to_include": 1,
    "duplicates_found": 0,
    "conflicts_found": 0
  }
}
```

## Hierarchy Recommendation

```json
"hierarchy_recommendation": {
  "type": "children_of_origin",
  "origin_issue": "[ISSUE_ID]",
  "rationale": "All proposed issues decompose origin issue scope"
}
```

| Type | When | Effect |
|------|------|--------|
| `children_of_origin` | All issues decompose the origin issue's scope | Set `parent_issue` to origin issue ID |
| `new_project` | Issues represent new capability beyond origin scope | Set `parent_issue: null`, create new project |
| `mixed` | Some in-scope, some new | Split: children of origin + new standalone/project |
| `none` | No `origin_issue` provided | No hierarchy guidance (legacy behavior) |

**Only present when `origin_issue` was provided in input.** When `type` is `none` or field is absent, `parent_issue` defaults to null.

## Context

```json
"context": {
  "source": "roadmap-create",
  "research_path": "docs/research/[ISSUE_ID]/findings.md",
  "origin_issue": "[ISSUE_ID]",
  "plan_path": "docs/roadmaps/roadmap-feature-name.md"
}
```

| Field | Description |
|-------|-------------|
| `source` | Workflow that will consume this output (always `"roadmap-create"`) |
| `research_path` | Research findings path (null if no research) |
| `origin_issue` | Origin issue ID (null if not provided) |
| `plan_path` | Path where plan markdown will be saved |

`plan_path` set by orchestrator (null during initial TPM output).

## Cross-Project Findings

### Duplicates

```json
"duplicates": [
  {
    "proposed_title": "Add API rate limiting",
    "existing_id": "[ISSUE_ID]",
    "existing_title": "Implement request throttling",
    "existing_project": "Phase 2: Infrastructure",
    "match_type": "partial",
    "recommendation": "expand",
    "reason": "Existing issue covers basic throttling; expand to include rate limiting"
  }
]
```

| Match Type | Meaning |
|------------|---------|
| `exact` | Same title and scope — skip proposed |
| `partial` | Overlapping scope — expand existing or descope proposed |
| `supersedes` | Proposed replaces existing entirely — cancel existing |

| Recommendation | Action |
|----------------|--------|
| `skip` | Don't create proposed, reference existing |
| `expand` | Expand existing to include proposed scope |
| `descope` | Reduce proposed scope to avoid overlap |
| `cancel` | Cancel existing, create proposed |

### Conflicts

```json
"conflicts": [
  {
    "proposed_title": "Refactor data pipeline",
    "conflicts_with": "[ISSUE_ID]",
    "conflict_type": "concurrent_work",
    "resolution": "Wait for [ISSUE_ID] to complete before starting",
    "risk": "medium"
  }
]
```

| Conflict Type | Meaning |
|---------------|---------|
| `breaks_existing` | Proposed would break existing completed work |
| `concurrent_work` | Proposed conflicts with in-progress work |
| `incompatible_approach` | Different approaches to same problem |

## Project Placement

```json
"project_placement": {
  "recommendation": "new",
  "project_name": "Phase 3: API Layer",
  "project_description": "REST API endpoints and middleware",
  "relations": [
    {"type": "blocked-by", "project": "Phase 2: Infrastructure", "reason": "Requires data layer infrastructure"},
    {"type": "blocks", "project": "Phase 4: Frontend", "reason": "API enables frontend integration"}
  ]
}
```

| Recommendation | Meaning |
|----------------|---------|
| `new` | Create new project |
| `existing` | Add to existing project (name = existing project) |

## Architecture Gaps

```json
"architecture_gaps": [
  {
    "component": "Request caching layer",
    "module_path": "src/cache/",
    "status": "missing",
    "evidence": "Module directory does not exist",
    "recommendation": "include",
    "reason": "Required for API response caching"
  }
]
```

| Status | Evidence |
|--------|----------|
| `missing` | Module/directory doesn't exist |
| `stubbed` | Exists but returns placeholders |
| `partial` | Some functionality, TODOs remain |

| Recommendation | When |
|----------------|------|
| `include` | Blocks proposed work or critical for feature |
| `defer` | Nice-to-have, not blocking |
| `out_of_scope` | Unrelated to feature |

## Organized Issues

```json
"organized_issues": [
  {
    "title": "Implement request router",
    "estimate": 3,
    "agent": "backend",
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
  },
  {
    "title": "Auth Middleware Bundle",
    "estimate": null,
    "agent": "multi",
    "agent_label": "agent:multi",
    "labels": ["agent:multi", "[DOMAIN_LABEL]"],
    "priority": 2,
    "action": "create",
    "target": null,
    "reason": "Bundle parent for auth middleware work",
    "is_bundle_parent": true,
    "parent_title": null,
    "depends_on_proposed": ["Implement request router"],
    "depends_on_existing": [],
    "blocked_by_proposed": ["Implement request router"],
    "critical_path": false,
    "layer": 2,
    "position": 200,
    "conflicts_with": [],
    "breaking_changes": [],
    "doc_updates": []
  },
  {
    "title": "Implement JWT validation middleware",
    "estimate": 2,
    "agent": "backend",
    "labels": ["agent:[TYPE]", "[DOMAIN_LABEL]"],
    "priority": 2,
    "action": "create",
    "target": null,
    "reason": "Auth middleware consuming router infrastructure",
    "is_bundle_parent": false,
    "parent_title": "Auth Middleware Bundle",
    "depends_on_proposed": [],
    "depends_on_existing": [],
    "blocked_by_proposed": [],
    "critical_path": false,
    "layer": 2,
    "position": 201,
    "conflicts_with": [],
    "breaking_changes": [],
    "doc_updates": ["docs/architecture/auth.md"]
  }
]
```

### Architecture Layers

| Layer | Meaning |
|-------|---------|
| 0 | Foundation — no dependencies, enables others |
| 1 | Infrastructure — depends on L0, enables L2+ |
| 2 | Features — depends on L0-L1 |
| 3 | Integration — depends on features |
| 4 | Testing/polish — depends on everything |

### Position Calculation

```
position = (layer x 100) + (enables_count x -10) + (estimate x 1)
```

Lower position = earlier in implementation order.

### Priority Computation

| Condition | Priority |
|-----------|----------|
| L0 + `critical_path` | P1 |
| L0/L1 + enables 2+ issues | P1 |
| L1/L2 | P2 |
| L3 | P3 |
| L4 | P4 |

**Propagation**: If an issue blocks a P1 issue, it becomes P1.

### Bundle Rules

- `is_bundle_parent: true` → aggregate issue, `estimate: null`
- `parent_title` set → child of that bundle
- Bundle when 2+ issues share: same agent + small estimates (1-2) + same work type
- `labels[]`: Full issue-label set for creation. Required before `roadmap-create` mutates Linear.
- `agent_label`: Backward-compatible derived field. If all children have same agent → parent gets that agent label. If 2+ distinct agents → parent gets the project-configured multi-agent label (for example `agent:multi` when present in taxonomy/inventory).

### Label Rules

- Labels are issue labels, not project labels.
- `labels[]` must include all project-required categories for new issues.
- Do not include parent/group labels.
- If TPM cannot determine a required category, it should flag the gap in `reason` instead of inventing labels.
- `agent`/`agent_label` are not enough for create; `roadmap-create` must preflight the full `labels[]` set against live inventory and project taxonomy.

### Action Assignment (from TPM 5.2)

Per-issue fields added by TPM validation step:

| Field | Type | Description |
|-------|------|-------------|
| `action` | string | `create`, `skip`, `expand`, `supersede`, `cancel` |
| `target` | string\|null | Existing issue ID for `expand`/`supersede`, null otherwise |
| `reason` | string | Why this action was assigned |

| Action | Meaning |
|--------|---------|
| `create` | Create new issue |
| `skip` | Don't create — exact duplicate exists |
| `expand` | Expand existing issue (target) to include this scope |
| `supersede` | Cancel existing (target), create replacement |
| `cancel` | Obsolete — already implemented |

### Relation Hierarchy

When issues are bundled, `blocks`/`blocked_by` between bundles go on **parent** issues, not children. Children within a bundle have no external blocking relations.

### Critical Path

`critical_path: true` when issue blocks 2+ other issues.

## Summary

```json
"summary": {
  "total_issues": 5,
  "bundles": 1,
  "critical_path_issues": 2,
  "gaps_to_include": 1,
  "duplicates_found": 0,
  "conflicts_found": 0
}
```

Quick counts for orchestrator validation and presentation.
