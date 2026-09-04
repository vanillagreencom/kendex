# code-quality

Code-authoring standards for dev agents, kept in one upstream copy. For a repository that wants every agent writing code in it to hold the same bar.

## Install

```bash
kendex add vanillagreencom/kendex --skill code-quality
```

## What it does

- Correctness rules: handle every error, never fail open, name the actual cause.
- Prove-your-guards: a new check ships with the defect it catches planted and seen red.
- Language discipline for Rust, Bash and TypeScript.
- Comment and markdown placement rules, over-engineering limits, and cleanup rules.

## How it works

An agent loads [SKILL.md](SKILL.md) before writing or modifying code and follows it. The rules are generic; nothing in the skill names a repository.

## Customise

- Repository-specific standards: `[skill-instructions]` in `kendex.toml`, rendered into the installed copy's Project Instructions section and read alongside the generic rules.
