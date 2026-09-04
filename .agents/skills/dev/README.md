# Dev Workflows

The implementer's half of an orchestrated cycle. A specialist agent loads this skill when the orchestrator hands it a work item and follows one lifecycle from delegation to return. For a project that runs the `orch` skill and wants its dev agents to implement and fix in one repeatable shape.

## Install

```bash
kendex add vanillagreencom/kendex --skill dev
```

Needs `orch` (the caller and shared runtime), `github`, `decider` and `code-quality` beside it, plus `linear` for Linear-tracked work. A benchmarking skill is optional; when one is installed, issues labelled `baseline` capture a pre-implementation baseline.

## What it does

- An implementation lifecycle: plan, implement, validate, commit, QA labels, summary, completion artifact, return.
- A review-fix lifecycle: evaluate each finding, apply or skip, validate, commit, artifact, return.
- Engineering rules for the round, delegating code standards to `code-quality`.

## How it works

The orchestrator owns the cycle; this skill owns one round of it. Both lifecycles end the same way: a completion artifact on disk, then a single message back. The artifact is what the orchestrator accepts on, so a round survives a lost return message or a test suite that outlives the agent's turn. Code review and QA review are a different role and live in the `reviewer` skill.

## Customise

- `DEV_VALIDATE_CMD`: the project's validation command for the Validate step, in `kendex.settings.toml` under `[env]`. Point it at a diff-scoped validator where one exists; unset, the workflows fall back to the project's documented build, lint and test command.
- Agent-type names, the commit prefix and QA-label triggers: [SKILL.md](SKILL.md) § Configuration.
