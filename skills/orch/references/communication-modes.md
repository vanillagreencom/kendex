# Communication modes

Read when an orch session decides whether a question reaches the owner, asks the owner, reports, delivers a message to the owner, writes the overseer handoff or records a decision. This file owns the ask set: nothing outside it narrows or widens that set. A gate that cites it restates neither. For the prose, read communication's [reader modes](../../communication/references/messages.md#reader-modes) and [questions](../../communication/references/questions.md).

`ORCH_USER_MODE` names who the session is talking to:

```bash
.agents/skills/orch/scripts/orch-env ORCH_USER_MODE ceo
```

| Value | Meaning |
|-------|---------|
| `ceo` | The session owns every technical decision. The user states intent and outcomes. Only a question in § Ask set reaches the user |
| `engineer` | Each composed key asks ([§ Composition](#composition)), with the same ask set |

The default and any other value: [settings.md](settings.md).

## Standing rulings

| Ruling | What it means for a session |
|--------|------------------------------|
| Technical decisions belong to the session | The session selects the mechanism |
| A question is asked only where § Ask set puts it | Everything else is decided and recorded per § Recording |

## Ask set

These questions reach the user in both modes, and nothing else does. Word them with communication's [questions](../../communication/references/questions.md) for the mode.

| Question | Reached by |
|----------|-----------|
| Scope expansion beyond the issue | Work the issue's Done-when does not carry |
| Revisiting a recorded decision | A change that contradicts a decision record |
| A destructive action | Deleting or discarding work that is not recoverable from the tracker or git |
| A change to user experience, workflow, outcome, cost or risk | A product question a finding or a lane raises |
| The way forward after a stopped review of a plan or design document | [oversee-events.md § End spirals](oversee-events.md#end-spirals) |
| An action spending the owner's standing outside this repository | A lane's question about filing or commenting in another repository's tracker, or about retiring a reviewer |

A gate outside the set keeps its own option list in both modes and asks only where its autonomy key is `ask`: `ORCH_MERGE_AUTONOMY` for merge consent, `PM_CREATE_AUTONOMY` for the audit's creations and every row of its Cancel section, `ORCH_DECISION_MODE` for the post-PR choices. Under a composed `auto`, those creations and cancellations are recorded per § Recording instead of asked. An overseer's heartbeat audit uses [heartbeat-audit.md](heartbeat-audit.md)'s authorization limits in both modes. Other audits ask under their own key alone, so a composed `auto` covers their filings wherever their tracker resolves. The last row above is a lane's question.

## Composition

`scripts/orch-env` composes three keys from the mode, and no workflow derives them again. A key the settings ladder sets wins in both modes. A key the ladder leaves unset takes the mode's value, never the caller's default:

| Key | Under `ceo` | Under `engineer` |
|-----|-------------|------------------|
| `ORCH_DECISION_MODE` | `auto-recommended` | `ask` |
| `ORCH_MERGE_AUTONOMY` | `auto` | `ask` |
| `PM_CREATE_AUTONOMY` | `auto` | `ask` |

## Owner asks

An overseer's question to the owner is one owner ask through the mailbox skill's `lane-mail`. Its form, deadline and every refusal are the owner-channel part of [`lane-mail --help`](../../mailbox/scripts/lane-mail).

1. Write the question with communication's [question template](../../communication/references/questions.md) for the mode, to a file with the harness file tool. The template's recommendation is the option the ask records as `recommend`, and the relay's Recommended line.
2. Choose the deadline. `--wait [MINUTES]` sets it for one ask; without it the ask takes `ORCH_ASK_WAIT_MINUTES`. An ask sent during the owner's night gets no reply before morning. Set its deadline after the owner's morning, unless the ask can stand on its recommended option as the safe choice.
3. Send it, and show one chat line naming the ask:

   ```bash
   .agents/skills/mailbox/scripts/lane-mail ask --item overseer --to owner --options [OPTION_A],[OPTION_B] --recommend [RECOMMENDED_OPTION] --effect none --file [PATH] --issue [ITEM] --do [ACTION_AND_CLOSING_EVIDENCE]
   ```

   Leave out `--issue` and `--do` for an ask about no tracker item. A recommended option that is irreversible, spends, makes a commitment, acts as the owner or releases is a reserved ask, below.

### Item asks

Where `ORCH_OWNER_ASK_LABEL` and `ORCH_OWNER_EMAIL` ([settings.md](settings.md)) are set, `--issue [ITEM]` puts the ask on the tracker item as well as in chat. What `lane-mail` writes on the item: `lane-mail --help`.

An item ask requires `--do [TEXT]`, worded as communication's [action requests](../../communication/references/questions.md#action-requests). An ask with no item stays in chat and creates no issue.

### Answers

The person answers with one comment on the issue and changes no state. `ok`, `yes` or `done`, alone and in any case, accepts the recommendation or approves the action a reserved ask proposes. Any other text is a change request: the overseer acts on it and answers on the same issue. Each long watch pass reads that person's new comments after the ask's comment.

The owner can answer more than once. Each answer lands as `lane-mail send --item overseer --re [ASK_ID] --file [PATH]` with its own delivery id. The ask stays open in `lane-mail pending --item overseer --to owner`. The watch in [oversee.md](../workflows/oversee.md) § 4 reports each answer as `owner-ask-resolved` with its answer id.

Record each chat answer with `send --re` before acting on it. `lane-mail resolve --item overseer --id [ASK_ID] --text [PATH]` records a chat answer and closes the ask together. Use it only when that answer is the ruling and came outside the mailbox.

### Closing

- Close the ask once you hold the ruling: `lane-mail resolve --item overseer --id [ASK_ID]`.
- At the deadline the watch runs `resolve --default` on each ask `pending --due` lists. Where nobody answered, that closes the ask on its recommendation.
- Record the ruling per § Recording. Then send `lane-mail notice --item overseer --to owner --ref [ASK_ID] --file [PATH]` naming it, so the relay posts the ruling where the question was asked.
- After the close, send a later chat answer as `lane-mail send --item overseer --directive --file [PATH]`. A tracker comment is delivered only as the answer to an ask still open on its issue.

For an owner request the relay delivered, `--ref [ENVELOPE_ID]` on the reply binds it to that request's delivery id. Answer it under [§ Owner delivery](#owner-delivery).

### Reserved and draft asks

A decision the owner's authority reserves to the owner is a reserved ask: a deletion or other irreversible step, spending beyond an approved figure, an external commitment, anything sent as the owner, and an x.0 release of kendex or an app. A send as the owner on Slack or by email is a draft ask, below. Every other send as the owner, such as a GitHub or Linear comment, is a reserved ask. No deadline closes a reserved ask: close it once you hold the owner's answer.

```bash
.agents/skills/mailbox/scripts/lane-mail ask --item overseer --to owner --options [OPTION_A],[OPTION_B] --reserved --file [PATH]
```

A request for the owner to approve a Slack message or an email sent as the owner is a draft ask: `--draft [PATH]` in place of `--options` and `--recommend`, the draft file in the shape `lane-mail --help` gives. Send the message only when the approval for that ask id names the `text_hash` that `lane-mail pending --item overseer --to owner` prints. An edited draft is a new ask.

## Opening question

A session that starts with no item to work, no handoff file, no owner note and no pending owner ask (`lane-mail pending --item overseer --to owner`) asks this as an owner ask, worded with communication's [opening question](../../communication/references/questions.md#opening-question):

```bash
.agents/skills/mailbox/scripts/lane-mail ask --item overseer --to owner --options idle,tracker --recommend idle --effect none --file [PATH]
```

`idle` stands at the deadline and launches nothing. The overseer keeps its watch running until the owner writes. That empty queue is not [oversee.md § 5](../workflows/oversee.md#5-stop)'s Stop. `tracker` takes work as [oversee.md § 2](../workflows/oversee.md#2-select-work) selects it. A reply naming issue ids or describing the work is an answer. Close the ask with `resolve` once you hold the ruling. A reply after the deadline arrives as an owner note.

## Status report

1. Apply [§ Handoff](#handoff)'s hold check and count the items whose hold dropped as ready. Then apply [oversee.md § 2](../workflows/oversee.md#2-select-work).
2. Read the report the runtime renders: `.agents/skills/orch/scripts/orch-runtime report render --state [FLEET] --repo [OWNER/REPO]`, one `--repo` per repository.
3. Write the owner's summary to a file under communication's [reports](../../communication/references/reports.md), in the owner's selected format below. Format its questions under [Waiting on you](../../communication/references/reports.md#waiting-on-you).
4. Publish: `.agents/skills/orch/scripts/orch-runtime report write --state [FLEET] --repo [OWNER/REPO] --summary-file [FILE]`. Add `--succession` for a handover report. Keep the reply's `result.path` and `result.notice_id` with the report's receipt.

Repeat a failed write with the same summary within the same UTC minute, the minute the report's name carries. Every other refused `write` and its remedy: [oversee-events.md, `report-due`](oversee-events.md#report-due).

The owner's selected format, which overrides communication's shared summary sections for this report:

- Keep the three opening quote blocks separate, then put Numbers before Completed.
- Under Numbers, give the merged, created, verified and cancelled counts across all Linear teams since the previous owner report, each with its source and window. Keep a count unread when its source has no reading.
- Then give the post-merge checks waiting, the active workers, and the workers past 3.5 hours with their work and identity. Keep an issue's stage age separate from a job's duration.
- Continue with Completed, In progress, Blocked, the linked Issues created, Waiting on you, per-account Headroom remaining, the self-analysis and Next report, in that order.
- Each Bad line names its fix in that bullet.
- Show a reserved ask as answered when its resolution stands, and keep it pending until it closes.
- Escapes counts a merged pull request once, in the week of its first finding within 14 days of the merge. A finding is a revert subject, or a bug issue's plain or bold `Regressed-by: #N` line. A source citation alone is no finding. An unread source leaves Escapes unread.

## Owner-only verification

No item waits for the owner's own use. A check only a person can take is sent only when no test can cover it and the item needs it. It is written as exact steps: what to press, what to say and what to see.

Route each due or overdue post-merge box by who can read its evidence:

| Reader | Action |
|---|---|
| A tool on the operator machine | The overseer reads the evidence and records the result on the item. |
| Jarvis, the owner's delegate | The box's `Where:` names "Jarvis, the owner's delegate". Send Jarvis a notice naming the item, box, check, Where and deadline, and record the delegate's reading on the item. |
| The owner alone | Send one owner ask on the same item, naming the box, check, Where and deadline. The owner answers with one comment under § Owner asks. Record the reading before closing the ask. |

A delegate notice creates no owner ask. Each overseer owns its verification ask through its close.

## Owner delivery

Read [communication](../../communication/SKILL.md) before each post the relay makes for a `to=owner` envelope, each `slack post`, and each notice or ask for the owner. This holds for the Jarvis session and every overseer. A message only a session reads, such as a `lane-mail send` to a lane, keeps its full detail.

### Routing

Progress reports and scheduled messages go to every open text medium (Slack and terminal), never the phone. Replies follow communication's [medium and threads](../../communication/references/messages.md#medium-and-threads).

| Message | Where | When | Mention |
|---|---|---|---|
| Decision needed | Slack and chat | When the question exists, through § Owner asks. A question only in the chat has not been asked. | Yes |
| Critical notice | Slack and chat | A failure that stops work, loses data or money, or needs the owner within the hour. | Yes |
| Progress report | Slack and chat | The Jarvis session every hour. An overseer every `ORCH_REPORT_EVERY_MINUTES` where that is set ([guide](../kendex.settings.toml.example)), while the session runs. Whether a succession writes one: [oversee.md § Succession](../workflows/oversee.md#succession). The quiet hours and the morning brief after them: [oversee-events.md, `report-due`](oversee-events.md#report-due). The brief takes communication's [summary shape](../../communication/references/reports.md#summary-shape). | No |
| Reply | As communication's medium rule requires | A reply on Slack shows in the chat as at most one line naming the post. | No |

- Only these message classes go to Slack, for every overseer.
- The `report-due` summary ([oversee-events.md § Event kinds](oversee-events.md#event-kinds)) reaches Slack as the report file's comment only. The chat and the report file keep [§ Status report](#status-report) and carry no summary.
- Deliver an image with `slack post --file [IMAGE_PATH]`, adding `--thread TS` for a reply.

### Thread delivery

- Give each answered owner message its own notice and `--ref`, and word it under communication's [thread rule](../../communication/references/messages.md#medium-and-threads).
- Answer a note typed in the pane in the pane only.
- Answer a Slack-delivered mailbox note with `lane-mail notice --item overseer --to owner --ref [DIRECTIVE_ID] --file [PATH]`. The pane shows at most one line naming the Slack post. A directive carrying `thread_ts` takes this notice, which keeps the reply in its thread.
- Reply to a `slack post` text with `--thread TS`.
- An owner's typed yes, and a voice request, follow [§ Voice requests](#voice-requests).
- On the first delivery to a reader generation, the Slack relay delivers the whole owner and app thread up to the note in `parent.thread`. Later deliveries carry only the messages since that generation's mark. Every delivery leaves out other users' messages, and answers already delivered one by one to that generation.
- Read the delivered `parent.thread` in full from the hook's persisted output, once per revision that applies. Make no other thread read unless required history is missing. Then read that history whole through `slack thread TS`, where TS names the root or a reply. A successor reads its own delivered context.

### Owner setup

Create nothing half-finished. Give each app, bot, account, channel or key its avatar, its name under the naming convention and its description when it is created.

### Voice requests

Read communication's [voice wording](../../communication/references/voice.md) before replying.

- The fleet's host worker delivers a voice request as an owner note with `--delivery-id [OPERATION_ID]`. Its envelope carries `delivery_id`. Its first line is `voice-request: caller=... operation=... conversation=... provenance=...`. The caller is its `caller=` value, never a name the transcription states. An employee caller cannot approve a step only the owner may approve.
- While the request is open, send a progress notice before any step that will keep the caller waiting: `lane-mail notice --item overseer --to owner --ref [REQUEST_ENVELOPE_ID] --progress --file [PATH]`. Send it again at the period the home sets in `JARVIS_VOICE_REMIND_SECS`. Jarvis may speak or hold a progress notice.
- Send the final reply once, without `--progress`: `lane-mail notice --item overseer --to owner --ref [REQUEST_ENVELOPE_ID] --file [PATH]`. An owner ask raised while answering the request also takes `--ref [REQUEST_ENVELOPE_ID]`, so the owner's answer binds to the call. The call's outcome appears in the next progress report.
- The owner's plain approval counts: a yes typed in Slack, or spoken on a call whose caller is the owner. A plain yes answers the ask it replies to (an ask bound with `--ref`, or a reserved or draft ask of [§ Owner asks](#owner-asks)), or approves a step no ask named. A yes to a draft ask approves only the exact text whose `text_hash` that ask carries. Acknowledge with communication's [action acknowledgement](../../communication/references/voice.md#action-acknowledgement) before acting. No code, on-screen card or option word is needed.
- A destructive or irreversible step (a delete, a force-push, a revoke, an offboard) and a money step (a payment, a purchase, new spending) wait for explicit confirmation, whatever a plain yes answered. On a call, the step waits for the caller's on-screen Approve, bound to the exact operation id and the caller. Read `approved_by` and `approval` from the directive's first line. Act only when both stand and `approval` is `on-screen`. In Slack, the step waits for a typed yes to a message that names the step. A transcription alone, or a yes to anything else, confirms no such step. A correction voids an earlier confirmation. The corrected step needs a new one.

## Handoff

Every hold in the handoff, the report's Next row or a lane's state names its items and an open owner ask id, or a blocking pull request or tracker item. At each start, read the named ask from `lane-mail pending --item overseer --to owner` and the named blocker from GitHub or the live tracker. Drop a hold with no id, a resolved or absent ask, or a blocker whose live state is terminal. Count its items as ready, then apply [oversee.md § 2](../workflows/oversee.md#2-select-work).

The installed snapshot has this shape. The writer generates the Start here line.

```markdown
Start here: [YYYY-MM-DDThh:mm:ssZ] generation=[FLEET RECORD'S .overseer.generation]

## State
Session: [HOST, SESSION STATUS, HOLDS WITH THEIR ASK OR BLOCKER IDS, AND STATE CHECK TIME]
Watch: [ONE REPEAT WATCH, LOG TAIL AND NATIVE WAIT, RE-ARM RULE, RUN DIRECTORY AND NEXT LOG LINE; AFTER STOP, `stopped` AND RUN DIRECTORY. SINGLE PASSES: `single passes`]
Next report: [WHEN THE REPORT IS DUE]
Open owner asks: [LANE-MAIL IDS ONLY]
In flight: [EACH TRACKER ID WITH ONE NEXT ACTION]
Unfinished sub-agents: [EACH RUNNING CONTROL-HOST SUBAGENT'S TASK FILE AND RESULT PATH, OR none; FLEET LANES STAY IN THE FLEET RECORD]

## Workarounds
[EACH WORKAROUND IN FORCE, ITS CAUSE AND THE EVENT THAT ENDS IT, OR none]
```

The handoff is a current snapshot. Its two sections carry what no other record holds, and nothing else. Write it at Stop ([oversee.md § 5](../workflows/oversee.md#5-stop)), and at a succession whose [oversee.md § Succession](../workflows/oversee.md#succession) route prepares one:

1. Before replacing the predecessor's handoff, move each record that belongs elsewhere to its home below, or confirm its home already holds it. A failed read or write at a home leaves the handoff untouched.
2. Prepare the complete body below Start here in a separate ignored scratch file. The successor and a recovery read only the installed handoff, never that scratch.
3. Write it with `.agents/skills/orch/scripts/orch-runtime handoff --fleet --body [BODY]`. Add `--handoff [PATH]` where the fleet uses another destination than `tmp/handoffs/OVERSEER-HANDOFF.md`. The writer replaces the whole snapshot and writes the fleet's current generation and the UTC time. It adds one State line naming every open lane ask the running lanes' mailboxes hold, each with its id and lane. It refuses a body that is the installed handoff, links to it or holds a Start here line.
4. A failed write stops the preparation: report its cause. Only after a successful write, complete the preparation, request a live transfer, claim a current snapshot or record it for manual recovery.

For a live self-succession, `request-transfer` refuses a handoff whose Start here generation is missing or differs from the fleet record. The model-switch recovery keeps the installed content below a new Start here line (`handoff --keep-prior`). A dead or walled recovery uses the existing handoff with bounded live records, even when the handoff is stale or absent. Keep no archive copy: commits, the tracker, mailboxes and Slack hold the history.

What stays out of the handoff, and where it goes:

- Drop each closed tracker id from State. Its completion evidence stays on the item.
- Keep a line only when the successor would act wrongly or redo work without it. Remove a workaround when its end event occurs or the item that removes it lands. An unresolved checkout condition stays in State until its cause clears.
- Account, process and lane facts stay in their own records.
- A standing instruction is a row of the oversee record's `standing[]` ([§ Recording](#recording)), never a handoff line.
- Standing procedures and traps go to the orch skill through a lane. Rulings and filing history go to the fleet log under [§ Recording](#recording).
- Verifying checks and readings stay on their tracker items, where the watch reads them. Owed items and acceptance lines stay in the tracker, with dispatch order in `launch_queue`. Item context, measured facts and failed approaches stay on the item they serve. Open exchanges stay in their mailboxes, read live.
- A hosted idle wake follows [oversee-lanes.md § Talking to a lane](oversee-lanes.md#talking-to-a-lane).

This file's stance is not copied into a handoff.

## Recording

Record a directive's stated speaker and source. Name Jarvis as the source of a Jarvis note and the overseer as the source of overseer words. Attribute words to the owner only when they came directly from the owner, or are quoted with their original source. Keep the speaker, the note id and the original quoted source in delegated filing input through its existing prose fields. The mailbox's `send:overseer` path sets `from=owner` for every sender. That routing value alone proves no authorship. Attribution changes neither authority nor the ask set.

| Decision | Record |
|----------|--------|
| Taken without asking | One `ruling` record in the fleet log, whose shape and append command are [oversee-events.md](oversee-events.md) § Judgement rules |
| Answered by the user | The same `ruling` record, plus whatever the answering gate already writes, such as `## Merge decision` in the pull request body |
| Refused or blocked | One `ruling` record naming the blocker and the option the session took |
| A standing instruction from the owner | One row of the oversee record's `standing[]` array ([workflow-state.md § Oversee state](../schemas/workflow-state.md#oversee-state)), as below |

A standing instruction:

1. When the owner gives it, write the row to a file with the harness file tool. `id` is the owner note's id; `end` is a date, an event or `until lifted`. `orch-runtime` stamps `at` where the row has none.
2. Append it with `.agents/skills/orch/scripts/orch-runtime state standing add --fleet [FILE]`. The text never crosses argv.
3. A successor reads the array whole at takeover with `.agents/skills/orch/scripts/orch-runtime state get --fleet /standing`, beside the mailbox and the handoff ([oversee-takeover.md § 1](../workflows/oversee-takeover.md#1-read-the-mailbox-and-handoff)).
4. At its end, write the remaining rows to a file as one array. Replace the field with `.agents/skills/orch/scripts/orch-runtime state standing lift --fleet [FILE]`, which records the lift as one `ruling` row in the same write.

A ruling given in a channel the overseer did not record is the overseer's miss, and the hand-over says so.

The fleet log is the oversee record's `fleet_log[]`. A standalone `submit-pr`, `merge-pr` or `audit-issues` session runs without that record. Its record is what its own answering gate already writes durably: `## Merge decision` in the pull request body, or the audit's § 8 report.

`engineer` records the same rows. The mode changes the wording, never what is written down.
