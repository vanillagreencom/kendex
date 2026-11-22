# code-quality

Code-writing rules for AI coding agents. Repository owners use this skill to supply common rules for correctness, tests and cleanup.

## Features

- Agents report a failure instead of hiding it, and remove unused code.
- Each resource and each decision has one owner, and agents build on another system through its documented interface.
- Test-only access stays out of the code you ship.
- Agents keep a test only for a failure that matters, weighed against its run time and upkeep, and show once that a new check can fail.
- Tests check results, not wording, and run by what a change affects.
- Rust, Bash and TypeScript rules load only for the language being changed, and the UI rules only for a changed view or its text.
- Each review finding on practice or design says whether this guidance misled the agent, missed the case or was not followed, and who owns the fix.

## Install

```bash
kendex add vanillagreencom/kendex --skill code-quality
```

## How it works

The agent loads [SKILL.md](SKILL.md) before it changes code. It reads the shared rules together with your project instructions. It applies those rules while implementing the change and validating the result. The test rules are [SKILL.md § Prove Your Guards](SKILL.md#prove-your-guards) and [§ Tests](SKILL.md#tests).

## Setup

kendex also installs docs-writing, which supplies the markdown rules.

- Repository-specific standards: `[skill-instructions]` in `kendex.toml`, rendered into the installed copy's Project Instructions section and read alongside the generic rules.

## Licence

MIT, in the repository's LICENSE file.
