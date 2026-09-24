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

Set `DEV_VALIDATE_CMD` in `kendex.settings.toml` under `[env]` to the project's full test, lint and typecheck command. The agent refuses to validate while it is empty and reports the setting to set. The command runs with `DEV_VALIDATE_CLASS` set to the change class of the work: `render`, `trivial`, `micro`, `small` or `standard`, from the harness-ci classifier, beside `DEV_VALIDATE_DOCS_ONLY` and `DEV_VALIDATE_PATHS`. Make the command read the class and skip the checks a small change does not need: a full run where the class does not need one is a failure of this setting, per [workflows/dev-implement.md](workflows/dev-implement.md) § 5. `standard` means run everything. The classifier proves `render` only on a committed tree, and the agent validates before it commits, so an uncommitted render change validates as `standard`. `DEV_VALIDATE_TIMEOUT_SECS` bounds that run, one hour by default; the agent's wait ends the moment the run does, and can never last past that bound plus the kill grace and one poll interval.

Set project instructions in `kendex.toml` under `[skill-instructions]`. The agent and commit format are described in [SKILL.md](SKILL.md) § Configuration.
