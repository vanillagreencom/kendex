---
name: decider
description: "Architecture Decision Record (ADR) and architectural decision document management: templates, creation, search, supersession tracking, and INDEX maintenance."
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

# Decider

> **Problem with this skill?** Run `kendex report` — it files to the owning repo automatically. Do not hand-file.

Numbered decision documents indexed in one `INDEX.md` (default `docs/decisions/`), with a search CLI, canonical format, and creation/supersession workflows.

```bash
.agents/skills/decider/scripts/decisions <command> [options]
```

| Command | Purpose | Output |
|---------|---------|--------|
| `search --issue [ID]` | Decisions linked to an issue — exact match on the INDEX Research column | JSON `[{id, decision, path}]` |
| `search "[KEYWORDS]"` | Ranked keyword search (AND, scored) | JSON `[{id, decision, path, score}]` |
| `search "a\|b"` | Regex mode — a query containing `\|`, `()`, or `\` | JSON `[{id, decision, path}]` |
| `list` | Decisions whose status starts with `Active` | JSON `[{id, decision, path}]` |
| `next-id` | Next ID, scheme inferred from the INDEX ID column | One ID line |
| `get [DECISION_ID]` | Decision details | JSON `{id, decision, status, date, path}` |

`--limit N` (default 5) caps search results. There is no bare `issue` action; use `search --issue`.

Keyword and regex search cover the `INDEX.md` summary columns (decision, reason, id) **and** the body of each linked decision document. Summary matches outrank body-only matches. `search --issue` does not scan bodies.

Read the full decision file before acting on a hit. A suggestion contradicting an active decision is invalid unless the decision itself is flawed.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `DECISIONS_DIR` | Decision documents directory | Nearest ancestor holding `docs/decisions/`, `decisions/`, `doc/decisions/`, or `adr/` with an `INDEX.md` |
| `DECISION_ID_PREFIX` | ID prefix for `next-id` | Inferred from the last populated ID-column value, else `D` |
| `DECISION_ID_WIDTH` | Zero-padding width for `next-id` | Inferred from that same value, else `3` |

Set shared values in `kendex.settings.toml` under `[env]`; `.env.local` overrides locally.

With no decisions directory, `search` and `list` emit `[]` with a stderr note and exit 0. `next-id` and `get` require an initialized directory. A configured path that exists but is not a directory is a hard error.

## Workflows

| Workflow | Trigger |
|----------|---------|
| `workflows/create-decision.md` | A significant path choice is settled |
| `workflows/update-decision.md` | A new decision supersedes, partially supersedes, or revisits an existing one |

Format: `schemas/decision-format.md` (constraints), `templates/decision-entry.md` (document skeleton), `templates/index-row.md` (INDEX row).

## Approval

Never create a decision document without explicit user approval. When work settles a choice worth recording, say on completion: "this introduced a decision worth recording: [summary]. Want me to create a decision entry?"

Record: technology selections with alternatives, performance trade-offs, path choices whose conditions may change. Do not record: variable names, small refactors, bug fixes, choices with no realistic alternative, standard pattern applications.
