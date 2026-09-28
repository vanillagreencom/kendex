# code-quality

Code-writing rules for AI coding agents. Repository owners use this skill to supply common rules for correctness, tests and cleanup.

## Install

```bash
kendex add vanillagreencom/kendex --skill code-quality
```

kendex also installs docs-writing, which supplies the markdown rules.

## Features

- Define how agents handle errors and remove unused code.
- Set structure rules for resource ownership and exports, abstraction rules for shared decisions, and a rule to build on another system through its own interface.
- Keep test-only setup and readback out of shipped code.
- Require checks to fail on the defects they claim to catch, one control for each independent rule a guard enforces.
- Set test rules: at least one control per tested surface, one assertion library per tree, no tests that pin prose, and checks selected from what a change affects.
- Supply language rules for Rust, Bash and TypeScript.
- Direct markdown work to the docs-writing skill.

## How it works

The agent loads [SKILL.md](SKILL.md) before it changes code. It reads the shared rules together with your project instructions. It applies those rules while implementing the change and validating the result. The test rules are [SKILL.md § Prove Your Guards](SKILL.md#prove-your-guards) and [§ Tests](SKILL.md#tests).

## Settings

- Repository-specific standards: `[skill-instructions]` in `kendex.toml`, rendered into the installed copy's Project Instructions section and read alongside the generic rules.
