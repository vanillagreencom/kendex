# Architecture Docs

The convention for the markdown an AI coding harness loads: the root `AGENTS.md`, `docs/architecture/overview.md` and its topic files, and nested `AGENTS.md` files in directories with rules of their own. It says what each file holds, what none of them hold, how they are formatted, and how a repository rewrites its existing docs onto it.

## What it ships

- `SKILL.md`: the convention, loaded by an agent that writes or reviews these files.
- `templates/`: skeletons for the overview, a topic file, the root map, and a nested file.
- `workflows/rewrite.md`: the blank-page rewrite of an existing repository.

## What enforces it

The rules the convention states mechanically are enforced by sibling packages, not by this one: `growth-guards` (`md-format`, `md-refs`, `prose` lanes), `size-ratchet` (byte classes per file kind), the `doc-drift-check` hook (docs move with the code they cover), and kendex itself (the per-harness shims that make nested `AGENTS.md` files reachable). Install those beside this skill.

## Install

```bash
kendex add --skill arch-docs
```
