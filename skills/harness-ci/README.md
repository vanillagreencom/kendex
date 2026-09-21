# harness-ci

A changed-file check for CI. It lets CI skip selected checks when a change contains only recorded generated files or only documentation files.

## Install

```bash
kendex add vanillagreencom/kendex --skill harness-ci
```

Commit the installed skill and generated-file inventory. The CI runner needs `jq`, and, for the change classifier's `render` class, a `kendex` on its PATH and a source mirror it has already fetched. Pin the version that runner installs: the `render` proof reads what `kendex verify` prints, so a release that prints it differently answers `standard` instead. Follow [references/wiring.md](references/wiring.md) for workflow setup.

## Features

- Compare the files a change touched with the list of files kendex generated.
- Classify documentation-only changes.
- Run product checks for unrecorded files and uncertain results.
- Support pull requests, pushes and merge-queue events.
- Validate skipped jobs before a required-context aggregator reports success.
- Name the kind of a change: a re-rendered install, a trivial edit, a micro or small change, or anything else.

## How it works

- kendex writes a list of every file it generated, called the inventory, beside the files it installed.
- Your CI step tells the checker which GitHub event it is handling and which two commits to compare.
- The checker works out the range that event needs, then reads the inventory as it stood at each end of that range.
- Harness mode answers `true` only when every file the change touched is on the inventory at each end where that file exists.
- Docs mode answers `true` only when every changed path is in its documented path set.
- Anything it cannot prove answers `false`, and your workflow uses that answer to run or skip the product checks.
- The aggregate helper accepts a skipped job only when a successful classifier authorized that job.
- The change classifier reuses that same reading of the diff and adds size and path rules, so CI, the review gate and a working agent all read one verdict instead of inventing their own.
- It proves a re-rendered install by asking kendex to re-render, never by trusting the list of generated files or the install record, either of which the change itself could rewrite. Every changed file has to be one kendex reported as checked and in sync, or one of kendex's own two bookkeeping files, which hold no rendered content and are accepted by name. The checkout it reads has to hold nothing uncommitted.
- Only some kinds record where kendex installed them, and only those can be matched to a changed file: a skill, a Pi extension, and a command on a harness that stores it as a skill tree. A change that re-renders an agent, a hook, an MCP server, a plugin, a command on any other harness, or one of the files that register hooks and prompts with a harness is not provable this way, and the classifier says so rather than guessing.

## Settings

The harness and docs checkers have no project settings. The change classifier reads two, each with a shipped default: `HARNESS_CI_TRIVIAL_PATHS`, the repository's own low-blast allowlist as blank-separated globs (empty, the default, uses the documentation path set: `docs/`, `changelog.d/` and root Markdown files, so a root `README.md` edit under the ceiling counts as trivial while `AGENTS.md`, `CLAUDE.md` and every configuration source is refused ahead of it), and `HARNESS_CI_TRIVIAL_MAX_LINES`, the line ceiling under which those paths count as trivial (default 20). The CI call supplies the mode, event, and commit identifiers. A check that must apply its own policy rules to the exact changed-path set reads it from `harness-only --paths-output`, where that set is derived. Use `harness-only --help`, `change-class --help` and `aggregate-needs --help` for all arguments.


Workflow setup: [references/wiring.md](references/wiring.md). Maintainer rules and tests: [DEVELOPMENT.md](DEVELOPMENT.md).
