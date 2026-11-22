# code-quality

Code-writing rules for AI coding agents. Repository owners use this skill to supply common rules for correctness, tests and cleanup.

## Features

- Agents report a failure instead of hiding it.
- Agents remove unused code.
- Each resource and each decision has one owner.
- Agents build on another system through its documented interface.
- Test-only access adds nothing to the API or commands you ship.
- Agents keep a test only for a failure that matters, weighed against its run time and upkeep.
- Agents show once that a new or changed check can fail.
- Tests check results, not wording.
- Where a repository runs tests by what a change affects, the existing entry point selects them.
- Agents load the Rust, Bash and TypeScript rules only for the language being changed.
- Agents load the UI rules only for a changed view or its text.
- Each review finding on practice or design says whether this guidance misled the agent, missed the case or was not followed, and which guidance or route owns the cause.

## Install

```bash
kendex add vanillagreencom/kendex --skill code-quality
```

## How it works

1. The agent loads [SKILL.md](SKILL.md) before it changes code.
2. It reads the shared rules together with your project instructions.
3. It applies those rules while implementing the change and validating the result.

The test rules are [SKILL.md § Prove Your Guards](SKILL.md#prove-your-guards) and [§ Tests](SKILL.md#tests).

## Setup

kendex also installs docs-writing, which supplies the markdown rules.

- Repository-specific standards: `[skill-instructions]` in `kendex.toml`, rendered into the installed copy's Project Instructions section and read alongside the generic rules.

## Licence

MIT, in the repository's LICENSE file.
