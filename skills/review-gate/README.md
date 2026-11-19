# Review operations

This package updates kendex installs in consumer repositories. GitHub rulesets enforce the approval and review-thread requirements. The github skill watches pull requests and reports their review state.

## Features

- Open or update a consumer refresh pull request.
- Handle automatic review findings during consumer refresh.

## Install

```bash
kendex add vanillagreencom/kendex --skill review-gate
```

## How it works

Consumer refresh updates one rolling branch. The [arm contract](SKILL.md#scripts) defines when it requests auto-merge. The [consumer refresh rules](references/adoption.md#automatic-consumer-refresh) define how it handles automatic review threads.

## Setup

After installing, run `kendex refresh` and commit the installed files.

Existing consumers first take the [trusted removal PR](workflows/retire-consumer-writer.md). [Repository wiring and settings](references/adoption.md) describes the required GitHub configuration and consumer refresh setup.

github-repository-settings, which review-gate installs, runs the GitHub rules and required-checks report. Its [platform checks](../github-repository-settings/references/platform-checks.md) reference holds the report's settings and the migration from review-gate.

## Licence

MIT, in the repository's LICENSE file.
