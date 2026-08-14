# INDEX.md Row

```markdown
| [DATE] | [DECISION_ID] | [RESEARCH_REF] | [DECISION_SUMMARY] | [RATIONALE_SUMMARY] | [REVISIT_WHEN] | [STATUS] | [LINK] |
```

| Field | Format | Example |
|-------|--------|---------|
| `DATE` | `YYYY-MM-DD` | `2026-03-24` |
| `DECISION_ID` | The project's scheme, numeric suffix | `D034`, `ADR-0034` |
| `RESEARCH_REF` | `[ID](path)` or `—` | `[PROJ-189](../research/PROJ-189/findings.md)` |
| `DECISION_SUMMARY` | 5-15 words: the choice | `Use tokio for async runtime` |
| `RATIONALE_SUMMARY` | 5-15 words: the key reason | `Battle-tested, ecosystem support` |
| `REVISIT_WHEN` | 5-15 words: the trigger | `Alternative runtime outperforms tokio 2x` |
| `STATUS` | See `../schemas/decision-format.md` | `Active (ThreadBound → D017)` |
| `LINK` | `[Full](DECISION_ID-descriptor.md)` | `[Full](D034-async-runtime.md)` |

The Link cell is how the CLI reaches the decision document for body search and `get`; a cell naming no file leaves those blind to the decision.

New rows go at the end of the table, before the `---` separator — append-only, never re-sorted (the Date cell carries chronology; a decision written up late still appends).

```markdown
| 2026-03-24 | D034 | [PROJ-200](../research/PROJ-200/findings.md) | Use tokio for async runtime | Battle-tested, ecosystem support | Alternative runtime outperforms tokio 2x | Active | [Full](D034-async-runtime.md) |
| 2026-03-24 | D035 | — | Fixed 10-level depth limit | Eliminates allocation, predictable layout | Need variable depth | Active | [Full](D035-fixed-depth-limit.md) |
| 2026-02-17 | D011 | [PROJ-410](../research/PROJ-410/findings.md) | Zero-allocation object pools | HashMap → Vec for buffers | Pool count exceeds 1024 | Active (ThreadBound → D017) | [Full](D011-zero-alloc-pools.md) |
```
