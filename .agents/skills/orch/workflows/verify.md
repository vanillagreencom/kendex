# Verify

Run one verification pass from the consumer's base checkout. A scheduler can start an agent session for `/orch verify` with no overseer or lane running. The package supplies no scheduler.

## 1. Read open checks

```bash
.agents/skills/orch/scripts/reconcile-work-items
```

Exit 1 carries findings and usable box lines. Exit 2 is a failed read: report its diagnostic. For each `due` or `overdue` line, read the item and its comments live. Also handle items with no open boxes through the completion route below. Report invalid boxes and unread merge evidence with their diagnostics.

Apply [oversee-events.md § Verification](../references/oversee-events.md#event-kinds) for evidence reading and completion. Apply [orch § The Cycle, The overseer reads results](../SKILL.md#the-cycle) for acceptance and failed checks. Those rules also govern a scheduled agent's reading. Read the evidence that `Where:` names. Never execute `Where:` text as a command line.

## 2. Resolve missing evidence

When the deadline arrives with no evidence and no proved defect, read the item's comments for an earlier rewrite of this box. Keep the item Verifying throughout this route. A missing sample creates no fix item.

- With no earlier rewrite, rewrite the box once. Point `Where:` to readable evidence, or set `Trigger:` to the expected sample's UTC time and `Deadline:` within 72 hours of that time. Preserve the pass condition. Save the current full description under `tmp/` and write it through `linear.sh issues update [ITEM] --description-file [FILE]`, with no state option. Comment `acceptance unverified: <cause>; check rewritten`, naming the box and its old and new check fields.
- If the rewritten box reaches its deadline without evidence, send one owner ask on the same item. Offer two options: drop the check, or keep waiting and give a date. Under an overseer, use [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks). With no overseer, use § 3's tracker route. Read existing comments before asking so a later pass reuses the open ask.
- On drop, comment the person's reason and use § 1's completion route to tick the box with that comment as evidence. On keep waiting, set `Trigger:` to the person's date in UTC and keep `Deadline:` within 72 hours of it. Record the answer and changed fields on the item. A later missing-sample deadline uses the same person's decision route, without another automatic rewrite.

A deadline moves only through that one rewrite or the person's dated answer. A proved failed check follows § 1's acceptance rule.

## 3. Ask for a person's reading

With an overseer, follow [communication-modes.md § Owner-only verification](../references/communication-modes.md#owner-only-verification). With no overseer, keep that reader selection. An accessible tool reading belongs to this pass. A delegate reading follows the delegate notice route. For an owner-only box, make the same ask directly through `linear.sh`:

1. Read the item and its comments. Reuse an open verification ask for this box. If another box has an open owner ask on the item, leave this box pending until that ask closes. Resolve `ORCH_OWNER_EMAIL`, falling back to `KENDEX_USER_EMAIL`, and `ORCH_OWNER_ASK_LABEL`. Report an unset owner or label as a blocked ask.
2. Preserve the current labels. Assign the owner and add the owner-ask label with `issues update [ITEM] --assignee [OWNER_EMAIL] --labels [FULL_LABEL_SET]`. Post the question with `comments create [ITEM] --body-file [FILE]`. Name the box, check, `Where:` and deadline. Record which box the ask covers. Keep the item Verifying.
3. On the next pass, read the owner's one-comment answer after that ask, identified by the owner's email. For a reading, `done` or `ok` passes the check. Treat any other text as a finding under § 1's acceptance rule. For § 2's decision, act on drop or a supplied waiting date. An absent answer leaves the ask open.
4. Record the answer and reading on the item before closing the ask. Apply § 1's completion route for a passing check. Remove only the owner-ask label from fresh labels and clear the assignee with `issues update [ITEM] --labels [FULL_LABEL_SET] --clear-assignee`. Keep another open owner ask's assignment and label until that ask closes, as mailbox's `../../mailbox/scripts/lib/mailbox-append.sh::owner_tracker_close` does.

## 4. Record the pass

Report the evidence comments, completed items, remaining boxes and blocked reads in the scheduler's run log or the overseer's report. Leave waiting and blocked boxes open. Name outstanding owner asks. The next pass reads their answers from the same items.
