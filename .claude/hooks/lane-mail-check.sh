#!/usr/bin/env bash
# ---
# name: lane-mail-check
# event: Stop
# matcher:
# description: Blocks a lane's turn end while its overseer mailbox holds unread lines, so a directive or a ruling reaches the lane without a keystroke, a pane or a question tool. The lane is the work item `LANE_MAIL_ITEM` names, or the one directory under `<repo>/tmp/lane-mail/` whose name lowercases to the current branch; a session with neither is not a lane and passes silently, as does a lane whose mailbox holds no unread line and a directory git reports no repository for and that holds no mailbox of its own. `<repo>` is the lane's root, resolved in this order: `CLAUDE_PROJECT_DIR`, the directory Claude Code started the session in; else the root the launch marker for `LANE_MAIL_ITEM` binds, where that root exists; else the directory the hook runs in, which on Codex and Pi is the session's start directory and on Claude Code without the variable is the call's own. A Claude Code lane working from the main clone is therefore still judged on its own mailbox. A root its launch marker binds that has no `tmp/lane-mail` directory is refused at a turn end, before any tool call and after the lead's finished one, opening `lane-mail-check: mailbox-missing=<path>` with the marker and the one `mkdir` command that restores the directory, and that command alone passes a tool call. Before a tool call a subagent is refused whatever it runs; after one it is handed nothing and refused nothing, as with any mail, and its next call meets the refusal. The marker is looked up for the item `LANE_MAIL_ITEM` names or else the branch names, so that check costs one stat in a repository whose common git directory holds no `lane-mail` directory, and one branch read and one marker stat in one that does. A mailbox belongs to a lane only where a launch recorded one: `open-terminal` and `lane-host create` write the lane's root to `lane-mail/<item in lower case>` under the repository's common git directory and create the lane's own `tmp/lane-mail/<item>`, and a mailbox with no marker bound to this root passes silently. Unread lines are peeked through the orch skill's own `lane-mail inbox --peek`, the one reader of the mailbox and its cursor, and acknowledged with `inbox --ack` only once the refusal is written, so a hook killed at its budget leaves them unread and a line acknowledged here is never handed over twice. That reader is resolved from this hook's own install, walking up to the home directory for `skills/orch/scripts/lane-mail` or the shared `.agents/skills/orch/scripts/lane-mail` beside it, then the home's own shared tree for a harness root relocated out of it; the open repository's `.agents/skills/orch/scripts/lane-mail` is used only where this hook is installed in that repository, and a reader outside that containment is refused rather than run. The refusal opens with `lane-mail-check: unread=<count>` and carries one JSON envelope per line under it; the turn then continues with them. Run with the argument `deliver` by the lane-mail-deliver hook after a tool call, it exits 0 with the harness's JSON on stdout, whose `additionalContext` carries the same lines. Run with `halt` by the lane-mail-halt hook before one, it acknowledges nothing and refuses the call while an unread directive sent with `lane-mail send --halt` stands, opening `lane-mail-check: halt=<id>` with the directive and the one `lane-mail inbox` command that reads it, which names the lane's root with `--root` so it reads the same mailbox from any checkout; that command alone passes. A call a subagent makes, whose payload carries a non-empty `agent_id` or `agent_type`, is handed no mail and acknowledges none, and while a halt stands it is refused without that command. `stop_hook_active` true skips the mailbox check whole on the turn-end run. The flag is in the payload, so nothing above the payload read knows a turn was continued, and `arm`, the `missing-tools` refusal for `jq` or `cat`, `payload=unreadable` and `payload=invalid-json` are refused on every turn, the continued one included. Below that read one rule holds and every refusal is on one side of it: a refusal the lane itself can clear is still made, and a refusal it cannot is reported on stderr and passed. The lane clears the two handoff marks, and `script`, `setting`, `setting-range` and both `transcript` refusals, by writing its handoff record, and `mailbox-missing` by running the command it names, so those are refused on a continued turn as on any other. It clears none of `workdir`, `git`, `item`, `marker` or the `missing-tools` refusal for `git`, `tr`, `awk`, `mktemp` or `tail`, so each of those is reported and the turn ends, where a fresh turn refuses it. The halt arm reports and passes that same set at every tool call: a lane whose tool calls are refused can clear nothing, since clearing it takes a tool call, so there only the payload refusals and the mailbox's own, `reader`, `inbox`, `halt` and `mailbox-missing`, are refused, the last two each passing the one command that clears it. The same turn-end run hands the lane off before it runs out, so the handoff never waits on an overseer reading a pane. It reads this session's context use from the `transcript_path` the payload names, the last assistant usage the harness itself recorded, in either of the two spellings a harness writes that usage in, Claude Code's `input_tokens` with the two cache counts beside it and Pi's `input` with `cacheRead` and `cacheWrite`, and refuses the turn end at or past `ORCH_HANDOFF_CONTEXT_TOKENS` (default 500000). It reads the account the credential this session runs on still has through the orch skill's own `lanes pick --lane`, and refuses at or below `ORCH_HANDOFF_HEADROOM_PCT` (default 3). Either refusal opens `lane-mail-check: context=<tokens>` or `lane-mail-check: headroom=<percent>` and carries one instruction: reach the next safe point, write the record with `workflow-state set <item> handoff`, send a `handoff` notice, and exit. The instruction opens with the `workflow-state init <item>` that `set` needs where the item has no state file yet, so it is enough on its own. It repeats at every turn end, `stop_hook_active` included, until the item's workflow state carries a `.handoff` object no relaunch has resumed; only the lane can write that record, so a single refusal it declines to act on would end the session with nothing recorded. That record is judged before every mark, before every read they rest on and before `orch-env` and `lanes` are looked for, so no failure but the record's own writer can hold a lane that has already done what it was asked. `orch-env` or `lanes` missing from this hook's install, a mark setting that is not a whole number in range, and a transcript the payload names and nothing can read are refusals too, each on the lane path alone and each carrying the same instruction. What the marks cannot judge is reported and passed, never refused: a payload naming no transcript leaves the context unread, and so does a transcript whose last usage line is an object carrying neither spelling, which is reported under `usage-unread=<path>` rather than summed to a figure of zero and read as room; an account `lanes` keeps no inventory for, one it could not measure and a read that passed this hook's own ceiling each leave the account unjudged under `account=unlisted`, `account=unmeasured` or `account=timeout`, never read as room, so a setup with no usage endpoint still ends its turns; and a lane whose handoff record cannot be judged leaves both marks unjudged under one of four keys, `handoff-skipped=<path>` for a reader or a script this install has not got, or `handoff-skipped=unlocatable` where this hook's own directory could not be resolved and none of them could be looked for, `handoff-outside=<path>` for one only the open repository supplies, `handoff-unanswered=<path>` for one that is there and answered nothing this hook can read, and `handoff-unreadable=<path>` for a state file the install's own `workflow-state` could not read. Passing the turn is the answer for all four. For the first three it is because an install whose orch scripts cannot answer cannot run `workflow-state set` either, so a lane told to record a handoff with them could never end a turn again; for `handoff-unreadable` the install answers and the fault is the item's own state file, which is the file the record would be written into, so that write could not land either and the refusal would be as uncloseable. A subagent's turn end is judged on neither mark. The fleet's OVERSEER meets four triggers of its own on its turn end: a session with no lane of its own whose tmux server and pane are the pair the oversee workflow state records under `.overseer` is that overseer, and nothing weaker establishes one, so an ordinary session in a fleet checkout is judged on nothing. Those marks are judged by `oversee-succeed --check-marks` from this hook's own install and by nothing here, under the same ceiling the account read runs under, so the turn-end refusal and the `overseer-mark` watch event cannot describe one overseer differently. Its refusal opens with the `context=`, `headroom=`, `rate=` or `qualifying=` key, carrying the figure that judgement read, and names `oversee-succeed` as the route, with `workflow-state set oversee handoff` under it for a succession that refuses, so the refusal always has an escape the overseer can reach. That record names the session that wrote it, in a `session_id` the payload gives and a `pane_key` for a harness that sends none. One other refusal stands on that path, `script` for an `oversee-succeed` this install has not got, and the record clears it as it clears the marks. `ORCH_OVERSEER_SUCCESSION=off`, read off the judgement's own line and never here, turns the refusal off with the succession it names. An answer this hook cannot act on, one the ceiling abandoned, and one whose own reading was unmeasured are reported under `marks=unjudged`, `marks=timeout` and `marks=unmeasured` and the turn ends, never held. A lane asks its overseer only through lane mail, and this hook holds that rule at both places a lane could ask elsewhere. Before a tool call in a launched lane, the halt arm refuses the harness question tool, whichever of the four names the payload's `tool_name` carries, Claude Code's `AskUserQuestion` and `EnterPlanMode`, Codex's `request_user_input` and Pi's `question`, opening `lane-mail-check: question-tool=<name>` and naming the `lane-mail ask --item <ID> --file <PATH>` send and the `lane-mail wait` on its printed id as the route, because a dialog on the pane reaches no overseer; an unread halt is refused ahead of it, a subagent's call is refused and told to report its question to the lead, and a session that is no launched lane passes the call silently, a committed mailbox and status file included. At a lane lead's turn end, once no handoff record stands, it refuses a turn whose final assistant text ends in a question while the mailbox holds no ask of this lane still waiting for an answer, opening `lane-mail-check: question-turn=<transcript>` with the same route. The question test is deterministic: the last non-empty line of the text blocks of the last assistant record in the transcript, trailing whitespace dropped, ends with `?`, read in Claude Code's `assistant` record and Pi's assistant `message` record, so a Codex lane's rollout, which spells neither, leaves its turn end unjudged; the ask test is the reader's own `lane-mail pending`, whose asks are the ones the overseer still owes. A turn whose ask is pending passes, a continued turn is refused again, since sending the ask is what clears it, and a payload naming no transcript, a window holding no assistant text in either spelling, and an install with no reader leave the turn unjudged, the last under the marks' own `handoff-skipped` line; a `pending` listing that fails is reported under `pending=<status>` and the turn ends, because nothing a lane does at its turn end repairs its mailbox. Not run on gemini: it has no Stop event. Not run on copilot: its agentStop also fires at each subagent's end. Not run on antigravity: its Stop payload carries no `stop_hook_active`.
# summary: Hands a lane the messages its overseer sent before the turn can end, so a directive is acted on instead of waiting for the next launch. It also holds the turn end once the lane is near the end of its context window or its account's limit, until the lane records where it got to and exits, so the work resumes in a fresh session instead of stopping mid-round. The session running the fleet is held the same way, and hands itself over to a fresh one. On Claude Code and Pi, a lane that ends its turn on a question it never sent through lane mail is held until it sends it, so no question waits in a pane nobody reads.
# safety: Reads the payload, the repository's branch, the lane's launch marker, read with the shell's own `read`, and the lane mailbox directory; the only write is the mailbox cursor the orch reader advances. Exit 2 names the unread count and the messages, and asks for them to be acted on, never bypassed. The reader it runs comes from its own install, never from the repository a session has open, so a repository that tracks a mailbox and an executable at that path cannot have it run. jq and cat read the payload; a payload it cannot read is refused on every turn, the continued one included, because the flag that marks a continued turn is in the payload none of those refusals reached. A mailbox whose reader is missing or fails is refused on the turns the mailbox check runs, which is every turn end but a continued one; on a continued turn that check is skipped whole, and the same missing reader is reported under `handoff-skipped` or `handoff-outside` and the turn is passed. An item name outside the alphabet a work item is spelled in, a branch that matches more than one mailbox, and a repository state git cannot report where a mailbox sits under the working directory are refused on a fresh turn and reported on a continued one and before a tool call, by the one rule the description states; none of them is ever passed in silence. For a lane's handoff marks it also reads the transcript the payload names and runs `orch-env`, `lanes` and `workflow-state` from the same install as the mailbox reader, never the open repository's; it writes nothing for them. A session that names no lane costs nothing more outside tmux, where the overseer test stops at its first condition. Inside tmux it costs that install's resolution, one child shell sourcing the orch context library, one tmux read and one `workflow-state` read, which together ask the oversee state whether this pane is the overseer's; a session the state does not name stops there. The overseer's own marks are then judged by `oversee-succeed --check-marks` from that same install, under the same 20 second ceiling the lane's account read runs under. That judgement measures the one account the overseer session runs on, through the same `lanes pick --lane` this hook asks about a lane, renewing an expired token in that account's credential file and refreshing that account's usage cache, the writes `lanes` states in its own contract; it opens no window and launches nothing. Only the last 1 MiB of the transcript is parsed, and the whole file only where that window carries no usage line, so the cost does not grow with the session. `lanes pick --lane` measures one account and renews that account's expired token, the write its own contract states; it can wait on a credentials lock and two network calls, and on a cache miss on the host-wide usage refresh lock for up to 10 seconds and, after a 429 with nothing cached, one sleep of up to 5 seconds and one more usage request, so it runs under a 20 second ceiling that leaves the rest of the run inside this hook's 30 second budget, and a read that reaches the ceiling is reported as a gap rather than refused. Where `timeout` is not installed that read runs unbounded, and a hook the harness then kills at its budget leaves the account unjudged, the same outcome the reported gap gives without the line. For the question rule it reads the payload's `tool_name` before a tool call and, at a turn end, the last assistant text in the transcript, and runs the reader's `pending` listing, which moves no cursor; it writes nothing for either. Every refusal opens with `lane-mail-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 30
# harnesses: [claude, codex, pi, opencode, cursor]
# requires: [lane-mail-deliver, lane-mail-halt]
# ---

set -euo pipefail

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
# refusal. Empty until each is known.
MARK=""
PCT=""
HANDOFF_INSTRUCTION=""
# The two commands a lane asks its overseer through, built by ask_route where
# a question refusal names them. Empty until one does.
ASK_ROUTE=""
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
# What a resolution step could not settle, for the phase that asked to refuse
# or to report, and the words the step's own command wrote. Empty until one
# fails.
FAIL_KEY=""
FAIL_VALUE=""
FAIL_CAUSE=""
# Who made the call the payload describes: lead, or subagent.
CALLER=""
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
# The word transcript_tokens prints for a usage object whose field names it
# does not read, kept apart from a figure and from the empty answer a window
# carrying no usage line gives: those two are judged, this one is reported.
USAGE_UNREAD=unread
NL='
'

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `lane-mail-check: <key>=<value>`: a
# stable key for the condition and the value acted on. The English explanation
# follows it, and never a bypass.
message() { # KEY VALUE [CAUSE]
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
        echo "this hook judges a turn end with no argument, a finished tool call with deliver, and a tool call about to run with halt; $2 is none of them"
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
        if [ "$CALLER" = subagent ]; then
          printf 'the overseer halted the lane this agent works in, and every tool call is refused until the lane lead reads the halt. Stop, and report the halt to the lead:\n%s\n' "$HALT_TEXT"
        else
          printf 'the overseer halted this lane, and every tool call is refused until the lane reads the halt. Run exactly this command, then act on the directive:\n%s\n%s\n' "$ACK_COMMAND" "$HALT_TEXT"
        fi
        ;;
      inbox=*)
        echo "the lane mailbox reader exited $2, so whether messages are waiting is unknown:"
        ;;
      handoff-skipped=unlocatable)
        echo "this hook's own directory could not be resolved, so the orch scripts the handoff marks are judged with could not be looked for; both marks are unjudged and this turn end is passed rather than held."
        ;;
      handoff-skipped=*)
        echo "the handoff marks are judged with the orch scripts beside this hook, and $2 is not there; this turn end is passed unjudged rather than held, because the same install holds the one command that records a handoff and a refusal naming a command the lane has not got could never be cleared. Install the orch skill beside this hook."
        ;;
      handoff-outside=*)
        echo "the only orch install on offer is $2, supplied by the repository this session has open, and this hook is not installed in that repository; refusing to judge the handoff marks with it. Both marks are unjudged and this turn end is passed rather than held. Install the orch skill in the scope this hook is installed in."
        ;;
      handoff-unanswered=*)
        echo "the handoff marks are judged with the orch scripts beside this hook, and $2 is there but did not answer; both marks are unjudged while that stands, and this turn end is passed rather than held, because the same install holds the one command that records a handoff. Check the settings those scripts load, .env.local first, or refresh the orch install. Anything it wrote is below."
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
        echo "the last usage line in $2 carries neither of the field spellings this hook reads a token count from, so the context mark is not judged and this gap is reported rather than held; an unread figure is never summed to zero and read as room, and the account mark is judged as usual"
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
          printf 'oversee-succeed reads this overseer as having used %s tokens of its context window, at or past the ORCH_HANDOFF_CONTEXT_TOKENS mark of %s. Succeed this session yourself: this refusal reaches the session at its turn end, and the watch reports the same judgement as an overseer-mark line, which is what reaches one that has not ended a turn since it crossed.\n%s\n' \
            "$2" "$MARK" "$HANDOFF_INSTRUCTION"
        else
          printf 'this lane has used %s tokens of its context window, at or past the ORCH_HANDOFF_CONTEXT_TOKENS mark of %s, and no handoff record stands. Hand this lane off yourself: the overseer polling a pane is a backstop and reads nothing at all on a hosted fleet.\n%s\n' \
            "$2" "$MARK" "$HANDOFF_INSTRUCTION"
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
        printf 'oversee-succeed finds %s successor accounts, at or below the ORCH_OVERSEER_SUCCESSOR_ACCOUNTS mark of %s. Succeed this session yourself before no account remains.\n%s\n' \
          "$2" "$MARK" "$HANDOFF_INSTRUCTION"
        ;;
      question-tool=*)
        if [ "$CALLER" = subagent ]; then
          printf 'this agent works in a lane, and a lane asks its overseer only through lane mail: %s opens a dialog on a pane the overseer cannot see or answer. Stop, and report the question to the lead, which sends it with lane-mail ask.\n' "$2"
        else
          printf 'this session is a lane, and a lane asks its overseer only through lane mail: %s opens a dialog on a pane the overseer cannot see or answer. Write the question to a file and send it, then wait on the id the send prints:\n%s\n' \
            "$2" "$ASK_ROUTE"
        fi
        ;;
      question-turn=*)
        printf 'the final assistant text in %s ends in a question, and the lane mailbox holds no ask of this lane still waiting for an answer, so the question reaches nobody: the overseer reads the mailbox, never the pane. Write the question to a file and send it, then wait on the id the send prints:\n%s\n' \
          "$2" "$ASK_ROUTE"
        ;;
      pending=envelope)
        echo "an envelope the lane mailbox reader's pending listing printed could not be read, so whether this lane's question was already sent is unknown; the turn ends unjudged rather than held, because nothing a lane does at its turn end repairs its mailbox:"
        ;;
      pending=*)
        echo "the lane mailbox reader's pending listing exited $2, so whether this lane's question was already sent is unknown; the turn ends unjudged rather than held, because nothing a lane does at its turn end repairs its mailbox:"
        ;;
      notice=unwritten)
        echo "the notice carrying the lane's unread messages could not be written, so they stay unread for the next tool call:"
        ;;
      unread=*)
        printf 'the overseer sent these messages to this lane; act on each as its text directs:\n%s\n' "$UNREAD"
        ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
}

# A refusal with nothing to offer beyond its own text: every arm above the
# handoff marks, the arm check, the payload readers and every mailbox refusal.
# The handoff refusals use `refuse_handoff` below, the one site that builds the
# instruction, so no other path pays for text it would not print.
refuse() { # KEY VALUE [CAUSE]
  message "$@"
  exit 2
}

# The event this run judges: a turn end with no argument, or the arm the
# lane-mail-deliver or lane-mail-halt hook beside this one names.
case "${1:-stop}" in
  stop | deliver | halt) ARM="${1:-stop}" ;;
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

# One read of the payload: the turn-end retry flag, who made the call, the
# transcript the harness records this session in, the id it names this
# session by, and the tool a call about to run names. A subagent's call
# carries agent_id on one harness and agent_type on another; the lane lead's
# carries neither. The five are joined on TAB rather than a space, so a
# transcript path holding spaces stays one field.
READ=$(printf '%s' "$INPUT" | jq -r '
  def str(f): if f == null then "" elif (f | type) == "string" then f else error("not a string") end;
  [(.stop_hook_active == true | tostring),
   (if str(.agent_id) + str(.agent_type) == "" then "lead" else "subagent" end),
   str(.transcript_path),
   str(.session_id),
   str(.tool_name)] | join("\t")' 2>&1) ||
  refuse payload invalid-json "$READ"
TAB=$(printf '\t')
ACTIVE=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
CALLER=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
TRANSCRIPT=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
SESSION=${READ%%"$TAB"*}
TOOL=${READ#*"$TAB"}
# The id is composed into the fleet handoff record below, so it is held to the
# alphabet a harness spells one in rather than handed to a second JSON encoder.
# A payload spelling it any other way leaves this empty, which is the same
# answer as a payload carrying no id: the record falls back to the pane key,
# the pair the fleet state already keys the overseer on.
case "$SESSION" in
  '' | *[!A-Za-z0-9._-]*) SESSION="" ;;
esac

# The harness sets stop_hook_active on the turn it continued because a stop
# hook blocked. That turn skips the mailbox check whole, and everything the
# lane cannot clear is reported rather than refused on it.
CONTINUED=false
if [ "$ARM" = stop ] && [ "$ACTIVE" = "true" ]; then CONTINUED=true; fi

# Refuse on a fresh turn end; on a continued one, and before a tool call,
# report the same line and pass. Only this hook's acknowledgement and the
# lane's own handoff record clear a refusal, and every other one repeats for
# as long as its cause stands: at every turn end, which is the loop
# stop_hook_active exists to end, and in the halt arm at every tool call,
# where the lane can clear nothing because clearing it takes the tool call
# this hook refuses. The handoff marks are not stalled: the record clears them
# and only the lane can write it.
REPORTED=false
if [ "$CONTINUED" = true ] || [ "$ARM" = halt ]; then REPORTED=true; fi
stall() { # KEY VALUE [CAUSE]
  if [ "$REPORTED" = true ]; then
    message "$@"
    exit 0
  fi
  refuse "$@"
}

# Lane mail belongs to the lane lead: a subagent's finished call is handed none
# and acknowledges none, so the lead's own run still finds it unread.
if [ "$ARM" = deliver ] && [ "$CALLER" = subagent ]; then
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
# on them the last step is the lane's own root already.
#
# Git reports one status for a directory that is no repository and for
# metadata it cannot read, and a lane always runs in one. So that directory
# answers: with no mailbox under it this session is not a lane and passes;
# with one the lane cannot be named, which is never passed off as no lane.
# The common git directory rides the same call: the launch markers live there.
LANE_DIR=${CLAUDE_PROJECT_DIR:-$PWD}
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

# Whether the call about to run is the lane lead's and is exactly COMMAND: the
# one call a refusal before a tool call passes, so the lane can run what clears
# it. A subagent's call never is, and no call is outside the halt arm.
lead_runs() { # COMMAND
  { [ "$ARM" = halt ] && [ "$CALLER" = lead ]; } || return 1
  COMMAND=$(printf '%s' "$INPUT" | jq -r '(.tool_input | objects | .command | strings) // ""' 2>&1) ||
    refuse payload invalid-json "$COMMAND"
  [ "$COMMAND" = "$1" ]
}

# A root its launch marker binds is a lane whatever else it lacks, and a lane
# with no mailbox directory reads no halt and no directive while its overseer's
# sends have nowhere to land. So it is refused, naming the marker and the one
# command that restores the directory; that command alone passes a tool call,
# as the acknowledging read passes a halt. The command makes the directory and
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
if [ ! -d "$MAIL_ROOT" ] && [ -d "$COMMON/lane-mail" ]; then
  NAMED=${LANE_MAIL_ITEM:-}
  if [ -z "$NAMED" ]; then
    read_branch
    NAMED=$BRANCH
  fi
  if item_alphabet "$NAMED"; then
    read_marker "$NAMED"
    if [ "$BOUND" = "$ROOT" ]; then
      printf -v MAILBOX_COMMAND 'mkdir -p -- %q' "$MAIL_ROOT"
      ! lead_runs "$MAILBOX_COMMAND" || exit 0
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
# Returns where the lane has nothing waiting; exits where it has. The order is
# the cheapest question first: a lane never written to has no file to read, so
# neither its launch marker nor the reader beside this hook is looked for, and
# a lane with no orch skill installed still ends its turns and runs its tools.

mail_check() {
  # Reading a file that is there is the orch reader's job: it owns the cursor,
  # so neither this hook nor a workflow wait point hands the same line twice.
  # Anything present at that path, a directory or a dangling link included, goes
  # on to the reader, whose component rule refuses what it cannot read.
  [ -e "$MAIL_ROOT/$ITEM/to-lane.jsonl" ] || [ -L "$MAIL_ROOT/$ITEM/to-lane.jsonl" ] || return 0
  lane_launched || return 0
  resolve_reader || refuse "$FAIL_KEY" "$FAIL_VALUE" "$FAIL_CAUSE"

  # Every reader call names the lane's root: a lane verb otherwise roots itself
  # at the call's cwd, which is the main clone for a lane's post-merge steps.
  RC=0
  PEEK=$("$READER" inbox --item "$ITEM" --root "$ROOT" --peek 2>"$WORK_DIR/reader.err") || RC=$?
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

  # The halt arm acknowledges nothing. It refuses while an unread halt stands and
  # passes the one plain read that acknowledges it, so the lane can run that read.
  # Unread lines that hold no halt return rather than exit: the question rule
  # still judges the call, or a directive in the mailbox would open the dialog.
  if [ "$ARM" = halt ]; then
    HALT=$(printf '%s\n' "$UNREAD" | jq -c -s 'map(select(.halt == true)) | first // empty' 2>&1) ||
      refuse inbox envelope "$HALT"
    [ -n "$HALT" ] || return 0
    HALT_ID=$(printf '%s' "$HALT" | jq -r '.id | strings' 2>&1) || refuse inbox envelope "$HALT_ID"
    HALT_TEXT=$(printf '%s' "$HALT" | jq -r '.text | strings' 2>&1) || refuse inbox envelope "$HALT_TEXT"
    # Only the lead acknowledges a halt: a subagent is refused whatever it runs,
    # and is never offered the command. The command names the lane's root, so
    # it reads this mailbox from whichever checkout the lane's shell is in.
    printf -v ACK_COMMAND '%q inbox --item %q --root %q' "$READER" "$ITEM" "$ROOT"
    ! lead_runs "$ACK_COMMAND" || exit 0
    refuse halt "$HALT_ID"
  fi

  COUNT=$(printf '%s\n' "$UNREAD" | awk 'END { print NR + 0 }')

  # After a tool call the notice travels as the context the harness's JSON
  # carries, exit 0: an exit 2 there replaces the tool's own output on one
  # harness. The keyed line opens that context. Acknowledged once it is written,
  # as below.
  if [ "$ARM" = deliver ]; then
    NOTICE=$(message unread "$COUNT" 2>&1)
    jq -nc --arg text "$NOTICE" '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $text}}' \
      2>"$WORK_DIR/notice.err" || refuse notice unwritten "$(cat -- "$WORK_DIR/notice.err")"
    "$READER" inbox --item "$ITEM" --root "$ROOT" --ack "$LINES" >/dev/null 2>"$WORK_DIR/ack.err" ||
      { cat -- "$WORK_DIR/ack.err" >&2 || :; }
    exit 0
  fi
  # Peek, then acknowledge: the cursor moves only once the refusal is written, so
  # a hook killed at its budget leaves the lines unread for the next stop rather
  # than consumed unseen. An acknowledgement that fails costs a repeat, never a
  # loss, and its cause stands under the refusal.
  message unread "$COUNT"
  "$READER" inbox --item "$ITEM" --root "$ROOT" --ack "$LINES" >/dev/null 2>"$WORK_DIR/ack.err" ||
    { cat -- "$WORK_DIR/ack.err" >&2 || :; }
  exit 2
}

# --- the question rule ---------------------------------------------------
#
# A lane asks its overseer only through lane mail: the overseer reads the
# mailbox and never the pane, so a harness question dialog and a question
# written as the turn's last words both reach nobody, and on a hosted fleet
# the item stalls until a person finds the pane. The rule is held at both
# places a lane could ask elsewhere, the tool call and the turn end, and both
# refusals name the same route. Neither holds a session that is no launched
# lane: an ordinary session asks its user through its harness as it always
# did, and a committed mailbox poses as no lane here, as it poses as none for
# the mailbox check.

# The harness question tools, by the names their PreToolUse payloads carry:
# Claude Code's AskUserQuestion and EnterPlanMode, whose plan ends in an
# approval dialog; Codex's request_user_input; and the `question` tool
# pi-questions registers on Pi, which the pi-hooks carrier hands over under
# its own id. The one list of those names: the launch words that take each
# tool away live in the orch skill's lane-launch library, and the table in
# skills/orch/references/skill-rules.md § Coordination cites this list
# beside them.
question_tool() { # NAME
  case "$1" in
    AskUserQuestion | EnterPlanMode | request_user_input | question) return 0 ;;
  esac
  return 1
}

# The two commands that route a lane's question, named by every question
# refusal. The reader is this hook's own where it resolves; an install with
# none is told the verb by name, since the route is the rule and the gap in
# the install has its own line elsewhere. Both name the lane's root, as the
# halt's read does: a lane verb otherwise roots itself at the call's cwd, so
# a lane working from the main clone would write an ask into a mailbox its
# overseer never reads and wait on an answer that never comes.
ask_route() {
  local asker=lane-mail
  ! resolve_reader || asker="$READER"
  printf -v ASK_ROUTE '  %q ask --item %q --root %q --file [PATH]\n  %q wait --item %q --root %q --id [MSGID]' \
    "$asker" "$ITEM" "$ROOT" "$asker" "$ITEM" "$ROOT"
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

# The last non-empty line of the final assistant text, trailing whitespace
# dropped, in the two spellings a harness writes its transcript in: Claude
# Code's `assistant` record and Pi's `message` record whose message role is
# assistant (`AssistantMessage`, @earendil-works/pi-ai), each carrying content
# blocks of which the `text` ones are the words the lane wrote. The last
# record carrying any text is the final text; a record holding only a tool
# call or thinking carries no question. Empty where the window holds no such
# record. `fromjson?` skips the partial line a byte window opens on.
transcript_final_line() {
  jq -Rr 'fromjson?
    | select(.type == "assistant" or (.type == "message" and .message?.role == "assistant"))
    | [.message?.content? | arrays | .[] | objects | select(.type == "text") | .text | strings]
    | join("\n") | split("\n") | map(sub("\\s+$"; "")) | map(select(. != ""))
    | last // empty' 2>"$WORK_DIR/transcript.err" |
    tail -n 1
}

# At a lane lead's turn end: a final text ending in a question is refused
# unless the mailbox holds an ask of this lane the overseer still owes an
# answer to, which `lane-mail pending` lists and nothing here re-derives. Sent
# ahead of the marks, so the question is routed before the lane is told to
# hand off, and refused on a continued turn too: sending the ask is what
# clears it, and only the lane can. The transcript read is left to the marks
# where it cannot be made: they run the same tail on the same file next and
# refuse it under `transcript=unread`.
question_turn_check() {
  [ -n "$TRANSCRIPT" ] || return 0
  { [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; } || return 0
  LAST=$(tail -c "$TRANSCRIPT_WINDOW" -- "$TRANSCRIPT" | transcript_final_line) || return 0
  case "$LAST" in
    *'?') ;;
    *) return 0 ;;
  esac
  PENDING_RC=0
  PENDING=$("$READER" pending --item "$ITEM" --root "$ROOT" 2>"$WORK_DIR/pending.err") || PENDING_RC=$?
  if [ "$PENDING_RC" -ne 0 ]; then
    message pending "$PENDING_RC" "$(cat -- "$WORK_DIR/pending.err")"
    return 0
  fi
  ASKS=$(printf '%s\n' "$PENDING" | jq -c 'select(.kind == "ask")' 2>&1) ||
    { message pending envelope "$ASKS"; return 0; }
  [ -z "$ASKS" ] || return 0
  ask_route
  refuse question-turn "$TRANSCRIPT"
}

# --- the handoff marks ---------------------------------------------------
#
# A lane hands ITSELF off. The overseer's `lanes context` poll of a pane is a
# backstop: it is blind to a hosted pane, no watch event carries a context
# figure, and an overseer between events, at its own wall or in succession
# reads nothing at all, so lanes ran 50 to 190 thousand tokens past the mark
# waiting to be told. Two marks fire one instruction, and the lane's own
# handoff record clears both.
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
# else this hook refuses. The escapes differ: this hook's own acknowledgement
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
      'Reach a safe point first, with no merged event part-handled and no lane waiting on an answer only the root can give. There, rewrite the overseer handoff file and succeed this session:\n  %q -- [THE PERMISSION, MODEL AND EFFORT FLAGS THIS SESSION RUNS UNDER]\nWhere that refuses, tell the user a fresh overseer session must be started by hand, then record the handoff and end this session:\n%s  %q set %q handoff %s\nWrite the record as it stands above: the two names in it are what end this refusal for this session and for no other. It repeats at every turn end until the succession lands or that record stands.' \
      "$SCRIPTS/oversee-succeed" "$INIT_LINE" "$SCRIPTS/workflow-state" "$ITEM" \
      "'$OVERSEER_RECORD'"
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
  message "$@"
  exit 2
}

# The context the transcript records: every assistant message carries the
# tokens its prompt was billed for, and the context is that count plus the
# cache the prompt was read from. The LAST such line is the window as it
# stands, so a compaction that reset it reads as the reset it is. `fromjson?`
# skips the partial line a byte window opens on and the line the harness is
# still appending as this runs.
#
# Two harnesses write that usage object and each spells its fields its own way:
# Claude Code's `input_tokens` with the two cache counts beside it, and Pi's
# `input` with `cacheRead` and `cacheWrite` (`Usage`, @earendil-works/pi-ai).
# Neither field set is defaulted into the other's sum, because a missing field
# and a field spelled the other way are the same absence to `//` and would read
# a whole window as zero. A usage object carrying neither spelling is answered
# with USAGE_UNREAD rather than a figure: the caller reports it as a mark it
# could not judge, and the empty answer stays what it has always been, a window
# holding no usage line at all, which the whole-file read behind it resolves.
transcript_tokens() {
  jq -Rr --arg unread "$USAGE_UNREAD" 'fromjson? | .message?.usage? // empty
    | (objects
       | if has("input_tokens") or has("cache_read_input_tokens")
            or has("cache_creation_input_tokens")
         then (.input_tokens // 0) + (.cache_read_input_tokens // 0)
              + (.cache_creation_input_tokens // 0)
         elif has("input") or has("cacheRead") or has("cacheWrite")
         then (.input // 0) + (.cacheRead // 0) + (.cacheWrite // 0)
         else empty end) // $unread' 2>"$WORK_DIR/transcript.err" |
    tail -n 1
}

# Whether THIS session is the fleet's overseer, established positively and in
# one way: `oversee-watch` records the overseer's tmux server and pane in the
# fleet state before its first pass (`overseer_command_record`), and a session
# whose own pane key is that pair is that overseer. Nothing weaker will do. The
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
OVERSEER_ITEM=oversee
overseer_identified() {
  [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ] || return 1
  [ -e "$SCRIPTS/lib/lane-context.sh" ] || return 1
  if ! CALLER_KEY=$("$BASH" -euo pipefail -c '. "$1" && lane_context_caller_key' \
    _ "$SCRIPTS/lib/lane-context.sh" 2>/dev/null)
  then
    return 1
  fi
  [ -n "$CALLER_KEY" ] || return 1
  if ! RECORDED_KEY=$("$SCRIPTS/workflow-state" get "$OVERSEER_ITEM" \
    '(.overseer.server // "") + " " + (.overseer.pane // "")' 2>/dev/null)
  then
    return 1
  fi
  [ "$RECORDED_KEY" = "$CALLER_KEY" ] || return 1
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
    2>"$WORK_DIR/judge.err") || JUDGE_RC=$?
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
      succession=*) SUCCESSION=${field#succession=} ;;
    esac
  done
  # A line missing one of the three is an answer this hook cannot act on, and
  # refusing on it would name a figure nothing read.
  if [ -z "$MARK_KIND" ] || [ -z "$MARK_VALUE" ] || [ -z "$MARK" ]; then
    message marks unjudged "$JUDGE_LINE"
    return 0
  fi
  # Succession off leaves the overseer nothing this hook could hold it for: the
  # succession is its route out, and a refusal whose route the operator has
  # turned off is a turn end nothing the overseer does can reach. The setting
  # is read off the judgement's own line rather than here, so a spelling this
  # hook would take for `on` and that script refuses cannot exist: that script
  # refuses it, and the refusal is reported under `marks=unjudged`. The watch
  # still reports the mark, so the fleet is not left silent.
  [ "$SUCCESSION" != off ] || return 0
  case "$MARK_KIND" in
    context) refuse_handoff context "$MARK_VALUE" ;;
    headroom) PCT="$MARK"; refuse_handoff headroom "$MARK_VALUE" ;;
    rate|qualifying) refuse_handoff "$MARK_KIND" "$MARK_VALUE" ;;
    *) message marks unjudged "$JUDGE_LINE" ;;
  esac
  return 0
}

# Called plainly, so errexit is live throughout this body: a status left to it
# would exit the hook with neither 0 nor 2 and end the turn with no mark
# judged. Every status is therefore tested where it is taken.
handoff_check() {
  [ "$ARM" = stop ] && [ "$CALLER" = lead ] || return 0
  if [ -z "$ITEM" ]; then
    # An overseer runs in a tmux pane, and the fleet state names that pane:
    # a session with neither is not one, and this is the whole of what a
    # session outside tmux pays at its turn end. Judged before the install is
    # resolved, so an ordinary checkout costs what it cost before this arm
    # existed.
    { [ -n "${TMUX:-}" ] && [ -n "${TMUX_PANE:-}" ]; } || return 0
    NO_LANE_ITEM=1
  else
    lane_launched || return 0
  fi

  # The marks are judged with the orch scripts beside the mailbox reader, from
  # this hook's own install and never the open repository's, as the reader is.
  # An install that carries none of them carries no `workflow-state` either, so
  # the lane could not record a handoff whatever it was told: the gap is
  # reported and the turn ends. A reader the open repository supplies is that
  # same gap for a different reason, and says so under its own key rather than
  # sending the operator to reinstall a skill that is installed.
  if ! resolve_reader; then
    # An install this hook could not find is also what would have established
    # that a session naming no lane item is the overseer, so that session is
    # neither and reporting a gap for it would put a keyed line on every turn
    # end of every session in the checkout.
    [ "$NO_LANE_ITEM" -eq 0 ] || return 0
    case "$FAIL_KEY" in
      reader-outside) message handoff-outside "$FAIL_VALUE" "$FAIL_CAUSE" ;;
      *) message handoff-skipped "$FAIL_VALUE" "$FAIL_CAUSE" ;;
    esac
    exit 0
  fi
  if [ ! -x "$SCRIPTS/workflow-state" ]; then
    [ "$NO_LANE_ITEM" -eq 0 ] || return 0
    message handoff-skipped "$SCRIPTS/workflow-state"
    exit 0
  fi
  # The fleet state is what names the overseer, so this is the first step that
  # can ask. A session that is not it has no marks of this hook's to meet.
  if [ "$NO_LANE_ITEM" -eq 1 ]; then
    overseer_identified || return 0
    ROLE=overseer
    ITEM="$OVERSEER_ITEM"
  fi

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

  # A lane's question is routed before the lane is told to hand off. The
  # overseer owns its harness's question tool and asks the user through it.
  [ "$ROLE" = overseer ] || question_turn_check

  # The overseer's marks are judged by the script that performs its succession
  # and by nothing here. A second derivation was the defect: this hook reads a
  # lane's context out of the transcript and its account through `lanes pick`,
  # while `oversee-succeed` reads the overseer's context off the pane status
  # line behind a 1M-window gate and its account off the caller row of `lanes
  # context`. On a model whose window that reader does not hold, the two
  # disagree, and the turn end is refused at a mark the succession then reports
  # as not reached — a session held by one command and released by the other.
  if [ "$ROLE" = overseer ]; then
    overseer_marks
    return 0
  fi

  for script in orch-env lanes; do
    [ -x "$SCRIPTS/$script" ] || refuse_handoff script "$SCRIPTS/$script"
  done

  # A bounded tail first: a session transcript grows without limit and parsing
  # the whole of one at every turn end costs more than the rest of this hook
  # together. The full file answers only where that window holds no usage line
  # — a session on its first turns, or one whose recent lines are all tool
  # results. A payload naming no transcript leaves the figure empty and below
  # every mark.
  TOKENS=""
  if [ -n "$TRANSCRIPT" ]; then
    { [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; } || refuse_handoff transcript unreadable
    TOKENS=$(tail -c "$TRANSCRIPT_WINDOW" -- "$TRANSCRIPT" | transcript_tokens) ||
      refuse_handoff transcript unread "$(cat -- "$WORK_DIR/transcript.err")"
    [ -n "$TOKENS" ] || TOKENS=$(transcript_tokens <"$TRANSCRIPT") ||
      refuse_handoff transcript unread "$(cat -- "$WORK_DIR/transcript.err")"
  fi

  MARK=$("$SCRIPTS/orch-env" ORCH_HANDOFF_CONTEXT_TOKENS 500000 2>"$WORK_DIR/env.err") ||
    refuse_handoff setting ORCH_HANDOFF_CONTEXT_TOKENS "$(cat -- "$WORK_DIR/env.err")"
  whole_number "$MARK" || refuse_handoff setting-range "ORCH_HANDOFF_CONTEXT_TOKENS=$MARK"
  # Three answers, and the mark is judged on one of them. A figure is compared;
  # the empty answer is a transcript with no usage line and leaves the mark
  # unjudged in silence, which the description states as this hook's one
  # documented gap; a usage object neither spelling reads leaves it unjudged
  # too, and that one gets its own key, because the figure IS there and a lane
  # told nothing would run to its wall believing the mark was watching.
  if [ "$TOKENS" = "$USAGE_UNREAD" ]; then
    message usage-unread "$TRANSCRIPT"
  elif [ -n "$TOKENS" ] && [ "$TOKENS" -ge "$MARK" ]; then
    refuse_handoff context "$TOKENS"
  fi

  # The account the credential THIS session runs on still has, judged by the
  # one script that measures a lane and against the one setting that marks a
  # lane for handoff. `pick --lane` answers about that directory alone: 0 has
  # room, 3 is at or below the mark, and 4 is a directory that is no configured
  # lane of this harness. Every other exit, and a read that passes the ceiling,
  # is an account nothing measured: reported and passed, never read as room and
  # never held, because a setup with no usage endpoint must still end its turns.
  #
  # Which harness this session is comes from this hook's own install, the one
  # place that records it: `hook_target` in `crates/core/src/engine/targets.rs`
  # writes the claude copy under `.claude/hooks` and the codex copy under
  # `.codex/hooks`. A harness `lanes` keeps no inventory for leaves the account
  # unnamed, and its lanes are judged on the context mark alone.
  case "$HOOK_DIR" in
    */.claude/hooks) HARNESS=claude ;;
    */.codex/hooks) HARNESS=codex ;;
    *) HARNESS="" ;;
  esac
  if [ -z "$HARNESS" ]; then
    message account unlisted "$HOOK_DIR is no harness lanes keeps an inventory for"
    return 0
  fi
  # The account rule is a function in the orch library, and an install older
  # than it is readable, sources without error and then leaves the call to
  # bash's command-not-found, which would end the turn on 127 with no keyed
  # line at all. So the capability is probed, not the file, and a library that
  # cannot answer is the same reported gap a missing one is, under the key that
  # says which. The sourcing is captured at the site, because bash writes a
  # broken library's syntax errors as it reads it and they would otherwise
  # stand ahead of the keyed line.
  if [ ! -e "$SCRIPTS/lib/lane-context.sh" ]; then
    message handoff-skipped "$SCRIPTS/lib/lane-context.sh"
    return 0
  fi
  # Probed in a child of THIS interpreter, under this script's own options,
  # and sourced in-process only once that child has answered. In-process is
  # where the probe cannot live: bash 3.2 kills the shell on a source it cannot
  # parse or read, even as the condition of an `if`, where bash 5 takes the
  # non-zero status and carries on. This hook's EXIT trap then succeeds and
  # lends the run its own 0, so the turn passed with the account mark unjudged
  # and not one line on stderr. A child dies alone and hands back a status.
  #
  # `$BASH` is the running interpreter's own path, never a PATH lookup: the two
  # bash versions disagree on exactly this operation, so a probe answered by a
  # different bash than the one about to source the file answers another
  # question. The options are passed with it for the same reason. No readability
  # test stands ahead of the probe, because failing the source is what writes
  # bash's own words to the file the arm below replays; a `-r` test would leave
  # that cause empty under a line that promises one.
  : >"$WORK_DIR/lib.err"
  if ! "$BASH" -euo pipefail -c '. "$1" && declare -F lane_context_caller_cfg >/dev/null' _ "$SCRIPTS/lib/lane-context.sh" 2>"$WORK_DIR/lib.err"; then
    message handoff-unanswered "$SCRIPTS/lib/lane-context.sh" "$(cat -- "$WORK_DIR/lib.err")"
    return 0
  fi
  # The probe proved this source parses, reads and returns 0 under these very
  # options, so there is no status left here to take. Its stderr still goes to
  # the captured file rather than the hook's own, so a library that writes as
  # it loads cannot put a word ahead of a keyed line.
  # shellcheck source=../skills/orch/scripts/lib/lane-context.sh
  . "$SCRIPTS/lib/lane-context.sh" 2>>"$WORK_DIR/lib.err"
  # Every arm of lane_context_caller_cfg returns 0 and prints one directory,
  # and this hook reaches it only with claude or codex, so the directory is the
  # whole of its answer and there is no status to take.
  CFG=$(lane_context_caller_cfg "$HARNESS")

  PCT=$("$SCRIPTS/orch-env" ORCH_HANDOFF_HEADROOM_PCT 3 2>"$WORK_DIR/env.err") ||
    refuse_handoff setting ORCH_HANDOFF_HEADROOM_PCT "$(cat -- "$WORK_DIR/env.err")"
  percent_in_range "$PCT" || refuse_handoff setting-range "ORCH_HANDOFF_HEADROOM_PCT=$PCT"

  # Bounded by BOUND_BY, for the reason stated where it is set: a read that
  # passes the ceiling exits 124 and is reported under `account=timeout`.
  PICK_RC=0
  PICK=$(${BOUND_BY[@]+"${BOUND_BY[@]}"} "$SCRIPTS/lanes" pick --lane "$CFG" --harness "$HARNESS" \
    --min-headroom-pct "$PCT" --json 2>"$WORK_DIR/lanes.err") || PICK_RC=$?
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

# The mailbox belongs to a lane and only a lane names one here; the marks are
# judged for a lane and for the overseer alike, and decide which of the two
# this session is themselves.
if [ "$CONTINUED" = false ] && [ -n "$ITEM" ]; then
  mail_check
fi
if [ "$ARM" = halt ] && [ -n "$ITEM" ]; then
  question_tool_check
fi
handoff_check
exit 0
