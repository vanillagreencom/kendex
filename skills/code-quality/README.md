# code-quality

Code-writing rules for AI coding agents. Repository owners use this skill to supply common rules for correctness, tests and cleanup.

## Features

- Define how agents handle errors and remove unused code.
- Set structure rules for resource ownership and exports, abstraction rules for shared decisions, and a rule to build on another system through its own interface.
- Keep fixture interfaces out of shipped APIs while permitting private test access.
- Require checks to fail on the defects they claim to catch, one control for each independent rule a guard enforces.
- Set test rules for defect controls, typed results, progress evidence and checks selected from what a change affects.
- Load Rust, Bash and TypeScript rules only for the stack being changed, and the UI polish bar and screenshot set only for a changed view.
- Direct markdown work to the docs-writing skill.

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
