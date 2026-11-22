# Verify

Run one verification pass over the items in Verifying and the GitHub items in verification, from the consumer's base checkout. A scheduler can start an agent session for `/orch verify` with no overseer or lane running. The package supplies no scheduler.

## 1. Read open checks

```bash
.agents/skills/orch/scripts/orch-runtime reconcile-items
```

Read the JSON reply.

- Pass `--inventory PATH` to reuse the current pass's complete team inventory through the linear package.
- A successful reply exits 0 and carries `result.findings`, `result.lines` and `result.counts`; findings are data.
- A refused reply exits 1: report its diagnostic.
- A usage error exits 2.

Then:

1. Keep the box lines the invoking watch event or heartbeat supplied, including boxes the reconciliation leaves out. The watch has already ticked each box it read met, and commented on each it read failed or inconclusive.
2. For each `due` or `overdue` box from either source, read the item and its comments live. Read each box once in this pass.
3. Complete items with no open box under **Completion** below.
4. Report invalid boxes with their diagnostics.

A `verifying-merge-unread` item is one the reconciliation's search found no merge for. Where such an item has no usable watch box lines:

1. Find its linked merged pull requests in their own repositories, with the linked-PR read of [oversee-events.md § Verification](../references/oversee-events.md#verification).
2. Run the reconciliation again with one `--merged` per pull request:

```bash
.agents/skills/orch/scripts/orch-runtime reconcile-items --merged [ITEM]=[OWNER/REPO]#[N]
```

The verb reads each named pull request's merge from GitHub and judges the item's boxes from the latest one.

- Take their due or overdue boxes through the same evidence and completion steps.
- Keep waiting and blocked boxes open.
- Where the item has no linked merged pull request, or the reply refuses a named read, report the item, its open boxes and the failed read.
- Do not repeat the watch's repository search.

For every item:

- For acceptance and failed checks, apply [SKILL.md § The Cycle](../SKILL.md#the-cycle), The overseer reads results. It governs a scheduled session's reading too.
- A merged item never returns to In Progress, also after a failed check: never select that state with `linear.sh issues update`.
- Read the evidence `Where:` names. Never run `Where:` text as a command line.

**Completion.**

- Complete a proved box, a merged item and a container through the steps of [oversee-events.md § Verification](../references/oversee-events.md#verification): the evidence comment and file, `linear.sh issues complete` with the merge's `--post-merge-at`, `orch-runtime container-close` for a container, and the parent's close.
- Run them from the base checkout, outside any confined lane. In a confined lane `container-close` writes nothing; the overseer's route owns the close.

### GitHub items

`reconcile-items` and the watch's verification duty judge no GitHub item's post-merge boxes, so every pass judges them here.

`linear.sh done-when parse` classifies each body, as [SKILL.md § Tracker Resolution](../SKILL.md#tracker-resolution) states. Where the linear package is not installed, report the pass's GitHub items unread.

A GitHub item is in verification while all three hold:

- The issue is open.
- A pull request from its branch `issue-[N]`, not from a fork, merged.
- Its Done-when holds a post-merge box, open, ticked or waived: a `boxes` row with `post_merge` true in the parser's answer, or a `- Waived: Post-merge:` line under `## Done when`.

`[OWNER/REPO]` is what `gh repo view --json nameWithOwner --jq .nameWithOwner` answers from the base checkout.

1. Read every open issue:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh api --paginate "repos/[OWNER/REPO]/issues?state=open&per_page=100" --jq '.[] | select(.pull_request == null) | {number, body}'
   ```

   A failed read leaves the pass's GitHub items unread: report it, never as none.

2. Save each body under `tmp/` and classify it:

   ```bash
   .agents/skills/linear/scripts/linear.sh done-when parse --description-file [BODY_FILE]
   ```

   - If the body holds no post-merge box, open, ticked or waived, the issue is not in verification: leave it.
   - If the parser exits nonzero, that issue is unread: report it with the parser's stderr.

3. For each issue with a post-merge box, read its merges:

   ```bash
   env -u GH_REPO -u GITHUB_REPOSITORY gh pr list --repo [OWNER/REPO] --state merged --head issue-[N] --json number,mergedAt,mergeCommit,isCrossRepository
   ```

   - Drop each row whose `isCrossRepository` is true: a fork's branch of the same name is not the item's merge, as `reconcile-items` reads it.
   - If the read fails or does not decode, that issue is unread: report it with the cause.
   - If no row is left, the issue is a development item: leave it.
   - The row with the latest `mergedAt` gives `[MERGED_AT]` and `[MERGE_SHA]`, its `mergeCommit.oid`. Each box's trigger is judged after that merge.

4. Classify the body again with `--merged-at [MERGED_AT]`.

   - If the answer's `errors` is nonempty, the checklist is invalid. Report the issue with its errors and keep it open. Judge none of its boxes.
   - Judge each open post-merge box, `post_merge` true and `checked` false, by its `trigger_kind`:
     - `merge` or `time`: the trigger fires at `[MERGED_AT]` or at the box's `trigger` time. The deadline end is `deadline_end`.
     - `release`: the trigger is the first release of `release_repo` published after `[MERGED_AT]` whose tag matches the Bash pattern `release_glob` and, where `release_repo` is `[OWNER/REPO]`, contains `[MERGE_SHA]`. The deadline end is that release's `published_at` plus `deadline_hours`.
   - A box is `overdue` once its deadline end has passed, `waiting` before a `time` or `release` trigger fires, and `due` otherwise.
   - Read each due or overdue box under § 1's acceptance. Keep waiting boxes open.

   For a release trigger, read the published releases, then check each candidate tag in publication order:

   ```bash
   gh api --paginate "repos/[RELEASE_REPO]/releases?per_page=100" --jq '.[] | select(.draft == false) | {tag_name, published_at}'
   gh api "repos/[OWNER/REPO]/compare/[MERGE_SHA]...[TAG]" --jq .status
   ```

   - `[TAG]` is percent-encoded as one path segment.
   - A status of `ahead` or `identical` contains the merge. A status of `behind` or `diverged` does not: take the next tag.
   - If either read fails, or the status is any other value, the box is unread: report it.
   - If no release qualifies, the box is waiting.

5. For each proved box:
   1. Post the evidence comment with `gh issue comment [N] --repo [OWNER/REPO] --body-file [FILE]`.
   2. Tick the box and put the indented `Evidence:` line citing that comment under it, in the form `linear.sh issues complete --done-when-met` writes.
   3. Save the full body under `tmp/` and write it with `gh issue edit [N] --repo [OWNER/REPO] --body-file [FILE]`.
6. Classify the body as last written. If it holds no open post-merge box and no `errors`, close the issue, whatever route retired its last box:

   ```bash
   gh issue close [N] --repo [OWNER/REPO] --reason completed
   ```

A GitHub item takes § 2 and § 3 through these writes:

- § 2's box rewrite and a drop save the full body under `tmp/` and write it with `gh issue edit [N] --repo [OWNER/REPO] --body-file [FILE]`.
- § 2's rewrite comment and decision record go through `gh issue comment [N] --repo [OWNER/REPO] --body-file [FILE]`.
- A drop keeps the box in the body as `- Waived: …` with its `Reason:` line, in the form `linear.sh issues complete --done-when-waived` writes.
- An accepted reading under § 3 ticks its box through step 5.
- After a drop or an accepted reading, run step 6 on that issue.
- § 2's wait for an event has no GitHub form: report the box as a blocked ask in § 4.
- With no overseer, report an owner-only box on a GitHub item as a blocked ask in § 4: § 3's tracker route is Linear's.

## 2. Resolve missing evidence

When a box's deadline arrives with no evidence and no proved defect:

- Read the item's comments for an earlier rewrite of this box.
- Keep the item Verifying throughout.
- A missing sample creates no fix item.

1. **First deadline: rewrite the box once.**

   - Point `Where:` at readable evidence, or set `Trigger:` to the expected sample's UTC time and `Deadline:` within 72 hours of it.
   - Keep the pass condition.
   - Save the current full description under `tmp/`, and write it back with no state option:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ITEM] --description-file [FILE]
   ```

   Comment `acceptance unverified: <cause>; check rewritten`, naming the box and its old and new check fields.

2. **Rewritten box past its deadline: decide.** First judge whether the missing evidence matters.

   - Where no owner-reserved outcome turns on it, this session decides: record the decision on the item as a ruling with its reason, and act on it under step 3.
   - Where an owner-reserved outcome turns on it, send one owner ask on the item.
     - Name each option with its practical consequence and give a recommendation.
     - Offer: drop the check, keep waiting with a date, or keep waiting for an event the person names.
     - Under an overseer, use [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks); with no overseer, use § 3's tracker route.
     - Read the comments first, so a later pass reuses an open ask.

3. **Act on the decision**, and record the decision and the changed fields on the item:

   - **Drop.** Retire the box.
     1. Write `[N]: [AUTHORITY]: [REASON]` to an evidence file; the authority is the owner's answer or this session's recorded ruling.
     2. Run `.agents/skills/linear/scripts/linear.sh issues complete [ITEM] --post-merge-at [MERGED_AT] --done-when-waived [N] --evidence-file [FILE]`, reading `[MERGED_AT]` as the completion steps read it.

     The box keeps its text as `- Waived: …` with a `Reason:` line and is never ticked. The item reaches Done once every other box is met or retired.

   - **Keep waiting, with a date.** Set `Trigger:` to the date in UTC and `Deadline:` within 72 hours of it.
   - **Keep waiting, for an event.**
     1. Record the event as a blocker and write no date: `.agents/skills/linear/scripts/linear.sh issues block [ITEM] --by [EVENT_ITEM]`.
     2. Assign the event's item to the person who waits on it.

     While that blocker is open, the box reads `blocked`, never overdue.

- A later missing-sample deadline on the same box takes the same decision route, without another automatic rewrite.
- A deadline moves only through the one rewrite or a decision.
- A proved failed check follows § 1's acceptance rule.

## 3. Ask for a person's reading

- With an overseer, follow [communication-modes.md § Owner-only verification](../references/communication-modes.md#owner-only-verification).
- With no overseer, keep that reader selection. This pass takes an accessible tool reading; a delegate reading follows the delegate notice route.

  For an owner-only box, or § 2's ask, ask directly through the linear skill:

  1. Read the item and its comments.
     - Reuse an open verification ask for this box.
     - Where another box has an open owner ask on the item, leave this box pending until that ask closes.
     - Resolve `ORCH_OWNER_EMAIL` and `ORCH_OWNER_ASK_LABEL` ([settings.md § Talking to you](../references/settings.md#talking-to-you)). Report an unset owner or label as a blocked ask.

  2. Keep the current labels. Assign the owner and add the owner-ask label:

     ```bash
     .agents/skills/linear/scripts/linear.sh issues update [ITEM] --assignee [OWNER_EMAIL] --labels [FULL_LABEL_SET]
     ```

     Post the question, naming the box, the check, `Where:` and the deadline:

     ```bash
     .agents/skills/linear/scripts/linear.sh comments create [ITEM] --body-file [FILE]
     ```

     Record which box the ask covers. Keep the item Verifying.

  3. On the next pass, read the owner's one-comment answer after that ask; the owner's email identifies it.
     - For a reading, apply the answer acceptance rule of [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks). An accepted reading passes the check; a change request follows § 1's acceptance rule.
     - For § 2's ask, act on the chosen option under § 2 step 3.
     - An absent answer leaves the ask open.

  4. Before closing the ask:
     - Record the answer and the reading on the item.
     - Complete a passing check under § 1's Completion.
     - Read the labels fresh, remove only the owner-ask label, and clear the assignee:

     ```bash
     .agents/skills/linear/scripts/linear.sh issues update [ITEM] --labels [FULL_LABEL_SET] --clear-assignee
     ```

     Keep another open owner ask's assignment and label until that ask closes, as the watch's `../runtime/src/watch/tracker.rs::clear_owner_item` does.

## 4. Record the pass

- Report the evidence comments, completed items, remaining boxes and blocked reads in the scheduler's run log or the overseer's report.
- Leave waiting and blocked boxes open.
- Name the open owner asks; the next pass reads their answers from the same items.
