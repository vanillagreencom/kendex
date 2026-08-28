# Finding disposition

How a review finding is dispositioned: applied in this PR, filed as a tracked issue, or declined. Bias toward reliability when uncertain.

**Verification prerequisite.** Before classifying anything as noise, stale, or not actionable, read the files it references. A comment is stale only when the code proves it so. No file read, no dismissal.

## Decision flow

One pass, in order; the first verdict stands.

1. **Does it claim a defect** (a failing state, broken path, wrong output)? Verify the mechanism yourself:
   - **False** → `decline`, naming the passing state or the false premise. Scope, age, and "pre-existing" never answer a defect claim.
   - **True, and this diff introduces or arms it** → is the defective code required by the issue's Done-when? Not required (the Done-when holds without it) → `fix` by deleting that code, never by hardening it; the reply is the deleting sha. Required → `fix`, in scope by definition. Pre-existing caps, thresholds, or code the diff newly composes into a failing path count as armed.
   - **True, pre-existing, unarmed by this diff** → `issue` if it clears the filing bar below (create it first, reply `Tracked: <ID>`), else `decline` naming the bar it misses; `fix` here only when it blocks this change from working.
2. **Actionable?** It needs a specific deliverable, an observable impact, and bounded scope. Vague items ("add logging", "consider X") and informational notes are omitted. Automated regression detection is never informational.
3. **Related?** The test is semantic — about the problem or the change — not file membership. An out-of-diff file documenting the mechanism being fixed is related; a nearby improvement unrelated to the problem is not. Unrelated → `issue` regardless of size.
4. **Size?** Small enough to apply here → `fix`. Needs delegation, tracking, history, or new files → `issue`.

Size tripwire, checked before every round's dispositions: the PR's diffstat against the commit its first review was posted on (`gh api repos/<owner>/<repo>/pulls/<n>/reviews --jq '.[0].commit_id'`; a force-push does not move it). Past 2x, the round is one cut back to the Done-when and every thread on the cut code closes with the deleting sha, whatever the findings say one by one.

Round cap: `REVIEW_MAX_EXTERNAL_ROUNDS` (default 4) bounds the external review rounds on an open PR, counted in `pr_comment_review.iterations`. Past it every finding gets a disposition — `Declined: <reason>` or `Tracked: <ID>` — and no fix push. One exception: a defect this diff itself introduces or arms is fixed whatever the round count — a cap that forces a disposition onto a defect the change created ships the defect. Step 1's `fix` verdict outranks the cap; nothing else does.

Uncertain about category, prefer `fix` (if related); uncertain about relevance, prefer `issue`; if neither fits, omit. A finding that lives in a PR review thread ends as exactly one reply — `Fixed in <sha>`, `Declined: <reason>`, or `Tracked: <ID>` (the merge gate rejects a tracking claim naming no issue); local and pre-PR reviews record the same verdicts in the review artifact instead. Under thread enforcement, a thread's disposition is its newest non-bot reply that opens with `Fixed in <sha>` or `Declined:` or carries a track-word (track/tracked/tracking/tracks); when that reply is a track-word with no issue id it trips the gate, prose included — write "committed" for git-tracked files. Other replies and resolving the thread do not move the disposition.

| Signal | Category |
|--------|----------|
| Small, quick to apply | `fix` |
| Doc or reference updates for changed code | `fix`, always, regardless of size |
| Test coverage added to an existing test | `fix` |
| Test coverage needing a new file, suite, or scenarios | `issue` |
| Performance fix inside touched code | `fix` |
| Performance work needing benchmarks | `issue` |
| Architectural or cross-component change | `issue` |
| Error-handling gaps | `issue` |
| Security vulnerability | `fix` if quick, else `issue` — never skipped |
| Data validation gaps | `fix` if quick, else `issue` |
| A finding class arriving in two rounds running (a drifting claim, a re-derived enumeration, a second copy) | `fix` as a structural close — derive, bind, or delete the generator |

## Filing bar

An `issue` signal is necessary but not sufficient. Every candidate carries its schema `impact` line — who hits this, on what real path; an impact that needs "could", "might", or "in theory" is a decline. File only for:

- **Behavioral defects outside this PR's scope** — wrong behavior a user or caller can hit.
- **est≥2 refactors** — restructuring too large to absorb here that unblocks or protects user-visible work.
- **Decision revisits** — a recorded decision the finding argues should change.
- **Unexplained anomalies with evidence** — observed and reproducible, cause unknown; filed as an investigation issue whose deliverable is the diagnosis.

Never for a race between two invocations on one machine, a crash between two writes, an input no shipped producer emits, or a hole in a mechanism that itself came from a review round: those are declined, not filed. The one exception is a security or data-loss defect a shipped path reaches, which follows the rows above.

A recurring finding class the diff introduces or arms never files as "improve X": the structural-close row closes its generator in this PR.

The audit pipeline applies project-management's creation bar (its SKILL.md § Disposition) as the final authority; these classes describe what clears it.

Everything else is absorbed or declined. P4 polish never files: absorb it when it is est-1 and related, otherwise drop it with a one-line note in the review summary. A finding that cannot affect real usage is declined with a one-line reason — neither fixed nor filed. A decline is terminal: it appears as its summary line and is never re-presented as a question ("file it anyway?").

When a same-surface bundle or umbrella parent already exists, residue attaches to it as a child or related issue; a standalone filing needs a stated reason.

## Priority

| Pri | Meaning | Use when |
|-----|---------|----------|
| P1 | Urgent | Blocks the critical path |
| P2 | High | Important, architectural |
| P3 | Normal | Standard work |
| P4 | Low | Nice-to-have, cleanup |
