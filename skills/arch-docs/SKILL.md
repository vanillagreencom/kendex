---
name: arch-docs
description: "Load to write, rewrite, or review a repository's AGENTS.md files or its docs/architecture/ against the shipped convention."
summary: "The convention for root and nested AGENTS.md and docs/architecture/: what each holds, what is excluded, the format, templates, and the rewrite workflow."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.0.0"
tags: [docs]
---

# Architecture Docs

Instruction files and architecture docs hold what the code cannot show: invariants, layer boundaries, decisions with their reason, conventions that differ from tool defaults, and pointers to canonical code and to the test that proves a claim. Everything else lives in the code, the tests, and git history.

## What goes where

| File | Holds | Loaded |
|---|---|---|
| Root `AGENTS.md` | A map: what the repo is in two or three sentences, commands that are not discoverable, conventions that differ from tool defaults, one line per deeper doc saying when to read it. | Every session, every harness. |
| `docs/architecture/overview.md` | The one idea, vocabulary, layer boundaries, invariants as one line each with a pointer to the test or check that enforces it, an index of topic files. | On demand. |
| `docs/architecture/<topic>.md` | The same kinds of content for one subsystem, opening with a `Covers:` line naming the paths it describes. A plain repo-relative path covers that file or directory. A shell glob matches the full path, with `*` crossing `/`. | On demand; the `doc-drift-check` hook names it when covered code changes without it. |
| Nested `AGENTS.md` | Conventions and invariants local to that directory, small. | When an agent works in the directory. |
| `docs/decisions/` | The why ledger, through the `decider` skill. Architecture docs cite a decision by ID and never restate it. | When opened. |

Excluded everywhere: directory layouts and file-by-file descriptions, behaviour walkthroughs, command listings a `--help` already gives, CI topology, step-by-step flows, history (dates, issue numbers, past states), and any list a declaration file or a checker already holds. A claim that a checker enforces something names the checker. A rule a shipped kendex package states is never restated in the repo's own markdown; the repo installs the package and customises through `kendex.toml`.

Codex reads only the root-to-cwd chain of `AGENTS.md` files, at launch, under a 32 KiB combined cap, so everything a Codex session must know stays in the root file; nested files hold what is local to a directory. Claude Code and Gemini reach nested files through shims kendex writes and verifies (`kendex apply`, `kendex refresh`, `kendex verify`): a sibling `CLAUDE.md` holding `@AGENTS.md`, and `context.fileName` in `.gemini/settings.json`. Pi reaches them through the `pi-nested-agents-md` extension, declared in the manifest and installed by `kendex update-pi`. Shims are committed and never hand-written.

## Package files

| File | For | Holds |
|---|---|---|
| `README.md` | People, consumers of the package or repo. | What it is in a few sentences, install where needed, a short plain feature list, a few lines of how it works, and the need-to-know for customising it (settings), critical items only. |
| `DEVELOPMENT.md` | Maintainers, human or agent. | Everything deeper: mechanics, edge cases, invariants a maintainer must not break, test strategy, internals. |
| `SKILL.md`, agent files | Agents, on every load. | The shortest unambiguous rule and the commands; no mechanics, rationale, or history. |

A fact lives in one of the three; the others point at it. A README that explains mechanics moves them to `DEVELOPMENT.md`; a `SKILL.md` that explains why moves the why to `DEVELOPMENT.md` or a decision record. READMEs are held to the same format and size lanes as every other markdown file (a README byte class in size-ratchet). Start from [templates/README.md](templates/README.md).

## Rules

- Docs change in the same commit as the code they describe. The `doc-drift-check` hook blocks a stop that changed covered code without touching its docs; confirm or update the docs, then finish.
- One paragraph per line, one list item per line, no hard wraps inside either; blank lines separate paragraphs, list blocks, headings, and fences; tables and fenced code stay as written. The growth-guards `md-format` lane enforces it and `md-reflow` converts a file once.
- Every relative link, `<path>.md § Heading` or `<path>.md#anchor` citation, and decision ID resolves; the `md-refs` lane checks them.
- No history prose in agent-loaded markdown; the `prose` lane checks it.
- Size is a size-ratchet byte class per file kind (root `AGENTS.md`, nested `AGENTS.md`, `overview.md`, topic files); a file over its class is frozen in the baseline and only shrinks. A repo overrides a class through its settings, never by inventing a number in prose.
- A topic file exists only where a subsystem has invariants or boundaries of its own; a subsystem with none is a line in the overview.

## Writing

Rewrite from a blank page, never by editing the old text: [workflows/rewrite.md](workflows/rewrite.md). Start from [templates/overview.md](templates/overview.md), [templates/topic.md](templates/topic.md), [templates/root-AGENTS.md](templates/root-AGENTS.md), and [templates/nested-AGENTS.md](templates/nested-AGENTS.md).
