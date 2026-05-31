# Project Management Skill

TPM methodology for roadmap planning, cycle planning, issue auditing, prioritization, and progress tracking. Workflows analyze issue tracker state and return structured JSON recommendations — the orchestrator or user handles execution.

This skill is methodology-based. All guidance lives in reference documents, workflows, and schemas.

## Structure

```
skills/project-management/
├── SKILL.md                                # Skill definition for AI agents and skill-aware harnesses
├── README.md                               # This file — human-facing docs
├── references/
│   ├── issues.md                           # Issue creation, fields, sub-issues, estimates, templates
│   ├── initiatives-projects.md             # Initiative/project lifecycle, naming, breakdown
│   ├── dependencies.md                     # Blocking rules, relation types, remediation
│   ├── prioritization.md                   # Scoring formula, factor definitions, trade-offs
│   └── labels.md                           # Issue-label inventory preflight, taxonomy contract, exclusivity, lifecycle
├── workflows/
│   ├── tpm-cycle-plan.md                   # Analyze backlog, compute architecture order for cycle
│   ├── tpm-roadmap-plan.md                 # Cross-project analysis, architecture gaps
│   ├── tpm-audit.md                        # Audit issues/projects for relations, hierarchy
│   └── tpm-audit-project-order.md          # Analyze project dependencies and ordering
└── schemas/
    ├── cycle-plan-output.md                # Cycle planning JSON output schema
    ├── roadmap-plan-output.md              # Roadmap analysis JSON output schema
    ├── audit-output.md                     # Issue/project audit JSON output schema
    └── audit-project-order-output.md       # Project order audit JSON output schema
```

## Skill Dependencies

This skill requires an issue tracker CLI for all read/write operations. Configure the `.agents/skills/linear/scripts/linear.sh` variable to point to your issue tracker's CLI tool.

| Dependency | Purpose | Variable |
|------------|---------|----------|
| Issue tracker CLI (e.g., `linear` skill) | Issue CRUD, cache, comments, labels, relations | `.agents/skills/linear/scripts/linear.sh` |

## Key Concepts

- **Hierarchy**: Initiative → Project → Milestone → Issue → Sub-Issue
- **Prioritization**: Weighted scoring formula (Critical Path x3, Dependencies x2, Risk x2, Value x1, Estimate x-0.5)
- **Same-project rule**: Blocking relations and parent-child relations must be within the same project
- **Blocking level rule**: Blocking relations go on bundle parents, not children
- **Label preflight**: Issue creates/label updates load live issue-label inventory + project taxonomy, validate full final `labels[]`, and preserve unrelated labels on updates
- **Workflows return JSON only**: No direct modifications to the issue tracker — recommendations are executed by the caller
