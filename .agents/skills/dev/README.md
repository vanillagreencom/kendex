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

Set `DEV_VALIDATE_CMD` in `kendex.settings.toml` under `[env]` to the project's full test, lint and typecheck command. The agent refuses to validate while it is empty and reports the setting to set. Make the command read `DEV_VALIDATE_CLASS`. Each validation command, and the selector's preview of a run, receives:

- `DEV_VALIDATE_CLASS`: `render`, `trivial`, `micro`, `small` or `standard`.
- `DEV_VALIDATE_DOCS_ONLY`: `true` or `false`.
- `DEV_VALIDATE_PATHS`: the path to a file listing the changed paths.
- `DEV_VALIDATE_BASE`: the base commit a range or ci run compares from; empty where the run has none, as for a full or docs run.
- `DEV_VALIDATE_MODE`: `full`, `range`, `docs` or `ci`: the mode the run resolved, or for the selector's preview the mode the start asked for, except `docs` for a docs-only change.
- `DEV_VALIDATE_SCOPED`: `true` where the runtime runs the selector as the command, scoped to the change; `false` otherwise.
- `DEV_VALIDATE_CI_EVENT`: the event required CI proves the head on, empty where CI does not take the run.
- `DEV_VALIDATE_CI_ADMISSION`: `admitted` or the `ci-fallback=` cause, empty where no admission was read.

Set `DEV_VALIDATE_RANGE_CMD` to a command that validates only the changes since the commit in `DEV_VALIDATE_BASE`. Review-fix rounds and orch restacks use it when they need local validation. Orch's merge-pr-restack.md defines the restack route.

`DEV_VALIDATE_SELECTION_CMD`, optional, owns changed-file selection: a docs-only tree runs its scoped text suites. With no selector, `DEV_VALIDATE_TEXT_CMD`, optional, supplies the text checks. With neither, the runtime records the range or full command it runs.

Set `DEV_VALIDATE_CI_CONTEXT` to the required status check whose run covers the full command: the merge-group run for a queue-only change, the pull request run otherwise. Covered implementation and fix rounds leave validation to that check, before publication too, whatever `ORCH_PR_ORDER` says: before a pull request opens, the resolved base branch's rules decide. The round accepts local edits with CI pending. Submit reuses a pending receipt for the current commit. The merge-group run proves a queue-only change's head before merge, and a red one returns the change to its lane. Uncovered work keeps local validation. Orch's `references/artifact-checks.md` § Validation entry answers lists the `ci-fallback=` causes for a CI request that runs locally.

A local run has no time limit: the executor ends it as stalled only after the start's `quiet-secs`, 660 seconds, with no output, no new process and no CPU work, and the wait then prints `validate=FAILING cause=stalled`. The agent's wait ends when the run does.

Set project instructions in `kendex.toml` under `[skill-instructions]`.

## Licence

MIT, in the repository's LICENSE file.
