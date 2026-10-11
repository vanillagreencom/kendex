# Design review

Read at a `lane-long` event and before the overseer files a fix item. The outcome is a patch chain closed at its cause, with the lane building the item's Done-when. The overseer reads and directs; it implements nothing.

## Inputs and actions

| Input | Action |
|-------|--------|
| `lane-long` line: `repeated_class_rounds >= 1` or `review_rounds >= 3` | Start the read and brief in this pass. A count starts no pause by itself. |
| A count is `-`, `unread`, missing or unreadable | Widen the read to the lane's `patched_causes`, using the command in [Finding disposition § Recurrence](finding-disposition.md#recurrence), and its pull request timeline under [Oversee events § Event kinds](oversee-events.md#event-kinds). Start the review if that read shows the trigger facts. A read that shows nothing takes the existing cause-naming step. No missing record blocks or adds a wait. Keep that handler's rule for a parked lane's stopped disk. |
| Before filing a fix item | Read the fleet log's `filed` and `cycle` rows whose `at` falls in the last 24 hours. A prior fix to the same mechanism means a Location file in common and the same cause, stated as the rule every site breaks. Run this review on that mechanism instead of filing a second patch item. Use the brief as the item's body through [File one item alone](oversee-events.md#judgement-rules). |
| Read shows a legitimate cause: a large migration, long validation or a real multi-round review | End the review with one `ruling` whose text starts `long-reason` and names the cause. The lane continues. Age or round count alone never proves a patch chain. |
| Read shows a patch chain | The overseer decides to pause and records its reason. Apply the actions below in order. |
| Neither trigger holds | Name the cause under the existing `lane-long` handler. Record one `ruling` whose text starts `long-reason`. Keep its cause list and Fix the source route. |

## Patch-chain actions

| Step | Action |
|------|--------|
| Pause | Send one `lane-mail send --directive`: finish the current round, start no further fix round, then `lane-mail ask` and `lane-mail wait` for the answer. That existing wait is the only wait this review adds. A Claude cloud lane has no mailbox; send the directive through its session channel under [oversee.md § 3](../workflows/oversee.md#3-launch). With no current lane, put the brief in the item's body and direct its lane before implementation. |
| Brief | Write one page with five parts: the item's Done-when; the defect class and cause as the rule every site breaks; options, including cutting surface the Done-when does not require; the chosen design and what it deletes; what stays out of scope. Keep it in tracker or `tmp/` content. |
| Second opinion | Request one one-shot `reviewer-arch` review of the brief. Under [SKILL.md § The Cycle, Item work stays in lanes](../SKILL.md#the-cycle), a hosted overseer sends the brief to the paused lane, which runs the reviewer and returns its verdict in `lane-mail ask`. A local overseer may launch the reviewer through the one-shot subagent route in [Oversee events § Judgement rules](oversee-events.md#judgement-rules). Revise once for its blockers. A failed or empty review is recorded as `second-opinion=unread`; it does not hold the lane. |
| Approve and resume | The overseer answers the lane's ask with the approved brief through `lane-mail send --re`. For a cloud lane, send the brief as the next session directive. The next round builds that design. Record `recurrence: structural-close` on each item it closes, per [Finding disposition § Recurrence](finding-disposition.md#recurrence), for `dev-round-write` to accept. |
| Record | Post the brief as a tracker comment on the item. Append one fleet-log `ruling` under [Oversee events § Judgement rules](oversee-events.md#judgement-rules). Its text starts `design-review rounds_before=[review_rounds] repeated=[repeated_class_rounds]` and names the brief, the pause reason, the second opinion and the overseer's decision. Preserve missing counts as unread. |

A `lane-long` event with neither a `design-review` nor a `long-reason` ruling for its item is a finding for the owner's audit. The missing row identifies it. No gate reads it.
