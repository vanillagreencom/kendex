# Review operations

This package watches GitHub pull requests and reports their review state. It also checks organization standards and updates kendex installs in consumer repositories. GitHub rulesets enforce the approval and review-thread requirements.

## Install

Install with `kendex add review-gate`, then run `kendex refresh` and commit the installed files.

## Features

- Report pull requests that need attention.
- Report repository rules and app-secret placement against an organization standard.
- Provision app-secret environments from the owner's machine.
- Open or update a consumer refresh pull request.
- File automatic review findings upstream before resolving their threads.

## How it works

The pull-request watcher reads GitHub's review state. It reports open threads, objections and approvals that do not arrive within the wait period. The standard report compares GitHub configuration with the repository's settings. Consumer refresh updates one rolling branch and requests auto-merge. A finding that cannot be filed keeps its thread open and holds the merge.

## Settings

Declare organization-standard values in `kendex.settings.toml` under `[env]`. Set `PR_REVIEW_WAIT_SECS` to change the watcher's quiet period. Existing consumers first take the [trusted removal PR](references/adoption.md#trusted-removal-for-an-existing-consumer). [Repository wiring and settings](references/adoption.md) describes the required GitHub configuration and consumer refresh setup.
