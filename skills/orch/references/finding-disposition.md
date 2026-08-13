# Finding disposition

How a review finding is dispositioned: applied in this PR, filed as a tracked issue, or declined. Bias toward reliability when uncertain.

**Verification prerequisite.** Before classifying anything as noise, stale, or not actionable, read the files it references. A comment is stale only when the code proves it so. No file read, no dismissal.

## Decision flow

1. **Actionable?** It needs a specific deliverable, an observable impact, and bounded scope. Vague items ("add logging", "consider X") and informational notes are omitted. Automated regression detection is never informational.
2. **Related?** The test is semantic — about the problem or the change — not mechanical file membership. An out-of-diff file documenting the mechanism being fixed is related; a nearby improvement unrelated to the problem is not. Unrelated → `issue` regardless of size.
3. **Size?** Small enough to apply here → `fix`. Needs delegation, tracking, history, or new files → `issue`.

Uncertain about category, prefer `fix` (if related); uncertain about relevance, prefer `issue`; if neither fits, omit.

| Signal | Category |
|--------|----------|
| Small, quick to apply | `fix` |
| Doc or reference updates for changed code | `fix`, always, regardless of size |
| Test coverage added to an existing test | `fix` |
| Test coverage needing a new file, suite, or scenarios | `issue` |
| Performance fix inside touched code | `fix` |
| Performance work needing benchmarks | `issue` |
| Architectural or cross-component change | `issue` |
| Error-handling gaps | `issue` — silent failures have real cost |
| Security vulnerability | `fix` if quick, else `issue` — never skipped |
| Data validation gaps | `fix` if quick, else `issue` |
| The same claim or enumeration drifting for two rounds running | `fix` as a structural close — derive, bind, or delete the claim; prose-level fixes regenerate the finding next round |

## Filing bar

An `issue` signal is necessary but not sufficient. File only for:

- **Behavioral defects outside this PR's scope** — wrong behavior a user or caller can hit.
- **est≥2 refactors** — restructuring too large to absorb here that unblocks or protects user-visible work.
- **Decision revisits** — a recorded decision the finding argues should change.
- **Unexplained anomalies with evidence** — observed and reproducible, cause unknown; filed as an investigation issue whose deliverable is the diagnosis.

The audit pipeline applies project-management's creation bar (its SKILL.md § Disposition) as the final authority; these classes describe what clears it.

Everything else is absorbed or declined. P4 polish never files: absorb it when it is est-1 and related, otherwise drop it with a one-line note in the review summary. A finding that cannot affect real usage is declined with one line of rationale — neither fixed nor filed. Vague items are noise, not visibility.

When a same-surface bundle or umbrella parent already exists, residue attaches to it as a child or related issue; a standalone filing needs a stated reason.

## Priority

| Pri | Meaning | Use when |
|-----|---------|----------|
| P1 | Urgent | Blocks the critical path |
| P2 | High | Important, architectural |
| P3 | Normal | Standard work |
| P4 | Low | Nice-to-have, cleanup |
