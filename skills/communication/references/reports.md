# Reports and briefings

Read when writing a report or briefing. Use the wording and markup in [messages](messages.md).

## Reports

Say the outcome for the person or fleet, not the issue title. Link each work item to its owning tracker issue: the Linear issue for a Linear item or the GitHub issue for an `issue-N` item. Do not use its pull request or commit as the work-item link. The tracker issue links to its pull request.

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

- Put one item per line, at most 20 words. A line may carry two links.
- Put a blank line before each label. Each label stands alone: **Landed**, **Running**, **Blocked**, **Waiting on you**.
- Put each figure on its own line. Group account headroom after the opening outcome readings.
- Use at most `ORCH_REPORT_SUMMARY_LINES` item lines for an orch report, default 20. Blank lines, labels and the first opening line do not count. Leave excess items in the report file. Never pack a line to fit the cap.
- Use no table in an owner message.

## Owner summary template

Use this mrkdwn template for the report file's comment. For a post without a file, use standard Markdown under [References and markup](messages.md#references-and-markup).

```text
[DATE]: [REPOSITORY OUTCOME READING] (<SOURCE URL|SOURCE>)
[DATE]: [REPOSITORY OUTCOME READING] (<SOURCE URL|SOURCE>)

[ACCOUNT HEADROOM FIGURE]

*Landed*
- [OUTCOME] (<https://linear.app/vanillagreen/issue/KEY-N|KEY-N>)

*Running*
- [OUTCOME IN PROGRESS] (<https://linear.app/vanillagreen/issue/KEY-N|KEY-N>)

*Blocked*
- Nothing

*Waiting on you*
- Nothing
```
