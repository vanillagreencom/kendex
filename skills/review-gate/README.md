# Review operations

This package checks organization standards and updates kendex installs in consumer repositories. GitHub rulesets enforce the approval and review-thread requirements. The github skill watches pull requests and reports their review state.

## Features

- Report repository rules and required checks against an organization standard.
- Open or update a consumer refresh pull request.
- Handle automatic review findings during consumer refresh.

## Install

```bash
kendex add vanillagreencom/kendex --skill review-gate
```

## How it works

The standard report compares GitHub configuration with the repository's settings. Consumer refresh updates one rolling branch. The [arm contract](SKILL.md#scripts) defines when it requests auto-merge. The [consumer refresh rules](references/adoption.md#automatic-consumer-refresh) define how it handles automatic review threads.

## Setup

After installing, run `kendex refresh` and commit the installed files.

Declare organization-standard values in `kendex.settings.toml` under `[env]`. Existing consumers first take the [trusted removal PR](workflows/retire-consumer-writer.md). [Repository wiring and settings](references/adoption.md) describes the required GitHub configuration and consumer refresh setup.

## Licence

MIT, in the repository's LICENSE file.
