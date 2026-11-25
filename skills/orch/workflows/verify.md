# Verify

Run one verification pass over the items in Verifying, from the consumer's base checkout. A scheduler can start an agent session for `/orch verify` with no overseer or lane running. The package supplies no scheduler.

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
- Read the evidence `Where:` names or follow **Reading lanes** when it names that reader. Never run `Where:` text as a command line.

### Reading lanes

When an open post-merge box is `due` or `overdue` and its live `Where:` starts with `reading lane at `, use this route before the missing-evidence steps. A container outcome or an outside-authored GitHub item reported as `verifying-unjudged` stays on its existing route.

On `idle-after-return` or a recovery event for an existing reading lane, take steps 2 and 5 even if the box has closed or its `Where:` has changed. Only the due or overdue reading-lane route can start a worker.

1. Use `verify-[ITEM]-box-[N]` as the lane key for a Linear item. For GitHub use `verify-gh-[REPO_HASH]-[ISSUE_NUMBER]-box-[N]`, where `REPO_HASH` is `git hash-object --stdin` over the lowercase `OWNER/REPO` with no trailing newline. Use the live checklist's box number and keep its slot through rewrites. The original item's development lane has its own key and record.
2. The overseer owns the start where one is running. Otherwise, the scheduled pass owns it. The launch owner handles one pass at a time. Before sending a launch or handling an event for a reading lane, read the original item's live comments and `orch-runtime state inspect --fleet` for the same key, including `result.open_intents` and `result.state.lanes` at every status. Initialize an absent fleet record through [oversee.md § Controller start and adoption](oversee.md#controller-start-and-adoption) step 1. An unread source leaves the launch blocked.
   - A reading lane's result for this box holds the start even after fleet pruning. This includes a comment that identifies an earlier reading lane for the same box. Take its result through step 5.
   - A matching launch intent or lane record also holds the start. Reconcile an open launch with its original request. Retry under the same key only after resolving a refusal or failed effect and proving the worker never started. An unresolved start stays pending.
   - Where the live comments show no result, keep the worker pending until you confirm it started and then ended or became unusable. An idle screen alone leaves it pending. The watch can continue the same reachable worker once after a provider error or output limit, using its original box and brief. After a confirmed end or loss of use, post an unread result in step 4's form with the cause and take it through step 5.
3. Choose a local terminal or provider-backed terminal placement and its account under [lane-launch.md § Lane directive](../references/lane-launch.md#lane-directive). Exclude `claude-cloud`. A standalone hosted pass uses the terminal launch in [handoff.md § 2](handoff.md#2-launch). Before launching, confirm the chosen worker can reach the authorized evidence at the named revision and post to the original item from that placement, including under any confinement. Report a blocked launch with the cause if no compatible placement or evidence route is confirmed. Leave the box open without recording a reading result.
4. Send one `launch-lane` request with the reading lane key as `item` and as the local worktree key where required. For a GitHub item set `repo` to the original item's `OWNER/REPO`. Omit `tracker`. Set `read_only: true` where [the read-only launch contract](../references/lane-directive.md#a-read-only-launch) admits it. Put the original tracker item, box number, `Post-merge:`, `Where:` and `Why after merge:` text, merge revision and deadline in `brief_file`. Copy the check fields as plain text, preserving their values and dropping Markdown code delimiters so evidence paths make no write claims. The brief tells the lane to perform that reading only, use scratch for its output, and leave code, commits, pull requests, and the item's state and checklist to their owners. Tell the lane to post the artifact or its durable link on the original item in the [verification comment](../references/oversee-events.md#verification-comment) form, with `Reading lane: [LANE_KEY]` under `### Box [N]`. If the reading cannot be made, post an unread result with the cause in that form. Use the existing verification comment route for a GitHub item. Report a launch as started only when its effect confirms the worker started.
5. Read the result and its artifact on the original item. Close any still-open reading lane through `close-owned-resources` using its reading key and `ended.source` set to the result comment URL, even if the box has since closed. For open boxes, apply **Completion** to a proved box. A failed check follows this section's acceptance rules. An inconclusive result follows § 2 at the deadline. Keep a pending reading open even after its deadline passes.

**Completion.**

- Complete a proved box, a merged item and a container through the steps of [oversee-events.md § Verification](../references/oversee-events.md#verification): the evidence comment and file, `linear.sh issues complete` with the merge's `--post-merge-at`, `orch-runtime container-close` for a container, and the parent's close.
- A GitHub item, `[OWNER/REPO]#[N]`, takes that section's GitHub form in their place.
- Run them from the base checkout, outside any confined lane. In a confined lane `container-close` writes nothing; the overseer's route owns the close.

## 2. Resolve missing evidence

A GitHub item's writes below take the form [oversee-events.md § Verification](../references/oversee-events.md#verification) gives them.

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
     - For a GitHub item, `[OWNER/REPO]#[N]`, use the [GitHub owner ask form in oversee-events.md § Verification](../references/oversee-events.md#github-owner-asks). For a Linear item, use § 3.

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

- Select the reader through [communication-modes.md § Owner-only verification](../references/communication-modes.md#owner-only-verification). With no overseer, this pass takes an accessible tool reading and a delegate reading follows the delegate notice route.
- For an owner-only reading or § 2's ask on a GitHub item, `[OWNER/REPO]#[N]`, use the [GitHub owner ask form in oversee-events.md § Verification](../references/oversee-events.md#github-owner-asks).
- With an overseer, read the Linear item's comments first and reuse an open ask for this box. A new ask follows [communication-modes.md § Owner asks](../references/communication-modes.md#owner-asks).

For a Linear owner-only box or § 2's ask with no overseer, ask directly through the linear skill:

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
