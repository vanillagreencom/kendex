# Communication modes

`ORCH_USER_MODE` names who an orch session is talking to. This file owns the ask set; nothing outside it narrows or widens that set, and a gate citing it states neither. For prose, read communication's [reader modes](../../communication/references/messages.md#reader-modes) and [questions](../../communication/references/questions.md).

```bash
.agents/skills/orch/scripts/orch-env ORCH_USER_MODE ceo
```

| Value | Meaning |
|-------|---------|
| `ceo` | The session owns every technical decision. The user states intent and outcomes. Only a question in § Ask set reaches the user |
| `engineer` | The package's original behaviour, with the same ask set |

## Standing rulings

| Ruling | What it means for a session |
|--------|------------------------------|
| Technical decisions belong to the session | The session selects the mechanism |
| A question is asked only where § Ask set puts it | Everything else is decided and recorded per § Recording |

## Ask set

These questions reach the user in both modes. Nothing else does. Use communication's [question wording](../../communication/references/questions.md) for the mode. A gate outside the set keeps its own option list under both modes and asks only where its autonomy key is set to `ask`.

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

Under `engineer` every key keeps its own default, listed in [README.md](../README.md) § Setup.

## Owner asks

An overseer's question to the owner is one owner ask: communication's [question template](../../communication/references/questions.md) for the mode, written to a file, sent with its form and its deadline as fields, never as prose. The template's recommendation is the option the ask records as `recommend` and the relay's Recommended line. The chat shows one line naming the ask. `--wait` names one ask's minutes, and an ask without it takes `ORCH_ASK_WAIT_MINUTES`. Which forms record a recommendation, and what the deadline does for each, is the [lane-mail owner-channel contract](../../mailbox/scripts/lane-mail)'s.

An ask sent during the owner's night gets no reply before morning. An ask's recorded recommendation is the safe choice. Its deadline (`--wait`) falls after the owner's morning unless the ask can stand on that option.

```bash
.agents/skills/mailbox/scripts/lane-mail ask --item overseer --to owner --options [OPTION_A],[OPTION_B] --recommend [RECOMMENDED_OPTION] --file [PATH] --issue [ITEM] --do [ACTION_AND_CLOSING_EVIDENCE]
```

For an item ask, set `ORCH_OWNER_ASK_LABEL` and the owner email to enable the Linear route. `ORCH_OWNER_EMAIL` names the person and defaults to `KENDEX_USER_EMAIL`. The item supplies its own team. The overseer assigns that person, adds the label without replacing other labels, and posts the question as one plain comment. Its first line mentions that person by the Linear profile URL, built from the workspace key the tracker reports and the person's display name, so Linear notifies them. Then come the question text, its options, the recommendation or the reserved note with the deadline, the draft on a draft ask, the reply instruction, and a last line `Requested by` naming the asking overseer. The comment carries no ask header, ask id or Slack id: the posting record keeps the comment's id, and the watch finds replies after that comment. Linear sends the assignment notification. After the complete tracker question is confirmed, Slack posts one line: the owner mention, `Question from <sender>:`, the question's first line, the item link and its deadline, if any. A failed tracker write keeps the full chat question, options and deadline, and the pending ask names the failed operation as `tracker_cause`. It retains the item binding for cleanup and uses the chat deadline route. Unset settings report `lane-mail: tracker-unwritten issue=<ID> cause=settings-unset`. A failed settings read reports `cause=settings-unreadable`. An ask with no item stays on the chat route and creates no issue.

An item ask requires `--do TEXT`, worded as communication's [action requests](../../communication/references/questions.md#action-requests). A missing or empty action refuses as `owner-action-missing`, names `--do` as the fix and writes nothing. The label update also opens the description with `**<FIRST_NAME>, what you do:** <TEXT>`, a blank line, then the existing body. The first name comes from the Linear user the route assigns. A later ask replaces the opening line. The existing long watch pass restores a missing line from the ask's `do` field.

The person answers with one comment on the issue and changes no state. `ok`, `yes` or `done`, alone and in any case, accepts the recommendation or approves the action a reserved ask proposes. Any other text is a change request. The overseer acts on that request and replies on the same issue. Each long watch pass reads new comments by that person's email after the ask's comment. Each comment ID is its delivery ID, so a repeated read delivers nothing new. The watch adds `eyes` after it delivers an answer. When the ask closes on that answer's ruling, the close route adds `white_check_mark` and removes its own `eyes`. On Linear the check means the ask closed. A reaction failure reports `reaction-unwritten` and leaves delivery or closure successful. A failed tracker read reports `KEN-3624-unread` and leaves the other checks running.

The owner can answer more than once. Each answer lands through `send --item overseer --re [ASK_ID] --file [PATH]`, with its own delivery id. Answers leave the ask open in `pending --item overseer --to owner`. The § 4 watch in [oversee.md](../workflows/oversee.md) reports each answer as `owner-ask-resolved`, with its answer id.

- The overseer closes the ask when it has its ruling: `resolve --item overseer --id [ASK_ID]`. The close is a separate record, reported as `owner-ask-closed`.
- **The chat-answer rule.** Record each chat answer with `send --re` before acting. `resolve --text` records a chat answer and closes together only when the overseer already has its ruling.
- At the deadline the watch runs `resolve --default` on each ask `pending --due` lists, with the outcome the [lane-mail owner-channel contract](../../mailbox/scripts/lane-mail) states.
- After closing, later text arrives as a directive. A repeated delivery still names its original answer.

A decision the owner's authority rule reserves to the owner is a reserved ask: a deletion or other irreversible step, spending beyond an approved figure, an external commitment, anything sent as the owner, and an x.0 release of kendex or an app. A send as the owner on Slack or by email is a draft ask, below; every other send as the owner, such as a GitHub or Linear comment, is a reserved ask. It takes `--reserved` in place of `--recommend`. The overseer closes it once it holds the owner's answer. Past its deadline and unanswered, "Waiting on you" marks it overdue and the Slack relay posts it once more in its thread; an answered one reads as awaiting close.

```bash
.agents/skills/mailbox/scripts/lane-mail ask --item overseer --to owner --options [OPTION_A],[OPTION_B] --reserved --file [PATH]
```

An ask for the owner to approve a Slack message or an email sent as the owner is a draft ask: `--draft [PATH]` in place of `--options` and `--recommend`. The [lane-mail owner-channel contract](../../mailbox/scripts/lane-mail) states the draft's fields and its `text_hash`. Send only when the approval for that ask id names the `text_hash` that `pending --item overseer --to owner` prints. An edited draft is a new ask.

At `owner-ask-closed`, by any route including the watch's default close, the tracker route posts the ruling on the issue. Posting evidence retains the applied label, so close can clean up when settings are unset or unreadable. Each ask uses its recorded label. An older record without that label uses the configured label, never another ask’s recorded label. A legacy record cannot identify a label from earlier settings, so an unidentified historic label remains. If a closing or remaining legacy ask needs unavailable settings, close reports `tracker-unwritten` with the settings cause and leaves tracker ownership unchanged. The watch surfaces that diagnostic. Close removes its ask's label only when no remaining tracker-posted ask on that issue uses it. It keeps the labels of the remaining asks and unrelated item labels. While an ask remains, it keeps the assignee and shows the latest remaining ask's action. The watch finds owner replies through the remaining asks' recorded labels. After the last ask closes, close removes the assignee and opening action line. The overseer records the ruling per § Recording and sends `lane-mail notice --item overseer --to owner --ref [ASK_ID]` naming it, so a relay posts the ruling where the question was asked.

For a delivered owner request, `--ref` binds the reply to that request's delivery id through the [lane-mail owner-channel contract](../../mailbox/scripts/lane-mail). Answer it under the Reply row and Thread delivery in [§ Owner delivery](#owner-delivery).

## Opening question

A session that starts with no item to work, no handoff file, no owner note and no pending owner ask (`lane-mail pending --item overseer --to owner`) asks this as an owner ask:

```bash
.agents/skills/mailbox/scripts/lane-mail ask --item overseer --to owner --options idle,tracker --recommend idle --file [PATH]
```

Use communication's [opening question](../../communication/references/questions.md#opening-question).

`idle`, which stands at the deadline, launches nothing: the overseer keeps its watch running until the owner writes, and that empty queue is not [oversee.md § 5](../workflows/oversee.md#5-stop)'s Stop. `tracker` has it take work as [oversee.md § 2](../workflows/oversee.md#2-select-work) selects it. A reply naming issue ids or describing the work is an answer. The overseer closes with `resolve` when it has its ruling; a reply after the deadline arrives as an owner note.

## Status report

At each report, apply [§ Handoff](#handoff)'s hold check before counting ready items. Count items whose hold was dropped as ready, then apply `oversee.md` § 2 Select Work.

```text
Landed: [WHAT SHIPPED AND WHAT IT CHANGES FOR THE USER]
Escapes: [MERGED PULL REQUESTS A REVERT OR A BUG ISSUE'S REGRESSED-BY LINE NAMED WITHIN 14 DAYS: THIS WEEK, LAST WEEK, THE WEEK THE REVIEW CAP FELL TO 1]
Running: [WHAT IS IN FLIGHT AND WHEN IT LANDS]
Validation: [EACH RUNNING LANE: MINUTES SPENT VALIDATING, IN TOTAL AND PER ROUND OR RESTACK, THEN RESTACK RE-TESTS SKIPPED]
Rounds: [EACH RUNNING LANE: review_rounds, fix_receipts, validation_runs, restacks, repeated_class_rounds; UNAVAILABLE COUNTS READ unread]
Use 1: [HEADS SINCE THE LAST REPORT BY OUTCOME: APPROVED BY COPILOT ON RE-REQUEST, OVERSEER FALLBACK, DECLINES ON AN UNCHANGED HEAD]
Next: [WHAT STARTS AFTER THAT]
Waiting on you: [EACH OPEN QUESTION WITH WHAT ITS DEADLINE DOES AND WHEN, THEN EACH LANE BLOCKER, OR none]
```

The chat and the report file keep these rows. For the owner's written summary, read communication's [reports and template](../../communication/references/reports.md). `scripts/oversee-report write` runs the advisory summary check of Jarvis's `check-summary` call, held to the mrkdwn of its file comment, then sends on the writer's word; its `--help` defines the keyed output. The Validation line per lane comes from that lane's workflow state `validate_rounds`, which `dev-artifact-check` and `worktree-push` write, so the owner sees what each round's and each restack's validation cost, and from its `restack_skips`, which [`merge-pr-restack.md`](../workflows/merge-pr-restack.md) step 2 writes, so the owner sees each restack that skipped its re-test, counted apart from the runs. The Rounds row uses the five counts defined in [oversee-events.md § lane-long](oversee-events.md#event-kinds). It reads `Rounds: none` with no running lane. The Escapes line is `oversee-report --help`'s count, so the owner sees whether one review cycle before the pull request lets more defects through. A bug issue counts only through its `Regressed-by: #N` line, which [issue-description-template.md](../../project-management/templates/issue-description-template.md) writes where the pull request that caused the defect is known; an issue that names a pull request only as its source is not an escape. The Use 1 line counts the fleet log's `use1` rows, which the overseer writes under [copilot-head-notices.md § Use 1 rows](copilot-head-notices.md#use-1-rows), one row per head approved through a Copilot head notice or the `awaiting-stale` fallback, so the owner sees each such head's route: approved by Copilot on re-request, overseer fallback, or declines on an unchanged head. Waiting on you reads the unresolved owner asks from `lane-mail pending --item overseer --to owner`, one record for the report, the relay and the chat. Format it under communication's [Waiting on you](../../communication/references/reports.md#waiting-on-you).

## Owner-only verification

Route each due or overdue post-merge box by who can read its evidence:

| Reader | Action |
|---|---|
| A tool on the operator machine | The overseer reads the evidence and records the result on the item. |
| Jarvis, the owner's delegate | Send Jarvis a notice naming the item, box, check, Where and deadline. This route applies when `Where:` names "Jarvis, the owner's delegate", or the item carries `jarvis-check`. Record the delegate's reading on the item. |
| The owner alone | Send one owner ask on the same item. Name the box, check, Where and deadline. The owner answers with one comment under § Owner asks. Record the reading before closing the ask. |

A delegate notice creates no owner ask. Each overseer owns a verification ask through closure.

## Owner delivery

Read [communication](../../communication/SKILL.md) before each post the relay makes for a `to=owner` envelope, each `slack post`, and each notice or ask for the owner. This route holds for the Jarvis session and every overseer. A message only a session reads, such as a `lane-mail send` to a lane, keeps its full detail.

### Routing

Progress reports and scheduled messages go to every open text medium (Slack and terminal), never the phone. Replies follow communication's [medium and threads](../../communication/references/messages.md#medium-and-threads).

| Message | Where | When | Mention |
|---|---|---|---|
| Decision needed | Slack and chat | At the moment the question exists, through § Owner asks. A question only in the chat has not been asked. | Yes |
| Critical notice | Slack and chat | A failure that stops work, loses data or money, or needs the owner within the hour. | Yes |
| Progress report | Slack and chat | The Jarvis session every hour, an overseer by `ORCH_REPORT_EVERY_MINUTES` ([Settings](../README.md#setup)), while the session runs, and before a succession. `oversee-report` still writes and prints during `ORCH_REPORT_QUIET_HOURS` (default midnight to 7 am in `ORCH_OWNER_TIME_ZONE`, default `America/Los_Angeles`), but sends no owner notice. Empty quiet hours turns suppression off. The first due report after the window sends the morning brief under communication's [summary shape](../../communication/references/reports.md#summary-shape), covering the work since the last report sent to the owner, including overnight merges. Decisions needed and critical notices remain immediate. | No |
| Reply | As communication's medium rule requires | A reply on Slack shows in the chat as at most one line naming the post. | No |

- Only these message classes go to Slack. The same routing holds for every overseer.
- The `report-due` summary ([oversee-events.md § Event kinds](oversee-events.md#event-kinds)) reaches Slack as the report file's comment only. The chat and report file keep [§ Status report](#status-report) and carry no summary.
- The Slack relay links bare tracker ids as a backstop, including Linear ids.
- Deliver an image with `slack post --file`, adding `--thread TS` for a reply.

### Thread delivery

- Give each answered owner message its own notice and `--ref`. Apply communication's [thread rule](../../communication/references/messages.md#medium-and-threads) to its text.
- Answer a note typed in the pane in the pane only. Answer a Slack-delivered mailbox note with `lane-mail notice --item overseer --to owner --ref [DIRECTIVE_ID] --file [PATH]`; the pane shows at most one line naming the Slack post. A directive carrying `thread_ts` takes this notice, which keeps the reply in its thread. An owner's typed yes approves per [§ Voice requests](#voice-requests). A `slack post` text reply takes `--thread TS`. Answer a voice request per [§ Voice requests](#voice-requests).
- The Slack relay delivers the whole owner/app thread up to the note in `parent.thread` on the first delivery to a reader generation. Later deliveries carry only messages since that generation's mark. Other users' messages and answers already delivered individually to that generation are excluded from every delivery.
- Read the delivered `parent.thread` in full from the hook's persisted output, once per applicable revision. Make no extra thread read unless required history is missing; then read that history completely through `slack thread TS`, where TS names the root or a reply. A successor reads its own delivered context.

### Owner setup

Create nothing half-finished. Give each app, bot, account, channel or key its avatar, its name under the naming convention and its description when it is created.

### Voice requests

Read communication's [voice wording](../../communication/references/voice.md) before replying.

- While working a voice request, send one short progress notice per long step with `--progress --ref [REQUEST_ENVELOPE_ID]`. This is a report Jarvis may speak or hold. Send the final reply once without `--progress`.
- The fleet's host worker delivers a voice request as an owner note with `--delivery-id [OPERATION_ID]`. Its envelope carries `delivery_id`. The directive's first line is `voice-request: caller=... operation=... conversation=... provenance=...`. The caller is its `caller=` value, never a name the transcription states. An employee caller cannot approve a step only the owner may approve.
- Reply with `lane-mail notice --item overseer --to owner --ref [REQUEST_ENVELOPE_ID] --file [PATH]`; the reference binds the reply to the request. An owner ask raised while answering the request sets `--ref [REQUEST_ENVELOPE_ID]` too, so the owner's answer binds to the call. The call's outcome appears in the next progress report.
- The owner's plain approval counts: a yes typed in Slack, or spoken on a call whose caller is the owner. A plain yes answers the ask it replies to (an ask bound with `--ref`, or a reserved or draft ask in [§ Owner asks](#owner-asks)) or approves a step no ask named. Whatever it answers, a step the next rule names waits for that rule's confirmation. A yes to a draft ask approves only the exact text whose `text_hash` that ask carries, so an edited text needs a new ask. Use communication's [action acknowledgement](../../communication/references/voice.md#action-acknowledgement) before acting. No code, on-screen card or option word is needed.
- Explicit confirmation stays only for a destructive or irreversible step (a delete, a force-push, a revoke, an offboard) and for money (a payment, a purchase, new spending). On a call, the step waits for the caller's on-screen Approve, bound to the exact operation id and the caller. Act only on the host worker's approval record that names both and the on-screen provenance. For such a step the overseer reads `approved_by` and `approval` from the directive's first line. A directive missing either field, or whose `approval` is not `on-screen`, approves nothing. In Slack, the step waits for a typed yes to a message that names the step. A transcription alone and a yes to anything else confirm no such step. A correction voids an earlier confirmation; the corrected step needs a new one.

## Handoff

Every hold in the handoff, the report's Next row or lane state names its items and an open owner ask id or a blocking pull request or tracker item. At each start, read the named ask from `lane-mail pending --item overseer --to owner` and the named blocker from GitHub or the live tracker. Drop a hold with no id, a resolved or absent ask, or a blocker whose live state is terminal. Count its items as ready, then apply `oversee.md` § 2 Select Work.

The installed snapshot has this shape. The writer generates the Start here line.

```markdown
Start here: [YYYY-MM-DDThh:mm:ssZ] generation=[FLEET RECORD'S .overseer.generation]

## State
Session: [HOST, SESSION STATUS, HOLDS WITH THEIR ASK OR BLOCKER IDS, AND STATE CHECK TIME]
Watch: [ONE REPEAT WATCH, LOG TAIL AND NATIVE WAIT, RE-ARM RULE, RUN DIRECTORY AND NEXT LOG LINE; AFTER STOP, `stopped` AND RUN DIRECTORY. SINGLE PASSES: `single passes`]
Next report: [WHEN THE REPORT IS DUE]
Open owner asks: [LANE-MAIL IDS ONLY]
In flight: [EACH TRACKER ID WITH ONE NEXT ACTION]

## Sub-agents
[EACH RUNNING CONTROL-HOST SUBAGENT'S TASK FILE AND RESULT PATH; FLEET LANES STAY IN THE FLEET RECORD]

## Instructions in force
[EACH TEMPORARY OWNER INSTRUCTION, ITS SOURCE, RECORDED TIME AND END EVENT; LINK THE HOME OF A STANDING RULE]

## Progress log
[CURRENT SESSION'S OPEN PROGRESS ONLY: ONE LINE PER ACTION WITH ITS TIME, OPERATION, OBSERVED RESULT AND DECISION REASON; EXCLUDE RULINGS AND FILING HISTORY (FLEET LOG), AND VERIFYING READINGS (THEIR TRACKER ITEMS)]
```

The handoff is a current snapshot. Prepare the complete body below Start here in a separate ignored scratch file. At Stop and succession, write it with `oversee-succeed --write-only --handoff-body [BODY]` under [oversee.md § 5](../workflows/oversee.md#5-stop). Add `--handoff [PATH]` when the fleet uses another destination. Require a successful write before completing preparation, attempting plain succession, claiming a current installed snapshot or recording it for manual recovery. A failed write stops preparation; report its cause. The writer replaces the complete snapshot and supplies its current fleet generation and UTC write time. It refuses the installed handoff as body input, links to it and any body with a Start here line. In the body's Progress log, it refuses labeled rulings, filing history and Verifying readings with the first matching line number and record home; `oversee-succeed --help` names the refusal. It checks labeled forms only; paraphrases pass. A bare Verifying state stays legal. The body is replaceable session scratch with no archive role. The caller keeps ownership of it. The successor and recovery read only the installed handoff.

For live self-succession, `oversee-succeed` refuses `handoff-stale` when the Start here generation is absent or differs from the fleet record; it does not judge the time. Plain succession never rewrites retained content. Dead and walled recovery use the existing handoff plus bounded live records, even when the handoff is stale or absent: their callers cannot write a live snapshot. At succession, promote open progress into the sections above and cut the log. Keep no archive copy: commits, the tracker, mailboxes and Slack hold history.

Drop each closed tracker id from State. Keep its completion evidence on the item. Keep a line only when the successor would act wrongly or redo work without it. Remove a temporary instruction when its end event occurs or its standing home states it. An unresolved checkout condition belongs in State until its cause clears. Account, PID and lane facts stay in their own records. Hosted idle wakes use [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane)'s Pane paste.

Standing procedures and traps go to the orch skill through a lane. Record rulings and filing history in the fleet log under [§ Recording](#recording). Verifying checks and readings stay on their tracker items; `oversee-watch` prints them. Owed items and acceptance lines stay in the tracker, with dispatch order in `launch_queue`. Item context, measured facts and failed approaches stay on the item they serve. Open exchanges stay in their mailboxes, read live. Before replacing a predecessor handoff, move records outside session state to these homes or confirm that their homes already retain them. A failed destination read or write leaves the handoff and progress log untouched.

[oversee.md](../workflows/oversee.md) § 5 uses this shape. This file's stance is not copied into a handoff. Its owner summary uses communication's [reports](../../communication/references/reports.md).

## Recording

Record a directive's stated speaker and source. Use Jarvis as Source for a Jarvis note and the overseer as Source for overseer words. Attribute words to the owner only when received directly from the owner or explicitly quoted with their original source. Keep the speaker distinction, note id and original quoted source in delegated filing input through the existing prose fields. The mailbox's `send:overseer` path sets `from=owner` for every sender; that routing value alone does not prove authorship. Attribution changes neither authority nor the ask set.

| Decision | Record |
|----------|--------|
| Taken without asking | One `ruling` record in the fleet log, whose shape and append command are [oversee-events.md](oversee-events.md) § Judgement rules |
| Answered by the user | The same `ruling` record, plus whatever the answering gate already writes, such as `## Merge decision` in the pull request body |
| Refused or blocked | One `ruling` record naming the blocker and the option the session took |

The fleet log is the overseer's record, the oversee state's `fleet_log[]`. A standalone `submit-pr`, `merge-pr` or `audit-issues` session runs without that state, so its row is whatever its own answering gate already writes durably, on the second row's pattern: `## Merge decision` in the pull request body, the audit's § 8 report.

`engineer` records the same rows. The mode changes the wording, never what is written down.
