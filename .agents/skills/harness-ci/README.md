# harness-ci

A changed-file check for CI. It lets CI skip selected checks when a change contains only recorded generated files or only documentation files.

## Features

- Compare the files a change touched with the list of files kendex generated.
- Classify documentation-only changes.
- Run product checks for unrecorded files and uncertain results.
- Support pull requests, pushes and merge-queue events.
- Validate skipped jobs before a required-context aggregator reports success.
- Name the kind of a change: a re-rendered install, a trivial edit, a micro or small change, or anything else.
- Ship a CI workflow template that reports one `CI` check, the aggregate context every repository under the standard reports, and runs the same checks on a merge queue as on the pull request.

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

Classification contracts: [SKILL.md](SKILL.md). Workflow setup, the queue-only default and the nightly run: [references/wiring.md](references/wiring.md).

## Setup

Commit the installed skill and generated-file inventory. The runner needs `jq`, `python3`, a compatible `kendex` on PATH and a fetched source mirror. Follow [workflow wiring](references/wiring.md) to install the engine from the trusted default branch with review-gate's installer. An unsupported engine keeps product checks running. An update made by a newer unreleased engine needs a compatible release before CI can skip those checks.

Set repository options in the default branch's `kendex.settings.toml` under `[env]`:

| Setting | What to configure |
|---|---|
| `HARNESS_CI_STANDARD_PATHS` | High-risk paths that always need full checks. |
| `HARNESS_CI_PER_PUSH_REASON` | The reason the repository runs its lanes on each pull-request push and may merge outside the queue. Set, the lanes run on every pull-request push and only `:queue` lanes wait for the merge group. Unset, every change is queue-only, and the CI template's pull request runs no lane: the merge-queue run proves the head. A blank value is refused and read as unset. A repository with no merge queue sets it to `no merge queue`. |
| `HARNESS_CI_QUEUE_PATHS` | Read only with `HARNESS_CI_PER_PUSH_REASON`. The repository's own CI inputs that need the merge queue. Set it empty when the shipped list covers them all. Leaving it unset requires the queue for every change. |
| `HARNESS_CI_QUEUE_SELECTOR` | Read only with `HARNESS_CI_PER_PUSH_REASON`. The repository command that identifies merge-group jobs. Update harness-ci on the default branch and sync the merging checkout before using this setting. |
| `HARNESS_CI_TRIVIAL_PATHS` | Paths eligible for the trivial-change class. |
| `HARNESS_CI_TRIVIAL_MAX_LINES` | The line ceiling for that class. |
| `ORCH_SIZE_TEST_PATHS` | Test paths outside orch's default patterns. |

For several test groups, declare their input paths in `.github/ci-lanes.conf`. The [per-lane wiring contract](references/wiring.md#per-lane-verdicts) defines the declaration, the queue mark and the nightly mark for platform lanes. Refresh the install and sync the merging checkout before adding queue marks. Re-run CI on open pull requests after removing a mark, or after adding `HARNESS_CI_PER_PUSH_REASON`.

Arguments, defaults and setting precedence: `harness-only --help`, `change-class --help` and `aggregate-needs --help`. Maintainer rules and tests: [DEVELOPMENT.md](https://github.com/vanillagreencom/kendex/blob/main/skills/harness-ci/DEVELOPMENT.md).

## Licence

MIT, in the repository's LICENSE file.
