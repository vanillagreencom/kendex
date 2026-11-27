# Jarvis session and task commands

Read by section, only for the step that needs it: [Session command](#session-command) when starting, stopping, attaching to or handing over the managed Jarvis session, or when a `jarvis-session` answer needs its meaning, and [Task command](#task-command) when launching a Jarvis task, or when a `task` answer needs its meaning.

## Session command

- Start, resume and succession read published policy from the systemd user manager on Linux, and from launchd's caller context on macOS.
  - Shell-only exports do not reach a managed session.
  - `environment()` in `scripts/lib/session.py` owns the list of supported names; extend it through a package change.
  - A failed source read refuses launch before handover. Status and Stop stay available.
  - The selected account's launch owner supplies credentials and harness identity. Only Pi can keep the caller's explicit `CLAUDE_CONFIG_DIR`, for its Claude provider.
- Before the first Start with Copilot CLI, follow [Copilot folder trust](home-layout.md#copilot-folder-trust) unless the home's `JARVIS_UNATTENDED_HARNESSES` names `copilot`.
- Before the first Start with Claude Code in a home whose `JARVIS_UNATTENDED_HARNESSES` names `claude`, follow [Claude Code bypass consent](home-layout.md#claude-code-bypass-consent).
- `JARVIS_UNATTENDED_HARNESSES`, in the home's `kendex.settings.toml` `[env]`, lists comma-separated the start harnesses whose managed session runs with nobody at its pane.
  - The setting is read only when `jarvis-session start` builds a fresh launch or hands an adopted session over. That launch gives each named harness the full-bypass permission words orch writes for overseers: `--dangerously-skip-permissions` on Claude Code, `--dangerously-bypass-approvals-and-sandbox` on Codex and `--allow-all` on Copilot CLI. Every other start keeps the recorded posture.
  - Pi has no such word.
  - An adopted start, one with `--adopt-pane`, records the posture the adopted session was started under, read from its own launch words. Where those cannot be read, as on a host with no `/proc`, it keeps the posture already recorded for that same pane and process where that record names one, and records the harness's native defaults otherwise.
  - Its successor launches under that posture, or under the full bypass where the setting names its harness. A `succeed` retry carries the adopted session's recorded posture.
  - Succession does not read the setting. A `succeed` successor carries its predecessor's recorded posture.
  - After a bypass start, a successor on another harness launches under the full bypass. After a native start, succession's walk over `AGENT_RUNTIME_CONTROLLER_PREFERENCE` skips every entry of another harness.
  - After a bypass start, per-account setup, such as Claude Code bypass consent, applies to every account that preference's harnesses can pick.
  - The [settings example](../kendex.settings.toml.example) states its empty default.
- Start the controller through `.agents/skills/jarvis/scripts/jarvis-session start --home HOME --harness claude|codex|copilot|pi --account DIR --mode resume|new --origin manual`.
  - Use the Jarvis package installed in HOME.
  - Supply the account directory for the selected app.
- Append `--model MODEL --effort LEVEL`, both or neither, to launch a stated model.
  - `MODEL` accepts the model class or native model spelling the task command takes.
  - The session records the pair as its choice.
  - Start refuses a Pi model that spends another app's account, a `pi-claude/` model.
  - A succession that falls back to the recorded account keeps that choice.
  - Without the pair, a resumed session keeps its recorded choice, and a new one runs the app's default model.
  - A running session with another or no recorded choice starts new context, as an account change does.
- A consumer can append `--brief-file PATH`, its private instructions on one printable line.
  - After the harness confirms its native identity, the session command delivers those instructions with Start.
  - The session record keeps them, so every successor, a `succeed` retry included, receives them with its Start brief.
  - The consumer can remove the file once Start answers.
  - A session started without `--brief-file` or `--keep-brief` gives its successors the Start brief alone.
  - `--keep-brief` keeps the instructions the record already holds. It refuses beside `--brief-file` or `--adopt-pane`.
  - This route starts no repository overseer workflow.
- To move a Jarvis session that runs outside this package onto it, run Start from inside that session with `--mode new --origin manual --adopt-pane PANE --adopt-pid PID`. PANE is its tmux pane, and PID is that pane's process.
  - Start refuses, before saving or stopping anything, when the home's record names a running or starting controller, or when PANE is missing or dead, its process is not PID, or PID runs no supported harness or two at the same nearest depth.
  - The harness nearest PID names the session, so a Pi session's codex-bridge child is not a second one.
  - Start's own arguments select the successor's app, account, model and brief.
  - The command then follows [Succession](../workflows/session.md#succession): it saves `state/handoff.md` and ends that process by its process identity. It closes only that pane, and opens the home's `jarvis` session for the successor.
  - Start answers `handing-over`, and status reads as it does for succession.
  - A retry is `succeed`, which selects the successor through orch's walk, not Start's arguments.
- Read `.agents/skills/jarvis/scripts/jarvis-session status --home HOME` for the recorded session.
  - A `starting` answer means a fact Start waits for, such as the native identity or the session's taking of the Start brief, is still unconfirmed.
  - While a controller is live, status also prints the attach command on stderr.
  - `--mark-unread` adds the boolean `unread` and the recorded controller's identity, `controller`, to the answer. `unread` is true only where status could not make its read, such as a runtime refusal or an unreadable record: the state and reason then name that failure, not the controller. A recorded Start failure reads false. `controller` holds the recorded `session_id`, `pane` and `server_start`, and is null where the read is unread or records no controller. Without the flag the answer keeps its key set.
  - Status starts and stops nothing.
- `.agents/skills/jarvis/scripts/jarvis-session attach --home HOME` puts the caller's terminal on the live controller's session, under [Attach](home-layout.md#attach).
  - A refusal exits 1, and its line names the cause; `terminal-unresolved` means `xdg-terminal-exec` is not on PATH.
  - With no live controller, it starts nothing.
- `.agents/skills/jarvis/scripts/jarvis-session report-due --home HOME` reads orch's derived schedule under [Control-host events: Delivery](control-host-events.md#delivery).
  - Succession retains the controller's original session start.
  - When adopting the [progress checkpoint](../workflows/session.md#progress-checkpoint) in an already running session, repeat its Start command once to establish the start floor.
- On a satellite, `jarvis-session forward --home HOME --record PATH` forwards an owner request to the main, under [Agent reach: Forward](agent-reach.md#forward).
- Use `jarvis-session forward-drain --home HOME` under [Agent reach: Status](agent-reach.md#status).
- Wait for one forward's answer with `jarvis-session forward-wait --home HOME --key KEY` under [Agent reach: Forward](agent-reach.md#forward).
- Read `jarvis-session status --home HOME --main` for forwarding status.
- See [Agent reach: Status](agent-reach.md#status) for the satellite's `forward_confirm` field and kept answers.
- While the main session is unregistered, a request whose receipt was lost reads `queued` with `overseer-absent`, though the main already holds it. The next delivery or the answer settles it.
- Stop through `.agents/skills/jarvis/scripts/jarvis-session stop --home HOME`.
  - An app that turns Jarvis off uses `--origin app-off`.
  - Only `start --origin app-on` clears that Off.
  - A boot caller uses `start --origin boot`; a repeated call in the same login does not start another session.
- A controller whose harness process exited without a Stop, as after a crash or a `/logout`, reads `stopped` with reason `ended`. A recorded controller whose record holds a Start failure reads that failure: `failed` with `launch-failed`, or `blocked` with `sign-in-required`. The [watch loop](control-host-events.md#delivery) starts either again by this route:
  1. Start with `--mode resume --origin manual --keep-brief` on the recorded harness and account.
  2. If that Start refuses, at once or once its detached start records the refusal, run `jarvis-session succeed --home HOME --exited`. It hands the exited controller over to the next account the walk picks, never the recorded one, and retires nothing live.
     - `--exited` refuses `record-unreadable` while the controller runs, while a start is open, and after a Stop. After an app-off Stop it refuses `app-off`. During an open hand-over it answers `handing-over`, as every `succeed` does.
- After a machine restart, or once a tmux server holding the delegate, an overseer or a lane is gone, run `.agents/skills/jarvis/scripts/jarvis-session resume --home HOME`.
  - It resumes the recorded delegate first, through Start's resume of its recorded conversation. It never opens a new conversation.
  - It then resumes the overseer of each checkout `kendex project list --json` registers, through `orch-runtime resume-controller --fleet` run from that checkout. It skips the home's own controller, which is the delegate, and a controller stopped on purpose.
    - That resume first brings the checkout to the landed base. Where `sync-base` refuses to move the checkout, the overseer still starts, and its line reads `refused` with `cause=sync-base-REASON`, such as `sync-base-dirty` for a checkout with tracked changes.
  - It then relaunches each lane whose record reads `running`, and each lane recorded `stopped` with `restart_closed`, through `orch-runtime lane relaunch --fleet ITEM` run from its checkout. It leaves a lane hosted on another machine as it is.
  - Each session starts only after the one before it ends, so the command runs past the 60-second bound an app gives Start.
  - It does nothing to a session that still runs and prints it `resumed`: a delegate Start answers `existing`, an overseer whose start fails `controller-resume-failed` with `note=overseer-live`, and a lane refused `lane-live`.
  - A lane whose launch failed after its close, `launch-failed ... close=ID` at exit 3, is left `stopped` with `restart_closed`. A rerun relaunches it, and `lane relaunch` sends its launch alone. The rerun prints `resumed` or `refused` for it.
  - A lane whose launch is still open after its close, `launch-unconfirmed ... close=ID` at exit 75, is left `preparing` until its reconcile settles it. A rerun prints no line for it while it reads `preparing`.
  - It prints one line per session on stdout: `resumed kind=delegate|overseer|lane checkout=PATH`, with `item=KEY` for a lane, or `refused` with the same fields, then `cause=KEY` and the refusal's own fields. A refusal's field named `kind` or `cause`, or one naming the line's own field with another value, reads `orch_NAME`, such as `orch_cause=`.
  - A delegate's cause is the reason Start answers, such as `new-no-record`, `app-off` or `launch-failed`.
  - An overseer's or a lane's cause is orch's refusal key. Where a close, launch or resume failed or is unconfirmed, it is the key that leads orch's outcome line, with that line's fields.
  - An overseer's, a lane's or a fleet's `orch-runtime` call that cannot start or does not end has cause `unanswered`, and an answer with no key it can read has cause `answer-unread` with `exit=N`. A delegate's call that cannot start or does not end has cause `record-unreadable`.
  - A registry it cannot read prints `refused kind=projects cause=project-list-unread`. A checkout whose fleet it cannot read prints `refused kind=fleet`.
  - A registered checkout `kendex project list --json` lists as `folder-not-found`, `not-a-folder`, `unreadable` or `git-unclassified` prints `refused kind=fleet checkout=PATH cause=STATE`, as a volume not mounted yet leaves it.
  - It exits 0 when every line reads `resumed`, and 1 otherwise.

## Task command

- Launch a task with `.agents/skills/jarvis/scripts/task launch --home HOME --name NAME --harness claude|codex|copilot|pi --model MODEL --task-file PATH --result-file PATH`.
  - The managed Jarvis session must be running.
  - Use the same command for each harness.
  - `MODEL` accepts the model class or native model spelling; Pi uses its provider/model spelling.
  - Add `--effort LEVEL` unless high is the intended effort.
  - The lane selector chooses the account. Add `--account DIR` to ask that selector about a named account.
  - A Pi model naming a provider no reader measures, such as an `openai/` model paid by its API key, takes `--account` naming the Pi root that holds the key.
    - The key counts only where the root holds it: a key exported in the caller's environment never reaches the task window.
    - The launch starts where `pi auth check` reads the key ready, and the task record's `reading` is `unmeasured`; on a measured account it is `measured`.
    - The check reads the names `environment()` keeps for a task window, which hold no provider key, at the values the `task launch` process holds.
    - The task window takes the values its tmux server held when the server started.
    - Launched from the managed Jarvis session, which runs inside that server, the check's values match the window's.
    - Launched from elsewhere, the values can differ, so a `!command` key that reads a kept name, such as the agent socket or the display, can resolve differently in the check than in the window. This gap is declined with its reasons in https://github.com/vanillagreencom/kendex/pull/6890#issuecomment-7123905390.
    - Without the key it refuses `account-unmeasured`, and the printed record's `refusal` carries `cause` `provider-key` with Pi's `status` and `reason`.
- Add `--short` for a task of a few minutes when every account of the harness is past the launch limit.
  - The selector then accepts an account with room left up to its wall (`agent-runtime accounts pick --max-pct 100`).
  - The projected wall still applies.
- Put the private brief in the task file.
  - Add one `--input PATH` for each other input.
  - The task reads that brief directly and writes its Output to the result file.
  - This route starts no repository overseer workflow.
- For an agent that reads mail, pages or files, put a reference to [Authority](decisions.md#authority) in its brief.
  - Require it to read that section before acting.
- Add `--cwd PATH` to start the harness in an existing directory and use its native instruction loading there.
  - Without it, the task starts in `HOME`.
  - Relative task, input, result and working-directory paths resolve from the caller's directory.
  - Task records and scratch stay owned by the Jarvis home; the selected directory does not move them or the result destination.
  - An invalid or unavailable directory refuses before task allocation.
- Add `--browser` for browser work.
  - Each launch creates its own absolute scratch directory and browser profile beneath it.
  - The child receives `JARVIS_TASK_SCRATCH`, `JARVIS_BROWSER_PROFILE` and `JARVIS_BROWSER_PORT=0`, so Chromium allocates the profile's debugging endpoint; `jarvis-browser --port` reports the live port.
  - Use that profile with the [browser guide](browser.md#profile-and-tabs).
- Retain the returned task id.
  1. Read its record with `task status --home HOME --id ID`.
  2. Record the outcome with `task complete --home HOME --id ID --outcome succeeded|failed`. A succeeded task requires its result file.
     - Complete stops the browser running on the task's profile and closes the task's window last.
     - A succeeded task's scratch is removed, and its cleanup reads `done`.
     - A failed task's scratch stays for inspection, and its cleanup reads `kept`.
     - If complete refuses after it records the outcome, `task status` reads the completion set and cleanup `null`.
       1. Read the `refused=` reason. Reason `browser-running` names a browser on the task's profile that could not be stopped; close task-owned browser work.
       2. Retry `task complete` with the same id. The retry runs the pending teardown on the recorded outcome, whatever `--outcome` it names.
  3. Check the result.
  4. Close task-owned browser work.
  5. For a failed task, run `task cleanup --home HOME --id ID` once its scratch is read. Cleanup closes any window still open, stops the browser running on its profile, and removes its scratch.

- A launch records a running task only once the harness can take its brief.
  - When the account's harness cannot take it yet, the launch refuses `harness-setup-pending` or `harness-not-ready` and prints a `fix=` line naming the account and the steps to finish its setup.
- A launch refused after task allocation prints its task id and keeps the failure cause.
  - Read that record with `task status`.
  - If cleanup is pending:
    1. Read its `reason`. Reason `browser-running` names a browser on the task's profile that could not be stopped.
    2. Close task-owned browser work.
    3. Retry `task cleanup`.
- Task windows open in the Jarvis session, so Stop ends them with it.
  - Once the controller has ended, Stop or Start ends a session that holds only task windows.
  - A session of that name that holds any other window stays, and Start then answers `name-conflict`.
  - An unfinished task whose window is gone reads `failed` with reason `controller-ended`. Its scratch stays for inspection and explicit cleanup.
