# Linear Dev Workflows

Agent workflows for issue implementation, review fix delegation, pre-submission PR review, and QA review. Designed for specialist agents receiving delegations from an orchestrator.

## Structure

```
skills/linear-dev/
├── SKILL.md              # Skill definition for AI agents and skill-aware harnesses
├── README.md             # This file — human-facing docs
└── workflows/
    ├── dev-implement.md   # Main implementation lifecycle (§ 1-11)
    └── dev-fix.md         # Review fix delegation workflow (§ 1-6)
```

Code-review and QA-review workflows live in the reviewer skill: `skills/reviewer/workflows/review.md` and `skills/reviewer/workflows/qa-review.md`.

This skill is workflow-based. All behavior is defined in the workflow files.

## Workflows

### dev-implement.md

The main workflow for dev agents receiving `Issue: [ISSUE_ID]` delegations. Supports both single-issue and bundled (parent + sub-issues) flows. Covers the full lifecycle: environment setup, issue activation, research context, feasibility evaluation, implementation, validation, visual QA, skill reflection, commit, QA label application, completion summary, and finalization.

### dev-fix.md

The workflow for dev agents receiving review fix delegations. Each review item is evaluated independently against project decisions and conventions, then applied or skipped with reasoning. Includes validation, visual QA for UI fixes, and structured return with per-item decisions.

## Skill Dependencies

| Dependency | Purpose | Variable |
|------------|---------|----------|
| Issue tracker CLI (e.g., `linear` skill) | Issue CRUD, cache, comments, labels | `.agents/skills/linear/scripts/linear.sh` |
| Reviewer skill | Code-review + QA-review ethos, scope boundaries, workflows, and finding schema | Referenced by name |
| linear-orch skill | Recommendation-bias patterns | Referenced by name |
| Decider skill | Decision templates, search CLI, creation workflows | `.agents/skills/decider/scripts/decisions` |
| Benchmarking | Run benchmarks if a benchmarking skill is installed | Optional |

## Configuration

### Agent types

- **Dev agents**: `[AGENT_TYPE]` — specialist agents receiving implementation delegations
- **Review agents**: `[REVIEW_AGENT]` — agents that review specific aspects (correctness, quality, security, testing, docs, errors, structure)
- **QA agents**: `[QA_AGENT]` — agents for safety, performance, and architecture review

### Commit format

`[PREFIX]([ISSUE_ID]): [DESCRIPTION]` — configurable per project conventions.

## License

MIT
