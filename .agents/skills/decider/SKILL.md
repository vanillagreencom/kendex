---
name: decider
description: "Load to create, search, or supersede an architecture decision record."
summary: "Architecture decision records: what warrants one, the short format, creation, search, supersession tracking, and INDEX maintenance."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: kendex
  repository: "https://github.com/vanillagreencom/kendex"
  bugs: "https://github.com/vanillagreencom/kendex/issues"
  version: "2.0.2"
tags: [planning]
---

<!-- kendex:project-instructions:start -->
## Project Instructions

<!-- kendex:shared-instructions:start -->
Problems with a kendex-owned skill go through `kendex report`; check ownership in the file first.
<!-- kendex:shared-instructions:end -->
<!-- kendex:project-instructions:end -->

# Decider

Numbered decision documents indexed in one `INDEX.md` (default `docs/decisions/`), with a search CLI, canonical format, and creation/supersession workflows.

```bash
.agents/skills/decider/scripts/decisions <command> [options]
```

Actions (`search`, `search --issue`, `list`, `next-id`, `get`, `check`), search coverage and scoring, output shapes, and the `DECISIONS_DIR` / `DECISIONS_BASE_REF` / `DECISION_ID_*` environment: `decisions --help`. There is no bare `issue` action; use `search --issue`.

Read the full decision file and its status before acting on a hit. An active decision binds design policy; a suggestion contradicting it is invalid unless the decision itself is flawed. One marked superseded binds only what its status leaves active; a retired one binds nothing.

## What warrants a decision record, and why

A record exists to stop a reversal: a reviewer or a future agent, reading the code alone, would undo the choice because the code cannot show its reason. Judge the reach and the reason, not the number of sites.

Warranted:

- A choice that governs work beyond one site: one merge path for every repository; every removal goes to the trash and nothing deletes.
- A choice a reviewer or a future agent would otherwise reverse: a hand-written WebSocket client kept over a dependency, in a catalog that ships standard-library scripts.
- A choice whose reason the code cannot show: a bound set below a measured incident, with the measurement as its reason.

Not warranted:

- A local implementation choice: a lock taken before a cleanup is registered is a comment at the code.
- A restated convention: shell stays Bash 3.2 compatible is an `AGENTS.md` line.
- A choice no one would revisit: a file format version field, a naming scheme.
- A record of what was done: git history holds it.

A record is short: the choice, why, the main rejected alternative, the revisit trigger, with its ID, status, issue or evidence link and partial-supersession scope. Shortening a record keeps its ID and status; moving a reason into code is not a reversal. A record is never deleted: one withdrawn with no replacement is retired per `workflows/update-decision.md`, which keeps its row and a one-line document so the ID stays reserved and a citation still resolves. Supersede only changed policy.

## Workflows

| Workflow | Trigger |
|----------|---------|
| `workflows/create-decision.md` | A choice under the bar above is settled |
| `workflows/update-decision.md` | A new decision supersedes, partially supersedes, or revisits an existing one |

Format: `schemas/decision-format.md` (constraints), `templates/decision-entry.md` (document skeleton), `templates/index-row.md` (INDEX row). The finished example is the docs-writing skill's `examples/decision.md`.

## Approval

Never create a decision document without explicit user approval. When work settles a choice under the bar, say on completion: "this introduced a decision worth recording: [summary]. Want me to create a decision entry?"
