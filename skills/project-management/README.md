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
├── templates/
│   ├── issue-description-template.md        # Standard issue body structure
│   └── parent-issue-template.md             # Bundle/coordination parent issue structure
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

## Issue Tracker Setup Expectations

Before using roadmap, audit, research, or cycle-planning workflows, configure the companion issue-tracker skill and sync its cache so issues, projects, relations, and issue labels are readable. The workflows depend on current issue-label inventory from the issue-tracker skill; they should not infer labels from stale docs alone.

- **Issue labels vs project labels**: Issue creation uses issue labels. Project labels are separate issue-tracker resources and do not satisfy issue-label requirements. See [Label management](references/labels.md) and [Issue creation](references/issues.md).
- **Agent routing**: If a project routes work by agent, define one exclusive Agent label group/category and document the allowed agent labels in the project's taxonomy. Multi-agent bundle or coordination parents may need a documented multi-agent routing convention, but the exact label/value is project-defined.
- **Platform routing**: If a project tracks OS/platform-specific work, define an optional exclusive Platform category. Omit it when platform is irrelevant.
- **Domain/stack coverage**: Define project-specific domain or stack labels used for implementation ownership, research routing, and audit coverage. These labels are project-defined and may be additive.
- **Workflow/classification gates**: Treat workflow and classification labels as additive descriptors or gates, not exclusive ownership labels.
- **Label creation**: Missing labels require explicit user authorization before creation. Workflows must not create labels automatically. See [When to create labels](references/labels.md#when-to-create-labels).
- **Hierarchy and relations**: Preserve the expected hierarchy (`Initiative → Project → Milestone → Issue → Sub-Issue`), same-project parent/child and blocking relations, and bundle-parent blocking conventions. See [Issue creation](references/issues.md), [Initiatives & Projects](references/initiatives-projects.md), and [Dependency management](references/dependencies.md).
- **Templates**: Use the issue templates for consistent descriptions and parent/bundle coordination: [issue-description-template](templates/issue-description-template.md) and [parent-issue-template](templates/parent-issue-template.md).

## Key Concepts

- **Hierarchy**: Initiative → Project → Milestone → Issue → Sub-Issue
- **Prioritization**: Weighted scoring formula (Critical Path x3, Dependencies x2, Risk x2, Value x1, Estimate x-0.5)
- **Same-project rule**: Blocking relations and parent-child relations must be within the same project
- **Blocking level rule**: Blocking relations go on bundle parents, not children
- **Label preflight**: Issue creates/label updates load live issue-label inventory + project taxonomy, validate full final `labels[]`, and preserve unrelated labels on updates
- **Workflows return JSON only**: No direct modifications to the issue tracker — recommendations are executed by the caller
