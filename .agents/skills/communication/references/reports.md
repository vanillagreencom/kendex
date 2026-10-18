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

Open with the repository's outcome readings, each with its date and source. Reuse existing evidence comments and rulings. Do not open with a Landed count.

## Evidence

List completed work only after its acceptance check passes. Put a merge under Landed only after reading it from the source service in this session. An agent's notice that it is merging, or an approval, is not a landing.

## Waiting on you

End with **Waiting on you**, with `Nothing` when empty. Read current open requests and the person's replies since the last report when writing it. Do not copy this section from a handoff. Keep a step here only when no available tool can do it.

Name each open ask by its question, so the person can find its thread. Link each unanswered decision. State what its deadline does and when, using the [person's time zone](messages.md#times). This section is never empty while an ask is open.

## Account headroom

Report account headroom for every harness the fleet runs, including Claude, Codex and Copilot, side by side.

## Summary shape

A consumer's user instruction that sets a report format for its reader overrides the shared format for that reader.

- Put one item and one sentence per line, at most 20 words. A line may carry two links.
- Put a blank line before each label. Each label stands alone: **Landed**, **Running**, **Blocked**, **Waiting on you**.
- Put each figure on its own line. Group account headroom after the opening outcome readings.
- Use at most `ORCH_REPORT_SUMMARY_LINES` item lines for an orch report, default 20. Blank lines, labels and the first opening line do not count. Leave excess items in the report file. Never pack a line to fit the cap.
- Use no table in an owner message.

## Owner summary template

Jarvis and overseer reports use this shared summary shape. Use this mrkdwn template for the report file's comment. For a post without a file, use standard Markdown under [References and markup](messages.md#references-and-markup).

```text
[DATE]: [REPOSITORY OUTCOME READING] (<SOURCE URL|SOURCE>)
[DATE]: [REPOSITORY OUTCOME READING] (<SOURCE URL|SOURCE>)

[ACCOUNT HEADROOM FIGURE]

*Landed*
- [OUTCOME] (<TRACKER_ISSUE_URL|KEY-N>)

*Running*
- [OUTCOME IN PROGRESS] (<TRACKER_ISSUE_URL|KEY-N>)

*Blocked*
- Nothing

*Waiting on you*
- Nothing
```
