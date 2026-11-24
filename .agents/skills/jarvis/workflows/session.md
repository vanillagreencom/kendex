# Continuing session

Follow this workflow when starting a continuing session, reconciling open work or transferring control.

- Use [Task reconciliation](tasks.md) for incoming requests, replies, worker results and blocker changes before launching work or waiting.
- Run that same procedure during Start's queue reconciliation, Progress checkpoint and Succession's reconciliation.
- Read each named section with `.agents/skills/jarvis/scripts/jarvis-section FILE 'Heading text'`, using its owning file and exact heading. The command includes child sections and stops before the next heading of the same or higher level.
- Use already loaded text when a parent read includes the requested child.

The `jarvis-session` and `task` commands this workflow runs are in [Session command](../references/session-command.md#session-command) and [Task command](../references/session-command.md#task-command).

## Start

1. First read the State, Sub-agents and Instructions in force sections of `state/handoff.md` with `jarvis-section`, at the path in the [home layout](../references/home-layout.md).
   - If it is absent and the user has an earlier handoff elsewhere:
     - Read those sections there.
     - Have the user move that earlier handoff once to the current path.
   - For the handoff you read, at either path:
     - Read the [Handoff](../references/long-session.md#handoff) contract with `jarvis-section` before using it.
     - Apply its checkpoint, staleness and recovery rules.
     - If no staleness bound exists, ask the user to set one.
2. Load only the safety core at start: the role in [persona.md](../persona.md), the read content and consent rules of [Authority](../references/decisions.md#authority), [Secret transfer](../references/accounts-and-secrets.md#secret-transfer) and [Official records](../references/accounts-and-secrets.md#official-records).
   - Use already loaded text rather than reading it again.
   - Keep one assistant in control at a time.
3. Check current holds and temporary instructions in the compact handoff sections above.
   - Read the current owner request with its delivered context.
   - Apply its decision boundary through Authority before choosing work.
4. Check the event registration state in the handoff's State section.
5. Register and start the event source:
   - For control-host events, register and start `watch-loop` through [Control-host events](#control-host-events).
   - For another selected event source, use its supported registration and delivery interface.
6. On a satellite, read `jarvis-session status --home HOME --main`.
   - Report each open forward that has a cause.
   - A confirmation a crash left unforwarded is forwarded by running `forward` again with the same record.
   - A console confirmation with no reply still shows in `owner-unanswered`.
7. Check the user channel and each agent's channel for unread events.
   - Keep one communication channel per agent.
   - Use the source's delivery order rather than sorting event ids.
8. Run `.agents/skills/jarvis/scripts/owner-unanswered --root HOME`.
   - Each listed owner note whose first line opens `voice-request: caller=` is an open voice request.
   - Make each open voice request the first decision, before any other read.
   - Send a progress notice on its ref through `.agents/skills/mailbox/scripts/lane-mail notice --item overseer --to owner --ref ID --progress --file TEXT`.
   - Then send its answer.
9. Confirm the session prerequisites under [Homes](../references/long-session.md#homes).
   - If any is missing:
     - Take its setup route as the first decision after open voice requests.
     - Leave the handoff untouched.
   - Otherwise:
     - Read all open session work from the selected tracker project, through every page.
     - Compare that list with the handoff's tracker ids; those ids are an index, not the discovery source.
     - Reconcile the tracker queue, the open asks and the due audits through live reads of their homes.
     - Apply [State retention](../references/long-session.md#state-retention) to the State entries the predecessor left: remove each entry whose content its open tracker item supplies through the [Progress records](../references/long-session.md#progress-records) `progress-log` call with `--state-change 'remove State ID'`, and keep an entry whose source is unreadable until a readback succeeds.
       - Where the open item does not yet hold an entry's next action, record it on the item through [5. Retain the next action](tasks.md#5-retain-the-next-action) before the entry leaves State.
     - Keep a compact view of open work and due obligations for the first decision.
     - Check what each open item waits for, and why.
     - Resume authorized work once its wait no longer applies.
10. Read no other record before the first decision.
11. Before taking the selected action, load its sections under [Action routes](#action-routes).
12. Follow [Handoff replacement](#handoff-replacement).
13. Write the current handoff under the [Handoff](../references/long-session.md#handoff) contract.
14. Enter the event loop.

## Control-host events

1. Read [Control-host events](../references/control-host-events.md) before starting or recovering the producer.
   - Use the settings in the [example](../kendex.settings.toml.example).
   - Select one absolute home path for every start and recovery command.
2. From the native session's own pane, run `.agents/skills/orch/scripts/orch-runtime register --fleet`.
   - The session's next native hook establishes its session binding.
   - A satellite registers only in its own home, and its loop runs as a satellite under [Control-host events: Satellite](../references/control-host-events.md#satellite).
3. Set the existing orch keys `ORCH_WAKE_PROCESS` and `ORCH_WAKE_START` in the home's settings.
   - The process pattern matches `watch-loop --home HOME` for this home. Escape regular-expression characters in HOME.
   - The start command names this same home and its harness route below.
   - The existing turn-end check reports an absent loop and that command. It starts no process.
4. Start the loop by harness:
   - On Claude Code, run `.agents/skills/jarvis/scripts/watch-loop --home HOME` through Monitor at its maximum expiry.
     - Keep that same loop for the session.
     - A batch pointer means the directive is ready in the home mailbox. Read it through the installed deliver hook or `.agents/skills/mailbox/scripts/lane-mail inbox --item overseer` from HOME.
     - Re-arm Monitor only on expiry or reported loop death.
   - On Pi and Copilot, launch the same command through `.agents/skills/orch/scripts/orch-runtime launch-job --name NAME --run RUN -- .agents/skills/jarvis/scripts/watch-loop --home HOME`.
     - Use a home-specific NAME and an absolute, home-specific RUN in an existing directory.
     - Retain the reply's `record`, `RUN.runner`, in the handoff.
     - Exit 75 may have started the loop: keep `RUN.runner` and launch no second loop.
     - Pi's installed mailbox wake delivers the directive. Copilot's installed hooks deliver at their native checkpoints; this producer supplies no idle extension.

To stop the loop:

- Stop a job through `.agents/skills/orch/scripts/orch-runtime stop-job --record RUN.runner`, using its retained record; `"stopped":null` means the loop had already ended.
- Stop the Monitor-owned command through Monitor.
- Retain the event log and batch state for restart.

Keep the source registration, home, launch route and runner record in the handoff's State section.

## Action routes

Load each named section with `jarvis-section` before the step that acts on it.

- Read its full text, including its rules, rather than only its heading or a summary.
- Use [Acceptance](../references/verification.md#acceptance) to select any further instructions the task needs.
- A start instruction must not read whole rule files in advance.

| Action | Load before acting |
|---|---|
| Reply or request a decision | [Medium and threads](../../communication/references/messages.md#medium-and-threads), [Message types](../references/communication.md#message-types), [Delivery](../references/communication.md#delivery) and [Sources](../references/verification.md#sources). |
| Queue decision | [Authority](../references/decisions.md#authority), [Approach](../references/decisions.md#approach), [Evidence and risk](../references/decisions.md#evidence-and-risk), [Homes](../references/long-session.md#homes) and [Acceptance](../references/verification.md#acceptance). |
| Payment or spend | [Authority](../references/decisions.md#authority), [Evidence and risk](../references/decisions.md#evidence-and-risk) and [Account ledger](../references/accounts-and-secrets.md#account-ledger). |
| Browser or account step | [Authority](../references/decisions.md#authority), [Account ledger](../references/accounts-and-secrets.md#account-ledger) and [Secret transfer](../references/accounts-and-secrets.md#secret-transfer). |
| Merge | [Authority](../references/decisions.md#authority), orch's [Workflow Execution](../../orch/SKILL.md#workflow-execution) and its [merge workflow](../../orch/workflows/merge-pr.md). |
| Lane launch | [Authority](../references/decisions.md#authority), orch's [Delegation](../../orch/references/skill-rules.md#delegation) and [Agent Lifecycle](../../orch/references/skill-rules.md#agent-lifecycle). |
| Succession | [Succession](#succession), [Handoff replacement](#handoff-replacement), the [Handoff](../references/long-session.md#handoff) contract and [Retention](../references/accounts-and-secrets.md#retention). |

- **Payment or spend**: load [Official records](../references/accounts-and-secrets.md#official-records) when the action uses those records.
- **Browser or account step**:
  - For a browser step, load [Browser guide](../references/browser.md#browser-guide), [Profile and tabs](../references/browser.md#profile-and-tabs), [Forms and captures](../references/browser.md#forms-and-captures) and [Bot checks](../references/browser.md#bot-checks).
  - For sign-in, load [Remote sign-in](../references/accounts-and-secrets.md#remote-sign-in).
  - For the user's input devices, load [Desktop and terminal](../references/computer-use.md#desktop-and-terminal).
- **Merge**: load the target repository's merge instructions before its merge step.
- **Lane launch**: for an independent work-item session, follow orch's [handoff workflow](../../orch/workflows/handoff.md).

## Event loop

1. Read each delivered event.
   - Connect it to an open item or create that item.
2. On `EVENT report-due`, follow [Progress checkpoint](#progress-checkpoint).
   - Set no model timer.
   - Store no due row.
3. Load the action's sections under [Action routes](#action-routes) before acting.
4. Handle user decisions through [decisions.md:Authority](../references/decisions.md#authority).
5. Update the item's state after each action.
   - Keep an unresolved obligation open until its acceptance check passes.
6. Run the verify pass after handling events and before waiting again.
   - Select the checks under [Homes](../references/long-session.md#homes).
   - Check each due box at its evidence source under [verification.md:Sources](../references/verification.md#sources).
   - Record the outcome on the item.
   - Take the next action on failure.
7. Wait through the selected event source when no authorized work or due check remains.

## Progress checkpoint

1. Read [Homes](../references/long-session.md#homes), the [Handoff](../references/long-session.md#handoff) contract, [Message types](../references/communication.md#message-types) and [Delivery](../references/communication.md#delivery) through `jarvis-section`.
2. Capture the collection cutoff in UTC before reading live evidence.
3. Read the live evidence:
   - Read the tracker live through every page: Verifying counts, each item's entry time into that state, and open session checks.
   - Read landings with merge times at or after the event's `since` cutoff and before the collection cutoff.
   - Read pending asks and their answers from the live mailboxes.
   - Use the consumer's selected repositories and tracker project.
   - A failed read is unavailable evidence; preserve that distinction in the report.
4. Refresh changed lines in the handoff's four required sections and its checkpoint coverage.
   - Correct the State lines `progress-log --check-state` lists under the handoff contract in the same write.
   - Follow Handoff replacement before converting an older handoff.
   - Run the consumer's registered checks from its standing instructions.
   - Record their results at their owning tracker items.
5. Write the summary using communication's report template.
   - Follow the consumer's report format and delivery settings.
6. Write the report to the `result.path` of `.agents/skills/orch/scripts/orch-runtime state progress-report-path`.
7. Set the completed file's modification time to the retained collection cutoff with `TZ=UTC touch -t YYYYMMDDhhmm.SS -- PATH` before the first send.
8. Send it once through `.agents/skills/mailbox/scripts/lane-mail notice --item overseer --to owner --attach PATH --file SUMMARY`.
   - Keep the file and its modification time unchanged on a failed send.
   - Retry that same attachment.
   - Do not claim delivery without the writer's receipt.
   - Do not advance coverage without the writer's receipt.
   - Record an unresolved send as open work before waiting or handing over.
9. Read `jarvis-session report-due --home HOME` after delivery to confirm the schedule. The next checkpoint is derived from the receipted file, and succession inherits that schedule without copying a due time.
10. Commit changed session state under the handoff contract.

## Handoff replacement

1. After the initial reads and first decision, read the predecessor's State checkpoint and the progress-log records after its covered range.
   - For an ordinary transfer, reconcile only those later records. For a record inside the covered range, read its destination to confirm retention and write nothing again; a destination that lacks the record is a disagreement with a source.
   - Run the full replay instead for a legacy import (a handoff from an earlier path or with no checkpoint), an interrupted write (a State entry for an unfinished operation with no receipt), missing coverage, or a record that disagrees with its source.
   - The full replay reads every section of the predecessor handoff and its progress log, including records in Owed and open, Context, Agent contact, Verify and Open requests when those sections exist.
2. For every record outside session state that step 1 selects, write it to its home under [Homes](../references/long-session.md#homes), or confirm that its home already retains it.
   - Preserve its contents, durable id and recorded time.
   - Read each destination to confirm retention before replacing the handoff or clearing the progress log.
   - Advance the checkpoint's covered range only over records whose destination read confirmed retention.
   - A failed destination read or write leaves the predecessor handoff and progress log untouched and stops replacement.
3. Archive the predecessor's handoff and progress log in the `archive/` directory beside the current handoff, `state/archive/` in the [home layout](../references/home-layout.md), before replacing them.
4. Then index each archived file with `.agents/skills/jarvis/scripts/progress-log --archived FILE`, adding the `--handoff PATH` that selects the current handoff when it is not the default.
   - Use the retention rule in [accounts-and-secrets.md:Retention](../references/accounts-and-secrets.md#retention).
   - An archive or index failure stops replacement.

## Succession

1. Judge whether the remaining context permits continued work.
   - Use the user's succession trigger when they set one.
2. Wait for attached agents under the [Handoff](../references/long-session.md#handoff) contract before calling the session command.
   - Keep reconciliation and retention in this workflow.
3. Follow [Handoff replacement](#handoff-replacement) and the reconciliation and update rules in the [Handoff](../references/long-session.md#handoff) contract, read through `jarvis-section`.
4. Before running `succeed`, run `.agents/skills/jarvis/scripts/owner-unanswered --root HOME`.
   - Send each open voice request a progress notice on its ref: this session hands over, and the next session continues the request.
5. After replacement succeeds, leave the successor's progress log empty in `state/handoff.md`.
6. Run `.agents/skills/jarvis/scripts/jarvis-session succeed --home HOME` from the Jarvis package installed in that home.
   - A caller that has positively established an account wall runs `.agents/skills/jarvis/scripts/jarvis-session succeed --home HOME --account-walled`. The command binds that wall to the recorded controller's account, and excludes that account even when its reading reports room or cannot measure it. An eligible alternative can succeed; without one, the command refuses before ending the predecessor.
   - Ordinary context or voluntary succession omits the flag.
   - The command selects a successor through agent-runtime's controller preference walk and account pick, from the first `AGENT_RUNTIME_CONTROLLER_PREFERENCE` entry to the recorded account and its choice. The home and saved handoff stay with the successor.
   - Where no account has room, the walk takes one account nothing measured: the recorded account where the mark leaves it in, else a signed-in account whose usage query was refused with HTTP 429. The successor's record then carries `scope: unmeasured`.
   - When neither exists, or an entry's account reading fails, succession refuses before the predecessor ends.
   - A missing orch dependency refuses succession before the predecessor ends; report the returned account and failure to the owner.
   - The command saves the handoff, then selects a successor, leaving out a Claude Code account that has not finished first-run setup. agent-runtime opens the successor in a new window of the same tmux session. It ends the predecessor only after the successor confirms its native identity and takes the Start brief.
7. Read `jarvis-session status --home HOME` for the transfer.
   - An open transfer answers `handing-over`; read its status before retrying `succeed`.
   - A failed attempt whose note holds its account, such as `successor-not-ready` or a login wall at the successor's first turn, records that account `unproved`, and `succeed` goes on to the next account, never to one it already tried.
   - Any other failure, such as `successor-asking` with its `step`, ends `handover-failed` naming its note.
   - With no successor left, status reports `handover-failed`. Keep the handoff and the recorded failure cause.
   - An unfinished wall transfer keeps its spent-account exclusion on every retry, retries without the flag included; a completed transfer ends it, and a new explicit wall binds the current controller's account.
   - Boot and Start do not resume the retired predecessor.
8. Keep session state in the current handoff. Never move it into memory.
