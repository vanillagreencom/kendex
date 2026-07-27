# Dev Workflows

Agent workflows for issue implementation and review fix processing, for specialist agents receiving delegations from an orchestrator.

## Workflows

| Workflow | Purpose |
|----------|---------|
| `workflows/dev-implement.md` | Full implementation lifecycle: sync/activate → plan → implement → validate → commit → QA labels → summary → finalize (§ 1-11) |
| `workflows/dev-fix.md` | Process review fix items: evaluate → apply/skip → validate → commit → return |

Code-review and QA-review workflows live in the reviewer skill: `skills/reviewer/workflows/review.md` and `skills/reviewer/workflows/qa-review.md`.

## Tests

```bash
find skills/dev/tests -type f -name '*.test.sh' -exec bash {} \;
```

## Dependencies

| Dependency | Purpose |
|------------|---------|
| Issue tracker CLI | Linear (`linear.sh`) or GitHub (`gh issue`) for tracker updates |
| Reviewer skill | Code-review and QA-review ethos, workflows, and finding schema |
| orch skill | Recommendation-bias patterns |
| Decider skill | Decision search, templates, and creation workflow |
| Benchmarking skill | Baseline capture (optional) |

## License

MIT
