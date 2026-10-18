# Continuing session

Follow this workflow when starting a continuing session, reconciling open work or transferring control.

Read each named section with `.agents/skills/jarvis/scripts/jarvis-section FILE 'Heading text'`, using its owning file and exact heading. The command includes child sections and stops before the next heading of the same or higher level. Use already loaded text when a parent read includes the requested child.

## Session command

- Before the first Start with Copilot CLI, follow [Copilot folder trust](../references/home-layout.md#copilot-folder-trust).
- Start the controller through `.agents/skills/jarvis/scripts/jarvis-session start --home HOME --harness claude|codex|copilot|pi --account DIR --mode resume|new --origin manual`. Use the Jarvis package installed in HOME. Supply the account directory for the selected app. Both modes follow [Start](#start).
- A consumer can append `--brief-file PATH` with its private instructions on one printable line. The session command delivers those instructions with Start after the harness confirms its native identity. This route starts no repository overseer workflow.
- Read `.agents/skills/jarvis/scripts/jarvis-session status --home HOME` for the recorded session. A `starting` answer means a fact Start waits for is still unconfirmed: the native identity, on Copilot CLI and Codex the end of the kickoff turn the launch submits before the brief, or the session's taking of the Start brief at its first tool call or, on Claude Code, its turn end. Status starts and stops nothing.
- Stop through `.agents/skills/jarvis/scripts/jarvis-session stop --home HOME`. An app that turns Jarvis off uses `--origin app-off`. Only `start --origin app-on` clears that Off. A boot caller uses `start --origin boot`; a repeated call in the same login does not start another session.

## Start

- Read the State, Sub-agents and Instructions in force sections of `state/handoff.md` first with `jarvis-section`, at the path in the [home layout](../references/home-layout.md). If it is absent and the user has an earlier handoff elsewhere, read those sections there. Have the user move it once to the current path. Read the [Handoff contract](../references/long-session.md#handoff) with `jarvis-section` before using it. Apply its checkpoint, staleness and recovery rules. Ask the user to set the staleness bound if none exists.
- Load only the safety core at start: the role in [persona.md](../persona.md), [Authority](../references/decisions.md#authority), [Secret transfer](../references/accounts-and-secrets.md#secret-transfer) and [Official records](../references/accounts-and-secrets.md#official-records). Use already loaded text rather than reading it again. Keep one assistant in control at a time.
- Check current holds and temporary instructions in the compact handoff sections above. Read the current owner request with its delivered context. Apply its decision boundary through Authority before choosing work.
- Check the event registration state in the handoff's State section.
- For control-host events, register and start `watch-loop` through [Control-host events](#control-host-events). For another selected event source, use its supported registration and delivery interface.
- Check the user channel and each agent's channel for unread events. Keep one communication channel per agent. Use the source's delivery order rather than sorting event ids.
- Confirm the session prerequisites under [Homes](../references/long-session.md#homes). If they are missing, take its setup route as the first decision and leave the handoff untouched. Otherwise read all open session work from the selected tracker project, through every page. Compare that list with the handoff's tracker ids; those ids are an index, not the discovery source. Reconcile the tracker queue, the open asks and the due audits through live reads of their homes. Keep a compact view of open work and due obligations for the first decision. Check what each open item waits for and why. Resume authorized work when the wait no longer applies.
- Read no other record before the first decision.
- Before taking the selected action, load its sections under [Action routes](#action-routes).
- Follow [Handoff replacement](#handoff-replacement) before writing the current handoff under the [Handoff contract](../references/long-session.md#handoff) and entering the event loop.

## Control-host events

- Read [Control-host events](../references/control-host-events.md) before starting or recovering the producer. Use the settings in the [example](../kendex.settings.toml.example). Select one absolute home path for every start and recovery command.
- From the native session's own pane, run `.agents/skills/orch/scripts/oversee register`. The session's next native hook establishes its session binding. Registration alone cannot renew presence.
- Set the existing orch keys `ORCH_WAKE_PROCESS` and `ORCH_WAKE_START` in the home's settings. The process pattern matches `watch-loop --home HOME` for this home. Escape regular-expression characters in HOME. The start command names this same home and its harness route below. The existing turn-end check reports an absent loop and that command. It starts no process.
- On Claude Code, run `.agents/skills/jarvis/scripts/watch-loop --home HOME` through Monitor at its maximum expiry. Keep that same loop for the session. A batch pointer means the directive is ready in the home mailbox. Read it through the installed deliver hook or `.agents/skills/mailbox/scripts/lane-mail inbox --item overseer` from HOME. Re-arm Monitor only on expiry or reported loop death.
- On Pi and Copilot, launch the same command through `.agents/skills/orch/scripts/lib/job-unit.sh launch NAME RECORD -- .agents/skills/jarvis/scripts/watch-loop --home HOME`. Use a home-specific NAME and retain RECORD with the runner's process group PID in the handoff. Pi's installed mailbox wake delivers the directive. Copilot's installed hooks deliver at their native checkpoints; this producer supplies no idle extension.
- Stop a job through `.agents/skills/orch/scripts/lib/job-unit.sh stop-job RECORD PID '*watch-loop --home HOME*'`, using its retained record and process identity. Stop the Monitor-owned command through Monitor. Retain the event log and batch state for restart. Keep the source registration, home, launch route and runner record in the handoff's State section.

## Action routes

Load each named section with `jarvis-section` before the step that acts on it. Read its full text, including its rules, rather than only its heading or a summary. Use [Acceptance](../references/verification.md#acceptance) to select any further instructions the task needs. A start instruction must not read whole rule files in advance.

| Action | Load before acting |
|---|---|
| Reply or request a decision | [Medium and threads](../../communication/references/messages.md#medium-and-threads), [Message types](../references/communication.md#message-types), [Delivery](../references/communication.md#delivery) and [Sources](../references/verification.md#sources). |
| Queue decision | [Authority](../references/decisions.md#authority), [Approach](../references/decisions.md#approach), [Evidence and risk](../references/decisions.md#evidence-and-risk), [Homes](../references/long-session.md#homes) and [Acceptance](../references/verification.md#acceptance). |
| Payment or spend | [Authority](../references/decisions.md#authority), [Evidence and risk](../references/decisions.md#evidence-and-risk) and [Account ledger](../references/accounts-and-secrets.md#account-ledger). Load [Official records](../references/accounts-and-secrets.md#official-records) when the action uses those records. |
| Browser or account step | [Authority](../references/decisions.md#authority), [Account ledger](../references/accounts-and-secrets.md#account-ledger) and [Secret transfer](../references/accounts-and-secrets.md#secret-transfer). For a browser step, load [Browser guide](../references/browser.md#browser-guide), [Profile and tabs](../references/browser.md#profile-and-tabs), [Forms and captures](../references/browser.md#forms-and-captures) and [Bot checks](../references/browser.md#bot-checks). For sign-in, load [Remote sign-in](../references/accounts-and-secrets.md#remote-sign-in). For the user's input devices, load [Desktop and terminal](../references/computer-use.md#desktop-and-terminal). |
| Merge | [Authority](../references/decisions.md#authority), orch's [Workflow Execution](../../orch/SKILL.md#workflow-execution) and its [merge workflow](../../orch/workflows/merge-pr.md). Load the target repository's merge instructions before its merge step. |
| Lane launch | [Authority](../references/decisions.md#authority), orch's [Delegation](../../orch/references/skill-rules.md#delegation) and [Agent Lifecycle](../../orch/references/skill-rules.md#agent-lifecycle). For an independent work-item session, follow orch's [handoff workflow](../../orch/workflows/handoff.md). |
| Succession | [Succession](#succession), [Handoff replacement](#handoff-replacement), the [Handoff contract](../references/long-session.md#handoff) and [Retention](../references/accounts-and-secrets.md#retention). |

A consumer's own rule files keep their content. Its start instructions load only its safety-core sections above through `jarvis-section`. Give its remaining rule sections action routes for the same classes in this table. Each route names the owning file and its existing section heading. Load that section with `jarvis-section` before the action it governs. Keep consumer-specific rules in their owning files rather than copying them into this workflow or the handoff.

## Event loop

- Read each delivered event and connect it to an open item or create that item.
- Load the action's sections under [Action routes](#action-routes) before acting.
- Handle user decisions through [decisions.md:Authority](../references/decisions.md#authority). Use [communication.md:Message types](../references/communication.md#message-types) for replies, notices and scheduled reports.
- Update the item's state after each action. Keep an unresolved obligation open until its acceptance check passes.
- Run the verify pass after handling events and before waiting again. Select the checks under [Homes](../references/long-session.md#homes). Check each due box at its evidence source under [verification.md:Sources](../references/verification.md#sources). Record the outcome on the item and take the next action on failure.
- Wait through the selected event source when no authorized work or due check remains.

## Handoff replacement

- After the initial reads and first decision, read every section of the predecessor handoff and its progress log. Include records in Owed and open, Context, Agent contact, Verify and Open requests when those sections exist.
- For every record outside session state, write it to its home under [Homes](../references/long-session.md#homes), or confirm that its home already retains it. Preserve its contents, durable id and recorded time. Read each destination to confirm retention before replacing the handoff or clearing the progress log. A failed destination read or write leaves the predecessor handoff and progress log untouched and stops replacement.
- Archive the predecessor's handoff and progress log under `state/archive/` in the [home layout](../references/home-layout.md) before replacing them. Use the retention rule in [accounts-and-secrets.md:Retention](../references/accounts-and-secrets.md#retention). An archive failure stops replacement.

## Succession

- Judge whether the remaining context permits continued work. Use the user's succession trigger when they set one.
- Follow [Handoff replacement](#handoff-replacement) and the reconciliation and update rules in the [Handoff contract](../references/long-session.md#handoff), read through `jarvis-section`.
- Start the successor with that handoff. Transfer control before it acts. Stop the predecessor after the successor accepts control. During the transfer, only the assistant that holds control acts.
- Start the successor's log empty after replacement succeeds.
- Keep session state in the current handoff. Never move it into memory.
