# Dev Workflows

Implementation and review-fix workflows for coding agents. The orch skill assigns the work and receives the completed change.

## Install

```bash
kendex add vanillagreencom/kendex --skill dev
```

kendex installs the required skills beside dev. Add linear for Linear issues. The orch skill assigns implementation and review-fix work.

## Features

- Guide an agent through planning, implementation, validation and commit.
- Apply or decline review findings with recorded reasons.
- Return the commit, validation result and review needs to the primary agent.

## How it works

The primary agent assigns an issue and a worktree. The implementation agent reads the issue and changes the assigned files. It runs the project checks and commits the result. It writes a completion record and sends the result to the primary agent.

## Settings

Set `DEV_VALIDATE_CMD` in `kendex.settings.toml` under `[env]` to select the project validation command. Without it, the agent uses the documented build, lint and test command.

Set project instructions in `kendex.toml` under `[skill-instructions]`. The agent and commit format are described in [SKILL.md](SKILL.md) § Configuration.
