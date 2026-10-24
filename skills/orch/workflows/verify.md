# Verify

Run one verification pass from the consumer's base checkout. A scheduler can start an agent session for `/orch verify` with no overseer or lane running. The package supplies no scheduler.

## 1. Read open checks

```bash
.agents/skills/orch/scripts/reconcile-work-items
```

Exit 1 carries findings and usable box lines. Exit 2 is a failed read: report its diagnostic. Keep the box lines supplied by the invoking watch event or heartbeat, including boxes that reconciliation omits. For each `due` or `overdue` box from either source, read the item and its comments live. Read each box once in this pass. Also handle items with no open boxes through the completion route below. Report invalid boxes with their diagnostics.

For each `verifying-merge-unread` item without usable watch box lines, read the item's linked merged pull requests live in their own repositories. Use the linked-PR read in [oversee-events.md § Verification](../references/oversee-events.md#event-kinds), also requesting `mergeCommit` for release checks. Load the checklist library as [reconcile-work-items](../scripts/reconcile-work-items) does. Read and use `verifying_parse` and `verifying_judge` in [verifying.sh](../scripts/lib/verifying.sh) with their existing argument contracts. Supply the live item, the latest linked merge time, each repository's linked merge evidence and the current time. These helpers own box parsing, release checks and deadline status. Apply the same evidence and completion route below to their due or overdue boxes. Keep waiting and blocked boxes open. If linked merge evidence is absent or unreadable, report the item, its open boxes and the failed read. Do not repeat the watch's repository search.

Apply [oversee-events.md § Verification](../references/oversee-events.md#event-kinds) for evidence reading and completion. Apply [orch § The Cycle, The overseer reads results](../SKILL.md#the-cycle) for acceptance and failed checks. Those rules also govern a scheduled agent's reading. Read the evidence that `Where:` names. Never execute `Where:` text as a command line.

## 2. Resolve missing evidence

When the deadline arrives with no evidence and no proved defect, read the item's comments for an earlier rewrite of this box. Keep the item Verifying throughout this route. A missing sample creates no fix item.

- With no earlier rewrite, rewrite the box once. Point `Where:` to readable evidence, or set `Trigger:` to the expected sample's UTC time and `Deadline:` within 72 hours of that time. Preserve the pass condition. Save the current full description under `tmp/` and write it through `linear.sh issues update [ITEM] --description-file [FILE]`, with no state option. Use § 4’s observation form and retain the searchable line `acceptance unverified: <cause>; check rewritten`, naming the box and its exact old and new check fields. Preserve failed and missing-evidence history; this layout grants no additional rewrite.
- If the rewritten box reaches its deadline without evidence, send one owner ask on the same item. Offer two options: drop the check, or keep waiting and give a date. Under an overseer, use [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks). With no overseer, use § 3's tracker route. Read existing comments before asking so a later pass reuses the open ask.
- On drop, comment the person's reason and use § 1's completion route to tick the box with that comment as evidence. On keep waiting, set `Trigger:` to the person's date in UTC and keep `Deadline:` within 72 hours of it. Record the answer, source ask link and exact changed fields on the item using § 4’s Decision and Next fields. A later missing-sample deadline uses the same person's decision route, without another automatic rewrite.

A deadline moves only through that one rewrite or the person's dated answer. A proved failed check follows § 1's acceptance rule.

## 3. Ask for a person's reading

With an overseer, follow [communication-modes.md § Owner-only verification](../references/communication-modes.md#owner-only-verification). With no overseer, keep that reader selection. An accessible tool reading belongs to this pass. A delegate reading follows the delegate notice route. For an owner-only box, make the same ask directly through `linear.sh`:

1. Read the item and its comments. Reuse an open verification ask for this box. If another box has an open owner ask on the item, leave this box pending until that ask closes. Resolve `ORCH_OWNER_EMAIL`, falling back to `KENDEX_USER_EMAIL`, and `ORCH_OWNER_ASK_LABEL`. Report an unset owner or label as a blocked ask.
2. Preserve the current labels. Assign the owner and add the owner-ask label with `issues update [ITEM] --assignee [OWNER_EMAIL] --labels [FULL_LABEL_SET]`. Post the question with `comments create [ITEM] --body-file [FILE]`. Start with the decision or reading needed using communication’s questions form. Name the box, check, `Where:` and deadline. Record which box the ask covers. Keep the item Verifying.
3. On the next pass, read the owner's one-comment answer after that ask, identified by the owner's email. For a reading, apply the answer acceptance rule in [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks). An accepted reading passes the check. Act on a change request under § 1's acceptance rule. For § 2's decision, act on drop or a supplied waiting date. An absent answer leaves the ask open.
4. Record the answer and reading on the item before closing the ask. Apply § 1's completion route for a passing check. Remove only the owner-ask label from fresh labels and clear the assignee with `issues update [ITEM] --labels [FULL_LABEL_SET] --clear-assignee`. Keep another open owner ask's assignment and label until that ask closes, as mailbox's `../../mailbox/scripts/lib/mailbox-append.sh::owner_tracker_close` does.

## 4. Record the pass

Post an outcome-first observation comment on the item after reading its boxes, earlier comments and evidence. Use the form below for each box read; it records observations rather than adding a second checklist. Omit empty optional fields, retain unread evidence and keep any failed or waiting result open under the existing acceptance rule.

```markdown
[The observed result and its consequence.]

## Verification

**Reader**: [PERSON_OR_AGENT_AND_ANY_DELEGATED_AUTHORITY]

**Observed at**: [OBSERVATION_DATE_AND_TIME]

### Box [N]

**Result**: [pass | fail | unread | waiting] — [ACTUAL_OBSERVATION]

**Evidence**: [SOURCE_LINK, ARTIFACT_REVISION_AND_CONDITIONS_OR_MATCHED_SAMPLE; MEASURE_BESIDE_TARGET_AND_BEFORE_AFTER; MISSING_OR_UNREAD_EVIDENCE_EXPLICIT]

**Decision**: [WHAT_THE_READER_ACCEPTED_REJECTED_OR_KEPT_OPEN_AND_WHY; SOURCE_ASK_LINK_IF_APPLICABLE]

**Next**: [WHO_ACTS_WHAT_THEY_DO_AND_THE_EXISTING_DEADLINE_OR_TRIGGER_IF_WORK_REMAINS]
```

A delegate reading begins `Delegate checks (DATE): [result and effect]`, then keeps the same Reader, observation and per-box field order. Identify whose reading or ruling it is. A historical box without parsed Post-merge fields gains no watch trigger from the comment. `Where:` stays an evidence address, never shell text. Preserve the supported trigger and deadline grammar; this form adds no event trigger, firing record or deadline policy.

For a missing-evidence rewrite, include the searchable line and exact old/new fields required by § 2 beneath the affected box. For a later owner decision, link the ask and record the answer and field changes. Keep the original evidence comment as the proof source for the completion command’s `N: text` binding.

Report the evidence comments, completed items, remaining boxes and blocked reads in the scheduler's run log or the overseer's report. Leave waiting and blocked boxes open. Name outstanding owner asks. The next pass reads their answers from the same items.
