# Docs Writing

The convention for every markdown file a repository owns: the root and nested `AGENTS.md`, `docs/architecture/overview.md` and its topic files, `README.md`, `DEVELOPMENT.md`, `SKILL.md`, agent and workflow files, and reference docs. For a repository that wants its documentation to stay small, true, and free of what the code already says.

## Install

```bash
kendex add vanillagreencom/kendex --skill docs-writing
```

## What it does

- States one writing standard for every markdown file, with pairs showing what to write instead.
- States per file type who reads it, what it holds, and what it excludes.
- Splits a package's docs three ways: `README.md` for people, `DEVELOPMENT.md` for maintainers, `SKILL.md` for agents.
- Ships a template per file type.
- Ships a blank-page rewrite workflow for a repository whose docs predate the convention.
- Points at the `decider` skill for decision records rather than shipping a second format.

## How it works

An agent loads `SKILL.md` when it writes or reviews a markdown file and follows the convention there. Sibling packages enforce the mechanical half: `growth-guards` (the `md-format`, `md-refs` and `prose` lanes), `size-ratchet` (a byte class per file kind), the `doc-drift-check` hook (docs move with the code they cover), and kendex itself (the per-harness shims that make nested `AGENTS.md` files reachable). Install those beside this skill.

## Customise

- Size classes: a repository overrides one through size-ratchet's settings, never by stating a number in prose.
- Repository-specific instructions: `[skill-instructions]` in `kendex.toml`, rendered into the installed copy.
