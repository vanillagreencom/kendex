---
name: decider
description: "Architecture Decision Record (ADR) and architectural decision document management: templates, creation, search, supersession tracking, and INDEX maintenance."
license: MIT
user-invocable: true
metadata:
  author: vanillagreen
  source: vstack
  repository: "https://github.com/vanillagreencom/vstack"
  bugs: "https://github.com/vanillagreencom/vstack/issues"
  version: "1.1.0"
---

# Decider

> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.

Architectural decision records: numbered decision documents indexed in one `INDEX.md` (by default under `docs/decisions/`), with a search CLI, a canonical format, and creation/supersession workflows.

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

`--limit N` (default 5) caps search results. Issue lookup is exactly `search --issue` — there is no bare `issue` action.

Keyword and regex search cover the `INDEX.md` summary columns (decision, rationale, id) **and** the prose of each linked decision document, so a keyword that never reached a one-line summary still finds the decision governing it. Summary matches outrank body-only matches. `search --issue` is an explicit linkage lookup and does not scan bodies.

Read the full decision file before acting on a hit — index summaries omit scope and rejected alternatives. A suggestion contradicting an active decision is invalid unless the decision itself is flawed.

## Configuration

| Variable | Purpose | Default |
|----------|---------|---------|
| `DECISIONS_DIR` | Decision documents directory | Nearest ancestor holding `docs/decisions/`, `decisions/`, `doc/decisions/`, or `adr/` with an `INDEX.md` |
| `DECISION_ID_PREFIX` | ID prefix for `next-id` | Inferred from the last populated ID-column value, else `D` |
| `DECISION_ID_WIDTH` | Zero-padding width for `next-id` | Inferred from that same value, else `3` |

Set these in committed `vstack.settings.toml` under `[env]` when they are shared project policy; `.env.local` overrides locally.

Where no decisions directory exists, `search` and `list` emit `[]` with a stderr note and exit 0 — nothing recorded is not an error. `next-id` and `get` require an initialized directory. A configured path that exists but is not a directory is always a hard error.

## Workflows

| Workflow | Trigger |
|----------|---------|
| `workflows/create-decision.md` | A significant path choice is settled |
| `workflows/update-decision.md` | A new decision supersedes, partially supersedes, or revisits an existing one |

Format: `schemas/decision-format.md` (constraints), `templates/decision-entry.md` (document skeleton), `templates/index-row.md` (INDEX row).

## Approval

Never create a decision document without explicit user approval. When work settles an architectural choice, technology selection, or trade-off worth recording, say so on completion — "this introduced a decision worth recording: [summary]. Want me to create a decision entry?" — and let the user confirm.

Record technology selections with alternatives considered, performance trade-offs, and path choices whose conditions may change. Do not record variable names, small refactors, bug fixes, obvious choices with no realistic alternative, or standard pattern applications.
