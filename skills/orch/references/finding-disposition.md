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

Round cap: `REVIEW_MAX_EXTERNAL_ROUNDS` (default 4) bounds the external review rounds on an open PR, counted in `pr_comment_review.iterations`. Past it every finding gets a disposition — `Declined: <reason>` or `Tracked: <ID>` — and no fix push. The filing bar below decides which of the two, exactly as it does under the cap: a finding that misses the bar is declined at the cap as well, and an issue filed to empty a thread is the byproduct the bar exists to keep out of the backlog. One exception: a defect this diff itself introduces or arms is fixed whatever the round count — a cap that forces a disposition onto a defect the change created ships the defect. Only Step 1's introduced-or-armed branch outranks the cap. Step 1's other `fix` verdict — a pre-existing defect that blocks this change from working — is a fix below the cap and a disposition above it, like anything else.

Uncertain about category, prefer `fix` (if related); uncertain about relevance, prefer `issue`; if neither fits, omit. A finding that lives in a PR review thread ends as exactly one reply — `Fixed in <sha>`, `Declined: <reason>`, or `Tracked: <ID>` (the merge gate rejects a tracking claim naming no issue); local and pre-PR reviews record the same verdicts in the review artifact instead. `<reason>` states the mechanism the decline disproves: the passing state, or the false premise the finding rests on. A label is not a reason — `frozen`, `at the cap`, `out of scope`, `pre-existing`, `flagged separately` — and neither is a test count, since a passing suite says nothing about a path no test runs. That rule holds whatever the gate reaches. The gate reaches what it can decide by vocabulary: `unreasoned-decline` turns it red on a decline whose reason strips to nothing against its label list, reading the reply by its shape rather than its punctuation — `Declined, out of scope` is the same decline; a label beside a real reason is untouched. A label carrying a name past that list, a counted suite for one, clears the gate and still breaks the rule; `skills/review-gate/tests/corpus/declines-known-limit.txt` pins the boundary. Under thread enforcement, a thread's disposition is its newest non-bot reply that opens with `Fixed in <sha>` or `Declined:` or carries a track-word (track/tracked/tracking/tracks); when that reply is a track-word with no issue id it trips the gate, prose included — write "committed" for git-tracked files. Other replies and resolving the thread do not move the disposition.

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
| A finding sharing a root cause with one a prior round patched, at any site (a drifting claim, a re-derived enumeration, a second copy) | § Recurrence, which allows `structural-close` or `freeze` and no further patch |

## Recurrence

**Checked before every round's dispositions, ahead of any round cap.** A finding sharing a root cause with one a prior round fixed, the record `patched_causes` keeps, ends the patch sequence for that cause, at whatever site it appears; the cap counts rounds, this counts causes, and a cause recurs several times inside the cap's budget without the cap ever seeing it. A cause `patched_causes` does not name was never patched, and stays with the decision flow: a decline or a filing is not a fix. Two dispositions remain and neither is another patch: `structural-close`, which makes the class unrepresentable and shrinks or holds the diff, where cutting surface the Done-when does not require counts as the close; or `freeze`, which lands the narrow symptom fix already made and replies `Tracked: <ID>` against a class issue created first. `freeze` is available where a thread reply can name a class issue filed first, which is the comment loop, and there only for a cause this diff neither introduces nor arms. An introduced or armed cause takes `structural-close`, since a round count never answers a defect the diff armed. A cause the pre-PR loop meets that this diff neither introduces nor arms takes neither disposition, that loop having no thread to reply into: it rides to that workflow's issue audit as an escalated item. A close needing adoption per surface is not structural, and new sites that keep qualifying for it are recurrence taking whichever branch this diff's authorship leaves open. Once a cause is frozen its class issue is filed once: every later finding on that cause is `decline`d with its reason, never a second filing.

## Filing bar

An `issue` signal is necessary but not sufficient. Every candidate carries its schema `impact` line — who hits this, on what real path; an impact that needs "could", "might", or "in theory" is a decline. File only for:

- **Behavioral defects outside this PR's scope** — wrong behavior a user or caller can hit.
- **est≥2 refactors** — restructuring too large to absorb here that unblocks or protects user-visible work.
- **Decision revisits** — a recorded decision the finding argues should change.
- **Unexplained anomalies with evidence** — observed and reproducible, cause unknown; filed as an investigation issue whose deliverable is the diagnosis.

Never for a finding that asks for a product decision the issue does not carry — a new command, a parity feature, a behavior nobody specified: that is declined, since filing it makes a reviewer's preference look like ordered work. Never for a race between two invocations on one machine, a crash between two writes, an input no shipped producer emits, or a hole in a mechanism that itself came from a review round: those are declined, not filed. Never for a mechanism needing a second writer who already holds the user's privileges — retargeting a link between the check and the use, swapping an ancestor mid-apply — since that writer reaches the same end directly and the finding names no capability it lacked. The one exception is a security or data-loss defect a shipped path reaches, which follows the rows above. That exception does not reopen the second-writer clause: a writer already holding the user's privileges gains nothing the finding could name, so no finding that clause covers reaches it.

A recurring finding class the diff introduces or arms never files: § Recurrence closes its generator in this PR. A recurring class the diff neither introduces nor arms files once — as the class issue a `freeze` reply names, or through the pre-PR loop's issue audit.

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
