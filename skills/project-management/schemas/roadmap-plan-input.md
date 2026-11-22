# Roadmap Plan Input Schema

Written by `roadmap-plan.md` after specialist consultation, at `tmp/roadmap-input-YYYYMMDD-HHMMSS.json`.

```json
{
  "feature": "Feature name",
  "research_path": "tmp/plans/feature-plan.md",
  "research_read_path": "tmp/feature-plan.md",
  "research_source_issue": "PROJ-123",
  "spec_path": "tmp/plans/feature-plan.md",
  "origin_issue": {
    "id": "PROJ-136",
    "title": "Layout Shell & Navigation",
    "project": "Phase 2: UI Framework",
    "description": "...",
    "children": ["PROJ-137", "PROJ-138"]
  },
  "planner_handoff": {
    "plan_path": "tmp/plans/feature-plan.md",
    "summary": "Technical plan summary from the planner",
    "recommended_phases": ["Phase 1", "Phase 2"],
    "tpm_questions": ["Should this become a roadmap or child issues under PROJ-136?"]
  },
  "proposed_issues": [
    {
      "title": "Add dispose safety seam",
      "estimate": 2,
      "agent": "backend",
      "labels": ["agent:[TYPE]", "[DOMAIN_LABEL]"],
      "depends_on_proposed": ["Add error propagation"],
      "depends_on_existing": ["PROJ-301"],
      "conflicts_with": ["Current dispose pattern"],
      "breaking_changes": ["Order validation API signature"],
      "doc_updates": ["docs/architecture/backend.md"]
    }
  ]
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `feature` | Yes | Feature name from the command |
| `research_path` | No | Repository reference of the research input |
| `research_read_path` | When `research_path` is set | Readable file in the delegated checkout |
| `research_source_issue` | No | Issue holding the research/spec attachment |
| `spec_path` | No | Reference of a finished, reviewed plan |
| `origin_issue` | No | The issue that triggered this roadmap |
| `planner_handoff` | No | Technical context from a scout → planner chain |
| `proposed_issues[]` | Yes | Issues collected from the specialist agents |

- `research_path`: null when research was skipped. When the input is a SPEC this is the spec reference.
- `research_read_path`: resolved by the caller under [planning-artifacts.md](../references/planning-artifacts.md). Null when research was skipped.
- `research_source_issue`: null for an unpublished local input.
- `spec_path`:
  - Set exactly when the artifact in hand — the `@[path]` input or the roadmap-plan § 1 disk match — classified as a finished, reviewed plan (roadmap-plan § Inputs). Null otherwise.
  - Its approach and workstreams are binding on the TPM.
- `origin_issue`: context for the hierarchy decision, not a directive.
- `planner_handoff`:
  - Informs placement, grouping, and ordering.
  - Bypasses no gate, approval, or creation step.

### Proposed Issue Fields

| Field | Required | Description |
|-------|----------|-------------|
| `title` | Yes | `Verb: outcome` |
| `estimate` | Yes | 1-5 points per PR unit |
| `agent` | Yes | Source agent type |
| `labels` | No | Full issue-label set when the specialist knows the taxonomy |
| `depends_on_proposed` | No | Title references to other proposed issues |
| `depends_on_existing` | No | Existing issue IDs |
| `conflicts_with` | No | Existing code or patterns this replaces |
| `breaking_changes` | No | APIs or contracts affected |
| `doc_updates` | No | Files needing documentation updates |

`labels` is completed and validated before creation either way.

Each row of a specialist's response table maps to one entry: Title, Estimate, the source agent, Labels, "Depends on (proposed)", "Depends on (existing)", "Conflicts with", "Breaking changes", and "Skills/docs updates" → `doc_updates`.
