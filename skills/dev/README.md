# Dev Workflows

The implementer's half of an orchestrated cycle. A specialist agent loads this skill when the orchestrator hands it a work item and follows one of two lifecycles from delegation to return.

| Workflow | Purpose |
|----------|---------|
| `workflows/dev-implement.md` | Implementation: activate → plan → implement → validate → commit → QA labels → summary → artifact → return |
| `workflows/dev-fix.md` | Review fixes: evaluate → apply or skip → validate → commit → artifact → return |

## How it works

The orchestrator owns the cycle; this skill owns one round of it. Both lifecycles end the same way — a completion artifact on disk, then a single message back. The artifact is what the orchestrator accepts on, so a round survives a lost return message or a test suite that outlives the agent's turn. Code review and QA review are a different role and live in the `reviewer` skill.

## Setup

Install with `vstack add dev`; `vstack refresh` picks up updates. It needs `orch` (the shared runtime, and the caller), `github`, and `decider` alongside it, plus `linear` for Linear-tracked work. A benchmarking skill is optional: when one is installed, `baseline`-labelled issues capture a pre-implementation baseline for the performance QA agent.

Agent-type names, the commit prefix, and QA-label triggers are project-configurable — see SKILL.md § Configuration and the project's label application guide.

## Tests

```bash
find skills/dev/tests -type f -name '*.test.sh' -exec bash {} \;
```

These are documentation lints. They pin contracts the agent relies on finding in the workflow text: the Linear cache preflight and its ordering, the required-mode QA label gate, the supported decider issue lookup, and the tmp-file route for multiline tracker comments.

## License

MIT
