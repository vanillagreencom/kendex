# harness-ci

A changed-file check for CI. It lets CI skip selected checks when a change contains only recorded generated files or only documentation files.

## Install

```bash
kendex add vanillagreencom/kendex --skill harness-ci
```

Commit the installed skill and generated-file inventory. The CI runner needs `jq`, and, for the change classifier's `render` class, a `kendex` on its PATH and a source mirror it has already fetched. Pin the version that runner installs to one whose `kendex verify --json` prints a version 1 document: the `render` proof reads that document and nothing else kendex prints, so a build without it, or with another version of it, answers `standard` instead. Every release before that document, the v5.0.1 release included, answers `standard` on every diff. Follow [references/wiring.md](references/wiring.md) for workflow setup.

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
- It proves a re-rendered install by asking kendex to re-render, never by trusting the list of generated files or the install record, either of which the change itself could rewrite. `kendex verify --json` prints one record per thing it checked, with the files, trees and shared-file keys that thing occupies, and every changed file has to be covered by a record that passed. The two files kendex keeps about itself are records of that run like any other, each passing only where kendex found the file as it would write it, so a change that only re-runs kendex is a render and a change that edits those files by hand is not. It weighs a private checkout of the commit `--head` names, never the working tree it is pointed at, so nothing uncommitted there counts.
- A change of generated files alone whose re-render proof fails, or that touches a generated file no passing record covers, answers `standard` outright and is never measured, so only a change that touches a file kendex did not generate reaches the size rules at all.
- The files a harness itself executes as configuration are never trivial, micro or small, whoever wrote them: the settings, hook registries and MCP server lists under `.claude/`, `.codex/`, `.cursor/`, `.agents/`, `.pi/` and `.github/`, the repository root `.mcp.json` and opencode's root config file: one entry per harness kendex knows other than Gemini, whose settings file is named at the end of this bullet. Their keys decide which hooks run and which servers may be started. kendex writes entries in those files and never the whole file, so a re-render of one counts as a render only where kendex itself reports that nothing else in the file changed since the range's base; the Gemini settings file, whose record vouches for one key alone, is refused ahead of everything else as a changed configuration source.

## Settings

The harness and docs checkers have no project settings. The change classifier reads two, each with a shipped default: `HARNESS_CI_TRIVIAL_PATHS`, the repository's own low-blast allowlist as blank-separated globs (empty, the default, uses the documentation path set: `docs/`, `changelog.d/` and root Markdown files, so a root `README.md` edit under the ceiling counts as trivial while `AGENTS.md`, `CLAUDE.md` and every configuration source is refused ahead of it), and `HARNESS_CI_TRIVIAL_MAX_LINES`, the line ceiling under which those paths count as trivial (default 20). Two further inputs come from the workflow rather than from the repository being judged, because the classifier never reads that repository's own settings: `ORCH_SIZE_RENDER_ROOTS`, the harness directories a render mirrors a source into, and `ORCH_SIZE_TEST_PATHS`, the globs that mark a file as a test rather than as product code. The classify step of [references/wiring.md](references/wiring.md) § Shape 4 sets `ORCH_SIZE_RENDER_ROOTS` and carries `ORCH_SIZE_TEST_PATHS` as a commented line beside it, to be uncommented where the consumer's test files live outside orch's default globs. The CI call supplies the mode, event, and commit identifiers. A check that must apply its own policy rules to the exact changed-path set reads it from `harness-only --paths-output`, where that set is derived. Use `harness-only --help`, `change-class --help` and `aggregate-needs --help` for all arguments.


Workflow setup: [references/wiring.md](references/wiring.md). Maintainer rules and tests: [DEVELOPMENT.md](DEVELOPMENT.md).
