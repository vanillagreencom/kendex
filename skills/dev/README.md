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

The benchmarking skill is an interface by convention; consumers implement it. The QA-review workflow (`skills/reviewer/workflows/qa-review.md` § 2.4–2.5) scripts around three things: a regression check invocable as a documented standalone command whose exit code is the signal — 1 when regressions are detected, 0 clean — and direct runner/recorder commands usable without shell pipelines, redirection, or env-prefix plumbing (manual entry, where supported, passes the component name and JSON data only via a documented direct argument or body-file option). The recorder must produce a verifiable artifact: a run that records zero results, or a recorder that fails closed on all-zero counters, is reported as a benchmark tooling failure with `benchmark_commit: "none"` — never counted as coverage.

## License

MIT
