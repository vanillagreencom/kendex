#!/usr/bin/env bash
# ---
# name: lane-mail-check
# event: Stop
# matcher:
# description: Blocks a lane's turn end while its overseer mailbox holds unread lines, so a directive or a ruling reaches the lane without a keystroke, a pane or a question tool. The lane is the work item `LANE_MAIL_ITEM` names, or the one directory under `<repo>/tmp/lane-mail/` whose name lowercases to the current branch; a session with neither is not a lane; a lane whose mailbox holds no unread line passes silently, as does a directory git reports no repository for and that holds no mailbox of its own. The checkout's overseer mailbox, `<repo>/tmp/lane-mail/overseer`, has one reader: the session whose tmux server and pane the checkout's oversee workflow state names under `.overseer`, the pair every writer the orch `schemas/workflow-state.md` `overseer` row names writes, `oversee register` among them for a session opened by hand, and the one the fleet's OVERSEER is established by below, so a record naming a dead pane names no reader. The pair names a session only on the tmux server started at the record's `server_start`, so a server a tmux restart handed the recorded pid and pane id names no reader either, and a record carrying no start names none. Where a file stands there, that session is handed the notes `lane-mail peer send --repo` wrote there at its turn end and after its tool calls, under the same `unread=<count>` line, unless a live watch holds the fleet state: the `oversee-watch.pid` record a repeat `oversee-watch` writes beside the fleet state on every surface and removes on exit, judged by the orch `lib/watch-pid.sh` library's `watch_pid_live`, which reads the mailbox itself, so the named session is handed nothing from it beside that watch. A fleet watched in single passes writes no watch record, so its named overseer is handed the notes as `unread=` lines and the next pass does not report them. Every other session in the checkout, one the owner opened there for other work included, is handed nothing from that mailbox, and so is a session whose install has no reader beside this hook. For the named session, where the install's `workflow-state path oversee` prints no path, or the library cannot be sourced or answers neither way, the hook refuses, opening `lane-mail-check: fleet-state=<path of the failing file>` with that file's own words under it; the halt arm never reads that mailbox, a subagent's turn end is handed nothing from it, and a session in a checkout with no overseer mailbox pays two file tests for the question. `<repo>` is the lane's root, resolved in this order: `CLAUDE_PROJECT_DIR`, the directory Claude Code started the session in; else the root the launch marker for `LANE_MAIL_ITEM` binds, where that root exists; else the directory the hook runs in, which on Codex and Pi is the session's start directory and on Claude Code without the variable is the call's own. A Claude Code lane working from the main clone is therefore still judged on its own mailbox. A root its launch marker binds that has no `tmp/lane-mail` directory is refused at a turn end, before any tool call and after the lead's finished one, opening `lane-mail-check: mailbox-missing=<path>` with the marker and the one `mkdir` command that restores the directory, and that command alone passes a tool call. Before a tool call a subagent is refused whatever it runs, and a call whose caller is unknown may run that command; after one a subagent is handed nothing and refused nothing, as with any mail, and its next call meets the refusal. The marker is looked up for the item `LANE_MAIL_ITEM` names or else the branch names, so that check costs one stat in a repository whose common git directory holds no `lane-mail` directory, and one branch read and one marker stat in one that does. A mailbox belongs to a lane only where a launch recorded one: `open-terminal` and `lane-host create` write the lane's root to `lane-mail/<item in lower case>` under the repository's common git directory and create the lane's own `tmp/lane-mail/<item>`, and a mailbox with no marker bound to this root passes silently. Unread lines are peeked through the orch skill's own `lane-mail inbox --peek`, the one reader of the mailbox and its cursor, and acknowledged with `inbox --ack` only once the refusal is written, so a hook killed at its budget leaves them unread and a line acknowledged here is never handed over twice. That reader is resolved from this hook's own install, walking up to the home directory for `skills/orch/scripts/lane-mail` or the shared `.agents/skills/orch/scripts/lane-mail` beside it, then the home's own shared tree for a harness root relocated out of it; the open repository's `.agents/skills/orch/scripts/lane-mail` is used only where this hook is installed in that repository, and a reader outside that containment is refused rather than run. The refusal opens with `lane-mail-check: unread=<count>` and carries one JSON envelope per line under it, and for the lead, where a halt is among them, the one `lane-mail inbox` command that reads it; the turn then continues with them. Run with the argument `deliver` by the lane-mail-deliver hook after a tool call, it exits 0 with the harness's JSON on stdout, whose `additionalContext` carries the same lines. Run with `start` by the lane-mail-start hook at a session start, or with `prompt` by the lane-mail-prompt hook at a prompt, both on Copilot alone, it hands the same lines over the same way and acknowledges them only once that is written, and refuses nothing: every refusal this description names is its keyed line on stderr at exit 0, with nothing on stdout and nothing acknowledged. Run with `halt` by the lane-mail-halt hook before one, it acknowledges nothing and refuses the call while an unread directive sent with `lane-mail send --halt` stands, opening `lane-mail-check: halt=<id>` with the directive and the one `lane-mail inbox` command that reads it, which names the lane's root with `--root` so it reads the same mailbox from any checkout; that command alone passes. Run with `row` by the session-start-row, session-end-row and stop-failure-row hooks, it writes the event row of a session with no lane of its own, and only for the pane's top-level harness, through the orch skill's `lib/session-rows.sh`, the file those hooks describe, and refuses nothing: every gap below its payload read is reported and passed; the overseer's own turn end writes a Stop row there through the same library at every turn end, compact, its time, event, harness and session alone, except over a standing StopFailure row, which it lifts and where it keeps the turn's last message. On a Pi install a launched lane's lead writes its own turn rows through that library into its mailbox directory, `session-rows.jsonl`: a Stop row at each turn end, carrying the `stopReason` of the turn's last assistant message in the transcript and Pi's `errorMessage` where that reason is `error`, and a PreToolUse row at the first tool call of each turn, after a turn end or on an empty file, written ahead of the mailbox check; oversee-watch and `lanes state` judge a Pi lane idle, working or walled from those rows in place of its pane, and a gap in the write is reported under `lane-rows-skipped` or `lane-rows-unwritten` and passed. The Pi install is the hook directory under `.pi` or `.pi/agent`, or under the user root `PI_CODING_AGENT_DIR` names; an install naming no harness writes no row, which a launched lane's turn end reports under `harness-unlisted`. Who made a call is answered once for every arm: the lead, a subagent, or unknown. A payload carrying a non-empty `agent_id` or `agent_type` is a subagent's on every harness, handed no mail and acknowledging none, and while a halt stands refused without that command. On Copilot, whose payloads name no agent, a preToolUse or postToolUse call, a preCompact and a context reading the usage arm is handed are the lead's where the session id they carry is a lead session this install recorded, the one rule for all four: one empty file per session under `~/.cache/lane-mail/copilot-leads`, written at the session's sessionStart, which Copilot fires for the lead alone, and at each turn end the transcript rule below proves the lead's, and pruned at a start once untouched for 30 days. A custom subagent's call was measured on Copilot CLI 1.0.88 carrying its own session id, which nothing recorded; whether a built-in task-tool subagent's calls carry their own session id or the lead's is a pending live-lane proof, and one whose calls carry the lead's is read as the lead, handed the lead's mail after its calls, which marks it read, and under a halt shown the read that clears it. A call whose session is no recorded lead, a custom subagent's among them, is unknown: the deliver arm hands it nothing and acknowledges nothing, writing `lane-mail-check: session-unrecorded=<id>` to stderr, the compact arm flags nothing and writes the same line at exit 0, the usage arm records nothing and refuses under that key at exit 2, so the lead's turn end hands the lines over and acknowledges them, and the halt arm refuses it without showing that command yet passes the command, because the reader's `--ack` stops short of an unread halt and a lead whose record could not be written would otherwise be refused for good; the lead is shown the command by every notice and refusal that hands it the halt, its turn end's included. A record that cannot be written is reported on stderr under `lane-mail-check: lead-unrecorded=<path>`, or `=none` for a session start naming no session id, and never refused. A Copilot sessionStart or userPromptSubmitted is the lead's, and an agentStop is ruled by its transcript, below; a prompt records no lead, since that a subagent's prompt fires no userPromptSubmitted is unmeasured. `stop_hook_active` true skips the mailbox check whole on the turn-end run. The flag is in the payload, so nothing above the payload read knows a turn was continued, and `arm`, the `missing-tools` refusal for `jq` or `cat`, `payload=unreadable` and `payload=invalid-json` are refused on every turn, the continued one included. Below that read one rule holds and every refusal is on one side of it: a refusal the lane itself can clear is still made, and a refusal it cannot is reported on stderr and passed. The lane clears the two handoff marks, and `script`, `setting`, `setting-range` and both `transcript` refusals, by writing its handoff record, and `mailbox-missing` by running the command it names, so those are refused on a continued turn as on any other. It clears `idle` by sending a lane-mail ask or notice, so `idle` is refused on a turn another stop hook continued, except on Pi, as the idle rule below states. It clears none of `workdir`, `git`, `item`, `marker` or the `missing-tools` refusal for `git`, `tr`, `awk`, `mktemp` or `tail`, so each of those is reported and the turn ends, where a fresh turn refuses it. The halt arm reports and passes that same set at every tool call: a lane whose tool calls are refused can clear nothing, since clearing it takes a tool call, so there only the payload refusals and the mailbox's own, `reader`, `inbox`, `halt` and `mailbox-missing`, are refused, the last two each passing the one command that clears it. The same turn-end run hands the lane off before it runs out, so the handoff never waits on an overseer reading a pane. It reads this session's context use from the `transcript_path` the payload names, through the orch adapter for the harness this hook's install directory names, `.claude/hooks`, `.codex/hooks` or Pi's `kendex/hooks`: the tokens the last response left in context and effective capacity, with Pi reading the payload's own `context_window`. It records that reading as `context.json` in the lane's mailbox directory, where `lanes context` reads it, and refuses the turn end when `lane_context_handoff_due` requires handoff under the shared context rule in orch `references/oversee-events.md`, Judgement rules. It reads the account the credential this session runs on still has through the orch skill's own `lanes pick --lane`, and refuses at or below `ORCH_HANDOFF_HEADROOM_PCT` (default 3). A Pi session's account is the one its model's provider bills, by the orch `lane_pick_harness` rule on the `<provider>/<model>` its transcript names: a `pi-claude/` model spends the Claude seat `CLAUDE_CONFIG_DIR` names and is judged there on that model, a `github-copilot/` model spends the Copilot pool on Pi's own root, and any other provider, or a reading naming none, is left unjudged under `account=unmeasured`. Either refusal opens `lane-mail-check: context=<tokens>` or `lane-mail-check: headroom=<percent>` and carries one instruction: reach the next safe point, write the record with `workflow-state set <item> handoff`, send a `handoff` notice, and exit. The instruction opens with the `workflow-state init <item>` that `set` needs where the item has no state file yet, so it is enough on its own. It repeats at every turn end, `stop_hook_active` included, until the item's workflow state carries a `.handoff` object no relaunch has resumed; only the lane can write that record, so a single refusal it declines to act on would end the session with nothing recorded. That record is judged before every mark, before every read they rest on and before `orch-env` and `lanes` are looked for, so no failure but the record's own writer can hold a lane that has already done what it was asked. `orch-env` or `lanes` missing from this hook's install, a mark setting that is not a whole number in range, and a transcript the payload names and nothing can read are refusals too, each on the lane path alone and each carrying the same instruction. What the marks cannot judge is reported and passed, never refused: a payload naming no transcript leaves the context unread, and so does a transcript whose last usage line is an object carrying none of the field names its adapter reads, which is reported under `usage-unread=<path>` rather than summed to a figure of zero and read as room, a reading below the independent token limit whose capacity the adapter could not name, reported under `window-unread=<model>`, and an install directory naming no harness, reported under `harness-unlisted=<directory>`; a reading that could not be recorded is reported under `context-unrecorded=<path>` and still judged; an account `lanes` keeps no inventory for, one it could not measure and a read that passed this hook's own ceiling each leave the account unjudged under `account=unlisted`, `account=unmeasured` or `account=timeout`, never read as room, so a setup with no usage endpoint still ends its turns; and a lane whose handoff record cannot be judged leaves both marks unjudged under one of four keys, `handoff-skipped=<path>` for a reader or a script this install has not got, or `handoff-skipped=unlocatable` where this hook's own directory could not be resolved and none of them could be looked for, `handoff-outside=<path>` for one only the open repository supplies, `handoff-unanswered=<path>` for one that is there and answered nothing this hook can read, and `handoff-unreadable=<path>` for a state file the install's own `workflow-state` could not read. Passing the turn is the answer for all four. For the first three it is because an install whose orch scripts cannot answer cannot run `workflow-state set` either, so a lane told to record a handoff with them could never end a turn again; for `handoff-unreadable` the install answers and the fault is the item's own state file, which is the file the record would be written into, so that write could not land either and the refusal would be as uncloseable. A subagent's turn end is judged on neither mark. The fleet's OVERSEER meets four triggers of its own on its turn end: a session with no lane of its own whose tmux server and pane are the pair the oversee workflow state records under `.overseer` is that overseer, and nothing weaker establishes one, so an ordinary session in a fleet checkout is judged on nothing. A session the record does not name whose pane the overseer's `context.json` names, the overseer the record lost, is judged on nothing either, and reports `pane-unrecorded=<its pane key>` with the recorded key under it and writes that record with no reading and the gap `pane-unrecorded`; any other session the record does not name writes nothing, so the real overseer's reading stands. Before it reads that transcript for the overseer it binds it to the current session: the `transcript_path` the payload names is read only where it is this session's own native file, held to the `session_id` the payload carries and the launch home the fleet record names under `.overseer.home`, through the orch adapter for a claude, codex or copilot install; a Pi install states no transcript shape and reads the payload's own window as a Pi lane does. A file that is not this session's under that home, a newer unrelated transcript, a predecessor's in the same pane, or one under an account the fleet never picked, and a binding that cannot be made, a payload naming no session or a record naming no home, are each reported once under `transcript-unowned=<path>` with the reason the gate gave. Nothing is read then, and the context record is written with a null token count and that reason as its `gap` (orch `workflow-state.md`, `context.json` row), so it still advances at every turn end and oversee-watch reports the gap, and the judge is handed this install's harness and no context figure, so it judges the account triggers alone, the `transcript-unowned` line is this hook's one report that the context went unmeasured, and a session is never judged on a file it does not own. Every overseer turn end whose orch context library loads writes that record, a reading or a null token count with a `gap` naming why none was taken: the gate's reason, `binding-missing` for a payload naming no session, `home-unnamed` for a fleet record naming no launch home, `session-mismatch` for a file another session wrote and `home-mismatch` for one under another launch home, `transcript-unnamed` for a payload naming no transcript, `usage-absent` for a transcript holding no usage line, `usage-unread` for a usage object its adapter does not read, which is also reported under `usage-unread=<path>`, `session-record` for a Copilot session with no extension reading whose statusLine session record does not answer either, which is also reported under `session-record=<reason>`, or `pane-unrecorded` below. A Copilot statusLine record reporting allow_all_enabled false, read whether or not an extension reading stands, in a session whose `COPILOT_ALLOW_ALL` is true (a launch line granting `--allow-all` or `--yolo`), is reported under `stop-cause=allow-all-blocked-by-policy`, and the turn end judged as usual. An install naming no harness an adapter reads writes no gap, since its context is never read, and leaves the record as it was, and a Copilot one names none where the reading its usage arm wrote for this session stands, its turn end reading that record rather than taking a reading of its own; a gap record that cannot be written is reported under `context-gap-unrecorded=<path>`, the record keeping its earlier entry. This hook records the overseer's own context reading as `context.json` in the overseer mailbox directory at the main checkout, naming the session and its pane, and hands that reading to `oversee-succeed --check-marks --context <tokens>:<window>` from this hook's own install, which judges those marks on it and on no stored figure, and nothing here judges them, under the same ceiling the account read runs under, so the turn-end refusal and the `overseer-mark` watch event cannot describe one overseer differently. Its refusal opens with the `context=`, `headroom=`, `rate=` or `qualifying=` key, carrying the figure that judgement read, and names `oversee-succeed`, handed the same reading, as the route, with `workflow-state set oversee handoff` under it for a succession that refuses, so the refusal always has an escape the overseer can reach. That record names the session that wrote it, in a `session_id` the payload gives and a `pane_key` for a harness that sends none. One other refusal stands on that path, `script` for an `oversee-succeed` this install has not got, and the record clears it as it clears the marks. `ORCH_OVERSEER_SUCCESSION=off`, read off the judgement's own line and never here, turns the account-mark refusals off with the succession they name, the watch's `overseer-mark` event still reporting those marks; the context mark is refused whatever the setting, since only this hook judges it, and the handoff record ends that refusal. An answer this hook cannot act on, one the ceiling abandoned, and one whose own reading was unmeasured are reported under `marks=unjudged`, `marks=timeout` and `marks=unmeasured` and the turn ends, never held. A lane asks its overseer only through lane mail. Before a tool call in a launched lane, the halt arm refuses the harness question tool by its name, whichever of the four names the payload's `tool_name` carries, Claude Code's `AskUserQuestion` and `EnterPlanMode`, Codex's `request_user_input` and Pi's `question`, opening `lane-mail-check: question-tool=<name>` and naming the `lane-mail ask --item <ID> --file <PATH>` send and the `lane-mail wait` on its printed id as the route, because a dialog on the pane reaches no overseer; an unread halt is refused ahead of it, a subagent's call is refused and told to report its question to the lead, and a session that is no launched lane passes the call silently, a committed mailbox and status file included. At a launched lane lead's turn end, once the handoff marks pass, the lane is judged idle on lane-mail facts alone, never on words the lane wrote, on Claude Code, Codex, Pi and Copilot; OpenCode and Cursor run no kendex hooks, and Gemini and Antigravity do not run this one, so a lane there is never judged idle. The reader's own `lane-mail events` listing, which moves no cursor, counts the asks and notices in the lane's outbound file against the count this hook recorded at the lane's last judged turn end, `sent-count` in the lane's mailbox directory: a line holding the count and, where this judge refused that turn end, the word `held`; no record is a count of zero. A count other than the recorded one is a send this turn and passes, a standing handoff record ends the run before this judge, the newest directive the overseer sent carrying `halt` passes, and a lane whose launch marker no longer binds its root, the close-out's state, is no lane. With none of these the turn is refused and the hold recorded, opening `lane-mail-check: idle=<item>` with one continuation, the lane's `lane-mail inbox` read and then its workflow, beside the ask route and the `lane-mail notice` send, which is also the route for a lane that ends its turn to wait on a dispatched agent or an armed wake, the notice naming what it waits on. On a turn the harness continued for this judge's own recorded hold it refuses nothing and sends the overseer a lane notice stating what it checked, opening `lane-mail-check: idle-notice=<item>`, or `idle-notice-unsent=<exit status>` with the sender's words where the send fails, so an idle lane is reported and never looped. A turn another stop hook's refusal continued is held as a fresh one, except on Pi, whose pi-hooks carrier runs no further request after a continued turn, so there the notice is sent with no hold before it. The record counts that notice, so the lane's next turn is judged on what the lane itself sends. An `events` listing that fails, or whose envelopes jq cannot read, is reported under `events=<status>` or `events=envelope`, and a record that is not a plain file holding a whole number and at most the word `held` under `idle-record=<path>` and rewritten. A record that cannot be written is reported under `idle-unrecorded=<path>`; under `idle-hold-unrecorded=<path>` where it was to take a hold, which is then not made, since one with no record would be made again on every continued turn; and under `idle-notice-unrecorded=<path>` where it was to count the notice, which the next turn end then reads as the lane's own send. Each of these ends the turn, because nothing a lane does at its turn end repairs its mailbox; an install with no reader leaves the turn unjudged under the marks' own `handoff-skipped` line. On Copilot the event is `agentStop`, registered in Copilot's own hook file under its camelCase name, so the payload spells its fields `sessionId`, `transcriptPath` and `toolArgs`, which this hook reads beside the snake_case spellings; its reference spells `stop_hook_active` so on both, and `toolName` goes unread, since the question-tool rule names no Copilot tool. Copilot also runs the hooks `.claude/settings.json` registers, under their PascalCase names, but the registration kendex writes there exits 0 before its script in a Copilot hook process, so a Copilot call reaches an install that is not Copilot's, the claude copy of this hook among them, only through a registration made there by hand or one kendex wrote before that skip and no refresh has rewritten. Whether Copilot made the call is read from the call, never from the install: a payload carrying `timestamp`, which both of Copilot's payload formats carry and no Claude, Codex or Pi payload does, or naming the session `sessionId`, is Copilot's, and any install but Copilot's own passes it silently, exit 0 with nothing written and nothing acknowledged, so the Copilot install is the one reader of the mailbox for a Copilot call. A Copilot agentStop names no agent: the stop whose `transcriptPath` sits in the directory named for the `sessionId`, Copilot's `session-state/<session id>/events.jsonl`, is the lead's and records it, a stop naming a transcript under another directory is read as a subagent's, handed nothing and judged on nothing, and a payload naming no transcript, or no session, is the lead's and records nothing. Copilot CLI 1.0.88 was measured firing agentStop at a custom subagent's end too, with the subagent's own `sessionId` and the lead's `transcriptPath`, which this rule reads as a subagent's. A refusal on Copilot is the documented answer for its event, on stdout beside the keyed stderr line: at a turn end `{"decision":"block","reason":<the refusal text>}` with exit 0, which Copilot stops honouring after 8 consecutive blocks, ending that turn unheld, so a handoff refusal holds a Copilot session for 8 continued turns and then returns at its next turn end, before a tool call `{"permissionDecision":"deny","permissionDecisionReason":<the text>}` with exit 2, since any non-zero exit denies the call and the JSON carries the words, and after one `{"additionalContext":<the text>}` with exit 0, since Copilot reads a postToolUse answer only at exit 0. That halt decision is local, the mailbox peek and nothing else, so it lands inside the hook's deadline: a preToolUse hook that times out on Copilot lets the call through. A Copilot session's context is read through Copilot's own SDK event `session.usage_info`: the orch `copilot-lane-context` extension, which `open-terminal` installs in a Copilot fleet lane's `COPILOT_HOME` with the EXTENSIONS feature on, runs this hook with the argument `usage` at each reading of the session's root agent, handing it `{session_id, cwd, current_tokens, token_limit}` on stdin, and for a recorded lead session that is a launched lane's lead or the fleet's overseer, named by the same gate every arm that judges the marks asks, it records `current_tokens` as the tokens and, as the capacity, the limit Copilot compacts at: 80 percent of `token_limit`, the SDK's documented `backgroundCompactionThreshold` default, named in the record's `capacity_source`. It writes nothing on stdout; a gap is refused on stderr at exit 2, which the extension writes to the session timeline: `payload=invalid-json`, an orch install it cannot use under the key its turn end reports that gap under, `handoff-skipped=<path>`, `handoff-outside=<path>` or `handoff-unanswered=<path>`, or `context-unrecorded=<path>` for a reading that could not be written, where the session's earlier reading is removed too so its turn end reports the context unmeasured rather than judging an older figure as room. Any other session passes silently. The Copilot turn end judges this session's record under the shared context rule exactly as it judges a transcript reading, the capacity putting the handoff before Copilot's own compaction; no reading of this session, no record or a gap record, is read from the fallback below; where the pending marker the extension leaves at `~/.cache/lane-mail/copilot-usage/<session id>` for a reading it handed on and no run has recorded yet still stands after a wait of 5 seconds, the turn end reports `reading-pending=<marker>` and passes with the context unmeasured, reading no fallback, since the extension runs for that session, and never judging the earlier record as room, since nothing orders the extension's run before the turn end; and a record that stands and cannot be read is refused under `record=<path>`. Where no pending marker stands and no reading of the extension's stands for this session, no record, one naming another session, a gap record or one the fallback below wrote, which its `capacity_source` tells apart, the turn end reads the fallback: the session record the orch `copilot-statusline` command writes as the account's `statusLine`, under `<COPILOT_HOME>/lane-status/<session id>.json`, through the orch adapter for copilot, which holds the record to the payload's `sessionId`, its `transcriptPath` where one is named, the account directory and a freshness bound, and hands the shared judge the same compaction point of the window as the capacity; that reading is judged and recorded as any other harness's, and a record that does not answer leaves the context unmeasured under `reading-unrecorded=<path>` and `session-record=<reason>`, reported and passed, never read as room. An extension reading below the mark is never overridden by a statusLine record past it. Run with `compact` by the lane-mail-compact hook at a preCompact whose `trigger` is `auto`, from a recorded lead session that gate names, it flags that compaction as `compaction.json` beside the reading, the backstop for a turn that crossed into the compaction before a reading past the mark reached a turn end, and the turn end then refuses under `compacted=auto` until the handoff record stands, the overseer's whatever its succession setting; a gap there is refused under `compaction-unrecorded=<path>` on stderr at exit 2, which Copilot shows the operator without holding the compaction. A Copilot account is judged through `lanes pick --lane` like any other. Not run on gemini: it has no Stop event. Not run on antigravity: its Stop payload carries no `stop_hook_active`.
# summary: Hands a lane the messages its overseer sent before the turn can end, so a directive is acted on instead of waiting for the next launch, and the same way hands the notes another repository's overseer sent to the one session the checkout's fleet record names. It also holds the turn end once the lane is near the end of its context window or its account's limit, until the lane records where it got to and exits, so the work resumes in a fresh session instead of stopping mid-round. The session running the fleet is held the same way, and hands itself over to a fresh one. A launched lane's turn end with no lane-mail ask or notice sent is held or reported to its overseer, and never judged from the lane's words; this hook's description states when each happens.
# safety: Reads the payload, the repository's branch, the lane's launch marker, read with the shell's own `read`, and the lane mailbox directory, and for a session that is no lane the checkout's overseer mailbox and, where a file stands there and the fleet record names this session's pane, the fleet state's path from one `workflow-state path oversee` and the watch record beside it, read by the orch watch record library `lib/watch-pid.sh` sourced in a child shell from the same install as the mailbox reader, which checks the record's pid with `kill -0` and `ps`; the writes are the mailbox cursor the orch reader advances, the session's context reading, `context.json`, and a Copilot session's compaction flag, `compaction.json`, each renamed into its mailbox directory, and on a Pi lane its turn rows, `session-rows.jsonl`, appended there under that file's own lock at a turn end and at the first tool call of each turn, and for the overseer one row appended to its rows file, `session-<server>-<pane>.jsonl` in the overseer mailbox directory, under that file's own lock, a compact Stop at every overseer turn end, the overseer's directory made where the fleet has not made it yet, and on Copilot a lead session's empty record under `~/.cache/lane-mail/copilot-leads`, touched at its session start and at each turn end its transcript proves the lead's, with records untouched for 30 days removed by one `find` at each start, as are the extension's pending markers under `~/.cache/lane-mail/copilot-usage`, which a Copilot turn end reads and polls for 5 seconds. Exit 2 names the unread count and the messages, and asks for them to be acted on, never bypassed. The reader it runs comes from its own install, never from the repository a session has open, so a repository that tracks a mailbox and an executable at that path cannot have it run. jq and cat read the payload; a payload it cannot read is refused on every turn, the continued one included, because the flag that marks a continued turn is in the payload none of those refusals reached. A mailbox whose reader is missing or fails is refused on the turns the mailbox check runs, which is every turn end but a continued one; on a continued turn that check is skipped whole, and the same missing reader is reported under `handoff-skipped` or `handoff-outside` and the turn is passed. An item name outside the alphabet a work item is spelled in, a branch that matches more than one mailbox, and a repository state git cannot report where a mailbox sits under the working directory are refused on a fresh turn and reported on a continued one and before a tool call, by the one rule the description states; none of them is ever passed in silence. For a lane's handoff marks it also reads the transcript the payload names and runs `orch-env`, `lanes` and `workflow-state` and sources the orch context library from the same install as the mailbox reader, never the open repository's, and on Pi one child shell sourcing that install's `lib/lane-launch.sh` to name the account the session's provider bills; the context reading is the one thing it writes for them. A session that names no lane costs two file tests of the checkout's overseer mailbox; where a file stands there it adds that install's resolution and, inside tmux, the overseer test below, and for the session the record names one `workflow-state path oversee`, one child shell sourcing the watch record library, and the reader's peek where no live watch stands. Outside tmux it costs nothing more, where the overseer test stops at its first condition. Inside tmux the overseer test costs that install's resolution, one child shell sourcing the orch context library, one tmux read and one `workflow-state` read, which together ask the oversee state whether this pane is the overseer's, plus, for a session whose pane the state names beside a server start, one child shell sourcing the orch `lib/tmux-server.sh` library for one more tmux read of its server's start; a session the state does not name stops there, after one child shell loading the orch context library, one `git-context` call and one read of the overseer's `context.json` where the state names another pane or none, and where that record names this session's pane, one `pane-unrecorded` report and one rewrite of that record. The overseer's own marks are then judged by `oversee-succeed --check-marks` from that same install, under the same 20 second ceiling the lane's account read runs under. That judgement measures the one account the overseer session runs on, through the same `lanes pick --lane` this hook asks about a lane, renewing an expired token in that account's credential file and refreshing that account's usage cache, the writes `lanes` states in its own contract; it opens no window and launches nothing. Only the last 1 MiB of the transcript is parsed, and the whole file only where that window carries no usage line, so the cost does not grow with the session. `lanes pick --lane` measures one account and renews that account's expired token, the write its own contract states; it can wait on a credentials lock and two network calls, and on a cache miss on the host-wide usage refresh lock for up to 10 seconds and, after a 429 with nothing cached, one sleep of up to 5 seconds and one more usage request, so it runs under a 20 second ceiling that leaves the rest of the run inside this hook's 30 second budget, and a read that reaches the ceiling is reported as a gap rather than refused. Where `timeout` is not installed that read runs unbounded, and a hook the harness then kills at its budget leaves the account unjudged, the same outcome the reported gap gives without the line. For the question-tool rule it reads the payload's `tool_name` before a tool call. For the idle judge at a lane lead's turn end it runs the reader's `events` listing, which moves no cursor, and reads the kind, the box and the halt flag of each envelope, never its text and never the transcript; it writes the lane's `sent-count` record, renamed into its mailbox directory, and the one idle notice the description names, through the reader's `notice`. Every refusal opens with `lane-mail-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 30
# harnesses: [claude, codex, pi, copilot, opencode, cursor]
# requires: [lane-mail-deliver, lane-mail-halt]
# ---

set -euo pipefail

# The session-start-row, session-end-row and stop-failure-row hooks require
# this one, and it names none of them back: two run on Claude Code alone, and a
# companion that does not run on a harness withholds the hook requiring it
# there, which would take this judge off Codex, Pi and Copilot.

# Names are matched by byte ranges below, so the locale decides the match.
export LC_ALL=C

# What the refusal names, empty until it is known: the lane's unread lines,
# a halt's directive with the one command that reads it, and the one command
# that restores a marked lane's missing mailbox directory.
UNREAD=""
HALT_TEXT=""
ACK_COMMAND=""
MAILBOX_COMMAND=""
# The handoff marks: the two settings judged and the commands that end the
# refusal, and the window the context mark is judged against. Empty until each
# is known.
MARK=""
PCT=""
# The overseer's own account headroom as the judgement's line reads it: a
# number, or none or unreadable where nothing measured it.
MARK_HEADROOM=""
WINDOW=""
# Whether the lane-mail-compact hook flagged this Copilot session's automatic
# compaction, the backstop mark; false until its turn end reads the flag.
COMPACTED=false
# What the overseer's judge and the succession its refusal names are handed:
# the reading this turn end took, as `--context`, or the harness this install
# names where nothing was read; empty until the overseer path sets it.
JUDGE_ARGS=()
# The launch home the fleet record names for the overseer session, read beside
# its pane key and empty until then; the transcript ownership gate holds the
# payload's transcript to it.
OVERSEER_HOME=""
# 1 where overseer_identified read the fleet record and found it naming a pane
# other than this session's, this pane with no server start or an earlier tmux
# server's, or none; 0 for every other answer it gives.
OVERSEER_UNRECORDED=0
# Why this turn end took no context reading, the gap word the overseer's
# context record carries; empty where a reading was taken or none was tried.
READ_GAP=""
HANDOFF_INSTRUCTION=""
# The two commands a lane asks its overseer through, and the read of its own
# mail and the notice send the idle refusal continues with, built by ask_route
# where a refusal names them. Empty until one does.
ASK_ROUTE=""
INBOX_ROUTE=""
NOTICE_ROUTE=""
# Which session the marks are being judged for: a LANE, or the fleet's own
# OVERSEER. Assigned once each, and matched by name at every site after.
#
# `NO_LANE_ITEM` is the CANDIDATE, set where nothing here names a lane item;
# `ROLE` is the answer, and stays `lane` until the fleet state has actually
# named this session as its overseer. The two are apart because the guards
# between them return for a session that is neither, and a single flag would
# have them read as the overseer declining to report a gap of its own.
ROLE=lane
NO_LANE_ITEM=0
# The fleet's own workflow-state item: the mailbox check asks where its state
# file sits, the one a fleet's watch holds, and the marks whether its
# `.overseer` record names this session.
OVERSEER_ITEM=oversee
# What a resolution step could not settle, for the phase that asked to refuse
# or to report, and the words the step's own command wrote. Empty until one
# fails.
FAIL_KEY=""
FAIL_VALUE=""
FAIL_CAUSE=""
# The key session_gate reports an install gap under, beside FAIL_VALUE and
# FAIL_CAUSE: handoff-skipped, or handoff-outside for a reader the open
# repository supplies. Empty until the gate meets one.
GATE_KEY=""
# What a usage run whose record write failed left of the session's earlier
# reading: removed, or stands where the removal failed too. Empty until then.
STALE_RECORD=""
# Who made the call the payload describes: lead, subagent, or unknown where
# the payload cannot tell.
CALLER=""
# The event this run judges, and for an arm that hands mail over as context
# the event name that context is written under. Empty until the argument is
# read, which `refuse` may be reached before.
ARM=""
CONTEXT_EVENT=""
# The directory resolve_reader puts the orch scripts at, composed into every
# path the marks run. Empty until the reader resolves.
SCRIPTS=""
# The last bytes of the transcript the context figure is taken from, and the
# seconds an account read is given.
TRANSCRIPT_WINDOW=1048576
ACCOUNT_CEILING=20
# What bounds those reads, answered once: whether this host has `timeout` is a
# property of the host, not of the read. Both reads wait on a credentials lock
# and a usage endpoint, and on a cache miss on the host-wide usage refresh lock
# and a 429 retry's sleep and second request, so they can outlast this hook's
# budget, and a hook killed at its budget writes no line at all, so each is
# bounded here instead. Stock macOS ships no `timeout`, and there this is empty
# and the read runs unbounded: a hook the harness then kills leaves that read
# unjudged, the same outcome the reported gap gives without the line.
BOUND_BY=()
! command -v timeout >/dev/null 2>&1 || BOUND_BY=(timeout "$ACCOUNT_CEILING")
NL='
'

# Which harness this install serves comes from where it is installed, the one
# place that records it; which harness made the call is the payload's to say,
# read below, since a Copilot call can reach another harness's copy through a
# registration made in `.claude/settings.json` by hand or one kendex wrote
# before the Copilot skip that no refresh has rewritten; kendex's own current
# registration exits 0 before the script. `hook_target` in
# `crates/core/src/engine/targets.rs`
# writes the claude copy under `.claude/hooks`, the codex copy under
# `.codex/hooks`, Pi's under the `kendex/hooks` segment of `.pi` or of its
# user root `.pi/agent`, and the copilot copy under `.github/hooks` at project
# scope or `<COPILOT_HOME>/hooks` at global scope. The project copies are known
# by their path, which the registered command names. An account directory is
# spelled however the operator likes, so the global copilot copy is known by
# the marker its install alone leaves: `copilot_hook` there writes the
# registry document `<name>.json` beside `<name>.sh`, where claude and codex
# register in a shared settings file. Read before any read that could fail,
# because the answer decides the SHAPE of every refusal: Copilot takes its
# decision as JSON on stdout. It also picks the adapter that reads the
# session's context, the account inventory `lanes` keeps and the harness a
# session row names; a directory naming none, and the copilot install, leave
# both marks unjudged.
case "${BASH_SOURCE[0]%/*}" in
  */.claude/hooks) HARNESS=claude ;;
  */.codex/hooks) HARNESS=codex ;;
  */.pi/kendex/hooks | */.pi/agent/kendex/hooks) HARNESS=pi ;;
  */.github/hooks) HARNESS=copilot ;;
  *) HARNESS="" ;;
esac
# A Pi lane launched on a pool account runs under the user root
# PI_CODING_AGENT_DIR moves `.pi/agent` to, and its global copy sits in that
# root's `kendex/hooks`: compared as physical paths, since either may be
# spelled through a link.
if [ -z "$HARNESS" ] && [ -n "${PI_CODING_AGENT_DIR:-}" ]; then
  PI_HOOK_DIR=$(cd -- "${PI_CODING_AGENT_DIR%/}/kendex/hooks" 2>/dev/null && pwd -P) || PI_HOOK_DIR=""
  THIS_HOOK_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" 2>/dev/null && pwd -P) || THIS_HOOK_DIR=""
  [ -z "$PI_HOOK_DIR" ] || [ "$PI_HOOK_DIR" != "$THIS_HOOK_DIR" ] || HARNESS=pi
fi
if [ -z "$HARNESS" ] && [ -f "${BASH_SOURCE[0]%.sh}.json" ]; then HARNESS=copilot; fi

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `lane-mail-check: <key>=<value>`: a
# stable key for the condition and the value acted on. The English explanation
# follows it, and never a bypass.
message() { # KEY VALUE [CAUSE]
  # What an install gap in the handoff marks costs the arm that meets it: a
  # turn end is passed, and a reading or a flag the arm would have written is
  # not, the session's next turn end then passing on the same gap.
  local passed
  case "$ARM" in
    usage) passed="this context reading is not recorded, and this session's next turn end is passed" ;;
    compact) passed="this compaction is not flagged, and this session's next turn end is passed" ;;
    *) passed="this turn end is passed" ;;
  esac
  {
    printf 'lane-mail-check: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      missing-tools=*)
        echo "the commands ${2//,/, } are required to read the hook payload and the lane mailbox and are not on PATH; refusing rather than skipping the check"
        ;;
      payload=unreadable)
        echo "the hook payload could not be read from stdin"
        ;;
      payload=invalid-json)
        echo "the hook payload is not valid JSON, or a field it reads is not a string; refusing rather than skipping the check"
        ;;
      item=invalid)
        echo "LANE_MAIL_ITEM is not spelled in the alphabet a work item is spelled in, ASCII letters, digits, dot, underscore and hyphen, and is never . or ..; refusing rather than reading a mailbox it does not name"
        ;;
      item=ambiguous)
        echo "more than one directory under tmp/lane-mail/ lowercases to this branch, so the lane's own mailbox is not decided; set LANE_MAIL_ITEM, or remove the mailbox that is not this lane's"
        ;;
      git=*)
        echo "git $2 failed, so the repository this lane runs in is unknown. Git reports one status for a directory that is no repository and for metadata it cannot read, so this refuses rather than pass what it could not judge:"
        ;;
      marker=*)
        echo "the lane launch marker $2 could not be read, so whether this session is a launched lane is unknown:"
        ;;
      workdir=*)
        echo "a scratch directory for the reader's own words could not be made under $2"
        ;;
      reader=unlocatable)
        echo "this hook's own directory could not be resolved, so the reader beside it could not be found"
        ;;
      reader=*)
        echo "the lane mailbox has a to-lane.jsonl and $2 is not an executable reader, so whatever it holds cannot be handed over; install the orch skill beside this hook"
        ;;
      reader-outside=*)
        echo "the only lane mailbox reader on offer is $2, supplied by the repository this session has open, and this hook is not installed in that repository; refusing to run it. Install the orch skill in the scope this hook is installed in."
        ;;
      arm=*)
        echo "this hook judges a turn end with no argument, a finished tool call with deliver, a tool call about to run with halt, a session start with start, a prompt with prompt, a compaction about to begin with compact and a Copilot session's context reading with usage; $2 is none of them"
        ;;
      mailbox-missing=*)
        if [ "$CALLER" = subagent ]; then
          printf 'the launch marker %s binds this root to a lane, and the lane has no mailbox directory at %s, so no halt or directive its overseer sends can be read; every tool call is refused until the lane lead restores it. Stop, and report this to the lead.\n' \
            "$MARKER" "$2"
        else
          printf 'the launch marker %s binds this root to a lane, and the lane has no mailbox directory at %s, so no halt or directive its overseer sends can be read; refusing rather than passing a lane its overseer cannot reach. Run exactly this command, the one tool call that passes while this stands; the overseer'"'"'s first send makes the item'"'"'s own mailbox under it:\n%s\n' \
            "$MARKER" "$2" "$MAILBOX_COMMAND"
        fi
        ;;
      inbox=header)
        echo "the lane mailbox reader's --peek output did not open with its count line, so whether messages are waiting is unknown"
        ;;
      inbox=envelope)
        echo "an envelope the lane mailbox reader printed could not be read, so whether the overseer halted this lane is unknown:"
        ;;
      halt=*)
        case "$CALLER" in
          subagent)
            printf 'the overseer halted the lane this agent works in, and every tool call is refused until the lane lead reads the halt. Stop, and report the halt to the lead:\n%s\n' "$HALT_TEXT"
            ;;
          unknown)
            printf 'the overseer halted this lane, and every tool call is refused until the lane lead reads the halt. This call'"'"'s session is no lead session this install recorded, so whether the lane lead or a subagent made it is unknown and the command that reads the halt is not shown here: a subagent stops and reports the halt to the lead, and the lead ends its turn, where it is handed the halt and that command:\n%s\n' "$HALT_TEXT"
            ;;
          lead)
            printf 'the overseer halted this lane, and every tool call is refused until the lane reads the halt. Run exactly this command, then act on the directive:\n%s\n%s\n' "$ACK_COMMAND" "$HALT_TEXT"
            ;;
        esac
        ;;
      inbox=*)
        echo "the lane mailbox reader exited $2, so whether messages are waiting is unknown:"
        ;;
      handoff-skipped=unlocatable)
        echo "this hook's own directory could not be resolved, so the orch scripts the handoff marks are judged with could not be looked for; both marks are unjudged and $passed rather than held."
        ;;
      handoff-skipped=*)
        echo "the handoff marks are judged with the orch scripts beside this hook, and $2 is not there; $passed unjudged rather than held, because the same install holds the one command that records a handoff and a refusal naming a command the lane has not got could never be cleared. Install the orch skill beside this hook."
        ;;
      handoff-outside=*)
        echo "the only orch install on offer is $2, supplied by the repository this session has open, and this hook is not installed in that repository; refusing to judge the handoff marks with it. Both marks are unjudged and $passed rather than held. Install the orch skill in the scope this hook is installed in."
        ;;
      handoff-unanswered=*)
        echo "the handoff marks are judged with the orch scripts beside this hook, and $2 is there but did not answer; both marks are unjudged while that stands, and $passed rather than held, because the same install holds the one command that records a handoff. Check the settings those scripts load, .env.local first, or refresh the orch install. Anything it wrote is below."
        ;;
      handoff-unreadable=*)
        echo "the workflow state at $2 could not be read, so whether this lane has already handed off is unknown; this turn end is passed unjudged rather than held, because the handoff record would be written into that same file and a refusal naming a write that cannot land could never be cleared. Repair or remove it. Anything its reader wrote is below."
        ;;
      script=*)
        printf 'the handoff marks are judged with %s from this hook'"'"'s own install, and it is not an executable there; install the orch skill beside this hook. Recording the handoff also ends this refusal:\n%s\n' \
          "$2" "$HANDOFF_INSTRUCTION"
        ;;
      setting=*)
        printf 'the effective value of %s could not be read, so the handoff mark it sets is unknown. Recording the handoff ends this refusal:\n%s\n' \
          "$2" "$HANDOFF_INSTRUCTION"
        ;;
      setting-range=*)
        printf '%s is not a whole number in the range the mark it sets is judged in, so the mark cannot be judged; set it to a number in range. Recording the handoff also ends this refusal:\n%s\n' \
          "$2" "$HANDOFF_INSTRUCTION"
        ;;
      transcript=unreadable)
        printf 'the payload'"'"'s transcript_path %s is not a readable file, so this lane'"'"'s context use is unknown; refusing rather than letting it run past its handoff mark. Recording the handoff ends this refusal:\n%s\n' \
          "$TRANSCRIPT" "$HANDOFF_INSTRUCTION"
        ;;
      transcript=unread)
        printf 'the transcript %s could not be read, so this lane'"'"'s context use is unknown. Recording the handoff ends this refusal:\n%s\n' \
          "$TRANSCRIPT" "$HANDOFF_INSTRUCTION"
        ;;
      usage-unread=*)
        echo "the last usage line in $2 carries none of the field names this harness's adapter reads a token count from, so the context mark is not judged and this gap is reported rather than held; an unread figure is never summed to zero and read as room, and the account mark is judged as usual"
        ;;
      window-unread=*)
        echo "the adapter read this session's tokens but could not verify its compaction point from the effective settings and window for $2. The reading is below the independent token cap. The percentage mark is unmeasured, and the account mark is judged as usual"
        ;;
      compaction-unread=*)
        echo "the $2 compaction settings could not be read. The token cap is still judged; the percentage mark has no verified point:"
        ;;
      harness-unlisted=*)
        echo "$2 is no hook directory of a harness the orch adapters read a transcript for, so this session's context is not read and the context mark is not judged, and no Pi turn row is written, so a Pi lane running this install reads unjudged in oversee-watch and lanes state; the gap is reported rather than held"
        ;;
      session-record=*)
        echo "this Copilot session has no context reading from the kendex-lane-context extension, so it is read from the record its statusLine command, copilot-statusline, writes under the account directory, and that record did not answer for this session: $2. The context mark is not judged and the gap is reported rather than held; the account mark is judged as usual. Set statusLine in the account's settings.json to run copilot-statusline with a refreshInterval under two minutes."
        ;;
      stop-cause=*)
        echo "this Copilot session's record reports allow_all_enabled false: enterprise managed settings, for its account or for its machine, block the allow-all mode, so every tool call waits on a permission prompt nobody answers. The orch copilot-runtime reference names the remedy"
        ;;
      transcript-unowned=*)
        echo "the transcript $2 the payload names is not bound to this overseer session's own file under the launch home its fleet record names: the reason below is a session identity or a launch home that disagrees, a payload naming no session, or a record naming no launch home. Nothing is read; the context record is written with no reading and that reason as its gap, which oversee-watch reports as overseer-context-unmeasured, and the judge is handed this hook's harness and no reading, so the context is unmeasured while the account triggers are judged as usual and a session is never judged on a file it does not own:"
        ;;
      pane-unrecorded=*)
        echo "the fleet record names the overseer by the pane key below, or none, not this session's own, although the overseer context record holds this session's reading; this session is judged on no mark, and its context record is written with no reading and the gap pane-unrecorded, which oversee-watch reports as overseer-context-unmeasured. Run oversee register from the overseer's own pane, or oversee-succeed by hand, to name the overseer again:"
        ;;
      context-unrecorded=*)
        case "$ARM:$STALE_RECORD" in
          usage:removed)
            echo "this Copilot session's context reading could not be written to $2, and no earlier reading stands there now, so its next turn end reports the context unmeasured under reading-unrecorded, never judging an older figure as room, until a later reading is recorded. The cause follows:"
            ;;
          usage:stands)
            echo "this Copilot session's context reading could not be written to $2, and the earlier reading standing there could not be removed either, so its next turn end still judges that older figure, which can lie below the mark this reading crossed, until a later reading is recorded; repair the directory. The causes follow:"
            ;;
          *)
            echo "this session's context reading could not be written to $2, so lanes context and oversee-succeed still hold the reading before it; the mark itself is judged on the reading this hook took:"
            ;;
        esac
        ;;
      reading-pending=*)
        echo "a context reading of this Copilot session was handed to its usage hook run and is not recorded yet, since its pending marker $2 still stands after $PENDING_WAIT: the run is still going, or it failed, which the session timeline names under a kendex-lane-context: or lane-mail-check: warning. So this turn end judges the context unmeasured, never the earlier record as room; the gap is reported rather than held, and the next reading recorded removes the marker."
        ;;
      reading-unrecorded=*)
        printf 'no context reading of this Copilot session stands in %s, and the statusLine session record its fallback reads did not answer either, as the session-record line with this one names, so its context is unmeasured and the context mark is not judged; the gap is reported rather than held, and never read as room. The first reader is the kendex-lane-context Copilot extension open-terminal installs in the lane'"'"'s COPILOT_HOME, which records a reading at each model call of the session. A `kendex-lane-context:` or `lane-mail-check:` warning in the session timeline is the gap that reader met. None means the extension did not run: check that <COPILOT_HOME>/extensions/kendex-lane-context/extension.mjs stands, that enabledFeatureFlags.EXTENSIONS is true in that home'"'"'s settings.json, and Copilot'"'"'s own log.\n' "$2"
        ;;
      compaction-unrecorded=*)
        echo "for the operator: Copilot began compacting this fleet session automatically, the backstop handoff mark, and this hook could not flag it because $2 could not be used, so no turn end of this session will hold it for the compaction. Tell the session to write its handoff record and end, or end it and relaunch the item. The cause follows:"
        ;;
      record=*)
        printf 'the context record %s could not be read, so whether this Copilot session is past its handoff mark is unknown; refusing rather than letting it run on. Recording the handoff ends this refusal:\n%s\n' \
          "$2" "$HANDOFF_INSTRUCTION"
        ;;
      compacted=*)
        # The backstop: the reading marks a session before its compaction,
        # and this flag is what a turn that crossed into the compaction
        # before any reading past the mark reached its turn end leaves.
        COMPACTED_FACT="Copilot began compacting this session automatically, its preCompact hook naming trigger $2, before a context reading past the handoff mark reached a turn end. Nothing after that compaction is trusted, so start no new work and write the handoff from durable state, the workflow state, git and the PR, never from the conversation the compaction summarised."
        if [ "$ROLE" = overseer ]; then
          printf 'oversee-succeed requires handoff: %s Succeed this session yourself.\n%s\n' \
            "$COMPACTED_FACT" "$HANDOFF_INSTRUCTION"
        else
          printf 'this lane requires handoff: %s No handoff record stands. Then end the session, so the next one continues the work.\n%s\n' \
            "$COMPACTED_FACT" "$HANDOFF_INSTRUCTION"
        fi
        ;;
      context-gap-unrecorded=*)
        echo "this overseer turn end took no context reading, so the context mark is not judged at it, and the record naming why could not be written to $2, which keeps its earlier entry; the account marks are judged as usual:"
        ;;
      account=unlisted)
        echo "the directory this lane's credential lives in is no lane lanes keeps an inventory for, so the account mark is not judged and this gap is reported rather than held; the context mark is judged as usual:"
        ;;
      account=timeout)
        echo "the account read did not finish inside this hook's ceiling, so whether the account is about to wall is unknown; the gap is reported rather than held, because a lane whose account nothing can measure must still be able to end a turn. The account is not read as room:"
        ;;
      account=unmeasured)
        echo "the account this lane runs its credential out of could not be measured, so whether it is about to wall is unknown; the gap is reported rather than held, and an account nothing measured is never read as room:"
        ;;
      marks=timeout)
        echo "the overseer mark judgement did not finish inside this hook's ceiling, so none of this session's own triggers is judged; the gap is reported rather than held, because an overseer whose marks nothing can measure must still be able to end a turn. No trigger is read as room:"
        ;;
      marks=unmeasured)
        echo "oversee-succeed could not take one reading this session's triggers use, and the other did not fire; the gap is reported rather than held, and a reading nothing took is never read as room. Its own line, naming the figure that was missing, is below:"
        ;;
      marks=unjudged)
        echo "oversee-succeed, the one judge of this session's own marks, gave an answer this hook cannot act on: a run that printed nothing usable, or a keyed line naming a mark without the figure it read or a kind this hook does not know. No trigger is judged; the gap is reported rather than held, because the same command is the route out of the refusal and a session told to run one that cannot answer could never end a turn. What it wrote is below:"
        ;;
      context=*)
        if [ "$ROLE" = overseer ]; then
          printf 'oversee-succeed requires handoff under the shared context rule at %s tokens used, with an effective percentage setting of %s. Succeed this session yourself. This refusal reports context at turn end; the watch reports account triggers.\n%s\n' \
            "$2" "$MARK" "$HANDOFF_INSTRUCTION"
        else
          printf 'this lane requires handoff under the shared context rule: tokens used=%s, effective capacity=%s, effective percentage setting=%s. An empty capacity means unknown. No handoff record stands. Write the handoff so the next session can continue the work.\n%s\n' \
            "$2" "$WINDOW" "$MARK" "$HANDOFF_INSTRUCTION"
        fi
        ;;
      headroom=*)
        if [ "$ROLE" = overseer ]; then
          printf 'oversee-succeed reads the account this overseer runs its credential out of as having %s percent headroom left, at or below the ORCH_OVERSEER_HEADROOM_PCT mark of %s. Succeed this session yourself: a walled overseer runs no turn at all, so it reads no mail, handles no event and cannot hand over once the wall lands.\n%s\n' \
            "$2" "$PCT" "$HANDOFF_INSTRUCTION"
        else
          printf 'the account this lane runs its credential out of has %s percent headroom left, at or below the ORCH_HANDOFF_HEADROOM_PCT mark of %s, and no handoff record stands. Hand this lane off yourself: the account walls mid-round otherwise.\n%s\n' \
            "$2" "$PCT" "$HANDOFF_INSTRUCTION"
        fi
        ;;
      rate=*)
        printf 'oversee-succeed projects that this overseer account will reach its wall in %s minutes, at or before the ORCH_OVERSEER_WALL_MINUTES mark of %s. Succeed this session yourself before the account walls.\n%s\n' \
          "$2" "$MARK" "$HANDOFF_INSTRUCTION"
        ;;
      qualifying=*)
        printf 'oversee-succeed reads a qualifying-account count of %s against the ORCH_OVERSEER_SUCCESSOR_ACCOUNTS mark of %s, by the rule oversee-succeed --help states. The account this session runs on reads headroom=%s, where none or unreadable is an account nothing measured rather than one spent. Succeed this session yourself onto another account before no account remains.\n%s\n' \
          "$2" "$MARK" "${MARK_HEADROOM:-none}" "$HANDOFF_INSTRUCTION"
        ;;
      question-tool=*)
        if [ "$CALLER" = subagent ]; then
          printf 'this agent works in a lane, and a lane asks its overseer only through lane mail: %s opens a dialog on a pane the overseer cannot see or answer. Stop, and report the question to the lead, which sends it with lane-mail ask.\n' "$2"
        else
          printf 'this session is a lane, and a lane asks its overseer only through lane mail: %s opens a dialog on a pane the overseer cannot see or answer. Write the question to a file and send it, then wait on the id the send prints:\n%s\n' \
            "$2" "$ASK_ROUTE"
        fi
        ;;
      idle=*)
        printf 'this lane ended its turn with no lane-mail ask or notice sent since its last turn end, no handoff recorded and no halt standing. Its overseer reads the mailbox, never the pane. Read the lane'"'"'s mail and continue the workflow:\n%s\nA question only the overseer can answer is written to a file and sent, then waited on by the id the send prints:\n%s\nWork that is finished or blocked is written to a file and sent as a notice, and so is a turn that ends to wait on a dispatched agent or an armed wake: the notice names what the lane waits on, and the turn then ends:\n%s\n' \
          "$INBOX_ROUTE" "$ASK_ROUTE" "$NOTICE_ROUTE"
        ;;
      lane-idle=*)
        echo "this lane ended a turn that a stop hook's refusal continued, with no lane-mail ask or notice sent since its previous turn end, no handoff recorded and no halt standing. This hook refuses that turn end no further."
        ;;
      idle-notice=*)
        echo "this lane ended a turn that a stop hook's refusal continued, with no lane-mail ask or notice sent since its previous turn end, so this hook refuses it no further: the overseer is sent a lane notice stating so, and the turn ends"
        ;;
      idle-notice-unsent=*)
        echo "this lane ended a turn that a stop hook's refusal continued, with no lane-mail ask or notice sent since its previous turn end, and the notice that tells the overseer so exited $2, so nobody is told; the turn ends rather than loop on a refusal in a row. The sender's words follow:"
        ;;
      idle-record=*)
        echo "$2, the count of asks and notices this lane had sent at its last turn end, is not a plain file holding a whole number and at most the word held, so what this turn sent is unknown; the turn ends unjudged and the record is rewritten with the current count"
        ;;
      idle-unrecorded=*)
        echo "$2, the count of asks and notices this lane has sent, could not be written, so the next turn end compares against the record it already holds:"
        ;;
      idle-hold-unrecorded=*)
        echo "$2, the count of asks and notices this lane has sent, could not take this turn end's hold, so the hold is not made, since one with no record is made again on every continued turn:"
        ;;
      idle-notice-unrecorded=*)
        echo "$2, the count of asks and notices this lane has sent, could not take the idle notice this hook sent, so the next turn end reads that notice as the lane's own send and passes unheld:"
        ;;
      events=envelope)
        echo "an envelope the lane mailbox reader's events listing printed could not be read, so whether this lane sent anything this turn is unknown; the turn ends unjudged rather than held, because nothing a lane does at its turn end repairs its mailbox:"
        ;;
      events=*)
        echo "the lane mailbox reader's events listing exited $2, so whether this lane sent anything this turn is unknown; the turn ends unjudged rather than held, because nothing a lane does at its turn end repairs its mailbox:"
        ;;
      notice=unwritten)
        echo "the notice carrying the lane's unread messages could not be written, so they stay unread for the next point that delivers them:"
        ;;
      rows-skipped=*)
        echo "the orch session rows library is not in this hook's install, so no row of this session's own events is written and the overseer judgement reads its pane, the named fallback:"
        ;;
      rows-unwritten=*)
        echo "this session's event row could not be written, so the overseer judgement reads what the file already holds or, with no row, the pane, the named fallback; the session goes on:"
        ;;
      lane-rows-skipped=*)
        echo "the orch session rows library is not in this hook's install, so this Pi lane's turn row is not written and oversee-watch and lanes state judge the lane from the rows already written, or unjudged with none; the lane goes on:"
        ;;
      lane-rows-unwritten=*)
        echo "this Pi lane's turn row could not be written, so oversee-watch and lanes state judge the lane from the rows the file already holds; the lane goes on:"
        ;;
      unread=*)
        if [ "$MAILBOX_ITEM" = overseer ]; then
          printf 'the fleet record of the checkout this session works in names this session'"'"'s pane and no live watch holds the fleet state, so this session reads that checkout'"'"'s overseer mailbox; a peer repository or the owner sent these messages there. Act on each as its text directs:\n%s\n' "$UNREAD"
        else
          printf 'the overseer sent these messages to this lane; act on each as its text directs:\n%s\n' "$UNREAD"
        fi
        if [ "$CALLER" = lead ] && [ -n "$ACK_COMMAND" ]; then
          printf 'a halt among them refuses every tool call but one until the lane runs exactly this command:\n%s\n' "$ACK_COMMAND"
        fi
        ;;
      fleet-state=*)
        echo "the checkout's overseer mailbox holds a file, and whether a live watch holds the fleet state and reads it could not be settled by the orch file named above, so the mailbox is neither read here nor passed as read; the cause follows:"
        ;;
      lead-unrecorded=none)
        echo "this Copilot session start names no session id this hook can record, so the session's tool calls read as a caller it cannot name: they are handed no mail, and a halt's refusal does not show the command that reads it, which the turn end still hands over"
        ;;
      lead-unrecorded=*)
        echo "this Copilot session is the lead, and its record at $2 could not be written, so its tool calls read as a caller it cannot name: they are handed no mail, and a halt's refusal does not show the command that reads it, which the turn end still hands over:"
        ;;
      leads-unpruned=*)
        echo "the Copilot lead records or pending reading markers under $2 untouched for $LEAD_DAYS days could not be removed; this session's own lead record stands:"
        ;;
      session-unrecorded=*)
        case "$ARM" in
          compact)
            echo "this Copilot compaction's session $2 is no lead session this install recorded at a session start or at a turn end its own transcript proved, so it may be a subagent's compacting its own window: nothing is flagged, and no turn end of the lead's is held for it"
            ;;
          usage)
            echo "this Copilot context reading's session $2 is no lead session this install recorded at a session start or at a turn end its own transcript proved, so the reading is recorded nowhere and the session's turn end reports its context unmeasured under reading-unrecorded; once a turn end whose transcript proves the session the lead's records it, its later readings are recorded"
            ;;
          *)
            echo "this finished Copilot tool call's session $2 is no lead session this install recorded at a session start or at a turn end its own transcript proved, so it may be a subagent's: the unread lines are not handed over here and stay unread for the lead's turn end, which hands them over and acknowledges them"
            ;;
        esac
        ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
}

# A JSON string literal for TEXT, built here and not by jq: the refusal for a
# missing jq is the one that cannot borrow it, and on Copilot a refusal with
# no answer on stdout is a turn end that passes. Backslash and quote are
# escaped and every control character JSON forbids raw is written as \u00XX;
# bytes past ASCII pass as they are, which is what JSON reads.
json_string() { # TEXT
  local s="$1" bs=\\ q='"' octal c u
  s=${s//"$bs"/"$bs$bs"}
  s=${s//"$q"/"$bs$q"}
  for octal in 001 002 003 004 005 006 007 010 011 012 013 014 015 016 017 \
      020 021 022 023 024 025 026 027 030 031 032 033 034 035 036 037; do
    printf -v c '%b' "\\0$octal"
    printf -v u '\\u%04x' "0$octal"
    s=${s//"$c"/$u}
  done
  printf '"%s"' "$s"
}

# The one exit for a refusal, KEY VALUE [CAUSE] as `message` takes them:
# every arm above the handoff marks, the arm check, the payload readers and
# every mailbox refusal; the handoff refusals reach it through
# `refuse_handoff` below, the one site that builds the instruction, so no
# other path pays for text it would not print. The text is rendered once,
# written to stderr, and on Copilot handed back as the documented answer for
# the event on stdout, since there the exit status alone holds nothing: a
# turn end is held with `{"decision":"block","reason":...}` at exit 0, the one
# form its reference gives for agentStop; a tool call is denied with
# `{"permissionDecision":"deny","permissionDecisionReason":...}` under the exit
# 2 that denies on its own, so the call is refused whichever of the two the
# CLI reads first and the words reach the model either way; and a finished
# tool call is handed `{"additionalContext":...}` at exit 0, because its
# reference logs a postToolUse exit 2 for the user and parses stdout only at
# exit 0. The reason is the same text the keyed stderr line carries. Every
# other harness takes the exit status and stderr alone. Where mail_check set
# ACK_LINES, the mailbox cursor moves once the answer is written and before
# the exit, so a hook killed at its budget leaves the lines unread rather
# than consumed unseen. A session
# start and a prompt are never refused: there the keyed text is a report on
# stderr at exit 0, with nothing on stdout and nothing acknowledged. A
# compaction cannot be held either, but its reference shows a non-zero exit
# to the operator as a warning while the compaction goes on, so there the
# keyed text is on stderr at exit 2 with nothing on stdout, as on every
# harness but Copilot's other events. A context reading takes no answer either:
# the extension that runs it writes the keyed text of a run that exits
# non-zero to the session timeline, so there too the text is on stderr at exit
# 2. No caller exits on its own: the status is this function's, and it never
# returns.
ACK_LINES=""
refuse() { # KEY VALUE [CAUSE]
  local text
  text=$(message "$@" 2>&1)
  printf '%s\n' "$text" >&2
  case "$ARM" in
    start | prompt) exit 0 ;;
  esac
  if [ "$HARNESS" = copilot ]; then
    case "$ARM" in
      stop) printf '{"decision":"block","reason":%s}\n' "$(json_string "$text")" ;;
      halt) printf '{"permissionDecision":"deny","permissionDecisionReason":%s}\n' "$(json_string "$text")" ;;
      deliver) printf '{"additionalContext":%s}\n' "$(json_string "$text")" ;;
    esac
  fi
  [ -z "$ACK_LINES" ] || acknowledge
  case "$HARNESS:$ARM" in
    copilot:stop | copilot:deliver) exit 0 ;;
  esac
  exit 2
}

# The event this run judges: a turn end with no argument, or the arm the
# lane-mail-deliver, lane-mail-halt, lane-mail-start, lane-mail-prompt,
# session-start-row, session-end-row, stop-failure-row or lane-mail-compact
# hook beside this one names, or `usage`, which the orch copilot-lane-context
# extension names. The three arms that hand mail over as
# context carry the event name that context is written under. `row` judges
# nothing: it writes the session's own event row and refuses nothing.
# `compact` flags a Copilot session's automatic compaction, which its next
# turn end judges, and `usage` records a Copilot session's context reading,
# which the same turn end judges.
case "${1:-stop}" in
  stop | halt | row | compact | usage) ARM="${1:-stop}" ;;
  deliver) ARM=deliver CONTEXT_EVENT=PostToolUse ;;
  start) ARM=start CONTEXT_EVENT=SessionStart ;;
  prompt) ARM=prompt CONTEXT_EVENT=UserPromptSubmit ;;
  *) refuse arm "$1" ;;
esac

# The payload readers come first and alone: the flag that ends a stop hook's
# retry is in that payload, so refusing any other absence ahead of it would
# refuse the retry too, which is the loop the flag exists to end.
MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# cat's words are captured rather than left to precede the refusal: on failure
# the substitution holds them and the refusal replays them under the keyed line.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# One read of the payload: the turn-end retry flag, whether the payload names
# a subagent, the transcript the harness records this session in, the id it
# names this session by, the tool a call about to run names, and the context
# window carried by Pi. A subagent's call carries agent_id on one harness and
# agent_type on another; the lane lead's carries neither. Copilot spells the
# transcript and the session in camelCase under the event name kendex
# registers, so those two are read in both spellings, the snake_case one
# first. Its hooks reference spells the agentStop retry flag
# `stop_hook_active` all the same, and `question_tool` names no Copilot tool,
# so the flag and `tool_name` are read in the one spelling. Last, whether
# Copilot made the call, read from the call and never from the install: both
# payload formats its reference gives carry `timestamp`, and its own camelCase
# one names the session `sessionId`; no Claude, Codex or Pi payload carries
# either. Last the `trigger` a Copilot preCompact payload names, manual or
# auto, in the one spelling both its formats share, and the `cwd` the
# extension's usage payload names the session's directory by, read for that
# arm alone. TAB separators preserve transcript spaces.
READ=$(printf '%s' "$INPUT" | jq -r --arg arm "$ARM" '
  def str(f): if f == null then "" elif (f | type) == "string" then f else error("not a string") end;
  def whole(f): if f == null then "" elif (f | type) == "number" and f > 0 and f == (f | floor)
    then (f | tostring) else error("not a whole number") end;
  def either(a; b): if a != null then a else b end;
  [(.stop_hook_active == true | tostring),
   (if str(.agent_id) + str(.agent_type) == "" then "lead" else "subagent" end),
   str(either(.transcript_path; .transcriptPath)),
   str(either(.session_id; .sessionId)),
   str(.tool_name),
   whole(.context_window),
   (if type == "object" and (has("timestamp") or has("sessionId")) then "copilot" else "" end),
   str(.trigger),
   (if $arm == "usage" then str(.cwd) else "" end)] | join("\t")' 2>&1) ||
  refuse payload invalid-json "$READ"
TAB=$(printf '\t')
ACTIVE=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
CALLER=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
TRANSCRIPT=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
SESSION=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
TOOL=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
PAYLOAD_WINDOW=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
CALL_HARNESS=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
TRIGGER=${READ%%"$TAB"*}
PAYLOAD_CWD=${READ#*"$TAB"}
# A Copilot call reaches an install that is not Copilot's only through a
# registration made in `.claude/settings.json` by hand or one kendex wrote
# before the Copilot skip that no refresh has rewritten; kendex's own current
# registration exits 0 before the script. That install passes it
# silently, exit 0 with nothing written and nothing acknowledged: its answers
# take a shape Copilot does not read and its caller rules are not Copilot's,
# so the Copilot install is the one reader of the mailbox for a Copilot call.
if [ "$CALL_HARNESS" = copilot ] && [ "$HARNESS" != copilot ]; then exit 0; fi
# The id is composed into the fleet handoff record below, so it is held to the
# alphabet a harness spells one in rather than handed to a second JSON encoder.
# A payload spelling it any other way leaves this empty, which is the same
# answer as a payload carrying no id: the record falls back to the pane key,
# the pair the fleet state already keys the overseer on.
case "$SESSION" in
  '' | *[!A-Za-z0-9._-]*) SESSION="" ;;
esac

# Copilot's lead sessions, recorded so a tool call can be told from a
# subagent's: one empty file per session id under the user's cache, outside
# every source tree, since a custom subagent's pre- and postToolUse payloads
# carry its own session id and nothing else that names it, as Copilot CLI
# 1.0.88 was measured sending them. A session records itself at
# its sessionStart, which Copilot fires for the lead alone, a resume included,
# and at every turn end its own transcript proves it the lead's, which also
# records a lead whose start this install missed and refreshes an active one.
# A record is matched only by the session it names, so one a crashed or ended
# session left misleads no other; records untouched for LEAD_DAYS are pruned
# at each start, and a pruned lead that is still running records itself again
# at its next turn end. An environment variable names no session here: a CLI
# launched from another Copilot session inherits that session's.
COPILOT_LEADS="${HOME:-}/.cache/lane-mail/copilot-leads"
# The pending markers the orch copilot-lane-context extension leaves, one per
# session with a context reading handed to the usage arm and not yet recorded
# (copilot_reading_pending). Pruned with the lead records.
COPILOT_USAGE="${HOME:-}/.cache/lane-mail/copilot-usage"
LEAD_DAYS=30
LEAD_FILE=""
copilot_lead_file() { # 0 with LEAD_FILE set, 1 where the payload names no session
  [ -n "$SESSION" ] || return 1
  LEAD_FILE="$COPILOT_LEADS/$SESSION"
}
# A record that cannot be written is reported and never refused: the session
# goes on as a caller its tool calls leave unknown, which mail_check serves
# without handing it the lead's mail or the read that clears a halt.
record_lead() { # [prune]
  local err
  if ! copilot_lead_file; then
    message lead-unrecorded none
    return 0
  fi
  if ! err=$(mkdir -p -- "$COPILOT_LEADS" 2>&1 && touch -- "$LEAD_FILE" 2>&1); then
    message lead-unrecorded "$LEAD_FILE" "$err"
    return 0
  fi
  [ "${1:-}" = prune ] || return 0
  local dir
  for dir in "$COPILOT_LEADS" "$COPILOT_USAGE"; do
    [ -d "$dir" ] || continue
    err=$(find "$dir" -type f -mtime +"$LEAD_DAYS" -exec rm -f -- {} + 2>&1) ||
      message leads-unpruned "$dir" "$err"
  done
  return 0
}

# Who made the call, answered here once for every arm: lead, subagent, or
# unknown where the payload cannot tell. The read above answers subagent for a
# payload naming an agent, on every harness. Copilot's payloads name none, so
# there the rest is settled by event, by what Copilot CLI 1.0.88 was measured
# sending a lead and a custom subagent it started:
# - agentStop: the transcript. The lead's is the session's own,
#   `session-state/<session id>/events.jsonl`, so a stop whose transcript sits
#   in a directory named for the session id is the lead's, and records it. A
#   subagent's agentStop carries the subagent's own session id and names the
#   lead's transcript, so the directory names another session and the stop is
#   a subagent's. A stop naming no transcript, or no session the alphabet above
#   admits, is the lead's and records nothing: an empty session name matches no
#   directory and would otherwise make every such stop a subagent's.
# - preToolUse, postToolUse, preCompact and usage: the lead's where the
#   session is a recorded lead, and otherwise unknown, the one rule for every
#   Copilot arm that cannot prove the lead itself. They carry neither an agent
#   nor a transcript the rule above can trust, and a custom subagent's carry a
#   session id no sessionStart announced; a preCompact names a transcript, but
#   what a subagent's names is unmeasured, and a usage reading is the one the
#   extension took of the session's root agent, under the session id the hooks
#   see. An unknown caller is handed no mail and acknowledges none, so such a
#   subagent cannot take the lead's directive, which the lead's turn end hands
#   over; under a halt it is never shown the read that clears the halt, and
#   mail_check states why that read still passes. Its compaction flags nothing
#   and its reading is recorded nowhere, so a subagent never marks the lead's
#   session. Whether a built-in task-tool subagent's calls carry their own
#   session id or the lead's is a pending live-lane proof: one whose calls
#   carry the lead's is read as the lead, handed the lead's mail after its
#   calls, which marks it read, and under a halt shown the read that clears it.
# - sessionStart: the lead's, and recorded, being the session's own start.
# - userPromptSubmitted: the lead's, and never recorded: that a subagent's
#   prompt fires no such hook is unmeasured.
if [ "$CALLER" = lead ]; then
  case "$HARNESS:$ARM" in
    copilot:start) record_lead prune ;;
    copilot:stop)
      if [ -n "$TRANSCRIPT" ] && [ -n "$SESSION" ]; then
        TRANSCRIPT_DIR="${TRANSCRIPT%/*}"
        TRANSCRIPT_DIR="${TRANSCRIPT_DIR##*/}"
        if [ "$TRANSCRIPT_DIR" = "$SESSION" ]; then
          record_lead
        else
          CALLER=subagent
        fi
      fi
      ;;
    copilot:deliver | copilot:halt | copilot:compact | copilot:usage)
      { copilot_lead_file && [ -f "$LEAD_FILE" ]; } || CALLER=unknown
      ;;
    *) ;;
  esac
fi

# The harness sets stop_hook_active on the turn it continued because a stop
# hook blocked. That turn skips the mailbox check whole, and everything the
# lane cannot clear is reported rather than refused on it.
CONTINUED=false
if [ "$ARM" = stop ] && [ "$ACTIVE" = "true" ]; then CONTINUED=true; fi

# Refuse on a fresh turn end; on a continued one and before a tool call,
# report the same line and pass. Only this hook's acknowledgement and the
# lane's own handoff record clear a refusal, and every other one repeats for
# as long as its cause stands: at every turn end, which is the loop
# stop_hook_active exists to end, and in the halt arm
# at every tool call, where the lane can clear nothing because clearing it
# takes the tool call this hook refuses. The handoff marks are not stalled:
# the record clears them and only the lane can write it. A session start and
# a prompt take no part here: `refuse` itself reports and passes on those two
# arms, the one place that rule is held.
REPORTED=false
case "$CONTINUED:$ARM" in
  true:* | *:halt | *:row) REPORTED=true ;;
esac
stall() { # KEY VALUE [CAUSE]
  if [ "$REPORTED" = true ]; then
    message "$@"
    exit 0
  fi
  refuse "$@"
}

# Lane mail belongs to the lane lead: a subagent's finished call, session
# start or prompt is handed none and acknowledges none, so the lead's own run
# still finds it unread.
if [ -n "$CONTEXT_EVENT" ] && [ "$CALLER" = subagent ]; then
  exit 0
fi
# A compaction the caller rule does not name the lead's is a subagent's own
# window's, or a lead's whose record could not be written, and flags nothing
# for the lead; it is passed before any gap of the lead's is reached, the
# unknown one's automatic compaction reported on stderr at exit 0, since a
# warning to the operator at every subagent's compaction would bury the gaps
# the compact arm refuses.
if [ "$ARM" = compact ] && [ "$CALLER" != lead ]; then
  [ "$CALLER" != unknown ] || [ "$TRIGGER" != auto ] || message session-unrecorded "${SESSION:-none}"
  exit 0
fi

MISSING=""
for dependency in git tr awk mktemp tail; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || stall missing-tools "${MISSING#,}"

# The template is what makes TMPDIR the parent on both implementations:
# BSD mktemp reads TMPDIR only from a template or -t, and would otherwise
# work under /tmp while the stall report below names TMPDIR.
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/lane-mail-check.XXXXXX" 2>&1) || stall workdir "${TMPDIR:-/tmp}" "$WORK_DIR"
trap 'rm -rf -- "$WORK_DIR"' EXIT

# The lane's root, in this order: the directory Claude Code started the
# session in; else the root the launch marker for LANE_MAIL_ITEM binds, where
# that root exists; else the directory the call runs in. A lane runs its
# post-merge steps from the main clone, and a judge that asked the call's
# directory there found no mailbox and passed every call made from it, the arm
# step included. Codex and Pi run a hook in the session's start directory, so
# on them the last step is the lane's own root already. A Copilot context
# reading starts from the session directory its payload names.
#
# Git reports one status for a directory that is no repository and for
# metadata it cannot read, and a lane always runs in one. So that directory
# answers: with no mailbox under it this session is not a lane and passes;
# with one the lane cannot be named, which is never passed off as no lane.
# The common git directory rides the same call: the launch markers live there.
LANE_DIR=${CLAUDE_PROJECT_DIR:-$PWD}
[ "$ARM" != usage ] || LANE_DIR=$PAYLOAD_CWD
GIT_RC=0
GIT_DIRS=$(git -C "$LANE_DIR" rev-parse --show-toplevel --path-format=absolute --git-common-dir 2>&1) ||
  GIT_RC=$?
if [ "$GIT_RC" -ne 0 ]; then
  [ -d "$LANE_DIR/tmp/lane-mail" ] || exit 0
  stall git "-C $LANE_DIR rev-parse --show-toplevel --git-common-dir" "$GIT_DIRS"
fi
ROOT=${GIT_DIRS%%"$NL"*}
COMMON=${GIT_DIRS#*"$NL"}

item_alphabet() { # NAME
  case "$1" in
    '' | . | ..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The launch marker for ITEM, and the one place in this hook its path is
# composed: lane-marker writes the lane's root to lane-mail/<item in lower
# case> under the common git directory. MARKER is that path and BOUND the root
# it binds, empty where no marker stands. Read with the builtin, which forks
# nothing, and once per marker: a second ask for the same one answers from the
# first read. A marker present but not a readable plain file is refused rather
# than read as no lane.
MARKER=""
BOUND=""
read_marker() { # ITEM
  local path
  path="$COMMON/lane-mail/$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
  [ "$path" != "$MARKER" ] || return 0
  MARKER="$path"
  BOUND=""
  [ -e "$MARKER" ] || [ -L "$MARKER" ] || return 0
  { [ -f "$MARKER" ] && [ ! -L "$MARKER" ] && [ -r "$MARKER" ]; } || stall marker "$MARKER"
  IFS= read -r BOUND <"$MARKER" || :
}

# The branch ROOT has checked out, empty for a HEAD that names none.
# `symbolic-ref -q` exits 1 for a HEAD that names no branch — detached, and
# never a lane — and 128 for a repository it cannot read, so the two are told
# apart without reading git's prose. The answer lands in a variable rather
# than a substitution's stdout, so the refusal's exit is the hook's.
BRANCH=""
read_branch() {
  BRANCH_RC=0
  BRANCH=$(git -C "$ROOT" symbolic-ref -q --short HEAD 2>&1) || BRANCH_RC=$?
  case "$BRANCH_RC" in
    0) ;;
    1) BRANCH="" ;;
    *) stall git "-C $ROOT symbolic-ref -q --short HEAD" "$BRANCH" ;;
  esac
}

if [ -z "${CLAUDE_PROJECT_DIR:-}" ] && [ -n "${LANE_MAIL_ITEM:-}" ] &&
  item_alphabet "$LANE_MAIL_ITEM"; then
  read_marker "$LANE_MAIL_ITEM"
  [ -z "$BOUND" ] || [ ! -d "$BOUND" ] || ROOT="$BOUND"
fi
MAIL_ROOT="$ROOT/tmp/lane-mail"

# Whether the call about to run is exactly COMMAND: the one call a refusal
# before a tool call passes, so the lane can run what clears it. No call is
# outside the halt arm; which callers the pass is offered to is each site's
# own rule.
#
# The command is read where each harness carries it: `tool_input.command`, or
# Copilot's `toolArgs.command`, whose `toolArgs` arrives as an object or as
# one JSON-encoded string, the same two shapes the block-argv-kill hook reads.
call_runs() { # COMMAND
  [ "$ARM" = halt ] || return 1
  COMMAND=$(printf '%s' "$INPUT" | jq -r '
    def copilot: .toolArgs
      | if . == null then null elif type == "string" then fromjson else . end
      | if . == null then null elif type == "object" then .command else null end;
    (.tool_input | objects | .command | strings)
      // (copilot | strings) // ""' 2>&1) ||
    refuse payload invalid-json "$COMMAND"
  [ "$COMMAND" = "$1" ]
}

# A root its launch marker binds is a lane whatever else it lacks, and a lane
# with no mailbox directory reads no halt and no directive while its overseer's
# sends have nowhere to land. So it is refused, naming the marker and the one
# command that restores the directory; that command alone passes a tool call,
# as the acknowledging read passes a halt. A subagent is refused it and told
# to report the gap; a caller the payload leaves unknown may run it, since the
# directory holds no mail it could consume and the lane cannot otherwise
# restore it while every call is refused. The command makes the directory and
# no more: the hook knows the item only in lower case, the marker's and the
# branch's spelling, and a mailbox made in that case would be refused by
# lane-mail as a case variant of the one the overseer sends to, which the first
# send creates under the directory itself.
#
# The marker is looked up for the item the lane is named by, LANE_MAIL_ITEM or
# else the branch, which `worktree create` names after the item in lower case.
# A repository no launch reached has no lane-mail directory under its common
# git directory and pays that one stat; one that has pays a branch read and one
# marker's stat, however many lanes it launched.
if [ "$ARM" != row ] && [ ! -d "$MAIL_ROOT" ] && [ -d "$COMMON/lane-mail" ]; then
  NAMED=${LANE_MAIL_ITEM:-}
  if [ -z "$NAMED" ]; then
    read_branch
    NAMED=$BRANCH
  fi
  if item_alphabet "$NAMED"; then
    read_marker "$NAMED"
    if [ "$BOUND" = "$ROOT" ]; then
      printf -v MAILBOX_COMMAND 'mkdir -p -- %q' "$MAIL_ROOT"
      [ "$CALLER" = subagent ] || ! call_runs "$MAILBOX_COMMAND" || exit 0
      refuse mailbox-missing "$MAIL_ROOT"
    fi
  fi
fi

# The item is what the lane's launch brief set, or the mailbox whose name is
# the branch: `worktree create` names a lane's branch after its item in lower
# case, so the branch selects it without a second copy of any id grammar.
#
# Past the refusal above, a root with no mailbox directory holds no fleet lane:
# a launch creates the lane's own directory there beside its marker and a
# marked root without one was refused, so this stat gates the whole of item
# discovery, the branch read that answers it included. It does not gate the
# marks below: an empty ITEM leaves them to ask whether this session is the
# fleet's overseer, which no mailbox names, and that question costs nothing
# outside tmux.
ITEM=""
if [ -d "$MAIL_ROOT" ]; then
  read_branch
  if [ -n "${LANE_MAIL_ITEM:-}" ]; then
    item_alphabet "$LANE_MAIL_ITEM" || stall item invalid
    ITEM="$LANE_MAIL_ITEM"
  elif [ -n "$BRANCH" ]; then
    LOWER_BRANCH=$(printf '%s' "$BRANCH" | tr 'A-Z' 'a-z')
    MATCHES=0
    for candidate in "$MAIL_ROOT"/*; do
      [ -d "$candidate" ] || continue
      name=${candidate##*/}
      item_alphabet "$name" || continue
      [ "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" = "$LOWER_BRANCH" ] || continue
      ITEM="$name"
      MATCHES=$((MATCHES + 1))
    done
    [ "$MATCHES" -le 1 ] || stall item ambiguous
  fi
fi

# A launch makes a lane: open-terminal and lane-host create write the lane's
# root to lane-mail/<item in lower case> under the common git directory, which
# no checkout carries, so a mailbox a repository commits never poses as one.
# Answered once per run: the mailbox and the marks both rest on it, and the
# marks are reached on a turn end the mailbox had nothing to say on.
#
# Called on the left of `||` at both sites, so bash suspends errexit for this
# whole body; every status is tested where it is taken.
LAUNCHED=""
lane_launched() { # 0 where a launch recorded this lane, 1 where none did
  if [ -n "$LAUNCHED" ]; then
    [ "$LAUNCHED" = yes ] || return 1
    return 0
  fi
  read_marker "$ITEM"
  LAUNCHED=no
  [ "$BOUND" != "$ROOT" ] || LAUNCHED=yes
  [ "$LAUNCHED" = yes ] || return 1
  return 0
}

# The reader comes from this hook's own install, never from whichever
# repository the session has open: a repository can track a mailbox and an
# executable at .agents/skills/orch/scripts/lane-mail, and running that hands
# it a command at every turn end with no prompt. The walk is the one
# hooks/command-safety.sh makes for the commit-guards library, and the
# repository's own copy is read only where this hook is installed in it.
# Two skill roots per level: a harness's own skills directory and the shared
# `.agents/skills` tree several read. The walk stops at the home directory, the
# far edge of a global install: Pi's hook sits four directories under it.
#
# What it could not settle lands in FAIL_*, because the two callers answer it
# differently: a mailbox with a file in it cannot be left unread, while the
# handoff marks pass a lane whose install cannot record a handoff either.
# Called on the left of `||` at both sites, so bash suspends errexit for this
# whole body; every status is tested where it is taken.
READER=""
HOOK_DIR=""
resolve_reader() { # 0 with READER and SCRIPTS set, 2 with FAIL_* naming the gap
  [ -z "$READER" ] || return 0
  FAIL_KEY=reader
  FAIL_VALUE=unlocatable
  FAIL_CAUSE=""
  # `cd`'s own words are captured rather than left to the hook's stderr: they
  # would otherwise stand ahead of the keyed line, which is the one thing this
  # hook's output contract forbids. A refresh that replaces this hook's
  # directory while a turn ends is what removes it underfoot.
  HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>"$WORK_DIR/hookdir.err" && pwd -P) || {
    FAIL_CAUSE=$(cat -- "$WORK_DIR/hookdir.err")
    return 2
  }
  HOME_DIR=$(cd -- "${HOME:-/}" 2>/dev/null && pwd -P) || HOME_DIR=""
  AT="$HOOK_DIR"
  LEVELS=0
  while [ "$LEVELS" -lt 5 ] && [ "$AT" != "$ROOT" ] && [ "$AT" != / ]; do
    for CANDIDATE in "$AT/skills/orch/scripts/lane-mail" "$AT/.agents/skills/orch/scripts/lane-mail"; do
      if [ -x "$CANDIDATE" ]; then READER="$CANDIDATE"; break; fi
    done
    { [ -z "$READER" ] && [ "$AT" != "$HOME_DIR" ]; } || break
    AT="${AT%/*}"
    [ -n "$AT" ] || AT=/
    LEVELS=$((LEVELS + 1))
  done
  # CODEX_HOME and PI_CODING_AGENT_DIR move a harness's global root out of the
  # home directory, and the walk above then climbs ancestors kendex installed
  # nothing under. The shared tree is still the person's own, so it is offered
  # by name — unless the open repository is the home directory itself, where it
  # would be that repository's file rather than an install.
  if [ -z "$READER" ] && [ -n "$HOME_DIR" ] && [ "$HOME_DIR" != "$ROOT" ]; then
    CANDIDATE="$HOME_DIR/.agents/skills/orch/scripts/lane-mail"
    [ ! -x "$CANDIDATE" ] || READER="$CANDIDATE"
  fi
  if [ -z "$READER" ]; then
    case "$HOOK_DIR" in
      "$ROOT"/*) READER="$ROOT/.agents/skills/orch/scripts/lane-mail" ;;
      *)
        FAIL_KEY=reader-outside
        FAIL_VALUE="$ROOT/.agents/skills/orch/scripts/lane-mail"
        return 2
        ;;
    esac
  fi
  if [ ! -x "$READER" ]; then
    FAIL_KEY=reader
    FAIL_VALUE="$READER"
    READER=""
    return 2
  fi
  SCRIPTS=${READER%/*}
  return 0
}

# --- the mailbox ---------------------------------------------------------
#
# Returns where the session has nothing waiting; exits where it has. The order
# is the cheapest question first: a mailbox never written to has no file to
# read, so neither a launch marker nor the reader beside this hook is looked
# for, and a session with no orch skill installed still ends its turns and
# runs its tools.

# Whether a live watch holds the fleet state at this checkout: 0 where the
# record a repeat `oversee-watch` keeps beside the state names a watch still
# running, 1 where none stands or it names none. That watch reads the overseer
# mailbox itself through the cursor this hook's reader would move, so the
# session the fleet record names, reading it beside the watch, would take lines
# the watch never reports. With no live watch that session is handed the lines,
# a fleet watched in single passes included, since such a watch writes no
# record; the next pass then does not report them. The state's path is the install's own `workflow-state path oversee` from the
# checkout's root, the address a fleet starts its watch on, and liveness is the
# watch record library's own `watch_pid_live`, run in a child shell so its
# names stay out of this one: that shell exits 0 or 1 with the answer, and 3
# where the library cannot be sourced. A path the script does not print, or a
# child that answers neither way, leaves the question unanswered and is
# refused, since reading the mailbox on an unknown answer could take a live
# watch's mail, and passing on one could leave a checkout's mail unread.
#
# Called in condition position, so bash suspends errexit for this whole body;
# every status is tested where it is taken.
watch_live() {
  STATE_RC=0
  FLEET_STATE=$(cd -- "$ROOT" && "$SCRIPTS/workflow-state" path "$OVERSEER_ITEM" 2>"$WORK_DIR/state.err") || STATE_RC=$?
  [ "$STATE_RC" -eq 0 ] && [ -n "$FLEET_STATE" ] ||
    refuse fleet-state "$SCRIPTS/workflow-state" "$(cat -- "$WORK_DIR/state.err")"
  STATE_RC=0
  "$BASH" -c '. "$1" || exit 3; watch_pid_live "$2"' \
    _ "$SCRIPTS/lib/watch-pid.sh" "$FLEET_STATE" 2>"$WORK_DIR/state.err" || STATE_RC=$?
  case "$STATE_RC" in
    0) return 0 ;;
    1) return 1 ;;
    *) refuse fleet-state "$SCRIPTS/lib/watch-pid.sh" "$(cat -- "$WORK_DIR/state.err")" ;;
  esac
}

# The mailbox this session reads, into MAILBOX_ITEM: its own where it is a
# launched lane, and otherwise the checkout's overseer mailbox, where nothing
# names this session a lane, the fleet record names this session's pane
# (overseer_identified) and no live watch holds the checkout's fleet state.
# The overseer mailbox has that one reader: `lane-mail peer send --repo` lands
# a note there for the checkout's overseer, and a session the owner opened in
# the same checkout for other work is no overseer, so it is handed nothing.
# The record's writers are the orch schemas/workflow-state.md `overseer` row's;
# `oversee register` among them is how a hand-opened session becomes the
# reader, and the overseer, of a checkout that runs no fleet. The halt arm takes no part: a halt into the
# overseer mailbox halts no one, by the reader's own contract, and lane mail
# belongs to a session's lead, so a subagent's turn end is handed none. A
# session whose install has no reader beside this hook cannot be established
# as the one the record names and is handed nothing, as its marks are judged
# on nothing. An ordinary session in a checkout with no overseer mailbox pays
# two file tests here, and outside tmux one with a mailbox pays the reader's
# resolution besides.
MAILBOX_ITEM=""
mail_check() {
  if [ -n "$ITEM" ]; then
    # Reading a file that is there is the orch reader's job: it owns the cursor,
    # so neither this hook nor a workflow wait point hands the same line twice.
    # Anything present at that path, a directory or a dangling link included,
    # goes on to the reader, whose component rule refuses what it cannot read.
    [ -e "$MAIL_ROOT/$ITEM/to-lane.jsonl" ] || [ -L "$MAIL_ROOT/$ITEM/to-lane.jsonl" ] || return 0
    lane_launched || return 0
    # Lane mail is the lead's: a subagent's turn end, which Copilot's
    # agentStop reports as it reports the lead's, is handed nothing, as its
    # finished tool call is.
    { [ "$ARM" != stop ] || [ "$CALLER" = lead ]; } || return 0
    MAILBOX_ITEM="$ITEM"
  else
    [ "$ARM" != halt ] || return 0
    [ "$CALLER" != subagent ] || return 0
    [ -e "$MAIL_ROOT/overseer/to-lane.jsonl" ] || [ -L "$MAIL_ROOT/overseer/to-lane.jsonl" ] || return 0
    resolve_reader || return 0
    overseer_identified || return 0
    ! watch_live || return 0
    MAILBOX_ITEM=overseer
  fi
  resolve_reader || refuse "$FAIL_KEY" "$FAIL_VALUE" "$FAIL_CAUSE"

  # Every reader call names the session's root: a lane verb otherwise roots
  # itself at the call's cwd, which is the main clone for a lane's post-merge
  # steps, and the overseer verb at the cwd's main checkout, which the root
  # holding the mailbox already is.
  RC=0
  PEEK=$("$READER" inbox --item "$MAILBOX_ITEM" --root "$ROOT" --peek 2>"$WORK_DIR/reader.err") || RC=$?
  [ "$RC" -eq 0 ] || refuse inbox "$RC" "$(cat -- "$WORK_DIR/reader.err")"
  # The reader's header, then the unread envelopes. LINES is the count the
  # acknowledgement below moves the cursor to.
  HEADER=${PEEK%%"$NL"*}
  case "$HEADER" in
    count=[0-9]*) ;;
    *) refuse inbox header ;;
  esac
  LINES=${HEADER#count=}
  LINES=${LINES%% *}
  case "$LINES" in
    *[!0-9]*) refuse inbox header ;;
  esac
  # The substitution dropped the trailing newline, so a peek with nothing unread
  # is its header alone and holds no newline at all.
  case "$PEEK" in
    *"$NL"*) UNREAD=${PEEK#*"$NL"} ;;
  esac
  [ -n "$UNREAD" ] || return 0

  # A halt among the unread lines stands until the lane runs the one plain
  # read that acknowledges it, ACK_COMMAND: the reader's `--ack` stops short of
  # an unread halt, so no notice or refusal here consumes one. The command
  # names the lane's root, so it reads this mailbox from whichever checkout the
  # lane's shell is in. Only the lead is shown it, in every notice and refusal
  # that carries the halt. A subagent is never shown it nor passed it, since
  # running it would clear the lead's halt. A caller the payload leaves
  # unknown is not shown it but is passed it: on Copilot that is a tool call
  # whose session is no recorded lead, which may be the lead's own where its
  # record could not be written, and a halt the lead's calls could not clear
  # would refuse them for good. That lead learns it at its turn end, session
  # start or prompt, each of which names it.
  HALT=$(printf '%s\n' "$UNREAD" | jq -c -s 'map(select(.halt == true)) | first // empty' 2>&1) ||
    refuse inbox envelope "$HALT"
  [ -z "$HALT" ] || printf -v ACK_COMMAND '%q inbox --item %q --root %q' "$READER" "$MAILBOX_ITEM" "$ROOT"

  # The halt arm acknowledges nothing. It refuses while an unread halt stands and
  # passes the one plain read that acknowledges it, so the lane can run that read.
  # Unread lines that hold no halt return rather than exit: the question rule
  # still judges the call, or a directive in the mailbox would open the dialog.
  if [ "$ARM" = halt ]; then
    [ -n "$HALT" ] || return 0
    HALT_ID=$(printf '%s' "$HALT" | jq -r '.id | strings' 2>&1) || refuse inbox envelope "$HALT_ID"
    HALT_TEXT=$(printf '%s' "$HALT" | jq -r '.text | strings' 2>&1) || refuse inbox envelope "$HALT_TEXT"
    case "$CALLER" in
      lead | unknown) ! call_runs "$ACK_COMMAND" || exit 0 ;;
      subagent) ;;
    esac
    refuse halt "$HALT_ID"
  fi

  COUNT=$(printf '%s\n' "$UNREAD" | awk 'END { print NR + 0 }')

  # After a tool call, at a session start and at a prompt the notice travels
  # as the context the harness's JSON carries, exit 0: an exit 2 after a tool
  # call replaces the tool's own output on one harness, and a session start or
  # a prompt is never refused. The keyed line opens that context. Claude Code
  # reads it under `hookSpecificOutput.additionalContext` beside the event's
  # name. On Copilot it is a top-level `additionalContext`: its hooks
  # reference appends that key to the tool result the model sees on the same
  # turn after postToolUse, which an isolated probe against Copilot CLI 1.0.88
  # showed the model quoting, and says a sessionStart hook can inject it into
  # the session. For userPromptSubmitted the same reference documents only
  # `modifiedPrompt` and says a config-file hook's output is dropped; what
  # shows the context reaching the model there is the owner's own probe, a
  # repository hook in a fresh `copilot -p` run against a negative control.
  # A live-lane capture of each of the three is the proof still pending.
  # Acknowledged only once it is written, so a write that fails leaves the
  # lines unread for the next point that delivers them.
  if [ -n "$CONTEXT_EVENT" ]; then
    # A subagent left above. A caller the payload leaves unknown is handed
    # nothing: on Copilot a custom subagent's finished call hands its context
    # to that subagent's own model and not the lead's, so the lines wait for the
    # lead's turn end, and the keyed line that says so goes to stderr alone.
    if [ "$CALLER" = unknown ]; then
      message session-unrecorded "${SESSION:-none}"
      exit 0
    fi
    NOTICE=$(message unread "$COUNT" 2>&1)
    if [ "$HARNESS" = copilot ]; then
      CONTEXT_SHAPE='{additionalContext: $text}'
    else
      CONTEXT_SHAPE='{hookSpecificOutput: {hookEventName: $event, additionalContext: $text}}'
    fi
    jq -nc --arg text "$NOTICE" --arg event "$CONTEXT_EVENT" "$CONTEXT_SHAPE" \
      2>"$WORK_DIR/notice.err" || refuse notice unwritten "$(cat -- "$WORK_DIR/notice.err")"
    ACK_LINES=$LINES
    acknowledge
    exit 0
  fi
  # Peek, then answer, then acknowledge: `refuse` moves the cursor only once
  # the refusal is written, so a hook killed at its budget leaves the lines
  # unread for the next stop rather than consumed unseen.
  ACK_LINES=$LINES
  refuse unread "$COUNT"
}

# The cursor move for the lines a notice or refusal carried, ACK_LINES being
# the count the reader's header gave. An acknowledgement that fails costs a
# repeat, never a loss, and its cause stands under the refusal.
acknowledge() {
  "$READER" inbox --item "$MAILBOX_ITEM" --root "$ROOT" --ack "$ACK_LINES" >/dev/null 2>"$WORK_DIR/ack.err" ||
    { cat -- "$WORK_DIR/ack.err" >&2 || :; }
}

# --- the question rule ---------------------------------------------------
#
# A lane asks its overseer only through lane mail: the overseer reads the
# mailbox and never the pane, so a harness question dialog reaches nobody, and
# on a hosted fleet the item stalls until a person finds the pane. The tool is
# refused by its name, the one fact a call carries about it, on every harness
# alike; a Pi-only route that turned Pi's question tool into a lane-mail ask
# would be a second path for the one ask lane mail already carries. A
# question the lane writes as words instead is the idle judge's below, which
# reads no words.
# Neither holds a session that is no launched lane: an ordinary session asks
# its user through its harness as it always did, and a committed mailbox poses
# as no lane here, as it poses as none for the mailbox check.

# The harness question tools, by the names their PreToolUse payloads carry:
# Claude Code's AskUserQuestion and EnterPlanMode, whose plan ends in an
# approval dialog; Codex's request_user_input; and the `question` tool
# pi-questions registers on Pi, which the pi-hooks carrier hands over under
# its own id. The one list of those names: the launch words that take each
# tool away live in the orch skill's lane-launch library, and the table in
# the orch skill's skill rules § Coordination cites this list beside them.
question_tool() { # NAME
  case "$1" in
    AskUserQuestion | EnterPlanMode | request_user_input | question) return 0 ;;
  esac
  return 1
}

# The two commands that route a lane's question, named by the question-tool
# and the idle refusals, and the inbox read and the notice send the idle
# refusal continues the lane with. The reader is this hook's own where it
# resolves; an install with none is told the verb by name, since the route is
# the rule and the gap in the install has its own line elsewhere. All four
# name the lane's root, as the
# halt's read does: a lane verb otherwise roots itself at the call's cwd, so a
# lane working from the main clone would write an ask into a mailbox its
# overseer never reads and wait on an answer that never comes.
ask_route() {
  local asker=lane-mail
  ! resolve_reader || asker="$READER"
  printf -v ASK_ROUTE '  %q ask --item %q --root %q --file [PATH]\n  %q wait --item %q --root %q --id [MSGID]' \
    "$asker" "$ITEM" "$ROOT" "$asker" "$ITEM" "$ROOT"
  printf -v INBOX_ROUTE '  %q inbox --item %q --root %q' "$asker" "$ITEM" "$ROOT"
  printf -v NOTICE_ROUTE '  %q notice --item %q --root %q --file [PATH]' "$asker" "$ITEM" "$ROOT"
}

# Before a tool call: the question tool is refused in a launched lane, after
# the halt arm has had its say, so a halted lane meets its halt first. A
# subagent's call is refused too, without the commands: lane mail is the
# lead's, and the subagent reports the question up instead.
question_tool_check() {
  question_tool "$TOOL" || return 0
  lane_launched || return 0
  ask_route
  refuse question-tool "$TOOL"
}

# --- the idle judge ------------------------------------------------------
#
# A lane lead's turn end is judged on lane-mail facts alone, never on the
# words the lane wrote: nobody reads a lane's pane, so a turn that ends with
# nothing sent through lane mail is a lane its overseer does not know has
# stopped, whatever it said there. The facts are the reader's own `lane-mail
# events` listing and the count this judge recorded at the lane's last judged
# turn end:
#   - an ask or a notice the lane sent since then, which the listing's count of
#     them against the record shows;
#   - the lane's handoff record, which ends the run in handoff_check before this
#     judge is reached;
#   - a halt standing, the newest directive the overseer sent carrying `halt`;
#   - the close-out, which leaves no launch marker binding the lane's root, so
#     the session is no lane and is judged on nothing.
# With none of them the turn is held or reported to the overseer; the
# description states when each happens. Judged after the handoff marks, so a
# lane at its mark is told to hand off, not to go on.

# The record of the lane's last judged turn end, in the lane's own mailbox
# directory beside the context reading: one line, the count of asks and
# notices the lane had sent then, and the word `held` after it where this
# judge refused that turn end. The hold is always made at the count the line
# holds, so a word is its whole record. No record is a count of zero: a lane
# that has sent nothing ends its first turn idle. Every judged turn end that
# changes either field rewrites the line, so `held` names the latest one.
SENT_RECORD=""
record_sent() { # KEY COUNT [held]
  local key=$1 tmp=""
  shift
  if [ -L "$SENT_RECORD" ] || { [ -e "$SENT_RECORD" ] && [ ! -f "$SENT_RECORD" ]; }; then
    message "$key" "$SENT_RECORD"
    return 1
  fi
  # Written beside the record and renamed over it, so a reader never meets a
  # half-written count.
  if tmp=$(mktemp "$SENT_RECORD.XXXXXX" 2>"$WORK_DIR/sent.err") &&
    printf '%s\n' "$1${2:+ $2}" >"$tmp" 2>"$WORK_DIR/sent.err" &&
    mv -f -- "$tmp" "$SENT_RECORD" 2>"$WORK_DIR/sent.err"; then
    return 0
  fi
  [ -z "$tmp" ] || rm -f -- "${tmp:?}"
  message "$key" "$SENT_RECORD" "$(cat -- "$WORK_DIR/sent.err")"
  return 1
}

# The overseer is told through the lane's own mailbox, as a notice from the
# lane, and the turn ends: a second refusal is the loop stop_hook_active exists
# to end. The notice states what this judge checked and never why the lane
# stopped, which the hook cannot know. It lands in the lane's outbound file, so
# the record counts it, and the lane's next turn is judged on what the lane
# itself sends.
idle_notice() {
  NOTICE_RC=0
  {
    message lane-idle "$ITEM" 2>"$WORK_DIR/idle-notice.txt" &&
      "$READER" notice --item "$ITEM" --root "$ROOT" --file "$WORK_DIR/idle-notice.txt"
  } >/dev/null 2>"$WORK_DIR/idle-notice.err" || NOTICE_RC=$?
  if [ "$NOTICE_RC" -ne 0 ]; then
    message idle-notice-unsent "$NOTICE_RC" "$(cat -- "$WORK_DIR/idle-notice.err")"
    return 0
  fi
  record_sent idle-notice-unrecorded "$((SENT + 1))" || :
  message idle-notice "$ITEM"
}

idle_check() {
  { [ "$ARM" = stop ] && [ "$CALLER" = lead ] && [ "$ROLE" = lane ] && [ -n "$ITEM" ]; } || return 0
  lane_launched || return 0
  resolve_reader || return 0
  EVENTS_RC=0
  EVENTS=$("$READER" events --item "$ITEM" --root "$ROOT" 2>"$WORK_DIR/events.err") || EVENTS_RC=$?
  if [ "$EVENTS_RC" -ne 0 ]; then
    message events "$EVENTS_RC" "$(cat -- "$WORK_DIR/events.err")"
    return 0
  fi
  # Two facts, tab-separated: the asks and notices in the lane's outbound
  # file, and whether the newest directive the overseer sent is a halt.
  FACTS=$(printf '%s\n' "$EVENTS" | jq -rs '
    [(map(select(.box == "to-overseer" and (.kind == "ask" or .kind == "notice"))) | length),
     (map(select(.box == "to-lane" and .kind == "directive")) | last | .halt? == true)]
    | @tsv' 2>&1) || { message events envelope "$FACTS"; return 0; }
  SENT=${FACTS%%"	"*}
  HALTED=${FACTS#*"	"}
  SENT_RECORD="$MAIL_ROOT/$ITEM/sent-count"
  RECORDED=0
  HOLD=""
  if [ -e "$SENT_RECORD" ] || [ -L "$SENT_RECORD" ]; then
    RECORDED=""
    REST=""
    if [ -f "$SENT_RECORD" ] && [ ! -L "$SENT_RECORD" ]; then
      IFS=' ' read -r RECORDED HOLD REST <"$SENT_RECORD" || :
    fi
    if ! whole_number "$RECORDED" || [ -n "$REST" ] || { [ -n "$HOLD" ] && [ "$HOLD" != held ]; }; then
      message idle-record "$SENT_RECORD"
      record_sent idle-unrecorded "$SENT" || :
      return 0
    fi
  fi
  # A count other than the recorded one is a send this turn; a smaller one is
  # a mailbox replaced under the record, which starts it again.
  if [ "$SENT" != "$RECORDED" ]; then
    record_sent idle-unrecorded "$SENT" || :
    return 0
  fi
  if [ "$HALTED" = true ]; then
    [ -z "$HOLD" ] || record_sent idle-unrecorded "$SENT" || :
    return 0
  fi
  # The flag says a stop hook's refusal continued this turn, not which hook's:
  # the recorded hold says it was this judge's. A turn another hook continued
  # is held as a fresh one, and the recorded hold bounds the loop at one more
  # turn. On Pi the pi-hooks carrier runs no further request after a continued
  # turn, so a hold there reaches nobody and the notice is sent in its place.
  if [ "$CONTINUED" = true ] && { [ -n "$HOLD" ] || [ "$HARNESS" = pi ]; }; then
    idle_notice
    return 0
  fi
  record_sent idle-hold-unrecorded "$SENT" held || return 0
  ask_route
  refuse idle "$ITEM"
}

# --- the handoff marks ---------------------------------------------------
#
# A lane hands ITSELF off. The overseer's `lanes context` poll of the readings
# this hook records is a backstop: no watch event carries a context figure, and
# an overseer between events, at its own wall or in succession reads nothing at
# all, so lanes ran 50 to 190 thousand tokens past the mark waiting to be told.
# Two marks fire one instruction, and the lane's own handoff record clears
# both.
#
# The OVERSEER is judged here too, on two marks of its own. It does not share
# the reads below: `oversee-succeed --check-marks` is the one judge of where an
# overseer's marks sit and what its own pane and account say, and this hook
# acts on the key that judgement printed. Its escape is the succession, with
# the same record behind it, so a succession that refuses still leaves a turn
# end it can reach.
#
# The turn-end arm and the lane lead alone: a tool call is not a point to hand
# off at, and a subagent runs its own window on its own turn. The mailbox is
# handed over first and the marks are judged after it, so an overseer's own
# directive still reaches a lane that is about to hand off; every turn-end path
# the mailbox has nothing to say on arrives here.
#
# A handoff refusal is made on `stop_hook_active` turns too, unlike everything
# else this hook refuses but the idle judge's hold on a turn another hook
# continued, which its own record bounds. The escapes differ: this hook's own acknowledgement
# clears unread mail and nothing clears a resolution failure, so repeating
# either is the loop the flag exists to end, while only the LANE can write the
# handoff record, and a single refusal it declines to act on ends the session
# with nothing recorded.

# A whole number, with no leading zero that a shell would read as octal.
whole_number() { # VALUE
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    0) return 0 ;;
    0*) return 1 ;;
  esac
  return 0
}

# The bound `lanes` takes for the same setting, judged here before the value
# reaches it: `orch-env` falls back to its default only on a NON-numeric value,
# so 101 would reach `lanes`, die there as invalid-percent, and be reported
# under an account key for a setting's fault.
percent_in_range() { # VALUE
  whole_number "$1" || return 1
  case "$1" in ????*) return 1 ;; esac
  [ "$1" -le 100 ] || return 1
  return 0
}

# The record the watch reads, judged by the one script that owns the test.
# `workflow-state handoff-standing` publishes its verdict as the word on its
# first stdout line and exits 0 for every one of them, so the word is read here
# and its status never is. A status cannot carry the answer: every orch script
# sources the project's `.env.local` as shell before its dispatch is reached,
# and bash 3.2 kills the shell on a file it cannot parse. A hook reading that
# death's status as a verdict would key a fault in `.env.local` to the item's
# state file and report none of the loader's own words. Only a run that reached
# the verb writes a verdict line.
#
# HANDOFF_STATE is the whole answer and the caller matches on it, in the same
# words as the keys it emits:
#   stands      a record no relaunch has resumed
#   none        none stands, a state file that is not there included
#   unreadable  the verb's own word: it could not read the state
#   unanswered  no verdict line: an install older than the verb, one whose
#               settings file stopped it before dispatch, or any other death
# STATE_CAUSE holds what the script wrote, for the last two alike, and
# HANDOFF_RECORD the record body the verb prints under a `stands` verdict, for
# the one caller that asks whose record it is.
HANDOFF_VERDICT='workflow-state: handoff-standing'
HANDOFF_STATE=""
HANDOFF_RECORD=""
STATE_CAUSE=""
handoff_recorded() {
  STATE_CAUSE=""
  STATE_ANSWER=""
  HANDOFF_RECORD=""
  # A verdict only counts from a run that also finished, so a script that
  # printed one and then died leaves the line empty and falls to the arm for
  # an answer this hook cannot attribute.
  STATE_LINE=""
  if STATE_ANSWER=$("$SCRIPTS/workflow-state" handoff-standing "$ITEM" \
      2>"$WORK_DIR/state.err"); then
    STATE_LINE=${STATE_ANSWER%%"$NL"*}
  fi
  case "$STATE_LINE" in
    "$HANDOFF_VERDICT=stands")
      HANDOFF_STATE=stands
      # The record follows the verdict line. A verdict with nothing under it
      # names no writer, which handoff_is_mine reads as another session's.
      case "$STATE_ANSWER" in
        *"$NL"*) HANDOFF_RECORD=${STATE_ANSWER#*"$NL"} ;;
      esac
      return 0
      ;;
    "$HANDOFF_VERDICT=none") HANDOFF_STATE=none; return 0 ;;
    "$HANDOFF_VERDICT=unreadable") HANDOFF_STATE=unreadable ;;
    *) HANDOFF_STATE=unanswered ;;
  esac
  STATE_CAUSE=$(cat -- "$WORK_DIR/state.err")
  return 0
}

# Whether a standing record on the FLEET item is this session's own. The
# overseer that wrote one exited; a replacement started by hand in the same
# pane, which is what a refused succession leaves the operator to do, is a
# different session, and a record answering for it would pass its turn end
# past both marks in silence for the life of that session. So the record names
# the session that wrote it, and only that session reads it as its own.
#
# The payload's id is the name where the harness sends one. Where it sends
# none the pane key answers, the pair the fleet state already keys the
# overseer on, which tells a successor in ANOTHER pane apart from the writer
# and is all that is available there. A record from an older overseer carries
# neither field and is nobody's, so the marks are judged as if none stood: the
# refusal that follows has its own escape, which a silence would not.
#
# The answer is jq's own exit status under `-e`: a record naming this session
# is the only truthy result, and every other outcome — a false comparison, a
# record with no such field, an empty verdict line with nothing under it, and
# a document jq could not read — comes back non-zero and is another session's.
# Read through a status rather than a captured word, so no reading of this can
# fail open into `true`.
handoff_is_mine() {
  printf '%s' "$HANDOFF_RECORD" | jq -e --arg s "$SESSION" --arg k "$CALLER_KEY" '
    if $s != "" then ((.session_id? // "") == $s)
    else ($k != "" and (.pane_key? // "") == $k) end' >/dev/null 2>&1
}

# The state file `handoff-standing` could not read, named rather than left to
# the reader's own words: jq names the file for a wrong-typed document and not
# for the garbage and truncation a killed write leaves, and the other route to
# that status writes nothing at all. `path` is the verb that owns the mapping
# from item to file and answers it whatever the file holds. A read that cannot
# answer falls back to the item, which is worse than a path and better than a
# sentence promising one that is not there.
handoff_state_file() {
  STATE_PATH=$("$SCRIPTS/workflow-state" path "$ITEM" 2>/dev/null) || STATE_PATH=""
  [ -n "$STATE_PATH" ] || STATE_PATH="$ITEM"
}

# Whether the item already has a state file. A read that could not answer is
# read as no file: the instruction then opens with an init the item may not
# need, which costs a redundant line and never a refusal the lane cannot clear.
state_exists() {
  "$SCRIPTS/workflow-state" exists --json "$ITEM" 2>/dev/null |
    jq -e '.exists == true' >/dev/null 2>&1
}

# The two commands that end every refusal below. `workflow-state set` refuses a
# state file that is not there, so an item with none is told to init first: the
# account mark can fire on a lane's very first turn end, before any workflow has
# run init, and an instruction naming an escape the lane cannot take is none.
#
# The overseer's route is the succession and not a handoff to anyone: it opens
# its own replacement and closes this window, so a session that takes it ends
# and reaches no further turn end. The record is named under it because the
# succession can refuse — no lane of any preference entry with room — and a
# refusal with no second escape is a turn end the overseer could never reach.
# The init line is a lane's alone: an overseer is established by a read of the
# fleet item's own state file, which answers nothing without that file, so the
# item an overseer is judged under always has one.
handoff_instruction() {
  INIT_LINE=""
  if ! state_exists; then
    if [ -z "$BRANCH" ]; then
      printf -v INIT_LINE '  %q init %q\n' "$SCRIPTS/workflow-state" "$ITEM"
    else
      printf -v INIT_LINE '  %q init %q --branch %q\n' "$SCRIPTS/workflow-state" "$ITEM" "$BRANCH"
    fi
  fi
  if [ "$ROLE" = overseer ]; then
    # The record carries the two names of the session writing it, so the next
    # overseer of this fleet reads it as somebody else's and meets its own
    # marks. Both are spelled by this hook rather than left as placeholders:
    # the overseer knows neither its own tmux server pid nor the id its
    # harness put in the payload.
    printf -v OVERSEER_RECORD \
      '{"handoff_file":"[OVERSEER_HANDOFF_PATH]","pane_key":"%s","session_id":"%s"}' \
      "$CALLER_KEY" "$SESSION"
    printf -v HANDOFF_INSTRUCTION \
      'Reach a safe point first, with no merged event part-handled and no lane waiting on an answer only the root can give. There, rewrite the overseer handoff file and succeed this session:\n  %q%s -- [THE PERMISSION, MODEL AND EFFORT FLAGS THIS SESSION RUNS UNDER]\nWhere that refuses, tell the user a fresh overseer session must be started by hand, then record the handoff and end this session:\n%s  %q set %q handoff %s\nWrite the record as it stands above: the two names in it are what end this refusal for this session and for no other. It repeats at every turn end until the succession lands or that record stands.' \
      "$SCRIPTS/oversee-succeed" "${JUDGE_ARGS[*]+ ${JUDGE_ARGS[*]}}" "$INIT_LINE" \
      "$SCRIPTS/workflow-state" "$ITEM" "'$OVERSEER_RECORD'"
    return 0
  fi
  printf -v HANDOFF_INSTRUCTION \
    'Reach the next safe point first, a pushed head, a landed merge or a held PR; never interrupt a round or leave an unpushed tree. There, write the handoff record and send the notice, then end the session:\n%s  %q set %q handoff %s\n  %q notice --item %q --file [FILE NAMING WHAT IS LEFT]\nThis refusal repeats at every turn end until that record stands.' \
    "$INIT_LINE" \
    "$SCRIPTS/workflow-state" "$ITEM" \
    ''\''{"merged":["[PR]"],"remaining":["[STEP]"],"branch":"[BRANCH]","worktree":"[WORKTREE_PATH]","open_pr":[PR_NUMBER_OR_NULL],"traps":["[TRAP]"]}'\''' \
    "$READER" "$ITEM"
}

# A handoff refusal: the lane's own record ends it, so every one of these
# carries the two commands that write it. This is the only site that builds
# that text, and the marks' own refusals below are its only callers.
refuse_handoff() { # KEY VALUE [CAUSE]
  handoff_instruction
  refuse "$@"
}

# The orch context library, which owns the adapters that read a transcript,
# the one judge of a reading and the record it is written to. An install older
# than it is readable, sources without error and then leaves a call to bash's
# command-not-found, which would end the turn on 127 with no keyed line at all.
# So the capability is probed, not the file, and a library that cannot answer
# is the same reported gap a missing one is, under the key that says which;
# both marks stay unjudged, since the account mark asks it for the account.
#
# Probed in a child of THIS interpreter, under this script's own options, and
# sourced in-process only once that child has answered. In-process is where the
# probe cannot live: bash 3.2 kills the shell on a source it cannot parse or
# read, even as the condition of an `if`, where bash 5 takes the non-zero
# status and carries on. This hook's EXIT trap then succeeds and lends the run
# its own 0, so the turn passed with the marks unjudged and not one line on
# stderr. A child dies alone and hands back a status.
#
# `$BASH` is the running interpreter's own path, never a PATH lookup: the two
# bash versions disagree on exactly this operation, so a probe answered by a
# different bash than the one about to source the file answers another
# question. The options are passed with it for the same reason. No readability
# test stands ahead of the probe, because failing the source is what writes
# bash's own words to the cause; a `-r` test would leave that cause empty
# under a line that promises one.
#
# A gap returns 1 with FAIL_KEY, FAIL_VALUE and FAIL_CAUSE naming it and
# nothing written: a turn end reports it and passes, while the usage and
# compact arms refuse it.
#
# Called on the left of `||`, so bash suspends errexit for this whole body;
# every status is tested where it is taken.
load_context_lib() {
  [ -z "${LANE_CONTEXT_RECORD:-}" ] || return 0
  FAIL_VALUE="$SCRIPTS/lib/lane-context.sh"
  FAIL_CAUSE=""
  if [ ! -e "$SCRIPTS/lib/lane-context.sh" ]; then
    FAIL_KEY=handoff-skipped
    return 1
  fi
  : >"$WORK_DIR/lib.err"
  if ! "$BASH" -euo pipefail -c '. "$1" && declare -F lane_context_handoff_due >/dev/null' _ "$SCRIPTS/lib/lane-context.sh" 2>"$WORK_DIR/lib.err"; then
    FAIL_KEY=handoff-unanswered
    FAIL_CAUSE=$(cat -- "$WORK_DIR/lib.err")
    return 1
  fi
  # The probe proved this source parses, reads and returns 0 under these very
  # options, so there is no status left here to take. Its stderr still goes to
  # the captured file rather than the hook's own, so a library that writes as
  # it loads cannot put a word ahead of a keyed line.
  # shellcheck source=../skills/orch/scripts/lib/lane-context.sh
  . "$SCRIPTS/lib/lane-context.sh" 2>>"$WORK_DIR/lib.err"
  return 0
}

# This session's context, read from the transcript the payload names through
# the adapter for HARNESS, into TOKENS, WINDOW and MODEL, and recorded in BOX
# for every other reader. TOKENS is empty where there is nothing to read — no
# transcript named, no usage line in it, or a harness no adapter reads — and
# LANE_CONTEXT_UNREAD for a usage object the adapter does not read; neither is
# recorded, and READ_GAP names which it was, `transcript-unnamed`,
# `usage-absent`, `usage-unread` or, for a Copilot session with no extension
# reading, `session-record`, empty where a reading was taken or the harness is
# one no adapter reads. A transcript named and unreadable is
# refused, since the record is
# what clears it. A record that cannot be written is reported and the reading
# still judged: the mark rests on this read, the record serves the others.
#
# A bounded tail first: a session transcript grows without limit and parsing
# the whole of one at every turn end costs more than the rest of this hook
# together. The full file answers only where that window holds no usage line —
# a session on its first turns, or one whose recent lines are all tool results.
# The tail's own words go to a file and are replayed under the refusal: an
# adapter that stops reading leaves the tail a write error, which reaching
# stderr ahead of the keyed line would take its place.
#
# A Copilot transcript holds no live count. A Copilot session is read first
# from the reading the orch copilot-lane-context extension recorded
# (copilot_context_read). Only where no such reading of this session stands is
# it read from the session record its statusLine command writes, bound through
# lib/copilot-session.sh to the payload's session id, its transcript where it
# names one, and the account the session runs on, and held to the record's
# freshness bound: the fallback for a home whose EXTENSIONS feature is off,
# since the extension's usage event is the interface Copilot offers and the
# statusLine is a display command. That reading is recorded with its own
# capacity source, so no later turn end takes it for the extension's. A record
# that does not answer leaves the context unmeasured under
# `reading-unrecorded=<path>` and `session-record=<reason>` and the gap
# `session-record`, reported and passed like a transcript that names no usage,
# and never read as room. The record is read beside an extension reading too,
# for its stop cause alone, reported as `stop-cause=<cause>`.
context_read_and_record() { # BOX PANE_KEY
  TOKENS=""
  WINDOW=""
  MODEL=""
  READ_GAP=""
  COMPACTED=false
  SOURCE=""
  # An install directory naming no harness has no adapter to read its context,
  # so it is reported unmeasured where the payload names a transcript to go
  # unread. No gap is named for it, whatever the payload carries: this hook
  # never reads that context, so a gap would stand at every turn end for the
  # life of the session, and the record stays as it was, the mark documented
  # as unjudged there. Decided before anything else, so no path through such
  # an install names one.
  if [ -z "$HARNESS" ]; then
    [ -z "$TRANSCRIPT" ] || message harness-unlisted "$HOOK_DIR"
    return 0
  fi
  if [ "$HARNESS" = copilot ]; then
    # The extension's reading is the session's own and is never overwritten
    # here: the reader owns the record. The statusLine record alone carries
    # allow_all_enabled, so it is read for the stop cause beside either reading.
    EXTENSION_READ=true
    copilot_context_read "$1" || EXTENSION_READ=false
    [ "$COMPACTED" = false ] || return 0
    if ! copilot_session_read "$(lane_context_caller_cfg copilot)" "$SESSION" "$TRANSCRIPT" "$(date +%s)"; then
      [ "$EXTENSION_READ" = false ] || return 0
      READ_GAP=session-record
      message reading-unrecorded "$1/$LANE_CONTEXT_RECORD"
      message session-record "$COPILOT_SESSION_REASON"
      return 0
    fi
    ! STOP_CAUSE=$(copilot_session_stop_cause "$COPILOT_SESSION_RECORD" "${COPILOT_ALLOW_ALL:-}") || message stop-cause "$STOP_CAUSE"
    [ "$EXTENSION_READ" = false ] || return 0
    READING=$(lane_context_reading copilot <<<"$COPILOT_SESSION_RECORD" 2>"$WORK_DIR/transcript.err") ||
      refuse_handoff transcript unread "$(cat -- "$WORK_DIR/transcript.err")"
    SOURCE=$LANE_ADAPTER_COPILOT_CAPACITY_SOURCE
  else
    READ_GAP=transcript-unnamed
    [ -n "$TRANSCRIPT" ] || return 0
    { [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; } || refuse_handoff transcript unreadable
    if ! READING=$(tail -c "$TRANSCRIPT_WINDOW" -- "$TRANSCRIPT" 2>"$WORK_DIR/tail.err" |
      lane_context_reading "$HARNESS" "$PAYLOAD_WINDOW" "$LANE_DIR" 2>"$WORK_DIR/transcript.err"); then
      refuse_handoff transcript unread "$(cat -- "$WORK_DIR/transcript.err" "$WORK_DIR/tail.err")"
    fi
    if [ -z "$READING" ] && ! READING=$(lane_context_reading "$HARNESS" "$PAYLOAD_WINDOW" "$LANE_DIR" <"$TRANSCRIPT" 2>"$WORK_DIR/transcript.err"); then
      refuse_handoff transcript unread "$(cat -- "$WORK_DIR/transcript.err")"
    fi
  fi
  if [ -s "$WORK_DIR/transcript.err" ]; then
    message compaction-unread "$HARNESS" "$(cat -- "$WORK_DIR/transcript.err")"
  fi
  case "$READING" in
    '')
      READ_GAP=usage-absent
      return 0
      ;;
    "$LANE_CONTEXT_UNREAD")
      TOKENS=$READING
      READ_GAP=usage-unread
      return 0
      ;;
  esac
  READ_GAP=""
  TOKENS=${READING%%"$TAB"*}
  READING=${READING#*"$TAB"}
  WINDOW=${READING%%"$TAB"*}
  MODEL=${READING#*"$TAB"}
  lane_context_record "$1" "$HARNESS" "$TOKENS" "$WINDOW" "$MODEL" "$SESSION" "$2" "" "$SOURCE" \
    2>"$WORK_DIR/record.err" ||
    message context-unrecorded "$1/$LANE_CONTEXT_RECORD" "$(cat -- "$WORK_DIR/record.err")"
  return 0
}

# A Copilot session's context at its turn end, from BOX, as the orch
# copilot-lane-context extension recorded it: COMPACTED true where the
# lane-mail-compact hook flagged this session's automatic compaction, and
# TOKENS, WINDOW and MODEL from the reading the usage arm below last recorded
# for this session, WINDOW being the capacity it named, the limit Copilot
# compacts at. 0 once either is taken; nothing is written here, since the
# reader owns the record. 1 where no reading of the extension's stands for
# this session: no record, one naming another session, a predecessor's in the
# same mailbox included, and one whose capacity source is not the one the
# usage arm writes, which a gap record, written by the turn end of an overseer
# the fleet record lost, and a reading the statusLine fallback recorded both
# are. The caller then takes the statusLine
# fallback, and never reads that as room. A reading the extension handed on
# and no run has recorded yet leaves the context unmeasured under
# `reading-pending` (copilot_reading_pending), 0 with no fallback: the
# extension runs for this session, and the record standing is older than the
# reading on its way. A flag or a record that stands and cannot be read is
# refused, since the handoff record is what clears that.
copilot_context_read() { # BOX
  FLAG_RC=0
  lane_context_compaction_flagged "$1" "$SESSION" 2>"$WORK_DIR/flag.err" || FLAG_RC=$?
  case "$FLAG_RC" in
    0)
      # Past the mark whatever the reading says: the refusal follows, and a
      # report on the reading ahead of it would stand before its keyed line.
      COMPACTED=true
      return 0
      ;;
    1) ;;
    *) refuse_handoff record "$1/$LANE_CONTEXT_COMPACTION" "$(cat -- "$WORK_DIR/flag.err")" ;;
  esac
  if copilot_reading_pending; then
    message reading-pending "$PENDING_FILE"
    return 0
  fi
  [ -e "$1/$LANE_CONTEXT_RECORD" ] || return 1
  RECORD=$(cat -- "$1/$LANE_CONTEXT_RECORD" 2>"$WORK_DIR/record.err") ||
    refuse_handoff record "$1/$LANE_CONTEXT_RECORD" "$(cat -- "$WORK_DIR/record.err")"
  lane_context_record_fields "$RECORD" ||
    refuse_handoff record "$1/$LANE_CONTEXT_RECORD" "it is neither a reading nor a gap record"
  if [ "$LANE_CTX_SESSION" != "$SESSION" ] ||
    [ "$LANE_CTX_SOURCE" != "$LANE_CONTEXT_COPILOT_CAPACITY_SOURCE" ]; then
    return 1
  fi
  TOKENS=$LANE_CTX_TOKENS
  WINDOW=$LANE_CTX_WINDOW
  MODEL=$LANE_CTX_MODEL
  return 0
}

# Whether a context reading of this session is on its way to the record: 0
# where the extension's pending marker for SESSION, PENDING_FILE, still stands
# after PENDING_POLLS polls of 0.2 s, 1 where it is gone or the payload names
# no session. The extension hands each reading to a usage run apart from the
# session and removes the marker once a run records the last one, so nothing
# else orders that run before this turn end, and the record standing while it
# goes is an earlier reading, which can lie below the mark this one crossed.
# The wait covers a run that is recording as the turn ends; a marker that
# outlives it is a run still going or one that failed, and neither is read.
PENDING_POLLS=25
PENDING_WAIT="5 seconds"
PENDING_FILE=""
copilot_reading_pending() {
  local polls=0
  [ -n "$SESSION" ] || return 1
  PENDING_FILE="$COPILOT_USAGE/$SESSION"
  while [ -e "$PENDING_FILE" ]; do
    [ "$polls" -lt "$PENDING_POLLS" ] || return 0
    sleep 0.2
    polls=$((polls + 1))
  done
  return 1
}

# Whether this session is one the handoff marks are judged for, the one rule
# every arm that judges or records them asks: the lead of a launched lane, or
# the fleet's overseer. 0 with ROLE set, ITEM then naming the fleet item for
# the overseer; 1 for a session that is neither, passed in silence; 2 for a
# launched lane whose install this hook could not resolve, with GATE_KEY,
# FAIL_VALUE and FAIL_CAUSE naming the gap. A session naming no
# lane item is asked whether it is the overseer only inside tmux and only once
# the install resolves: a session outside tmux pays nothing, and an install
# this hook cannot find establishes no overseer, so that session reports
# nothing. The tmux test is that cost bound and no rule of its own: outside
# tmux the pane key the fleet state is matched on cannot be read either. The
# overseer is established by overseer_identified alone.
#
# Called on the left of `||`, so bash suspends errexit for this whole body;
# every status is tested where it is taken.
session_gate() {
  if [ -z "$ITEM" ]; then
    { [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; } || return 1
    NO_LANE_ITEM=1
  else
    lane_launched || return 1
  fi
  # The marks are judged with the orch scripts beside the mailbox reader, from
  # this hook's own install and never the open repository's, as the reader is.
  # An install that carries none of them carries no `workflow-state` either,
  # so a lane could not record a handoff whatever it was told.
  GATE_KEY=""
  if ! resolve_reader; then
    GATE_KEY=handoff-skipped
    [ "$FAIL_KEY" != reader-outside ] || GATE_KEY=handoff-outside
  elif [ ! -x "$SCRIPTS/workflow-state" ]; then
    GATE_KEY=handoff-skipped
    FAIL_VALUE="$SCRIPTS/workflow-state"
    FAIL_CAUSE=""
  fi
  if [ -n "$GATE_KEY" ]; then
    [ "$NO_LANE_ITEM" -eq 0 ] || return 1
    return 2
  fi
  # The fleet state is what names the overseer, so this is the first step that
  # can ask. A session that is not it has no marks of this hook's to meet.
  if [ "$NO_LANE_ITEM" -eq 1 ]; then
    overseer_identified || return 1
    ROLE=overseer
    ITEM="$OVERSEER_ITEM"
  fi
  return 0
}

# The mailbox directory the session session_gate established records in, into
# BOX, and the pane key its records carry, into PANE_KEY: the lane's own, or
# the overseer's, keyed by its pane so a successor tells its own record from
# its predecessor's.
gated_box() {
  if [ "$ROLE" = overseer ]; then
    overseer_box
    BOX=$OVERSEER_BOX
    PANE_KEY=$CALLER_KEY
  else
    BOX="$MAIL_ROOT/$ITEM"
    PANE_KEY=""
  fi
}

# The compact arm: a Copilot lane lead's or overseer's automatic compaction,
# flagged in the mailbox directory its turn end reads, which holds that turn
# end until the handoff record stands. The backstop: the usage reading
# hands a session off before Copilot compacts it, and this flag holds a turn
# that crossed into the compaction before any reading past the mark reached a
# turn end. Copilot's preCompact takes no answer and cannot be held, so a gap
# is refused at exit 2, which Copilot shows the operator as a warning while
# the compaction goes on. A manual compaction is the operator's own and flags
# nothing; nor does a session session_gate passes over, nor, passed before
# this, one the caller rule does not name the lead's. The hook is rendered
# for Copilot alone, whose compaction no switch turns off, so a copy run
# elsewhere flags nothing.
#
# Called plainly, so errexit is live: every status is tested where it is taken.
compaction_mark() {
  { [ "$HARNESS" = copilot ] && [ "$TRIGGER" = auto ]; } || return 0
  GATE_RC=0
  session_gate || GATE_RC=$?
  case "$GATE_RC" in
    0) ;;
    1) return 0 ;;
    *) refuse compaction-unrecorded "$FAIL_VALUE" "$FAIL_CAUSE" ;;
  esac
  load_context_lib || refuse compaction-unrecorded "$FAIL_VALUE" "$FAIL_CAUSE"
  gated_box
  lane_context_compaction_flag "$BOX" "$HARNESS" "$TRIGGER" "$SESSION" "$PANE_KEY" 2>"$WORK_DIR/flag.err" ||
    refuse compaction-unrecorded "$BOX/$LANE_CONTEXT_COMPACTION" "$(cat -- "$WORK_DIR/flag.err")"
  return 0
}

# The usage arm, the Copilot session's context reader: the orch
# copilot-lane-context extension hands it each reading Copilot's
# `session.usage_info` gives of the session's root agent, as
# {session_id, cwd, current_tokens, token_limit}. For a recorded lead session
# session_gate passes, the reading lib/lane-context.sh's lane_context_copilot_reading takes
# of that payload is recorded as the session's `context.json`, the capacity
# being the limit Copilot compacts at, which its turn end judges under the
# shared context rule as any other harness's reading. Nothing is written on
# stdout; a gap is refused on stderr at exit 2, which the extension writes to
# the session timeline, and a session that is no lane and no overseer passes
# silently.
#
# Called plainly, so errexit is live: every status is tested where it is taken.
usage_read() {
  [ "$HARNESS" = copilot ] || refuse harness-unlisted "${BASH_SOURCE[0]%/*}"
  GATE_RC=0
  session_gate || GATE_RC=$?
  case "$GATE_RC" in
    0) ;;
    1) return 0 ;;
    *) refuse "$GATE_KEY" "$FAIL_VALUE" "$FAIL_CAUSE" ;;
  esac
  # The extension hands over the root agent's readings alone, so a session
  # the caller rule leaves unknown is a lead whose record could not be
  # written; refused, so the gap reaches the session timeline.
  [ "$CALLER" = lead ] || refuse session-unrecorded "${SESSION:-none}"
  load_context_lib || refuse "$FAIL_KEY" "$FAIL_VALUE" "$FAIL_CAUSE"
  READING=$(printf '%s' "$INPUT" | lane_context_copilot_reading 2>"$WORK_DIR/reading.err") ||
    refuse payload invalid-json "$(cat -- "$WORK_DIR/reading.err")"
  TOKENS=${READING%%"$TAB"*}
  READING=${READING#*"$TAB"}
  WINDOW=${READING%%"$TAB"*}
  SOURCE=${READING#*"$TAB"}
  gated_box
  if ! lane_context_record "$BOX" "$HARNESS" "$TOKENS" "$WINDOW" "" "$SESSION" "$PANE_KEY" "" "$SOURCE" \
    2>"$WORK_DIR/record.err"; then
    # The record standing there is an earlier reading, which can lie below
    # the mark this one crossed: left in place, the next turn end would judge
    # it as room.
    STALE_RECORD=removed
    rm -f -- "${BOX:?}/$LANE_CONTEXT_RECORD" 2>>"$WORK_DIR/record.err" || STALE_RECORD=stands
    refuse context-unrecorded "$BOX/$LANE_CONTEXT_RECORD" "$(cat -- "$WORK_DIR/record.err")"
  fi
  return 0
}

# The overseer's mailbox directory, where its reading is recorded: the one
# lane-mail keeps for `--item overseer` at the main checkout, made here where
# the fleet has not written to it yet. A root that cannot be named, or a
# directory that cannot be made, leaves OVERSEER_BOX naming where it would be,
# and the record's own failure reports it.
overseer_box() {
  OVERSEER_BOX=$(lane_context_overseer_box "$ROOT")
  mkdir -p -- "$OVERSEER_BOX" 2>/dev/null || :
}

# Whether the overseer's transcript may be read: the file the payload names is
# this session's own native file, bound to the session id the payload carries
# and the launch home the fleet record's `.overseer.home` names (OVERSEER_HOME,
# written by lib/overseer-launch.sh), through lib/lane-context.sh's owner of
# that question, which also owns the list of harnesses with a transcript shape.
# 0 where the read goes ahead: the payload names no transcript, which the read
# leaves unread by the gap the description states; the file is bound; or the
# library answers `harness-unlisted`, for Pi, whose read binds nothing and
# takes the payload's own window, and for an install directory naming no
# harness, which the read reports under `harness-unlisted`. 1, with the reason
# reported once under `transcript-unowned`, where the file is not this
# session's under that home, so a session reading a newer unrelated
# transcript, a predecessor's in the same pane, or one under an account the
# fleet never picked is not judged as having room, and where no binding can be
# made, a payload naming no session or a record naming no home, which the
# library answers as `binding-missing` and `home-unnamed`. The account
# triggers still decide either way.
overseer_transcript_owned() {
  [ -n "$TRANSCRIPT" ] || return 0
  OWNED_RC=0
  lane_context_transcript_owned "$HARNESS" "$TRANSCRIPT" "$SESSION" "$OVERSEER_HOME" || OWNED_RC=$?
  case "$OWNED_RC" in
    0 | 3) return 0 ;;
  esac
  message transcript-unowned "$TRANSCRIPT" "$LANE_CONTEXT_OWNED_REASON"
  return 1
}

# Whether THIS session is the fleet's overseer, established positively and in
# one way: the fleet state records the overseer's tmux server and pane, written
# by every writer the orch schemas/workflow-state.md `overseer` row names, and
# a session whose own pane key is that pair, on a server started when the
# record's `server_start` says, is that overseer. Nothing weaker will do. It
# is the one answer to two questions: whether the marks below judge this session,
# and whether mail_check hands it the checkout's overseer mailbox. The
# first overseer of a fleet is started by hand, so it carries no launch marker,
# no lane claim and no variable of its own, and a test that took every
# non-lane session for the overseer would hold an ordinary session's turn end
# on marks nobody set for it.
#
# The pane key comes from the orch library that owns it, run in a CHILD of this
# interpreter for the reason the account mark's probe below gives: bash 3.2
# kills the shell on a source it cannot parse, and the turn would then end with
# no mark judged and nothing on stderr. A session that cannot answer any step
# here is not established as the overseer and is judged on nothing, which is
# what an ordinary session in a fleet checkout needs it to be.
#
# Called on the left of `||`, so bash suspends errexit for this whole body;
# every status is tested where it is taken.
overseer_identified() {
  [ -e "$SCRIPTS/lib/lane-context.sh" ] || return 1
  if ! CALLER_KEY=$("$BASH" -euo pipefail -c '. "$1" && lane_context_caller_key' \
    _ "$SCRIPTS/lib/lane-context.sh" 2>/dev/null)
  then
    return 1
  fi
  [ -n "$CALLER_KEY" ] || return 1
  # The launch home comes back beside the key on the one read: the ownership
  # gate above holds the payload's transcript to the home the record's
  # `.overseer.home` names this session launched under, written by
  # lib/overseer-launch.sh at launch and by `oversee register`, so a session
  # restarted in this pane onto another account reads context unmeasured
  # rather than off a file under a home the fleet never picked. A session
  # registered by hand with no account names none, and the gate reports the
  # reading unbound. Read at the checkout's root, the checkout whose overseer
  # mailbox mail_check reads.
  if ! RECORDED=$(cd -- "$ROOT" 2>/dev/null && "$SCRIPTS/workflow-state" get "$OVERSEER_ITEM" \
    '(.overseer.server // "") + " " + (.overseer.pane // "") + "\t" + (.overseer.server_start // "" | tostring)
     + "\t" + (.overseer.home // "")' 2>/dev/null)
  then
    return 1
  fi
  RECORDED_KEY=${RECORDED%%"$TAB"*}
  RECORDED=${RECORDED#*"$TAB"}
  RECORDED_START=${RECORDED%%"$TAB"*}
  OVERSEER_HOME=${RECORDED#*"$TAB"}
  if [ "$RECORDED_KEY" != "$CALLER_KEY" ]; then
    OVERSEER_UNRECORDED=1
    return 1
  fi
  # The pair alone repeats across servers: after a tmux restart a new server
  # may be handed the recorded pid and numbers its panes from %0 again. A
  # record carrying the start of the server it was written on names this
  # session only on a server started then, by the rule lib/overseer-launch.sh
  # § ol_names states for every orch reader of the record; one carrying none
  # names no session. The start is read only here, for the one session whose
  # pair matched, from the orch library that owns the read, in a child for the
  # reason the key's read above gives. A start that cannot be read establishes
  # nothing, as a key that cannot be read does above.
  [ -e "$SCRIPTS/lib/tmux-server.sh" ] || return 1
  if ! CALLER_START=$("$BASH" -euo pipefail -c '. "$1" && tmux_server_start "$2" "$3"' \
    _ "$SCRIPTS/lib/tmux-server.sh" "$TMUX_PANE" "${CALLER_KEY%% *}" 2>/dev/null)
  then
    return 1
  fi
  if [ "$CALLER_START" != "$RECORDED_START" ]; then
    OVERSEER_UNRECORDED=1
    return 1
  fi
  return 0
}

# The overseer's context record for a turn end that took no reading, written
# through lane_context_record with no figure and GAP, the reason, so the record
# still advances at every overseer turn end and oversee-watch reports why it
# carries no reading (`overseer-context-unmeasured`). Needs OVERSEER_BOX and
# CALLER_KEY; a write that fails is reported under its own key, since no
# reading stands behind it.
overseer_gap_record() { # GAP
  lane_context_record "$OVERSEER_BOX" "$HARNESS" null "" "" "$SESSION" "$CALLER_KEY" "$1" \
    2>"$WORK_DIR/record.err" ||
    message context-gap-unrecorded "$OVERSEER_BOX/$LANE_CONTEXT_RECORD" "$(cat -- "$WORK_DIR/record.err")"
  return 0
}

# A session the fleet record does not name, whose pane the overseer's own
# context record does: the overseer the record lost, to a watch or a
# registration in another pane or to a record rewritten without it. Its turn
# end still writes the context record, with the gap `pane-unrecorded`, and says
# so under that key; no mark is judged, since the fleet no longer names this
# session. Any other session the record does not name is an ordinary one and
# writes nothing: the context record names another pane or none, and
# overwriting it would hide the real overseer's reading. A record that cannot
# be read names no pane. Called plainly, so every status is tested here.
overseer_unrecorded() {
  [ "$OVERSEER_UNRECORDED" -eq 1 ] || return 0
  if ! load_context_lib; then
    message "$FAIL_KEY" "$FAIL_VALUE" "$FAIL_CAUSE"
    return 0
  fi
  # Named without overseer_box, which makes the directory: a session that is
  # no overseer's has no directory to make, and a record this reads is one
  # the directory already holds.
  OVERSEER_BOX=$(lane_context_overseer_box "$ROOT")
  [ -f "$OVERSEER_BOX/$LANE_CONTEXT_RECORD" ] || return 0
  lane_context_record_fields "$(cat -- "$OVERSEER_BOX/$LANE_CONTEXT_RECORD" 2>/dev/null)" || return 0
  [ "$LANE_CTX_PANE_KEY" = "$CALLER_KEY" ] || return 0
  RECORDED_NAMED=$RECORDED_KEY
  [ "$RECORDED_NAMED" != " " ] || RECORDED_NAMED=none
  message pane-unrecorded "$CALLER_KEY" "$RECORDED_NAMED"
  overseer_gap_record pane-unrecorded
  return 0
}

# The overseer's two marks, judged by `oversee-succeed --check-marks` and acted
# on here. That script decides where both marks sit, which account row is this
# session's, and what a reading it could not take means; this function reads
# the key it printed and nothing else, so the turn-end refusal and the watch
# event cannot describe one overseer differently.
#
# Called plainly from handoff_check, whose errexit is live: every status is
# tested where it is taken.
overseer_marks() {
  [ -x "$SCRIPTS/oversee-succeed" ] || refuse_handoff script "$SCRIPTS/oversee-succeed"

  # Bounded by BOUND_BY, for the reason stated where it is set: this judgement
  # reads the one account the overseer session runs on, through the same
  # `lanes pick --lane` the lane read below uses, so one credentials lock and
  # one usage endpoint, plus on a cache miss the host-wide usage refresh lock
  # (up to 10 seconds) and, after a 429 with nothing cached, one sleep of up to
  # 5 seconds and one more usage request.
  JUDGE_RC=0
  JUDGE=$(${BOUND_BY[@]+"${BOUND_BY[@]}"} "$SCRIPTS/oversee-succeed" --check-marks \
    ${JUDGE_ARGS[@]+"${JUDGE_ARGS[@]}"} 2>"$WORK_DIR/judge.err") || JUDGE_RC=$?
  case "$JUDGE_RC" in
    0) ;;
    124)
      message marks timeout "the read was abandoned after $ACCOUNT_CEILING seconds"
      return 0
      ;;
    *)
      message marks unjudged "$(cat -- "$WORK_DIR/judge.err")"
      return 0
      ;;
  esac

  # The keyed first line is that script's contract, and the three fields below
  # are what a refusal names. A `mark-reached` line always carries all three;
  # any other key is a mark that did not fire or a reading it could not take,
  # and both end the turn — an overseer whose marks nothing could measure must
  # still be able to end a turn, exactly as a lane whose account nothing
  # measured can.
  JUDGE_LINE=${JUDGE%%"$NL"*}
  case "$JUDGE_LINE" in
    'oversee-succeed: mark-reached '*) ;;
    'oversee-succeed: mark-unmeasured '*)
      message marks unmeasured "$JUDGE_LINE"
      return 0
      ;;
    *) return 0 ;;
  esac
  MARK_KIND=""
  MARK_VALUE=""
  SUCCESSION=on
  for field in $JUDGE_LINE; do
    case "$field" in
      kind=*) MARK_KIND=${field#kind=} ;;
      value=*) MARK_VALUE=${field#value=} ;;
      mark=*) MARK=${field#mark=} ;;
      headroom=*) MARK_HEADROOM=${field#headroom=} ;;
      succession=*) SUCCESSION=${field#succession=} ;;
    esac
  done
  # A line missing one of the three is an answer this hook cannot act on, and
  # refusing on it would name a figure nothing read.
  if [ -z "$MARK_KIND" ] || [ -z "$MARK_VALUE" ] || [ -z "$MARK" ]; then
    message marks unjudged "$JUDGE_LINE"
    return 0
  fi
  # Succession off passes an account mark: the watch judges the account marks
  # every pass and reports a reached one, so the fleet is not left silent. The
  # context mark is judged here alone, on the reading this turn end took, so it
  # is refused whatever the setting; the handoff record the refusal names ends
  # it once the succession it also names refuses as off. The setting is read
  # off the judgement's own line rather than here, so a spelling this hook
  # would take for `on` and that script refuses cannot exist: that script
  # refuses it, and the refusal is reported under `marks=unjudged`.
  [ "$SUCCESSION" != off ] || [ "$MARK_KIND" = context ] || return 0
  case "$MARK_KIND" in
    context) refuse_handoff context "$MARK_VALUE" ;;
    headroom) PCT="$MARK"; refuse_handoff headroom "$MARK_VALUE" ;;
    rate|qualifying) refuse_handoff "$MARK_KIND" "$MARK_VALUE" ;;
    *) message marks unjudged "$JUDGE_LINE" ;;
  esac
  return 0
}

# This session's own event row, written by the orch library that owns the
# rows' shape and file (lib/session-rows.sh), from this hook's own install
# and never the open repository's, in a CHILD of this interpreter for the
# reason overseer_identified gives. The row arm and the overseer's turn end
# both write through here. A session outside tmux has no pane to key a row by
# and an install with no orch reader has no library to write one with, so
# each writes nothing and says nothing: no reader looks for a row there. What
# could not be written is reported and passed, since a session's events must
# never stop the session.
session_row() {
  { [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; } || return 0
  resolve_reader || return 0
  if [ ! -e "$SCRIPTS/lib/session-rows.sh" ]; then
    message rows-skipped "$SCRIPTS/lib/session-rows.sh"
    return 0
  fi
  # The turn-end run is a Stop whatever its payload spells; a row hook's
  # payload names its own event.
  ROW_EVENT=""
  [ "$ARM" != stop ] || ROW_EVENT=Stop
  if ! printf '%s' "$INPUT" | "$BASH" -euo pipefail -c '
      . "$1/lib/file-lock.sh" && . "$1/lib/mailbox-append.sh" && . "$1/lib/lane-context.sh" &&
      . "$1/lib/lane-state.sh" &&
      . "$1/lib/session-rows.sh" && session_rows_write "$2" "$3" "$4"' \
    _ "$SCRIPTS" "$ROOT" "$HARNESS" "$ROW_EVENT" 2>"$WORK_DIR/row.err"; then
    message rows-unwritten "$ROOT" "$(cat -- "$WORK_DIR/row.err")"
  fi
  return 0
}

# The account a Pi lane spends, which its model's provider decides: CFG names
# it, and PICK_MODEL the model `lanes pick` judges it on, provider included, so
# `lanes` applies the rule lane_pick_harness in lib/lane-launch.sh states. That
# rule is asked here too, in a child shell sourcing the library from this
# hook's own install, because which directory is the account follows from its
# answer: a Claude seat is the config dir pi-claude-bridge runs Claude Code on,
# lane_context_caller_cfg's claude answer, and the Copilot pool is Pi's own
# root, its pi answer. A provider nothing measures is reported unmeasured here,
# never read as room, and `lanes` is not asked for the answer the rule already
# gave. MODEL is the reading's
# `<provider>/<model>`, the model alone where Pi's message named no provider,
# and empty where no reading was taken: no transcript named, no usage line
# yet, or a usage object the adapter does not read. Returns 1 with the
# account reported unmeasured where no reading named the model, the rule
# could not be asked, or it names a provider nothing measures.
pi_account() {
  local judged
  if [ -z "$MODEL" ]; then
    message account unmeasured "no reading of this Pi session's transcript named its model, so the provider whose account it spends is unknown"
    return 1
  fi
  if ! judged=$("$BASH" -c '. "$1" && lane_pick_harness pi "$2"' _ "$SCRIPTS/lib/lane-launch.sh" "$MODEL" \
    2>"$WORK_DIR/rule.err"); then
    message account unmeasured "$(cat -- "$WORK_DIR/rule.err")"
    return 1
  fi
  case "$judged" in
    claude | pi) CFG=$(lane_context_caller_cfg "$judged") ;;
    unmeasured)
      message account unmeasured "the provider of $MODEL bills no account lanes measures"
      return 1
      ;;
    *)
      message account unmeasured "lane_pick_harness answered '$judged' for a Pi model, a word naming no account"
      return 1
      ;;
  esac
  PICK_MODEL=(--model "$MODEL")
  return 0
}

# Called plainly, so errexit is live throughout this body: a status left to it
# would exit the hook with neither 0 nor 2 and end the turn with no mark
# judged. Every status is therefore tested where it is taken.
handoff_check() {
  [ "$ARM" = stop ] && [ "$CALLER" = lead ] || return 0
  # An install this hook could not find is also what would have established
  # that a session naming no lane item is the overseer, so session_gate passes
  # that session over in silence: a keyed line there would stand on every turn
  # end of every session in the checkout. A lane's gap is reported under the
  # key the gate names and the turn ends.
  GATE_RC=0
  session_gate || GATE_RC=$?
  case "$GATE_RC" in
    0) ;;
    1)
      # A session the fleet record lost as its overseer still writes the
      # overseer context record at its turn end, with the gap
      # `pane-unrecorded`; every other session the gate passes writes
      # nothing.
      overseer_unrecorded
      return 0
      ;;
    *)
      message "$GATE_KEY" "$FAIL_VALUE" "$FAIL_CAUSE"
      exit 0
      ;;
  esac

  # A record already standing is the lane handing itself off: it reached its
  # safe point and is exiting, so nothing below may hold it here. Judged
  # before every mark, before every read they rest on and before the scripts
  # only the marks need, so no failure of this hook's own can trap a lane that
  # has already done what it was asked. A state file the verb could not read
  # and an answer this hook cannot attribute to the verb are both passed for
  # the same reason a missing install is, under keys that name the two apart:
  # the repair for one is a state file, for the other an install or the
  # settings it loads.
  handoff_recorded
  case "$HANDOFF_STATE" in
    stands)
      # A lane's item carries one lane's record and no other session reaches
      # it. The fleet item is shared by every overseer of the fleet in turn,
      # so there the record has to name its writer.
      if [ "$ROLE" != overseer ] || handoff_is_mine; then
        exit 0
      fi
      ;;
    none) ;;
    unreadable)
      handoff_state_file
      message handoff-unreadable "$STATE_PATH" "$STATE_CAUSE"
      exit 0
      ;;
    *)
      message handoff-unanswered "$SCRIPTS/workflow-state" "$STATE_CAUSE"
      exit 0
      ;;
  esac

  # The overseer's marks are judged by the script that performs its succession
  # and by nothing here. A second derivation was the defect: this hook read a
  # lane's context out of the transcript and its account through `lanes pick`,
  # while `oversee-succeed` read the overseer's context off the pane status
  # line and its account off the caller row of `lanes context`, and the two
  # disagreed on a model whose window that reader did not hold. So this hook
  # hands that script the reading it just took of this session, the one context
  # figure the overseer is ever judged on, and acts on the key it prints. The
  # reading is recorded too, for the harness and model it names and never for
  # its figure.
  if [ "$ROLE" = overseer ]; then
    # A turn that ended lifts a wall its StopFailure row recorded, and dates
    # the turn end oversee-watch holds the context record against.
    session_row
    # Every turn end here whose orch context library loads writes the context
    # record, a reading or a gap naming why none was taken, so the record
    # advances whatever this turn end could read and oversee-watch reports a
    # gap rather than a stale figure passing for a mark that is watching; a
    # Copilot session's reading is its usage arm's where one stands, and it
    # names no gap over it. A library that does not load is reported under its
    # own key.
    if ! load_context_lib; then
      message "$FAIL_KEY" "$FAIL_VALUE" "$FAIL_CAUSE"
    else
      overseer_box
      if overseer_transcript_owned; then
        context_read_and_record "$OVERSEER_BOX" "$CALLER_KEY"
        case "$TOKENS" in
          '') ;;
          "$LANE_CONTEXT_UNREAD") message usage-unread "$TRANSCRIPT" ;;
          *) JUDGE_ARGS=(--context "$TOKENS:$WINDOW") ;;
        esac
        # The compaction backstop is a verdict, not a reading: no judge
        # derives it, and it is refused whatever the succession setting, as
        # the context mark is.
        [ "$COMPACTED" != true ] || refuse_handoff compacted auto
      else
        # The gate reported why nothing is read. With no reading of its own
        # to take the harness from, the judge is handed the one this install
        # names, so a session whose fleet record and pane command both leave
        # the harness unnamed is still judged on its account rather than
        # refused as unnamed.
        READ_GAP=$LANE_CONTEXT_OWNED_REASON
        JUDGE_ARGS=(--harness "$HARNESS")
      fi
      [ -z "$READ_GAP" ] || overseer_gap_record "$READ_GAP"
    fi
    overseer_marks
    return 0
  fi

  for script in orch-env lanes; do
    [ -x "$SCRIPTS/$script" ] || refuse_handoff script "$SCRIPTS/$script"
  done
  if ! load_context_lib; then
    message "$FAIL_KEY" "$FAIL_VALUE" "$FAIL_CAUSE"
    return 0
  fi

  MARK=$("$SCRIPTS/orch-env" ORCH_HANDOFF_CONTEXT_PCT 90 2>"$WORK_DIR/env.err") ||
    refuse_handoff setting ORCH_HANDOFF_CONTEXT_PCT "$(cat -- "$WORK_DIR/env.err")"
  REQUESTED_MARK=$MARK
  MARK=$(lane_context_handoff_pct "$REQUESTED_MARK") ||
    refuse_handoff setting-range "ORCH_HANDOFF_CONTEXT_PCT=$REQUESTED_MARK"
  context_read_and_record "$MAIL_ROOT/$ITEM" ""
  [ "$COMPACTED" != true ] || refuse_handoff compacted auto
  # Three answers, and the mark is judged on one of them. A reading with a
  # window is judged by the library's one judge; the empty answer is a
  # transcript with no usage line, or a payload naming none, and leaves the
  # mark unjudged in silence, which the description states as this hook's
  # documented gap; a usage object the adapter does not read, and a window it
  # could not name, leave it unjudged too, each under its own key, because the
  # figure IS there and a lane told nothing would run to its wall believing the
  # mark was watching.
  if [ "$TOKENS" = "$LANE_CONTEXT_UNREAD" ]; then
    message usage-unread "$TRANSCRIPT"
  elif [ -n "$TOKENS" ]; then
    DUE_RC=0
    DUE=$(lane_context_handoff_due "$TOKENS" "$WINDOW" "$MARK") || DUE_RC=$?
    case "$DUE_RC" in
      0) [ "$DUE" != due ] || refuse_handoff context "$TOKENS" ;;
      1) message window-unread "${MODEL:-$HARNESS}" ;;
      *) refuse_handoff setting-range "ORCH_HANDOFF_CONTEXT_PCT=$MARK" ;;
    esac
  fi

  # The account the credential THIS session runs on still has, judged by the
  # one script that measures a lane and against the one setting that marks a
  # lane for handoff. `pick --lane` answers about that directory alone: 0 has
  # room, 3 is at or below the mark, and 4 is a directory that is no configured
  # lane of this harness. Every other exit, and a read that passes the ceiling,
  # is an account nothing measured: reported and passed, never read as room and
  # never held, because a setup with no usage endpoint must still end its turns.
  # `lanes` keeps an inventory for claude, codex and copilot, and a Pi lane is
  # judged on the account its model's provider bills (pi_account), so only a
  # lane whose harness is unnamed is judged on the context mark alone.
  #
  # Every arm of lane_context_caller_cfg returns 0 and prints one directory,
  # and this hook reaches it only with claude, codex or copilot, so the
  # directory is the whole of its answer and there is no status to take.
  PICK_MODEL=()
  case "$HARNESS" in
    claude | codex | copilot) CFG=$(lane_context_caller_cfg "$HARNESS") ;;
    pi) pi_account || return 0 ;;
    *)
      message account unlisted "$HOOK_DIR is no harness lanes keeps an inventory for"
      return 0
      ;;
  esac

  PCT=$("$SCRIPTS/orch-env" ORCH_HANDOFF_HEADROOM_PCT 3 2>"$WORK_DIR/env.err") ||
    refuse_handoff setting ORCH_HANDOFF_HEADROOM_PCT "$(cat -- "$WORK_DIR/env.err")"
  percent_in_range "$PCT" || refuse_handoff setting-range "ORCH_HANDOFF_HEADROOM_PCT=$PCT"

  # Bounded by BOUND_BY, for the reason stated where it is set: a read that
  # passes the ceiling exits 124 and is reported under `account=timeout`.
  PICK_RC=0
  PICK=$(${BOUND_BY[@]+"${BOUND_BY[@]}"} "$SCRIPTS/lanes" pick --lane "$CFG" --harness "$HARNESS" \
    ${PICK_MODEL[@]+"${PICK_MODEL[@]}"} --min-headroom-pct "$PCT" --json 2>"$WORK_DIR/lanes.err") || PICK_RC=$?
  # `lanes` keeps a status-only contract where `workflow-state handoff-standing`
  # could not, and one reservation is what makes that safe here: every status
  # with an arm of its own below — 3 for a lane at its mark, 4 for one this
  # harness keeps no inventory for, 124 for a read the ceiling abandoned — is
  # one no death before the verb can produce. `lanes` loads the same
  # `.env.local` through the same loader, and a file bash 3.2 cannot parse
  # kills it with 1 or 2; both fall to `*` and are reported as an account
  # nothing measured, which is as true of a script that died in its loader as
  # of one that could not reach a usage endpoint. An arm that starts acting on
  # 1 or 2, or a `lanes` that starts publishing either, ends the reservation
  # and moves this read onto a verdict `lanes` publishes for itself.
  case "$PICK_RC" in
    0) ;;
    3)
      HEADROOM=$(printf '%s' "$PICK" | jq -r '.headroom_pct // "unknown"' 2>/dev/null) ||
        HEADROOM=unknown
      refuse_handoff headroom "$HEADROOM"
      ;;
    4) message account unlisted "$(cat -- "$WORK_DIR/lanes.err")" ;;
    124) message account timeout "the read was abandoned after $ACCOUNT_CEILING seconds" ;;
    *) message account unmeasured "$(cat -- "$WORK_DIR/lanes.err")" ;;
  esac
  return 0
}

# A Pi lane's own turn rows (lib/session-rows.sh § A Pi lane's own rows): a
# Stop row at the lead's turn end and a PreToolUse row at the first tool call
# of each turn, after a turn end or on an empty file, in the lane's mailbox
# directory, which is what oversee-watch and `lanes state` judge a Pi lane
# idle, working or walled from instead of its pane. Written ahead of
# the mailbox check, which may end the run, and reported and passed like the
# overseer's rows: a lane's events must never stop the lane. Only a Pi install
# writes them; the pane still judges a Claude Code or Codex lane.
lane_row() {
  { [ "$CALLER" = lead ] && [ -n "$ITEM" ]; } || return 0
  case "$ARM" in
    stop) ROW_EVENT=Stop ;;
    halt) ROW_EVENT=PreToolUse ;;
    *) return 0 ;;
  esac
  resolve_reader || return 0
  # An install naming no harness writes no row; the lane's turn end reports
  # that under `harness-unlisted`, once its mailbox has had its say.
  [ "$HARNESS" = pi ] || return 0
  lane_launched || return 0
  if [ ! -e "$SCRIPTS/lib/session-rows.sh" ]; then
    message lane-rows-skipped "$SCRIPTS/lib/session-rows.sh"
    return 0
  fi
  if ! "$BASH" -euo pipefail -c '
      . "$1/lib/file-lock.sh" && . "$1/lib/mailbox-append.sh" &&
      . "$1/lib/session-rows.sh" && session_rows_lane_write "$2" pi "$3" "$4"' \
    _ "$SCRIPTS" "$MAIL_ROOT/$ITEM" "$ROW_EVENT" "$TRANSCRIPT" 2>"$WORK_DIR/row.err"; then
    message lane-rows-unwritten "$MAIL_ROOT/$ITEM" "$(cat -- "$WORK_DIR/row.err")"
  fi
  return 0
}

# A row is a session's with no lane of its own: a lane's events are its own
# mailbox's to carry, and no reader of the overseer's rows reads them.
if [ "$ARM" = row ]; then
  [ -n "$ITEM" ] || session_row
  exit 0
fi
if [ "$ARM" = compact ]; then
  compaction_mark
  exit 0
fi
if [ "$ARM" = usage ]; then
  usage_read
  exit 0
fi
lane_row
# The mailbox check decides which mailbox, if any, this session reads; the
# marks are judged for a lane and for the overseer alike, and decide which of
# the two this session is themselves.
if [ "$CONTINUED" = false ]; then
  mail_check
fi
if [ "$ARM" = halt ] && [ -n "$ITEM" ]; then
  question_tool_check
fi
handoff_check
idle_check
exit 0
