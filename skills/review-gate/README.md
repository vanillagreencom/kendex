# Review operations

This package updates kendex installs in consumer repositories. GitHub rulesets enforce the approval and review-thread requirements.

## Features

- Open or update a consumer refresh pull request.
- Handle automatic review findings during consumer refresh.

## Install

```bash
kendex add vanillagreencom/kendex --skill review-gate
```

## How it works

Consumer refresh updates one rolling branch. The [publication rules](references/adoption.md#publication) define when it requests auto-merge. The [review thread rules](references/adoption.md#automatic-review-threads) define how it handles automatic review threads.

## Setup

After installing, run `kendex refresh` and commit the installed files.

Existing consumers first take the [trusted removal PR](workflows/retire-consumer-writer.md). [Repository wiring and settings](references/adoption.md) describes the required GitHub configuration and consumer refresh setup.

github-repository-settings, which review-gate installs, runs the GitHub rules and required-checks report. Its [platform checks](../github-repository-settings/references/platform-checks.md) reference holds the report's settings and the migration from review-gate.

## Licence

MIT, in the repository's LICENSE file.
