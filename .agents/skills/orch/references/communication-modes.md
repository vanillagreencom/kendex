# Communication modes

`ORCH_USER_MODE` names who an orch session is talking to. This file owns the ask set and the wording of the questions in it; nothing outside it narrows or widens that set, and a gate citing it states neither.

```bash
.agents/skills/orch/scripts/orch-env ORCH_USER_MODE ceo
```

| Value | Meaning |
|-------|---------|
| `ceo` | The session owns every technical decision. The user states intent and outcomes. Only a question in § Ask set reaches the user, worded as § The ceo question template requires |
| `engineer` | The package's original behaviour: the same ask set, worded as § The engineer question template requires |

## Standing rulings

| Ruling | What it means for a session |
|--------|------------------------------|
| Technical decisions belong to the session | The user is told the outcome, never asked to pick a mechanism |
| The user is informed at a high level | A decision report names the outcome and its cost, not the parts that produced it |
| A question is asked only where § Ask set puts it | Everything else is decided and recorded per § Recording |
| A question is framed as outcomes | Each path carries its gain, its cost and its odds, per path, in the template below |

## Ask set

These questions reach the user in both modes. Nothing else does.

| Question | Reached by |
|----------|-----------|
| Scope expansion beyond the issue | Work the issue's Done-when does not carry |
| Revisiting a recorded decision | A change that contradicts a decision record |
| A destructive action | Deleting or discarding work that is not recoverable from the tracker or git |
| A change to user experience, workflow, outcome, cost or risk | A product question a finding or a lane raises |
| An action spending the owner's standing outside this repository | A lane's question about filing or commenting in another repository's tracker, or about retiring a reviewer |

A gate also asks where its own autonomy key is set to `ask`: `ORCH_MERGE_AUTONOMY` for merge consent, `PM_CREATE_AUTONOMY` for the audit's creations and every row of its Cancel section, `ORCH_DECISION_MODE` for the post-PR choices. Which gate asks is that key's answer. Under a composed `auto` those creations and cancellations are recorded per § Recording rather than asked. Overseer heartbeat audits instead use [Heartbeat audit](heartbeat-audit.md)'s authorization limits in both modes. Other audits ask under their own key alone, so a composed `auto` covers their filings wherever their tracker resolves, and the row above is a lane's question.

## Composition

Under `ceo` a composed key the settings ladder leaves unset takes the value below instead of its caller default. A key the ladder sets wins in both modes. `scripts/orch-env` decides this; no workflow re-derives it.

| Key | Value under `ceo` when the ladder sets none |
|-----|---------------------------------------------|
| `ORCH_DECISION_MODE` | `auto-recommended` |
| `ORCH_MERGE_AUTONOMY` | `auto` |
| `PM_CREATE_AUTONOMY` | `auto` |

Under `engineer` every key keeps its own default, listed in [README.md](../README.md) § Settings.

## The ceo question template

```text
[WHAT THIS CHANGES FOR THE USER, ONE SENTENCE]

A. [OUTCOME OF THE FIRST PATH]
   Gains: [WHAT THE USER GETS]
   Costs: [WHAT THE USER GIVES UP]
   Odds: [HOW LIKELY THAT COST IS]
B. [OUTCOME OF THE SECOND PATH]
   Gains: [WHAT THE USER GETS]
   Costs: [WHAT THE USER GIVES UP]
   Odds: [HOW LIKELY THAT COST IS]

Recommended: [A OR B], because [ONE SENTENCE IN OUTCOME TERMS].
```

The template carries outcomes only. A question in the set names no mechanism the user does not act on, and no option by its internal name. A gate outside the set keeps its own option list under both modes and asks only where its autonomy key is set to `ask`.

## The engineer question template

```text
[QUESTION]: [OPTION_A] | [OPTION_B], with [RECOMMENDED_OPTION] recommended.
```

## Owner asks

An overseer's question to the owner is one owner ask: the template above for the mode, written to a file, sent with its form and its deadline as fields, never as prose. The template's recommendation is the option the ask records as `recommend`, the relay's Recommended line, and a question whose ask records none leaves it out. The chat shows one line naming the ask. `--wait` names one ask's minutes, and an ask without it takes `ORCH_ASK_WAIT_MINUTES`. Which forms record a recommendation, and what the deadline does for each, is the [lane-mail owner-channel contract](../scripts/lane-mail)'s.

```bash
.agents/skills/orch/scripts/lane-mail ask --item overseer --to owner --options [OPTION_A],[OPTION_B] --recommend [RECOMMENDED_OPTION] --file [PATH]
```

The owner can answer more than once. Each answer lands through `send --item overseer --re [ASK_ID] --file [PATH]`, with its own delivery id. Answers leave the ask open in `pending --item overseer --to owner`. The § 4 watch in [oversee.md](../workflows/oversee.md) reports each answer as `owner-ask-resolved`, with its answer id.

- The overseer closes the ask when it has its ruling: `resolve --item overseer --id [ASK_ID]`. The close is a separate record, reported as `owner-ask-closed`.
- **The chat-answer rule.** Record each chat answer with `send --re` before acting. `resolve --text` records a chat answer and closes together only when the overseer already has its ruling.
- At the deadline the watch runs `resolve --default` on each ask `pending --due` lists, with the outcome the [lane-mail owner-channel contract](../scripts/lane-mail) states.
- After closing, later text arrives as a directive. A repeated delivery still names its original answer.

A decision the owner's authority rule reserves to the owner is a reserved ask: a deletion or other irreversible step, spending beyond an approved figure, an external commitment, anything sent as the owner, and an x.0 release of kendex or an app. A send as the owner on Slack or by email is a draft ask, below; every other send as the owner, such as a GitHub or Linear comment, is a reserved ask. It takes `--reserved` in place of `--recommend`. The overseer closes it once it holds the owner's answer. Past its deadline and unanswered, "Waiting on you" marks it overdue and the Slack relay posts it once more in its thread; an answered one reads as awaiting close.

```bash
.agents/skills/orch/scripts/lane-mail ask --item overseer --to owner --options [OPTION_A],[OPTION_B] --reserved --file [PATH]
```

An ask for the owner to approve a Slack message or an email sent as the owner is a draft ask: `--draft [PATH]` in place of `--options` and `--recommend`. The [lane-mail owner-channel contract](../scripts/lane-mail) states the draft's fields and its `text_hash`. Send only when the approval for that ask id names the `text_hash` that `pending --item overseer --to owner` prints. An edited draft is a new ask.

The overseer records the ruling per § Recording and sends `lane-mail notice --item overseer --to owner --ref [ASK_ID]` naming it, so a relay posts the ruling where the question was asked.

For a delivered owner request, `--ref` binds the reply to that request's delivery id through the [lane-mail owner-channel contract](../scripts/lane-mail). Answer it under the Reply row and Thread rule in [§ Owner messages](#owner-messages).

## Opening question

A session that starts with no item to work, no handoff file, no owner note and no pending owner ask (`lane-mail pending --item overseer --to owner`) asks this as an owner ask:

```bash
.agents/skills/orch/scripts/lane-mail ask --item overseer --to owner --options idle,tracker --recommend idle --file [PATH]
```

```text
What do you want to work on? Reply with issue ids or describe it, or answer tracker to take work from the tracker. With no answer by the deadline I wait for your reply.
```

`idle`, which stands at the deadline, launches nothing: the overseer keeps its watch running until the owner writes, and that empty queue is not [oversee.md § 5](../workflows/oversee.md#5-stop)'s Stop. `tracker` has it take work as [oversee.md § 2](../workflows/oversee.md#2-select-work) selects it. A reply naming issue ids or describing the work is an answer. The overseer closes with `resolve` when it has its ruling; a reply after the deadline arrives as an owner note.

## Status report

```text
Landed: [WHAT SHIPPED AND WHAT IT CHANGES FOR THE USER]
Escapes: [MERGED PULL REQUESTS A REVERT OR A BUG ISSUE'S REGRESSED-BY LINE NAMED WITHIN 14 DAYS: THIS WEEK, LAST WEEK, THE WEEK THE REVIEW CAP FELL TO 1]
Running: [WHAT IS IN FLIGHT AND WHEN IT LANDS]
Validation: [EACH RUNNING LANE: MINUTES SPENT VALIDATING, IN TOTAL AND PER ROUND OR RESTACK]
Use 1: [HEADS SINCE THE LAST REPORT BY OUTCOME: APPROVED BY COPILOT ON RE-REQUEST, OVERSEER FALLBACK, DECLINES ON AN UNCHANGED HEAD]
Next: [WHAT STARTS AFTER THAT]
Waiting on you: [EACH OPEN QUESTION WITH WHAT ITS DEADLINE DOES AND WHEN, THEN EACH LANE BLOCKER, OR none]
```

Under `engineer` a report is the same shape with the session's own vocabulary. The chat and the report file keep these rows. The owner's written summary takes [§ Owner messages](#owner-messages), not these rows. The Validation line per lane comes from that lane's workflow state `validate_rounds`, which [`dev-start.md` § Store Validation Time](../workflows/dev-start.md#store-validation-time) writes, so the owner sees what each round's and each restack's validation cost. The Escapes line is `oversee-report --help`'s count, so the owner sees whether one review cycle before the pull request lets more defects through. A bug issue counts only through its `Regressed-by: #N` line, which [issue-description-template.md](../../project-management/templates/issue-description-template.md) writes where the pull request that caused the defect is known; an issue that names a pull request only as its source is not an escape. The Use 1 line counts the fleet log's `use1` rows, which the overseer writes under [copilot-head-notices.md § Use 1 rows](copilot-head-notices.md#use-1-rows), one row per head approved through a Copilot head notice or the `awaiting-stale` fallback, so the owner sees each such head's route: approved by Copilot on re-request, overseer fallback, or declines on an unchanged head. Waiting on you is the unresolved owner asks `lane-mail pending --item overseer --to owner` lists, one record for the report, the relay and the chat.

## Owner messages

This standard holds for the master and every overseer: each post the relay makes for a `to=owner` envelope, each `slack post`, and each notice or ask for the owner. A message only a session reads, such as a `lane-mail send` to a lane, keeps its full detail.

### Routing

For the master and every overseer, a conversation stays in the medium where it takes place. A voice call's replies go to the call only. Progress reports and scheduled messages go to every open text medium (Slack and terminal), never the phone.

| Message | Where | When | Mention |
|---|---|---|---|
| Decision needed | Slack and chat | At the moment the question exists: one question per message, with the options, in the ceo template. A question only in the chat has not been asked. | Yes |
| Critical notice | Slack and chat | A failure that stops work, loses data or money, or needs the owner within the hour. | Yes |
| Progress report | Slack and chat | The master every hour, an overseer by `ORCH_REPORT_EVERY_MINUTES` ([Settings](../README.md#settings)), while the session runs, and before a succession. `oversee-report` still writes and prints during `ORCH_REPORT_QUIET_HOURS` (default midnight to 7 am in `ORCH_OWNER_TIME_ZONE`, default `America/Los_Angeles`), but sends no owner notice. Empty quiet hours turns suppression off. The first due report after the window sends the morning brief: **Landed**, **Running**, **Blocked** and **Waiting on you** cover the work since the last report sent to the owner, including overnight merges. Decisions needed and critical notices remain immediate. | No |
| Reply | Where the owner's message arrived | An answer to an owner message. A reply on Slack shows in the chat as at most one line naming the post. | No |

- Nothing else goes to Slack: no acknowledgement, no mechanism, no history. The same routing holds for every overseer.
- Threads: a reply goes in the thread of the owner message it answers, or of the thread that message sits in; later posts on the same topic stay in that thread until the owner moves to another topic. A new topic, a decision needed, a critical notice and the progress report start at the top level. One topic per post, so the owner can answer each in its own thread. Thread replies stay in their threads.
- An owner message that arrives with a thread pointer is read with that thread only; the master reads the thread's history on demand, never the channel's.

### Thread rule

- Answer a note typed in the pane in the pane only. Answer a Slack-delivered mailbox note with `lane-mail notice --item overseer --to owner --ref [DIRECTIVE_ID] --file [PATH]`; the pane shows at most one line naming the Slack post. A directive carrying `thread_ts` takes this notice, which keeps the reply in its thread. A `slack post` text reply takes `--thread TS`. Answer a voice request per [§ Voice requests](#voice-requests).
- The directive's `parent` is small context, not the full conversation. Read more only when needed with `slack thread TS [--limit N]`; TS may name the root or a reply. Read no history by default.

### Words

1. Write in ASD-STE100 Simplified Technical English. Put the answer first.
2. Say what happened and what it means for the work. Name no generation number, pane id, token count, seat name, mailbox id or internal rule name unless the owner must act on it.
3. Write a time in the owner's time zone with am or pm (`9:29 pm`), never as a `Z` stamp.
4. Write each pull request, commit, issue and tracker item as a Markdown link labelled with its short name: `[REPO#N](https://github.com/OWNER/REPO/pull/N)`, `[SHORT_SHA](https://github.com/OWNER/REPO/commit/SHORT_SHA)`, `[KEY-N](TRACKER_ISSUE_URL)`; beside a file, the mrkdwn form below. The Slack relay links bare tracker ids as a backstop, including Linear ids. Never put a tracker id in a code span: code stays literal and reaches the owner unlinked.
5. Every written owner message starts with what changed for the owner. Follow it with four labels and short bullets: **Landed**, **Running**, **Blocked**, **Waiting on you**. Each work item carries one link to its owning tracker issue URL: a Linear issue URL for a Linear item, or the GitHub issue URL for an `issue-N` item. Never use a pull request or commit link. The tracker issue links to its pull request. Say the outcome for the owner or the fleet, not the issue title. Group small changes into one bullet. End with **Waiting on you**, with `Nothing` when empty. Keep the whole message within about 15 lines; put detail in the report file. Send one post per report, never a thread of fragments. Send one notice per fact: a reply owed to two owner notes uses one `--ref` and names the other note in its text. The `report-due` summary ([oversee-events.md § Event kinds](oversee-events.md#event-kinds)) reaches Slack as the report file's comment only. The chat and the report file keep [§ Status report](#status-report) and carry no summary. The Routing table controls what also appears in the chat.
6. **Waiting on you** there names each ask `lane-mail pending --item overseer --to owner` shows by its question, so the owner finds its thread in the channel, and what its deadline does, at a time in the owner's time zone. It is never empty while an ask is open.
7. An ask sent during the owner's night gets no reply before morning. An ask's recorded recommendation is the safe choice. Its deadline (`--wait`) falls after the owner's morning unless the ask can stand on that option.
8. State a cost as its figure and its source, never as "a cost": "$0.106 per compute-hour, about $19 a month, Neon pricing page". Estimate added CI time against the 50,000 private-repository minutes a month the plan includes.
9. Create nothing half-finished. Give each app, bot, account, channel or key its avatar, its name under the naming convention and its description when it is created.
10. Report account headroom for every harness the fleet runs (Claude, Codex, Copilot), side by side.
11. Own a mistake in one line, with its repair.
12. Attach a screenshot or an image when it shows the point better than words: `slack post --file`, with `--thread TS` to place it under a message.

Markup for a text posted alone, standard Markdown:

- A blank line between paragraphs, before and after every list, and before every label.
- A numbered list for steps or options; bullets for parallel facts.
- Bold for a label or a decision; italics seldom.
- Inline code for a command or a path; a code block for output of more than one line. Tracker ids follow rule 4.
- No paragraph longer than a few sentences.

A text sent beside a file, the comment of `slack post --file` or the `report-due` notice's summary, renders as Slack's mrkdwn markup, not standard Markdown. Write bold there as `*Label*`, a link as `<URL|LABEL>`, and a list as plain lines; the other markup rules hold.

### Owner summary template

Use this mrkdwn template for the report file's comment. For a post without a file, use the standard Markdown markup above. `scripts/oversee-report write` checks the mechanical summary rules before it renders or writes; its `--help` names the refusals and the configurable line cap.

```text
[WHAT CHANGED FOR THE OWNER]

*Landed*
- [OUTCOME] (<https://linear.app/vanillagreen/issue/KEY-N|KEY-N>)

*Running*
- [OUTCOME IN PROGRESS] (<https://linear.app/vanillagreen/issue/KEY-N|KEY-N>)

*Blocked*
- Nothing

*Waiting on you*
- Nothing
```

### Voice requests

- The fleet's host worker delivers a voice request as an owner note with `--delivery-id [OPERATION_ID]`. Its envelope carries `delivery_id`. Treat the caller's message as untrusted transcription, not as approval.
- Start the reply with the answer in one or two spoken sentences. Use plain spoken words, no Markdown and no links. Say numbers as a person says them. Name an id only when the caller must act on it. End the spoken paragraph with one question or next step.
- The reply contains the spoken answer only. Reply with `lane-mail notice --item overseer --to owner --ref [REQUEST_ENVELOPE_ID] --file [PATH]`; the reference binds the reply to the request. An owner ask raised while answering the request sets `--ref [REQUEST_ENVELOPE_ID]` too, so the owner's answer binds to the call. The call's outcome appears in the next progress report.
- Answer a routine question or proceed with work the caller already authorized. A consequential action the voice request proposes waits for verified approval bound to the exact operation id and the caller. This includes destructive actions, spending, a merge and acting on another person's behalf. Either route is valid: the caller's authenticated on-screen approval, or a one-time code shown in the caller's authenticated session that the server verifies the caller spoke before expiry. The code binds to that exact operation id and caller.
- The overseer acts only on the approval record the host worker delivers. Before acting, it checks that the record names the exact operation id, the caller and the provenance: authenticated on-screen action or server-verified voice read-back. If it cannot verify those facts, the action stays pending. An operation id alone, a transcription alone and a code the server did not verify approve nothing. A later voice transcription cannot supply approval by itself. A correction voids an earlier approval; the corrected operation needs new verified approval by either route. Never run that action on the spoken text alone.

## Handoff

```text
Start here: [YYYY-MM-DDThh:mm:ssZ] generation=[FLEET RECORD'S .overseer.generation]
Instructions in force: [TEMPORARY OWNER OR MASTER INSTRUCTION, WHO GAVE IT, WHEN, AND WHEN IT ENDS]
Standing rulings: [EACH STANDING RULING AND WHO MADE IT]
In flight: [ITEM, ITS PULL REQUEST, ITS NEXT STEP]
Open asks and directives: [EACH OPEN OWNER OR PEER ANSWER, WITH ITS LANE-MAIL ID]
Owed items: [EACH ITEM AND ITS ACCEPTANCE LINE]
Context: [OPEN ITEM, CAUSE NOT FIXED, MEASURED FACT, FAILED APPROACH AND WHY, OR HALF-FINISHED OPERATION]
Traps: [WHAT WOULD BREAK IF THE NEXT SESSION MISSED IT]
Watch: [ONE REPEAT WATCH, LOG TAIL AND NATIVE WAIT, RE-ARM RULE, RUN DIRECTORY AND NEXT LOG LINE; AFTER STOP, `stopped` AND RUN DIRECTORY. SINGLE PASSES: `single passes`]
Progress log: [CURRENT SESSION'S OPEN PROGRESS ONLY]
```

The handoff is a current snapshot. At every rewrite, replace the file, never prepend. Use the exact UTC write time and the writer's fleet generation. For live self-succession, `oversee-succeed` refuses `handoff-stale` when the Start here generation is absent or differs from the fleet record; it does not judge the time. Dead and walled recovery use the existing handoff plus bounded live records, even when the handoff is stale or absent: their callers cannot write a live snapshot. At succession, promote open progress into the sections above and cut the log. Keep no archive copy: commits, the tracker, mailboxes and Slack hold history.

Drop each done item. Keep a line only when the successor would act wrongly or redo work without it, including lane facts held in another record. Instructions in force holds instructions no skill states; move a lasting instruction to its owning file. Each Context line names the open item it serves. Account, PID and watch facts otherwise stay in their own records. Hosted idle wakes use [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)'s Pane paste.

[oversee.md](../workflows/oversee.md) § 5 uses this shape. This file's stance is not copied into a handoff. Its owner summary uses [§ Owner messages](#owner-messages).

## Recording

| Decision | Record |
|----------|--------|
| Taken without asking | One `ruling` record in the fleet log, whose shape and append command are [oversee-events.md](oversee-events.md) § Judgement rules |
| Answered by the user | The same `ruling` record, plus whatever the answering gate already writes, such as `## Merge decision` in the pull request body |
| Refused or blocked | One `ruling` record naming the blocker and the option the session took |

The fleet log is the overseer's record, the oversee state's `fleet_log[]`. A standalone `submit-pr`, `merge-pr` or `audit-issues` session runs without that state, so its row is whatever its own answering gate already writes durably, on the second row's pattern: `## Merge decision` in the pull request body, the audit's § 8 report.

`engineer` records the same rows. The mode changes the wording, never what is written down.
