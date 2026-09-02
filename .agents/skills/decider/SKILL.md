---
name: decider
description: "Load to create, search, or supersede an architecture decision record."
summary: "Architecture decision records: templates, creation, search, supersession tracking, and INDEX maintenance."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "1.1.0"
tags: [planning]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:project-instructions:end -->

# Decider

Numbered decision documents indexed in one `INDEX.md` (default `docs/decisions/`), with a search CLI, canonical format, and creation/supersession workflows.

```bash
.agents/skills/decider/scripts/decisions <command> [options]
```

Actions (`search`, `search --issue`, `list`, `next-id`, `get`), search coverage and scoring, output shapes, and the `DECISIONS_DIR` / `DECISION_ID_*` environment: `decisions --help`. There is no bare `issue` action; use `search --issue`.

Read the full decision file before acting on a hit. A suggestion contradicting an active decision is invalid unless the decision itself is flawed.

## Workflows

| Workflow | Trigger |
|----------|---------|
| `workflows/create-decision.md` | A significant path choice is settled |
| `workflows/update-decision.md` | A new decision supersedes, partially supersedes, or revisits an existing one |

Format: `schemas/decision-format.md` (constraints), `templates/decision-entry.md` (document skeleton), `templates/index-row.md` (INDEX row).

## Approval

Never create a decision document without explicit user approval. When work settles a choice worth recording, say on completion: "this introduced a decision worth recording: [summary]. Want me to create a decision entry?"

Record: technology selections with alternatives, performance trade-offs, path choices whose conditions may change. Do not record: variable names, small refactors, bug fixes, choices with no realistic alternative, standard pattern applications.
