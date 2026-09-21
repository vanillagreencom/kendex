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
- It proves a re-rendered install by asking kendex to re-render, never by trusting the list of generated files or the install record, either of which the change itself could rewrite. Every changed file has to be one that run itself names, which today is the instruction file kendex writes for Claude and nothing else. The two files kendex keeps about itself are named by no such line and are not accepted either, so a change that only re-runs kendex is measured like any other change. The checkout it reads has to hold nothing uncommitted.
- kendex does not yet report which installed file each thing it checked produced, so a change that re-renders a skill, an agent, a hook or a command cannot be matched to a checked item. The classifier says so rather than guessing: a change of generated files alone whose re-render proof fails, or that touches a generated file the run does not name, answers `standard` outright and is never measured, so only a change that touches a file kendex did not generate reaches the size rules at all.
- The files a harness itself executes as configuration are refused ahead of everything else, whoever wrote them: the settings, hook registries and MCP server lists under `.claude/`, `.codex/`, `.cursor/`, `.agents/`, `.gemini/`, `.pi/` and `.github/`, the repository root `.mcp.json` and opencode's root config file, which is one entry per harness kendex knows. Their keys decide which hooks run and which servers may be started, so a change to one is never trivial, micro or small, and a re-render of one is reported as a changed configuration source rather than as an unmatched generated file.

## Settings

The harness and docs checkers have no project settings. The change classifier reads two, each with a shipped default: `HARNESS_CI_TRIVIAL_PATHS`, the repository's own low-blast allowlist as blank-separated globs (empty, the default, uses the documentation path set: `docs/`, `changelog.d/` and root Markdown files, so a root `README.md` edit under the ceiling counts as trivial while `AGENTS.md`, `CLAUDE.md` and every configuration source is refused ahead of it), and `HARNESS_CI_TRIVIAL_MAX_LINES`, the line ceiling under which those paths count as trivial (default 20). Two further inputs come from the workflow rather than from the repository being judged, because the classifier never reads that repository's own settings: `ORCH_SIZE_RENDER_ROOTS`, the harness directories a render mirrors a source into, and `ORCH_SIZE_TEST_PATHS`, the globs that mark a file as a test rather than as product code. Both are set in the classify step of [references/wiring.md](references/wiring.md) § Shape 4. The CI call supplies the mode, event, and commit identifiers. A check that must apply its own policy rules to the exact changed-path set reads it from `harness-only --paths-output`, where that set is derived. Use `harness-only --help`, `change-class --help` and `aggregate-needs --help` for all arguments.


Workflow setup: [references/wiring.md](references/wiring.md). Maintainer rules and tests: [DEVELOPMENT.md](DEVELOPMENT.md).
