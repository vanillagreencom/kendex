# INDEX.md Row

```markdown
| [DATE] | [DECISION_ID] | [RESEARCH_REF] | [DECISION_SUMMARY] | [RATIONALE_SUMMARY] | [REVISIT_WHEN] | [STATUS] | [LINK] |
```

| Field | Format | Example |
|-------|--------|---------|
| `DATE` | `YYYY-MM-DD` | `2026-03-24` |
| `DECISION_ID` | The project's scheme, numeric suffix | `D034`, `ADR-0034` |
| `RESEARCH_REF` | `[ID](url)`, the tracker issue or the attachment on it, or `—` | `[PROJ-189](https://linear.app/acme/issue/PROJ-189)` |
| `DECISION_SUMMARY` | the choice | `Use tokio for async runtime` |
| `RATIONALE_SUMMARY` | the key reason | `Battle-tested, ecosystem support` |
| `REVISIT_WHEN` | the trigger | `Alternative runtime outperforms tokio 2x` |
| `STATUS` | See `../schemas/decision-format.md` | `Active (ThreadBound → D017)` |
| `LINK` | `[Full](DECISION_ID-descriptor.md)`, kept as written after the document is gone | `[Full](D034-async-runtime.md)` |

The Link cell names the decision file; the CLI resolves body search and `get` through it, and `decisions check` reads it as the record's identity across branches, so a retired or removed record keeps it as written.

Append new rows at the end of the table, before the `---` separator; never re-sort, even for a decision written up late.

```markdown
| 2026-03-24 | D034 | [PROJ-200](https://linear.app/acme/issue/PROJ-200) | Use tokio for async runtime | Battle-tested, ecosystem support | Alternative runtime outperforms tokio 2x | Active | [Full](D034-async-runtime.md) |
| 2026-03-24 | D035 | — | Fixed 10-level depth limit | Eliminates allocation, predictable layout | Need variable depth | Active | [Full](D035-fixed-depth-limit.md) |
| 2026-02-17 | D011 | [PROJ-410](https://linear.app/acme/issue/PROJ-410) | Zero-allocation object pools | HashMap → Vec for buffers | Pool count exceeds 1024 | Active (ThreadBound → D017) | [Full](D011-zero-alloc-pools.md) |
```
