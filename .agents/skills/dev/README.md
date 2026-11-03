# Dev Workflows

Implementation and review-fix workflows for coding agents. The orch skill assigns the work and receives the completed change.

## Features

- Guide an agent through planning, implementation, validation and commit.
- Apply or decline review findings with recorded reasons.
- Return the commit, validation result and review needs to the primary agent.

## Install

```bash
kendex add vanillagreencom/kendex --skill dev
```

## How it works

The primary agent assigns an issue and a worktree. The implementation agent reads the issue and changes the assigned files. It runs the project checks and commits the result. It writes a completion record and sends the result to the primary agent.

## Setup

kendex installs the required skills beside dev. Add linear for Linear issues. The orch skill assigns implementation and review-fix work.

Set `DEV_VALIDATE_CMD` in `kendex.settings.toml` under `[env]` to the project's full test, lint and typecheck command. An empty value refuses validation. The command must use the supplied change class to select the checks the change needs, as [workflows/dev-implement.md](workflows/dev-implement.md) § 5 requires.

Set `DEV_VALIDATE_RANGE_CMD` when fixes need a command that checks changes since `DEV_VALIDATE_BASE`. Set `DEV_VALIDATE_CI_CONTEXT` when a required CI check covers the full command. A round that leaves proof to CI records it as pending. Set `DEV_VALIDATE_TIMEOUT_SECS` to change the local run's bound.

Read [SKILL.md](SKILL.md) § Configuration for these settings. Orch's `dev-validate-run --help` owns command inputs, defaults, CI coverage and local fallback; its merge-pr-restack.md owns the restack route.

Set project instructions in `kendex.toml` under `[skill-instructions]`. The agent and commit format are described in [SKILL.md](SKILL.md) § Configuration.

## Licence

MIT, in the repository's LICENSE file.
