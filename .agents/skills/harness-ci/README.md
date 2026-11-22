# harness-ci

A changed-file check for CI. It lets CI skip selected checks when a change contains only recorded generated files or only documentation files.

## Features

- Compare the files a change touched with the list of files kendex generated.
- Classify documentation-only changes.
- Run product checks for unrecorded files and uncertain results.
- Support pull requests, pushes and merge-queue events.
- Validate skipped jobs before a required-context aggregator reports success.
- Name the kind of a change: a re-rendered install, a trivial edit, a micro or small change, or anything else.
- Ship a CI workflow template that reports one `CI` check, the aggregate context every repository under the standard reports, and runs the product checks in the merge queue.

## Install

```bash
kendex add vanillagreencom/kendex --skill harness-ci
```

## How it works

- CI identifies changes that contain only generated files or documentation.
- A proved generated-file update can skip product checks. An uncertain result keeps them running.
- Workflows with several test groups can select the groups a change needs.
- The classifier also tells the merge route when a change requires the merge queue.
- A required `CI` check reports success only after the required jobs pass or have an authorized skip.

The scripts and the wiring rules: [SKILL.md](SKILL.md). Workflow setup, the queue-only default and the nightly run: [references/wiring.md](references/wiring.md).

## Setup

- Commit the installed skill and generated-file inventory.
- The runner needs `jq`, `python3`, a compatible `kendex` on PATH and a fetched source mirror.
- Follow [workflow wiring](references/wiring.md) to install the engine from the trusted default branch with harness-ci's installer.
- An unsupported engine keeps product checks running.
- An update made by a newer unreleased engine needs a compatible release before CI can skip those checks.

Set repository options in the default branch's `kendex.settings.toml` under `[env]`:

| Setting | What to configure |
|---|---|
| `HARNESS_CI_STANDARD_PATHS` | High-risk paths that always need full checks. |
| `HARNESS_CI_DOCS_PATHS` | Exact Markdown files containing text displayed to users outside the built-in docs set. |
| `HARNESS_CI_UNREAD_PATHS` | Globs for files no CI job reads, such as `.github/dependabot.yml`. |
| `HARNESS_CI_PER_PUSH_REASON` | The reason the repository runs its lanes on each pull-request push and may merge outside the queue. |
| `HARNESS_CI_QUEUE_PATHS` | The repository's own CI inputs that need the merge queue. |
| `HARNESS_CI_QUEUE_SELECTOR` | The repository command that identifies merge-group jobs. |
| `HARNESS_CI_TRIVIAL_PATHS` | Paths eligible for the trivial-change class. |
| `HARNESS_CI_TRIVIAL_MAX_LINES` | The line ceiling for that class. |
| `HARNESS_CI_TRIVIAL_SETTINGS` | Adjustments to the installed packages' CI-unread keys. |
| `ORCH_SIZE_TEST_PATHS` | Test paths outside the branch measurement's default patterns. |

- `HARNESS_CI_DOCS_PATHS`: keep the checks claiming those files through the lane outputs. A path in the built-in docs set cannot be declared, and its entry is ignored. [Declaration contract](references/wiring.md#declared-product-text).
- `HARNESS_CI_UNREAD_PATHS`: a change to only those files, with no lane claiming them, runs no lane. Declared product text, a path on the shipped queue list, such as a workflow, and a path git quotes keep the unclaimed-path fallback. [Per-lane contract](references/wiring.md#per-lane-verdicts).
- `HARNESS_CI_PER_PUSH_REASON`: unset, every change is queue-only. A repository with no merge queue sets it to `no merge queue`. What it changes: [references/wiring.md § The CI template](references/wiring.md#the-ci-template).
- `HARNESS_CI_QUEUE_PATHS` is read only with `HARNESS_CI_PER_PUSH_REASON`. Set it empty when the shipped list covers all those inputs. Leaving it unset requires the queue for every change.
- `HARNESS_CI_QUEUE_SELECTOR` is read only with `HARNESS_CI_PER_PUSH_REASON`. Before you set it: [references/wiring.md § The CI template](references/wiring.md#the-ci-template).
- `HARNESS_CI_TRIVIAL_MAX_LINES`: a diff of admitted settings files alone has no ceiling.
- `HARNESS_CI_TRIVIAL_SETTINGS`: add key globs, or prefix a glob with `!` to remove them.
- `HARNESS_CI_TRIVIAL_SETTINGS`: list only keys that no CI job or review gate reads.

For several test groups, declare their input paths in `.github/ci-lanes.conf`.

- The [per-lane wiring contract](references/wiring.md#per-lane-verdicts) defines the declaration, the queue mark, the nightly mark for platform lanes and the steps before a queue mark lands.
- A `:queue` mark removed while an open pull request predates it can need one step before that pull request merges: [§ The endpoint expressions](references/wiring.md#the-endpoint-expressions).

Arguments, defaults and setting precedence: `harness-only --help`, `change-class --help`, `aggregate-needs --help` and, for the class and its settings, change-scope's `change-scope --help`. Maintainer rules and tests: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/harness-ci/DEVELOPMENT.md).

## Licence

MIT, in the repository's LICENSE file.
