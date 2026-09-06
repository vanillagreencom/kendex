# harness-ci

A changed-file check for repositories that commit kendex-generated files. It lets CI skip product checks when a change contains only recorded generated files.

## Install

```bash
kendex add vanillagreencom/kendex --skill harness-ci
```

Commit the installed skill and generated-file inventory. The CI runner needs `jq`. Follow [references/wiring.md](references/wiring.md) for workflow setup.

## Features

- Compare the files a change touched with the list of files kendex generated.
- Run product checks for unrecorded files and uncertain results.
- Support pull requests, pushes and merge-queue events.

## How it works

- kendex writes a list of every file it generated, called the inventory, beside the files it installed.
- Your CI step tells the checker which GitHub event it is handling and which two commits to compare.
- The checker works out the range that event needs, then reads the inventory as it stood at each end of that range.
- It answers `true` only when every file the change touched is on the inventory at each end where that file exists.
- Anything it cannot prove answers `false`, and your workflow uses that answer to run or skip the product checks.

## Settings

The checker has no project settings. The CI call supplies the event and commit identifiers. Use `harness-only --help` for its arguments.


Workflow setup: [references/wiring.md](references/wiring.md). Maintainer rules and tests: [DEVELOPMENT.md](DEVELOPMENT.md).
