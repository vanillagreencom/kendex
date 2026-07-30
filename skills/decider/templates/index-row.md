# INDEX.md Row Template

Template for adding rows to the project decision documents `INDEX.md` table.

## Row Format

```markdown
| [DATE] | [DECISION_ID] | [RESEARCH_REF] | [DECISION_SUMMARY] | [RATIONALE_SUMMARY] | [REVISIT_WHEN] | [STATUS] | [LINK] |
```

## Field Definitions

| Field | Format | Example |
|-------|--------|---------|
| `DATE` | `YYYY-MM-DD` | `2026-03-24` |
| `DECISION_ID` | Project's sequential ID with numeric suffix | `D034` or `ADR-0034` |
| `RESEARCH_REF` | `[ID](path)` or `—` | `[PROJ-189](../research/PROJ-189/findings.md)` |
| `DECISION_SUMMARY` | 5-15 word summary of choice | `Use Redis for session caching` |
| `RATIONALE_SUMMARY` | Key reason in 5-15 words | `Redis proven, cluster-ready` |
| `REVISIT_WHEN` | Trigger condition, 5-15 words | `Session count exceeds Redis capacity` |
| `STATUS` | Status value | `Active` |
| `LINK` | `[Full](DECISION_ID-descriptor.md)` | `Full -> D034-feature-name.md` |

## Status Values

- `Active` — Current decision in effect
- `Superseded by [DECISION_ID]` — Replaced by newer decision
- `Revisited` — Re-evaluated, with outcome noted
- `Active ([COMPONENTS] -> [DECISION_ID])` — Partially superseded (specific components replaced)

## Example Rows

**Minimal research decision:**
```markdown
| 2026-03-24 | D034 | [PROJ-200](../research/PROJ-200/findings.md) | Use tokio for async runtime | Battle-tested, ecosystem support | Alternative runtime outperforms tokio 2x | Active | Full -> `D034-async-runtime.md` |
```

**No-research decision:**
```markdown
| 2026-03-24 | D035 | — | Fixed 10-level depth limit | Eliminates allocation, predictable layout | Need variable depth | Active | Full -> `D035-fixed-depth-limit.md` |
```

**Partially superseded:**
```markdown
| 2026-02-17 | D011 | [PROJ-410](../research/PROJ-410/findings.md) | Zero-Allocation Object Pools | HashMap→Vec for buffers | Pool count >1024 | Active (ThreadBound -> D017) | Full -> `D011-zero-alloc-pools.md` |
```

## Placement

New rows are appended at the end of the table, before the `---` separator and `## Format Reference` section. Rows are ordered chronologically by date.
