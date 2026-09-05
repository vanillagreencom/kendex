# code-quality

Code-writing rules for AI coding agents. Repository owners use this skill to supply common rules for correctness, tests and cleanup.

## Install

```bash
kendex add vanillagreencom/kendex --skill code-quality
```

kendex also installs docs-writing, which supplies the markdown rules.

## Features

- Define how agents handle errors and remove unused code.
- Require checks to fail on the defects they claim to catch.
- Supply language rules for Rust, Bash and TypeScript.
- Direct markdown work to the docs-writing skill.

## How it works

The agent loads [SKILL.md](SKILL.md) before it changes code. It reads the shared rules together with your project instructions. It applies those rules while implementing the change and validating the result.

## Settings

- Repository-specific standards: `[skill-instructions]` in `kendex.toml`, rendered into the installed copy's Project Instructions section and read alongside the generic rules.
