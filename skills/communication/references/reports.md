# Reports and briefings

Read when writing a report, briefing, work-item description, comment or completion summary. Use the wording and markup in [messages](messages.md).

## Work story

Write a plain briefing as a chain of events. Open each area with good or bad, done or incomplete, and why. Then connect its goal, progress, completed work, remaining work, failures and the action taken. Use the person's words for the problem, its state and the outcome they experience.

State the goal as the outcome the person needs. Put the observed reading beside it. A measure alone is not the goal.

Apply the [visible comparison](questions.md#today-and-after). Keep technical detail on the tracker item.

A report names the author's own misses since the previous report. Give each miss its cause and the fix, or the reason no fix is needed.

## Reports

Say the outcome for the person or fleet. A project name or item title does not replace its effect. Link each work item to its owning tracker issue: the Linear issue for a Linear item or the GitHub issue for an `issue-N` item. Do not use its pull request or commit as the work-item link. The tracker issue links to its pull request.

Put detail in the report file. Send one post per report, not a thread of fragments. Give each blocked item its cause and next action.

## Report opening

Open with Overall in the [summary template](#summary-template). Put the outcome readings in Numbers before Completed, each with its date, scope and source. Name the decision taken when a reading moved. Keep the required Numbers readings below; omit an additional reading only when it has no change and no decision. Reuse existing evidence comments and rulings.

## Numbers

Jarvis and overseer progress reports include the readings below.

For Issues merged, Issues created, Issues verified and Issues cancelled, use the window since the actual previous progress report's coverage cutoff through this report's cutoff. Read that previous report; a planned report time is not its cutoff. State the period and time zone. An unread previous report leaves the period unknown.

Cover all Linear teams, including issues without a project. Name the source and the teams covered or unread. Count each unique Linear issue identity once per category within that window, even if it has several pull requests or repeated events. Categories may overlap. Keep partial counts labelled with their covered scope; missing evidence is unknown, never zero.

- **Issues merged:** Issues whose linked work actually merged in the window, using source-service merge times and the issue links.
- **Issues created:** Issues whose source creation time falls in the window.
- **Issues verified:** Issues whose required acceptance checks passed in the window, using dated acceptance evidence.
- **Issues cancelled:** Issues whose activity records a transition to cancelled in the window.

An issue's `updated_at`, current Done state or pull-request total proves none of these events. A merge alone does not prove verification. If event evidence cannot be read, state which category and coverage remain unread.

Also report these current readings, with their observation time and source:

- **Post-merge checks waiting:** Count unfinished required checks by Linear team and repository. Give each group's useful age or blocked-check detail, cause and action.
- **Active workers:** Count actual working sessions or jobs per repository. Use current session/job evidence; powered-on computers, open issues and old lane records are not workers. State unread repositories explicitly.
- **Workers past3.5hours:** Link each issue whose current worker run exceeds 3.5 hours. Give that run's actual hours, cause and action. Keep issue creation age and legacy lane age separate from current-run duration; an unread start time leaves duration unknown.

Retain other useful outcome readings with their source, period, meaning and action under [Evidence and costs](messages.md#evidence-and-costs).

## Issues created

Place Issues created immediately after Blocked, before Waiting on you. Use Completed's linked-issue bullet style. Cover the same window and issue identities as the Numbers count. State each issue's problem, user impact and owner. Keep any partial coverage or unread period explicit.

## Evidence

List completed work only after its acceptance check passes. Put a merge under Completed only after reading it from the source service in this session. An agent's notice that it is merging, or an approval, is not a landing.

## Waiting on you

Use **Waiting on you** in the template's order, with `Nothing` when empty. Read current open requests and the person's replies since the last report when writing it. Do not copy this section from a handoff. Keep a step here only when no available tool can do it.

Name each open ask by its question, so the person can find its thread. Link each unanswered decision. State what its deadline does and when, using the [person's time zone](messages.md#times). This section is never empty while an ask is open.

## Account headroom

Report headroom for every harness the consumer runs. Put one line per provider under Headroom remaining, with its remaining percent and account count.

## Summary shape

A consumer's user instruction that sets a report format for its reader overrides the shared format for that reader.

Jarvis and overseer reports follow the [summary template](#summary-template), including its quote opening, full code-block headers, opening bold bracketed linked item ids, bold bullet labels, plain italic section notes and inline Next report line. Name the reporting session in the last section. Use no emoji, dividers or spacer lines. Ordinary Slack messages follow [Slack messages](messages.md#slack-messages).

- The first three sections use plain sentences with no engineering language. Overall uses one or two sentences. These prose lines have no 20-word limit.
- Put one item and one sentence per bullet line, at most 20 words. Use indented sub-bullets and third-tier bullets for detail, with each figure on its own sub-bullet. Italicize parenthetical text, including its parentheses.
- Keep top-level bullet lines within the caller's line cap. Prose, headers, blank lines, sub-bullets, third-tier bullets and the Next report line do not count. Leave excess items in the report file. Never pack a line to fit the cap.
- Use no table in a message to a person.

## Summary template

Jarvis and overseer reports use this shared summary shape. Use this mrkdwn template for the report file's comment. For a post without a file, use standard Markdown under [References and markup](messages.md#references-and-markup).

Use each section where it applies. Keep the general format and the section order.

Give Overall, What's going well and What's not going well separate quote blocks, with an unquoted blank line between them in both forms. Apply the [work story](#work-story) to each What's not going well problem: state the action taken, or that nothing is being done and why. Use the [Numbers](#numbers) evidence and [Issues created](#issues-created) window below. For standard Markdown, use this opening and convert the remaining mrkdwn example under [References and markup](messages.md#references-and-markup):

```markdown
> **Overall:** [Overall outcome.]

> **What's going well:** [Progress and its effect.]

> **What's not going well:** [Each problem and action taken, or no action and why.]
```

The figures and items below are fictitious examples, not readings. Use each section where it applies, in this order. Replace Jarvis with the reporting session's name.

````text
> *Overall:* CI work is ahead of plan this week, and lanes now finish within the day. Account room is the one risk until Saturday's resets.

> *What's going well:* Merges reach main within an hour of review. The new lane order spends prepaid credit before it expires.

> *What's not going well:* Two workers have spent over 3.5 hours on unfinished checks; I addressed their failures. Finished work still waits a day for acceptance; I started checking the oldest today.

```
Numbers
```

_Issue events: previous report cutoff 9 am to 1 pm today, Pacific; all Linear teams covered, including issues without a project._

_Sources: Linear creation/activity records, linked service merge times and dated acceptance checks; counts use unique issue identities._

- *Issues merged:* 3 since the previous report; their changes are available.
- *Issues created:* 1 since the previous report; its problem and owner appear below.
- *Issues verified:* 2 since the previous report; their required acceptance checks passed.
- *Issues cancelled:* 1 since the previous report; its owner confirmed the work was no longer needed.
- *Post-merge checks waiting:* Acceptance is late; I started with the oldest:
    - KEN / kendex: 90 unfinished checks _(median 35 h)_; repeated test failures block acceptance; I inspected the oldest failure.
    - FLT / fleet: 10 unfinished checks; their prerequisite is incomplete; I asked its owner for the next action.
- *Active workers:* Current job records show 3 working sessions at 1 pm; acceptance work is running:
    - kendex: 2 workers running checks.
    - fleet: 1 worker repairing a failed check.
- *Workers past3.5hours:* 2 current runs exceed 3.5 hours at 1 pm; I addressed their causes:
    - *<https://linear.app/vanillagreen/issue/KEN-0002|[KEN-0002]>* _(4.2 h this run)_: Check setup blocks acceptance; I supplied the missing decision.
    - *<https://linear.app/vanillagreen/issue/FLT-0003|[FLT-0003]>* _(3.8 h this run)_: Repeated failures delay delivery; I narrowed its failing checks.

_Waiting-check counts and ages come from current acceptance records at 1 pm Pacific; worker durations come from current job starts._

_*<https://linear.app/vanillagreen/issue/KEN-0001|[KEN-0001]>* cuts the check time; I read it after it merges._

```
Completed
```

- *<https://linear.app/vanillagreen/issue/VGS-0004|[VGS-0004]>* Test windows no longer reset your idle timer
- *<https://linear.app/vanillagreen/issue/KEN-0005|[KEN-0005]>* Lanes warn before a prepaid grant runs out
- *<https://linear.app/vanillagreen/issue/HT-0006|[HT-0006]>* A file only tests read runs only those tests

```
In progress
```

- *<https://linear.app/vanillagreen/issue/VGS-0007|[VGS-0007]>* Power settings pane with the idle timeline
- *<https://linear.app/vanillagreen/issue/KEN-0008|[KEN-0008]>* Overseer restarts when its plan ends
- Moving four overseers to the account with the most room

```
Blocked
```

- *<https://linear.app/vanillagreen/issue/FLT-0009|[FLT-0009]>* Waits for its prerequisite

_It launches when *<https://linear.app/vanillagreen/issue/KEN-0008|[KEN-0008]>* merges._

```
Issues created
```

- *<https://linear.app/vanillagreen/issue/FLT-0011|[FLT-0011]>* Missing test results delay acceptance; fleet's overseer owns restoring them.

_One issue created from 9 am to 1 pm today, Pacific, matching Numbers._

```
Waiting on you
```

- *<https://linear.app/vanillagreen/issue/VG-0010|[VG-0010]>* Certified-mail receipt number for the Forms 8606

_Due by mail on Oct 23._

```
Headroom remaining
```

- *Claude:* 52% _(3 accounts)_
- *Codex:* 58% _(3 accounts)_
- *Copilot:* 9% _(1 account)_

_ai10 reaches its limit before Saturday; its overseers move first._

```
Jarvis self-analysis
```

- *Good:* Found the overseer outage cause within 30 minutes
- *Bad:* Missed two stopped overseers for 11 hours

_*<https://linear.app/vanillagreen/issue/KEN-0008|[KEN-0008]>* restarts a stopped overseer on its own._

`Next report: 1 pm`
````
