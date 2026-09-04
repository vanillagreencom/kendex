# Architecture Docs

The convention for the markdown an AI coding harness loads: the root `AGENTS.md`, `docs/architecture/overview.md` and its topic files, nested `AGENTS.md` files, and a package's `README.md`, `DEVELOPMENT.md` and `SKILL.md`. For a repository that wants its instruction files to stay small, true, and free of what the code already says.

## Install

```bash
kendex add vanillagreencom/kendex --skill arch-docs
```

## What it does

- States what each instruction and architecture file holds, and what none of them hold.
- Splits a package's docs three ways: `README.md` for people, `DEVELOPMENT.md` for maintainers, `SKILL.md` for agents.
- Ships templates for the overview, a topic file, the root map, a nested file, and a README.
- Ships a blank-page rewrite workflow for a repository whose docs predate the convention.

## How it works

An agent loads `SKILL.md` when it writes or reviews one of these files and follows the convention there. The rules the convention states mechanically are enforced by sibling packages, not by this one: `growth-guards` (the `md-format`, `md-refs` and `prose` lanes), `size-ratchet` (a byte class per file kind), the `doc-drift-check` hook (docs move with the code they cover), and kendex itself (the per-harness shims that make nested `AGENTS.md` files reachable). Install those beside this skill.

## Customise

- Size classes: a repository overrides one through size-ratchet's settings, never by stating a number in prose.
- Repository-specific instructions: `[skill-instructions]` in `kendex.toml`, rendered into the installed copy.
