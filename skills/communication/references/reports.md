# Reports and briefings

Read when writing a report, briefing, work-item description, comment or completion summary. Use the wording and markup in [messages](messages.md).

## Work story

Write a plain briefing as a chain of events. Open each area with good or bad, done or incomplete, and why. Then connect its goal, progress, completed work, remaining work, failures and the action taken. Use the person's words for the problem, its state and the outcome they experience.

State the goal as the outcome the person needs. Put the observed reading beside it. A measure alone is not the goal.

Work-item descriptions, comments and completion summaries use this story too. Apply the [visible comparison](questions.md#today-and-after). Keep technical detail on the tracker item.

A report names the author's own misses since the previous report. Give each miss its cause and the fix, or the reason no fix is needed.

## Reports

Say the outcome for the person or fleet. A project name or item title does not replace its effect. Link each work item to its owning tracker issue: the Linear issue for a Linear item or the GitHub issue for an `issue-N` item. Do not use its pull request or commit as the work-item link. The tracker issue links to its pull request.

Put detail in the report file. Send one post per report, not a thread of fragments. Give each blocked item its cause and next action.

## Report opening

Open with Overall in the [owner summary template](#owner-summary-template). Put the repository's outcome readings in Readings, each with its date, scope and source. Name the decision taken when the reading moved. Omit a reading when it has no change and no decision. Reuse existing evidence comments and rulings.

## Evidence

List completed work only after its acceptance check passes. Put a merge under Completed only after reading it from the source service in this session. An agent's notice that it is merging, or an approval, is not a landing.

## Waiting on you

Use **Waiting on you** in the template's order, with `Nothing` when empty. Read current open requests and the person's replies since the last report when writing it. Do not copy this section from a handoff. Keep a step here only when no available tool can do it.

Name each open ask by its question, so the person can find its thread. Link each unanswered decision. State what its deadline does and when, using the [person's time zone](messages.md#times). This section is never empty while an ask is open.

## Account headroom

Report headroom for every provider the fleet runs, including Claude, Codex and Copilot. Put one line per provider under Headroom Remaining, with its remaining percent and account count, for example `Codex: 27% (3 accounts)`.

## Summary shape

A consumer's user instruction that sets a report format for its reader overrides the shared format for that reader.

- Use the ten labels in the template's order: **Overall**, **What's going well**, **What's not going well**, **Readings**, **Completed**, **In-Progress**, **Blocked**, **Waiting on you**, **Headroom Remaining**, **Self-Analysis**. Name the reporting session in its Self-Analysis label. Labels may have a leading emoji code.
- Put a blank line between sections. A label may stand alone or introduce its section's prose. Separators and an italic Next report line are allowed.
- The first three sections use plain sentences with no engineering language. Overall uses one or two sentences. These prose lines have no 20-word limit.
- Put one item and one sentence per bullet line, at most 20 words. A line may carry two links. Use indented sub-bullets and third-tier bullets for detail, with each figure on its own sub-bullet. An italic Additional information line may explain a bullet.
- Use at most `ORCH_REPORT_SUMMARY_LINES` top-level bullet lines for an orch report, default 20. Prose, labels, blank lines, separators, sub-bullets, third-tier bullets and the Next report line do not count. Leave excess items in the report file. Never pack a line to fit the cap.
- Use no table in an owner message.

## Owner summary template

Jarvis and overseer reports use this shared summary shape. Use this mrkdwn template for the report file's comment. For a post without a file, use standard Markdown under [References and markup](messages.md#references-and-markup).

Use each section where it applies. Keep the general format and the section order.

| Section | Content |
|---|---|
| Overall | State what the work means for the person's goals and initiatives in one or two plain sentences. |
| What's going well | Say what helps the work in plain sentences. |
| What's not going well | Say what holds the work back in plain sentences. |
| Readings | Give each outcome reading a bullet, linked figures as sub-bullets, and a third-tier bullet when a figure needs explanation. |
| Completed | Give each completed item its linked tracker key and a human one-liner. |
| In-Progress | Use the same item format for current work; work without an item may use its name. |
| Blocked | Use the same item format and state the cause and next action. |
| Waiting on you | Name each open ask and add an italic Additional information line when needed. |
| Headroom Remaining | Give each provider one line with its remaining percent and account count. |
| Self-Analysis | Name the reporting session and give Good and Bad one-liners about its own conduct, with an italic line stating the action on each failure or why nothing is needed. |

The first three sections use plain words with no engineering language.

```text
*Overall:* [WHAT THE WORK MEANS FOR THE PERSON'S GOALS]

*What's going well:* [WHAT HELPS THE WORK]

*What's not going well:* [WHAT HOLDS THE WORK BACK]

----

:book: *Readings:*
- [OUTCOME READING]
  - [DATE], [SCOPE]: [FIGURE] (<SOURCE URL|SOURCE>)
    - [EXPLANATION OF THE FIGURE]
  _Additional information: [WHAT THE PERSON NEEDS TO KNOW]_

:large_green_square: *Completed:*
- [HUMAN OUTCOME] (<TRACKER_ISSUE_URL|KEY-N>)

:large_yellow_square: *In-Progress:*
- [HUMAN OUTCOME IN PROGRESS] (<TRACKER_ISSUE_URL|KEY-N>)

:large_red_square: *Blocked:*
- Nothing

----

:clock1: *Waiting on you:*
- Nothing
  _Additional information: [DETAIL FOR AN OPEN ASK]_

:moneybag: *Headroom Remaining:*
[PROVIDER]: [PERCENT]% ([COUNT] accounts)

:robot_face: *[SESSION NAME] Self-Analysis:*
- Good: [WHAT THE SESSION DID WELL]
- Bad: [THE SESSION'S MISS]
  _[ACTION ON THE FAILURE, OR WHY NOTHING IS NEEDED]_

----

_Next report: [TIME]_
```
