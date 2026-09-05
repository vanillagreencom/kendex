# harness-ci

A changed-file check for repositories that commit kendex-generated files. It lets CI skip product checks when a change contains only recorded generated files.

## Install

```bash
kendex add vanillagreencom/kendex --skill harness-ci
```

Commit the installed skill and generated-file inventory. The CI runner needs `jq`. Follow [references/wiring.md](references/wiring.md) for workflow setup.

## Features

- Compare changed files with kendex's generated-file inventory.
- Run product checks for unrecorded files and uncertain results.
- Support pull requests, pushes and merge-queue events.

## How it works

kendex writes a generated-file inventory beside the installed files. Your CI step gives the checker the event and the base and head commits. The checker reads both inventories and compares them with the changed files. It returns a value your workflow uses to run or skip product checks.

## Settings

The checker has no project settings. The CI call supplies the event and commit identifiers. Use `harness-only --help` for its arguments.


Workflow setup: [references/wiring.md](references/wiring.md). Maintainer rules and tests: [DEVELOPMENT.md](DEVELOPMENT.md).
