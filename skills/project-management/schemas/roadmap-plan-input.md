# Roadmap Plan Input Schema

Input file for roadmap analysis, created by orchestrator after specialist agent consultation.

**Location**: `tmp/roadmap-input-YYYYMMDD-HHMMSS.json`

## Schema

```json
{
  "feature": "Feature name",
  "research_path": "docs/research/PROJ-123/findings.md",
  "origin_issue": {
    "id": "PROJ-136",
    "title": "Layout Shell & Navigation",
    "project": "Phase 2: UI Framework",
    "description": "...",
    "children": ["PROJ-137", "PROJ-138"]
  },
  "planner_handoff": {
    "plan_path": "docs/plans/feature-plan.md",
    "summary": "Technical plan summary from planner",
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

## Field Definitions

| Field | Required | Description |
|-------|----------|-------------|
| `feature` | Yes | Feature name from roadmap command |
| `research_path` | No | Path to research findings (null if skipped) |
| `origin_issue` | No | Issue that triggered this roadmap (context, not directive) |
| `planner_handoff` | No | Technical planner context to preserve through TPM analysis: plan path (normally under `docs/plans/`), concise summary, proposed phases/issues, and explicit TPM decisions requested. Use when roadmap planning follows a scout/planner chain. This augments analysis and does not bypass research gates or approval steps. |
| `proposed_issues[]` | Yes | Issues collected from specialist agents |

### Proposed Issue Fields

| Field | Required | Description |
|-------|----------|-------------|
| `title` | Yes | Issue title in "Verb: outcome" format |
| `estimate` | Yes | 1-5 points |
| `agent` | Yes | Source agent type |
| `labels` | No | Full issue-label set when known. Orchestrator/TPM must complete and validate required taxonomy categories before creation. |
| `depends_on_proposed` | No | Title references to other proposed issues |
| `depends_on_existing` | No | Issue ID references to existing issues |
| `conflicts_with` | No | Existing code/patterns that would be replaced |
| `breaking_changes` | No | APIs or contracts affected |
| `doc_updates` | No | Files needing documentation updates |

## Building from Specialist Agents

Orchestrator collects responses from each relevant agent:

```
Agent response table row → proposed_issue entry
- Title column → title
- Estimate column → estimate
- Agent source → agent
- Labels column → labels[] (optional; full issue-label set if specialist knows project taxonomy)
- "Depends on (proposed)" → depends_on_proposed
- "Depends on (existing)" → depends_on_existing
- "Conflicts with" → conflicts_with
- "Breaking changes" → breaking_changes
- "Skills/docs updates" → doc_updates
```
