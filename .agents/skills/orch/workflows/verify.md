# Verify

Run one verification pass over the items in Verifying, from the consumer's base checkout. A scheduler can start an agent session for `/orch verify` with no overseer or lane running; the package supplies no scheduler.

## 1. Read open checks

```bash
.agents/skills/orch/scripts/orch-runtime reconcile-items
```

Read the JSON reply. A successful reply carries `result.findings`, `result.lines` and `result.counts`; findings are data, and the command exits 0. A refused reply exits 1: report its diagnostic. A usage error exits 2.

1. Keep the box lines the invoking watch event or heartbeat supplied, boxes the reconciliation leaves out included. The watch has already ticked a box it read met, and has already commented on one it read failed or inconclusive.
2. For each `due` or `overdue` box from either source, read the item and its comments live. Read each box once in this pass.
3. Complete items with no open box under **Completion** below.
4. Report invalid boxes with their diagnostics.

For a `verifying-merge-unread` item the reconciliation's search found no merge for, and that has no usable watch box lines, find the item's linked merged pull requests in their own repositories with the linked-PR read of [oversee-events.md § Verification](../references/oversee-events.md#verification). Run the reconciliation again naming each, one `--merged` per pull request:

```bash
.agents/skills/orch/scripts/orch-runtime reconcile-items --merged [ITEM]=[OWNER/REPO]#[N]
```

The verb reads each named pull request's merge from GitHub and judges the item's boxes from the latest one. Take their due or overdue boxes through the same evidence and completion steps. Keep waiting and blocked boxes open. Where the item has no linked merged pull request, or the reply refuses a named read, report the item, its open boxes and the failed read. Do not repeat the watch's repository search.

Apply [SKILL.md § The Cycle](../SKILL.md#the-cycle), The overseer reads results, for acceptance and failed checks; it governs a scheduled session's reading too. Read the evidence `Where:` names. Never run `Where:` text as a command line.

**Completion.** Complete a proved box, a merged item and a container through the steps of [oversee-events.md § Verification](../references/oversee-events.md#verification): the evidence comment and file, `linear.sh issues complete` with the merge's `--post-merge-at`, `orch-runtime container-close` for a container, and the parent's close. Run them from the base checkout outside any confined lane: there `container-close` writes nothing and answers `container-close: left cause=confined owner=overseer`, the overseer's route owning the close.

## 2. Resolve missing evidence

When a box's deadline arrives with no evidence and no proved defect, read the item's comments for an earlier rewrite of this box. Keep the item Verifying throughout. A missing sample creates no fix item.

1. **First deadline: rewrite the box once.** Point `Where:` at readable evidence, or set `Trigger:` to the expected sample's UTC time and `Deadline:` within 72 hours of it. Keep the pass condition. Save the current full description under `tmp/` and write it back with no state option:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ITEM] --description-file [FILE]
   ```

   Comment `acceptance unverified: <cause>; check rewritten`, naming the box and its old and new check fields.

2. **Rewritten box past its deadline: decide.** Judge first whether the missing evidence matters. Where no outcome reserved to the owner turns on it, the decision is this session's own: record it on the item as a ruling, with its reason, and act on it under step 3. Where an owner-reserved outcome turns on it, send one owner ask on the item. Name each option with its practical consequence, give a recommendation, and offer: drop the check, keep waiting with a date, or keep waiting for an event the person names. Under an overseer, use [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks); with no overseer, use § 3's tracker route. Read the comments first, so a later pass reuses an open ask.

3. **Act on the decision**, and record the decision and the changed fields on the item:

   - **Drop.** Retire the box: write `[N]: [AUTHORITY]: [REASON]` to an evidence file, the authority being the owner's answer or this session's recorded ruling, then run `.agents/skills/linear/scripts/linear.sh issues complete [ITEM] --post-merge-at [MERGED_AT] --done-when-waived [N] --evidence-file [FILE]`, `[MERGED_AT]` read as the completion steps read it. The box keeps its text as `- Waived: …` with a `Reason:` line and is never ticked; the item reaches Done once every other box is met or retired.
   - **Keep waiting, with a date.** Set `Trigger:` to the date in UTC and `Deadline:` within 72 hours of it.
   - **Keep waiting, for an event.** Record the event as a blocker, the event's item assigned to the person who waits on it, and write no date: `.agents/skills/linear/scripts/linear.sh issues block [ITEM] --by [EVENT_ITEM]`. The box reads `blocked`, never overdue, while that blocker is open.

A later missing-sample deadline on the same box takes the same decision route, without another automatic rewrite. A deadline moves only through the one rewrite or a decision. A proved failed check follows § 1's acceptance rule.

## 3. Ask for a person's reading

With an overseer, follow [communication-modes.md § Owner-only verification](../references/communication-modes.md#owner-only-verification). With no overseer, keep that reader selection: an accessible tool reading belongs to this pass, and a delegate reading follows the delegate notice route. For an owner-only box, or § 2's ask, ask directly through the linear skill:

1. Read the item and its comments. Reuse an open verification ask for this box. Where another box has an open owner ask on the item, leave this box pending until that ask closes. Resolve `ORCH_OWNER_EMAIL`, falling back to `KENDEX_USER_EMAIL`, and `ORCH_OWNER_ASK_LABEL`. Report an unset owner or label as a blocked ask.

2. Keep the current labels. Assign the owner and add the owner-ask label:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ITEM] --assignee [OWNER_EMAIL] --labels [FULL_LABEL_SET]
   ```

   Post the question, naming the box, the check, `Where:` and the deadline:

   ```bash
   .agents/skills/linear/scripts/linear.sh comments create [ITEM] --body-file [FILE]
   ```

   Record which box the ask covers. Keep the item Verifying.

3. On the next pass, read the owner's one-comment answer after that ask, known by the owner's email. For a reading, apply the answer acceptance rule of [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks): an accepted reading passes the check, and a change request follows § 1's acceptance rule. For § 2's ask, act on the option chosen under § 2 step 3. An absent answer leaves the ask open.

4. Record the answer and the reading on the item before closing the ask, and complete a passing check under § 1's Completion. Read the labels fresh, remove only the owner-ask label, and clear the assignee:

   ```bash
   .agents/skills/linear/scripts/linear.sh issues update [ITEM] --labels [FULL_LABEL_SET] --clear-assignee
   ```

   Keep another open owner ask's assignment and label until that ask closes, as the watch's `../runtime/src/watch/tracker.rs::clear_owner_item` does.

## 4. Record the pass

Report the evidence comments, completed items, remaining boxes and blocked reads in the scheduler's run log or the overseer's report. Leave waiting and blocked boxes open. Name the open owner asks; the next pass reads their answers from the same items.
