# Finding disposition

How a review finding is dispositioned: applied in this PR, filed as a tracked issue, or declined. Bias toward reliability when uncertain.

**Verification prerequisite.** Before classifying anything as noise, stale, or not actionable, read the files it references. A comment is stale only when the code proves it so. No file read, no dismissal.

## Decision flow

One pass, in order; the first verdict stands. Step 0 runs ahead of Step 1, so a finding it excludes never reaches the introduced-or-armed branch.

0. **Is it one of the excluded classes?** → `decline` naming the class and the fact that puts the finding in it, before the claim's truth is examined and whatever this diff introduced or armed. The classes: a race between two invocations on one machine; a crash between two writes; an input no shipped producer emits; a finding whose premise is a lexical shape, the characters a word or token scanner matches rather than the behavior it gates, which is declined and never patched however the input reached the scanner; a finding that is hypothetical and low severity, no run having produced it and the harm if one did being minor, which is declined here and so is not fixed either, not merely kept off the filing bar; a hole in a mechanism that itself came from a review round; a mechanism needing a second writer who already holds the user's privileges (retargeting a link between the check and the use, swapping an ancestor mid-apply), since that writer reaches the same end directly and the finding names no capability it lacked. Two exceptions go to Step 1: a security or data-loss defect a shipped path reaches, and a fail-open defect in gate, guard or CI code. Neither reopens the second-writer clause — a writer already holding the user's privileges gains nothing the finding could name, so no finding that clause covers reaches it.
1. **Does it claim a defect** (a failing state, broken path, wrong output)? Verify the mechanism yourself:
   - **False** → `decline`, naming the passing state or the false premise. Scope, age, and "pre-existing" never answer a defect claim.
   - **True, and this diff introduces or arms it** → is the defective code required by the issue's Done-when? Not required (the Done-when holds without it) → `fix` by deleting that code, never by hardening it and never by a second mechanism guarding the first; when a prior fix round added the code, revert that addition instead of patching it; the reply is the deleting sha. Required → `fix` in place, in scope by definition. Pre-existing caps, thresholds, or code the diff newly composes into a failing path count as armed.
   - **True, pre-existing, unarmed by this diff** → `issue` if it clears the filing bar below (create it first, reply `Tracked: <ID>`), else `decline` naming the bar it misses; `fix` here only when it blocks this change from working.
2. **Actionable?** It needs a specific deliverable, an observable impact, and bounded scope. Vague items ("add logging", "consider X") and informational notes are omitted. Automated regression detection is never informational.
3. **Related?** The test is semantic — about the problem or the change — not file membership. An out-of-diff file documenting the mechanism being fixed is related; a nearby improvement unrelated to the problem is not. Unrelated → `issue` regardless of size.
4. **Size?** Small enough to apply here → `fix`. Needs delegation, tracking, history, or new files → `issue`.

Size tripwire, enforced before fix delegation: `dev-round-write` exits 3 when the branch diffstat exceeds twice workflow state `pr.baseline_lines`. Stop the item-by-item fix path, report the current and baseline counts, and cut back to the Done-when before minting another round. Close every thread on cut code with the deleting sha.

Round cap: `REVIEW_MAX_EXTERNAL_ROUNDS` (default 4) bounds the external review rounds on an open PR, counted in `pr_comment_review.iterations`. Past it every finding gets a disposition — `Declined: <reason>` or `Tracked: <ID>` — and no fix push. The filing bar below decides which of the two, exactly as it does under the cap: a finding that misses the bar is declined at the cap as well. One exception: a defect this diff itself introduces or arms, and Step 0 does not exclude, is fixed whatever the round count. Only Step 1's introduced-or-armed branch outranks the cap. Step 1's other `fix` verdict — a pre-existing defect that blocks this change from working — is a fix below the cap and a disposition above it, like anything else.

Uncertain about category, prefer `fix` (if related); uncertain about relevance, prefer `issue`; if neither fits, omit. A finding that lives in a PR review thread ends as exactly one reply — `Fixed in <sha>`, `Declined: <reason>`, or `Tracked: <ID>`; local and pre-PR reviews record the same verdicts in the review artifact instead. Reserve `track` and its forms — `track`, `tracked`, `tracking`, `tracks` — for that third verdict, which names its issue. The gate matches them lexically, anywhere in a reply and whatever you meant, so write "committed" for a git-tracked file: a stray "tracked" in prose is a tracking claim naming no issue. `<reason>` states the mechanism the decline disproves, in one of three forms: the passing state, the false premise the finding rests on, or the Step 0 class the finding falls in, named with the fact that puts it in that class rather than the class alone, which would be a label. A label is not a reason — `frozen`, `at the cap`, `out of scope`, `pre-existing`, `flagged separately` — and neither is a test count, since a passing suite says nothing about a path no test runs. That rule holds whatever the gate reaches. Which reply on a thread the merge gate reads, which replies it turns red, and where its predicate stops, belong to the review-gate skill: [`skills/review-gate/SKILL.md`](../../review-gate/SKILL.md) § Decision table, `review-predicate.sh --help`, and the boundary corpus they pin. Read them before wording a reply — the gate reads shapes, not intent, so ordinary prose can carry one.

| Signal | Category |
|--------|----------|
| Small, quick to apply | `fix` |
| Doc or reference updates for changed code | `fix`, always, regardless of size |
| Test coverage added to an existing test | `fix` when the diff changes behavior no test exercises (AGENTS.md § Code Review Rules); otherwise `decline` |
| Test coverage needing a new file, suite, or scenarios | `issue` when the untested path can fail in real usage without a test reddening, the failure named; else `decline` |
| Performance fix inside touched code | `fix` |
| Performance work needing benchmarks | `issue` |
| Architectural or cross-component change | `issue` |
| Error-handling gaps | `issue` |
| Security vulnerability | `fix` if quick, else `issue` — never skipped |
| Data validation gaps | `fix` if quick, else `issue` |
| A finding sharing a root cause with one a prior round patched, at any site (a drifting claim, a re-derived enumeration, a second copy) | § Recurrence, which allows `structural-close` or `freeze` and no further patch |

## Recurrence

**Checked before every round's dispositions, ahead of any round cap and behind Step 0**, a class the project excludes being no cause worth closing structurally. A finding sharing a root cause with one a prior round fixed, the record `patched_causes` keeps, ends the patch sequence for that cause, at whatever site it appears. A cause `patched_causes` does not name was never patched, and stays with the decision flow: a decline or a filing is not a fix. Two dispositions remain and neither is another patch: `structural-close`, which makes the class unrepresentable and shrinks or holds the diff, where cutting surface the Done-when does not require counts as the close; or `freeze`, which lands the narrow symptom fix already made and replies `Tracked: <ID>` against a class issue created first. `freeze` is available where a thread reply can name a class issue filed first, which is the comment loop, and there only for a cause this diff neither introduces nor arms. That class issue is review-born, so it exists only where it clears the filing bar; a cause whose class misses the bar takes `structural-close`, or `decline` naming the bar the class misses, and never a class issue filed to make the reply legal. An introduced or armed cause takes `structural-close`. A cause the pre-PR loop meets that this diff neither introduces nor arms takes neither disposition, that loop having no thread to reply into: it rides to that workflow's issue audit as an escalated item. A close needing adoption per surface is not structural, and new sites that keep qualifying for it are recurrence taking whichever branch this diff's authorship leaves open. Once a cause is frozen its class issue is filed once: every later finding on that cause is `decline`d with its reason, never a second filing.

## Filing bar

An `issue` signal is necessary but not sufficient. Every candidate carries its schema `impact` line — who hits this, on what real path; an impact that needs "could", "might", or "in theory" is a decline. File only for:

- **Behavioral defects outside this PR's scope** — wrong behavior a user or caller can hit.
- **est≥2 refactors** — restructuring too large to absorb here that unblocks or protects user-visible work.
- **Decision revisits** — a recorded decision the finding argues should change.
- **Unexplained anomalies with evidence** — observed and reproducible, cause unknown; filed as an investigation issue whose deliverable is the diagnosis.

A review-born finding clears the bar only where what reaches it is a user or a shipped run, and files at priority 2 carrying the symptom that showed it (project-management SKILL.md § Disposition, which every filing goes through). Below that, a true defect is fixed here when it is tiny (est-1, no new helper, no new file) and is otherwise declined with its reason; a review-born P3 does not file.

Never for a finding that asks for a product decision the issue does not carry — a new command, a parity feature, a behavior nobody specified: that is declined. Every candidate runs through Step 0 before the bar judges it, whichever door it arrived by — a `category: "issue"` suggestion, an item escalated at a cap, a Discovered Work or deliberately-left-out bullet from a dev return — and one Step 0 excludes is declined there. Step 0 is the only place the classes are written.

A finding that does reach a fix round names, per delegated item, the shipped producer, user action, or fixture that reaches it — the `reach` field of [`../schemas/dev-round.md`](../schemas/dev-round.md). Step 0 runs first, and a reach never overrides it; a class Step 0 excludes is declined whether or not the finding can name one.

A recurring finding class the diff introduces or arms never files: § Recurrence closes its generator in this PR. A recurring class the diff neither introduces nor arms files once where it clears this bar — as the class issue a `freeze` reply names (§ Recurrence says what a `freeze` becomes when it does not), or through the pre-PR loop's issue audit.

The audit pipeline applies project-management's creation bar (its SKILL.md § Disposition) to what reaches it, which is what Step 0 and this bar have already passed; a candidate Step 0 or this bar refused is never filed on that bar's say-so.

Everything else is absorbed or declined. P4 polish never files: absorb it when it is est-1 and related, otherwise drop it with a one-line note in the review summary. A finding that cannot affect real usage is declined with a one-line reason — neither fixed nor filed. A decline is terminal: it appears as its summary line and is never re-presented as a question ("file it anyway?").

When a same-surface bundle or umbrella parent already exists, residue attaches to it as a child or related issue; a standalone filing needs a stated reason.

## Priority

| Pri | Meaning | Use when |
|-----|---------|----------|
| P1 | Urgent | Blocks the critical path |
| P2 | High | Important, architectural |
| P3 | Normal | Standard work |
| P4 | Low | Nice-to-have, cleanup |
