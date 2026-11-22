# Design review

Read at a `lane-long` event, at each `heartbeat`, before a recurring fix delegation, before the overseer files a fix item, and before an overseer answer changes a running item's Requirements or Done-when. The lane builds the item's Done-when on the approved design. The overseer reads and directs.

## The lane-long counts

The [`lane-long`](oversee-events.md#lane-long) line and the `lane status` reply ([lane-reach.md § Lane states](lane-reach.md#lane-states)) carry the same five counts, each a string of digits or `unread`.

## Inputs and actions

**Before a proposed fix delegation.** Input: a matched class's `observed_count >= 2` in the reply of `orch-runtime state findings query`.

1. Read this route after disposition and the previous round's closure, and before `begin-round`, a prune or a delegation time.
2. Carry the same query reply, with its prior coverage and exact sources, in the lane's ask or status, the design ruling and the next delegation.
3. Reuse a ruling that covers those sources; a later source is new evidence.
4. A failed record or query, or coverage that reads unknown, takes the widened read below and stays unknown.
5. A count starts no pause, fix, validation retry or cap extension.

**Before an overseer answer narrows, widens or replaces a running item's Requirements or Done-when.**

1. Write a short table. Name each input class and each owner the changed requirement reaches, with each outcome on main, on the branch and under the proposed change.
2. Check the proposed answer against the table.
3. Post the table on the item before sending the answer.

**A `lane-long` line with `repeated_class_rounds >= 1` or `review_rounds >= 3`.**

1. Start the read and the brief in this pass.
2. A count alone starts no pause.

**`heartbeat`.** Input: for each `running` lane, `.agents/skills/orch/scripts/orch-runtime lane status --item [ITEM]`.

1. Apply the `lane-long` entry above to the reply's [five counts](#the-lane-long-counts).
2. Apply the next entry to an `unread` count or a refused read.
3. Skip an item whose latest `design-review` or `long-reason` ruling records the counts this read shows.
4. A `long-reason` ruling from this read names them as `rounds=[review_rounds] repeated=[repeated_class_rounds]`.
5. Where neither the counts nor the widened read shows a trigger, record nothing.

**A count is `unread`, or the read refused.**

1. Widen the read to the lane's `patched_causes`, with the command in [finding-disposition.md § Recurrence](../../reviewer/references/finding-disposition.md#recurrence), and to its pull request timeline under [oversee-events.md § Event kinds](oversee-events.md#event-kinds).
2. Start the review if that read shows the trigger facts.
3. A read that shows nothing takes the cause-naming step of the `lane-long` handler.
4. No missing record blocks or adds a wait.
5. A parked lane's stopped disk keeps that handler's rule.

**A repeated class whose cause lies outside the item's goal and can land apart.**

1. File it once to its owner, with the item linked, and take it out of the lane's fix set.
2. Work the goal needs continues in the lane.
3. At a round cap the overseer rules on this split; the cap never ends work the goal needs. The ruling names each separated item.

**Before filing a fix item.**

1. Select recent activity: fleet-log `ruling` rows whose text starts `filed `, and item `cycle` rows whose `at` falls in the last 24 hours.
2. For each selected item, read its `filed ` ruling from the fleet log, whatever its age, the archives under [workflow-state.md § Recording policy](../schemas/workflow-state.md#recording-policy) and [§ Prune](../schemas/workflow-state.md#prune) included.
3. Match the selected item to the filed item the ruling's text names. [File one item alone](oversee-events.md#file-one-item-alone) writes the filed item's Location files and defect-class rule into that ruling.
4. A prior filing or merged fix concerns the same mechanism when its ruling names a Location file in common and the same rule every site breaks. `cycle` rows supply timing only.
5. Run this review on that mechanism instead of filing a second patch item.
6. File the approved outcome and requirements through that route's `description` and `recommendation` fields.
7. Post the complete brief through the Record step below, and carry it in the lane directive before implementation.

**The read shows a stopped review of a plan or design document, as [oversee-events.md § End spirals](oversee-events.md#end-spirals) defines it.** Take that rule in place of the `long-reason` and patch-chain entries below.

**The read shows a legitimate cause: a large migration, a long validation or a real multi-round review.**

1. End the review with one `ruling` whose text starts `long-reason` and names the cause.
2. The lane continues.
3. Age or a round count alone never proves a patch chain.

**The read shows a patch chain.** The overseer decides to pause and records its reason, then applies § Patch-chain actions in order.

**Neither holds.**

1. Name the cause under the `lane-long` handler and record one `ruling` whose text starts `long-reason`.
2. Keep that handler's cause list and its Fix the source route.

## Patch-chain actions

1. **Brief.** Write one page in five parts: the item's Done-when; the defect class and its cause, as the rule every site breaks; the options, including cutting surface the Done-when does not require; the chosen design and what it deletes; what stays out of scope. Keep it in tracker or `tmp/` content.
2. **Pause.**
   - A local overseer may first run one one-shot `reviewer-arch` review through [oversee-events.md § Judgement rules](oversee-events.md#judgement-rules).
   - Send one directive carrying the completed brief and either that verdict or the Second opinion instruction below.
   - The directive tells every paused lane to finish the current round, start no further fix round, complete any requested Second opinion, then return the supplied or produced verdict for approval.
   - A mailbox lane puts that verdict in its single approval `lane-mail ask`, then runs `lane-mail wait` for the matching answer. That wait is the only mailbox wait this review adds.
   - A cloud session lane posts the verdict and the pause reason under `## Lane status` in its pull request body and ends its turn ([skill-rules.md § Lane mail](skill-rules.md#lane-mail)); the overseer reads that body.
   - Send the directive through [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane): `lane-mail send --directive` for a mailbox lane, `orch-runtime send` for a session lane.
   - With no current lane, take the filing entry above and carry the complete brief in its lane's directive before implementation.
3. **Second opinion.**
   - A lane whose directive carries the review instruction runs one one-shot `reviewer-arch` review, in its own lane per [SKILL.md § The Cycle](../SKILL.md#the-cycle) "Item work stays in lanes".
   - The overseer revises the brief once for the review's blockers.
   - A failed or empty review yields `second-opinion=unread`, and the overseer goes on without another review.
4. **Approve and resume.**
   - Answer a mailbox lane's ask with the approved brief through `lane-mail send --re`.
   - Send a cloud session lane the approved brief as its next directive.
   - The next round builds that design.
5. **Record.**
   - Post the brief as a tracker comment on the item.
   - Append one fleet-log `ruling` under [oversee-events.md § Judgement rules](oversee-events.md#judgement-rules). Its text starts `design-review rounds_before=[review_rounds] repeated=[repeated_class_rounds]` and names the brief, the pause reason, the second opinion, the overseer's decision and any separated item.
   - Write an `unread` count as `unread`.
