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
tags: [planning]
---

# Decider

Numbered decision documents indexed in one `INDEX.md` (default `docs/decisions/`), with a search CLI, canonical format, and creation/supersession workflows.

```bash
.agents/skills/decider/scripts/decisions <command> [options]
```

Actions (`search`, `search --issue`, `list`, `next-id`, `get`, `check`), search coverage and scoring, output shapes, and the `DECISIONS_DIR` / `DECISIONS_BASE_REF` / `DECISION_ID_*` environment: `decisions --help`.

Read a search hit's INDEX row first. Then, by the record's status:

- Active or superseded: read its document before treating it as binding.
- Withdrawn: when considering the option, read its retained document and withdrawal reason.
- Removed: its reason lives where its Rationale cell names it, the comment at the code or the principle doc's section.

What a record binds:

- An active decision binds design policy. A suggestion contradicting it is invalid unless the decision itself is flawed.
- A superseded decision binds only what its status leaves active.
- A withdrawn decision binds nothing.
- A removed decision binds through the code or principle doc its INDEX row names.

## What warrants a decision record, and why

A record exists to stop a reversal: a reviewer or a future agent, reading the code alone, would undo the choice because the code cannot show its reason. Judge the reach and the reason, not the number of sites.

Warranted:

- A choice that governs work beyond one site: one merge path for every repository; every removal goes to the trash and nothing deletes.
- A choice a reviewer or a future agent would otherwise reverse: a hand-written WebSocket client kept over a dependency, in a catalog that ships standard-library scripts.
- A choice whose reason the code cannot show: a bound set below a measured incident, with the measurement as its reason.

Not warranted:

- A local implementation choice: a lock taken before a cleanup is registered is a comment at the code.
- A restated convention: shell stays Bash 3.2 compatible is a `[skill-instructions].code-quality` line in the consumer's `kendex.toml`, or in `kendex-local.toml` in a source-catalog checkout.
- A choice no one would revisit: a file format version field, a naming scheme.
- A record of what was done: git history holds it.

An existing record:

- Shortening a record keeps its ID and status. Moving a reason into code is not a reversal.
- A record whose choice is routine is removed once its reason lives in the code or principle doc it governs. Removal is not withdrawal and changes no policy.
- A withdrawal with no replacement is a retirement.

## Workflows

| Workflow | Trigger |
|----------|---------|
| `workflows/create-decision.md` | A choice under the bar above is settled |
| `workflows/update-decision.md` | A new decision supersedes, partially supersedes, or revisits an existing one, or an existing one is retired or removed |

Format: `schemas/decision-format.md` (constraints), `templates/decision-entry.md` (document skeleton), `templates/index-row.md` (INDEX row).

## Approval

Never create a decision document without explicit user approval. When work settles a choice under the bar, say on completion: "this introduced a decision worth recording: [summary]. Want me to create a decision entry?"
