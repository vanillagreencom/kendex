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
  version: "1.0.0"
---

# Decider

Manages Architecture Decision Records (ADRs) — represented in this skill as numbered `DXXX` architectural decision documents indexed in `INDEX.md` (by default under `docs/decisions/`) — with canonical templates, creation/update workflows, and a search CLI. Provides the single source of truth for decision entry format and lifecycle.

```bash
.agents/skills/decider/scripts/decisions <command> [options]
```

## Commands

| Command | Purpose | Output |
|---------|---------|--------|
| `search --issue [ID]` | Find decisions linked to an issue | JSON `[{id, decision, path}]` |
| `search "[KEYWORDS]"` | Ranked keyword search (AND, scored) | JSON `[{id, decision, path, score}]` |
| `search "a\|b"` | Regex OR search | JSON `[{id, decision, path}]` |
| `list` | List all active decisions | JSON `[{id, decision, path}]` |
| `next-id` | Get next available DXXX | Single `DXXX` line |
| `get [DXXX]` | Get decision details | JSON `{id, decision, status, date, path}` |

Options: `--limit N` (default: 5) for search results.

## Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `workflows/create-decision.md` | Research complete, significant path choice | Assign ID, write file, add INDEX row, update superseded |
| `workflows/update-decision.md` | New decision affects existing | Supersede, partial supersede, or revisit existing entries |
| `workflows/search-decisions.md` | Before implementing, reviewing, auditing | Search by issue, keywords, or ID |

## Templates

| Template | Purpose |
|----------|---------|
| `templates/decision-entry.md` | Decision file format (minimal, standard, comprehensive) |
| `templates/index-row.md` | INDEX.md table row format |

## Schemas

| Schema | Purpose |
|--------|---------|
| `schemas/decision-format.md` | Canonical format constraints for decision documents and INDEX |

Project-level configuration:

| Variable | Purpose | Default |
|----------|---------|---------|
| `$DECISIONS_DIR` | Path to decision documents directory | Auto-discovers `docs/decisions/`, `decisions/`, `doc/decisions/`, or `adr/` with `INDEX.md` |

Set `DECISIONS_DIR` in committed `vstack.settings.toml` under `[env]` when it is shared project policy. `.env.local` remains supported for local overrides.

## Decision Lifecycle

```
Research Complete → Create Decision (§ 6.1)
                        ↓
                 INDEX.md + DXXX-descriptor.md
                        ↓
            ┌───────────┴───────────┐
            ↓                       ↓
    Search/Reference         Update/Supersede
    (review, audit,          (new research,
     implementation)          revisit conditions met)
```

## Quick Reference

### Creating Decisions

1. Get next ID: `decisions next-id`
2. Select template size (minimal/standard/comprehensive) from `templates/decision-entry.md`
3. Write decision file to `[project decision documents]/[DECISION_ID]-[DESCRIPTOR].md`
4. Add row to `[project decision documents]/INDEX.md`
5. Update any partially superseded decisions

### Searching Decisions

1. By issue: `decisions search --issue [ISSUE_ID]`
2. By keywords: `decisions search "[RELEVANT_KEYWORDS]"`
3. Read full decision files — index summaries are insufficient for understanding scope and rejected alternatives
4. Suggestions contradicting active decisions are invalid unless decision is flawed

### Decision Entry Format

All entries require: title (`# DXXX: Title`), date, status, research ref (or `—`), decision statement, rationale, revisit conditions. See `schemas/decision-format.md` for full constraints.

## Decision Approval

Do not create decision documents without explicit user approval. If your work involves a significant architectural choice, technology selection, or trade-off that warrants a decision record, surface this in your response upon task completion — e.g., "This introduced a decision worth recording: [brief summary]. Want me to create a decision entry?" Let the user confirm before running the create workflow.

## Content Guidelines

### What to Log

- Technology selections with alternatives considered
- Performance trade-offs (chose X over Y for reason Z)
- Significant path choices where conditions might change
- Research-informed decisions

### What NOT to Log

- Variable names, small refactors, bug fixes
- Obvious choices with no realistic alternatives
- Standard pattern applications

## System Dependencies

- `bash` 4+
- `jq`
- GNU `grep` with `-P` (PCRE) support (`grep`, `ggrep`, or Homebrew `gnubin/grep`)
- `sed`, `find`
