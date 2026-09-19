#!/usr/bin/env bash
# ---
# name: lane-mail-check
# event: Stop
# matcher:
# description: Blocks a lane's turn end while its overseer mailbox holds unread lines, so a directive or a ruling reaches the lane without a keystroke, a pane or a question tool. The lane is the work item `LANE_MAIL_ITEM` names, or the one directory under `<repo>/tmp/lane-mail/` whose name lowercases to the current branch; a session with neither is not a lane and passes silently, as does a lane whose mailbox holds no unread line and a directory git reports no repository for and that holds no mailbox of its own. A mailbox belongs to a lane only where a launch recorded one: `open-terminal` and `lane-host create` write the lane's root to `lane-mail/<item in lower case>` under the repository's common git directory and create the lane's own `tmp/lane-mail/<item>`, and a mailbox with no marker bound to this root passes silently. Unread lines are peeked through the orch skill's own `lane-mail inbox --peek`, the one reader of the mailbox and its cursor, and acknowledged with `inbox --ack` only once the refusal is written, so a hook killed at its budget leaves them unread and a line acknowledged here is never handed over twice. That reader is resolved from this hook's own install, walking up to the home directory for `skills/orch/scripts/lane-mail` or the shared `.agents/skills/orch/scripts/lane-mail` beside it, then the home's own shared tree for a harness root relocated out of it; the open repository's `.agents/skills/orch/scripts/lane-mail` is used only where this hook is installed in that repository, and a reader outside that containment is refused rather than run. The refusal opens with `lane-mail-check: unread=<count>` and carries one JSON envelope per line under it; the turn then continues with them. Run with the argument `deliver` by the lane-mail-deliver hook after a tool call, it exits 0 with the harness's JSON on stdout, whose `additionalContext` carries the same lines. Run with `halt` by the lane-mail-halt hook before one, it acknowledges nothing and refuses the call while an unread directive sent with `lane-mail send --halt` stands, opening `lane-mail-check: halt=<id>` with the directive and the one `lane-mail inbox` command that reads it; that command alone passes. A call a subagent makes, whose payload carries a non-empty `agent_id` or `agent_type`, is handed no mail and acknowledges none, and while a halt stands it is refused without that command. `stop_hook_active` true skips the mailbox check whole on the turn-end run. What it does to a refusal on that turn follows one rule, and every refusal here is on one side of it: a refusal the lane itself can clear is still made, and a refusal it cannot is reported on stderr and passed. The lane clears the two handoff marks, and `script`, `setting`, `setting-range` and both `transcript` refusals, by writing its handoff record, so those are refused on a continued turn as on any other. It clears none of `missing-tools`, `workdir`, `git`, `item` or `marker`, so each of those is reported and the turn ends, where a fresh turn refuses it. The same turn-end run hands the lane off before it runs out, so the handoff never waits on an overseer reading a pane. It reads this session's context use from the `transcript_path` the payload names, the last assistant usage the harness itself recorded, and refuses the turn end at or past `ORCH_HANDOFF_CONTEXT_TOKENS` (default 500000). It reads the account the credential this session runs on still has through the orch skill's own `lanes pick --lane`, and refuses at or below `ORCH_HANDOFF_HEADROOM_PCT` (default 5). Either refusal opens `lane-mail-check: context=<tokens>` or `lane-mail-check: headroom=<percent>` and carries one instruction: reach the next safe point, write the record with `workflow-state set <item> handoff`, send a `handoff` notice, and exit. The instruction opens with the `workflow-state init <item>` that `set` needs where the item has no state file yet, so it is enough on its own. It repeats at every turn end, `stop_hook_active` included, until the item's workflow state carries a `.handoff` object no relaunch has resumed; only the lane can write that record, so a single refusal it declines to act on would end the session with nothing recorded. That record is judged before every mark, before every read they rest on and before `orch-env` and `lanes` are looked for, so no failure but the record's own writer can hold a lane that has already done what it was asked. `orch-env` or `lanes` missing from this hook's install, a mark setting that is not a whole number in range, and a transcript the payload names and nothing can read are refusals too, and each carries the same instruction. What the marks cannot judge is reported and passed, never refused: a payload naming no transcript leaves the context unread; an account `lanes` keeps no inventory for, one it could not measure and a read that passed this hook's own ceiling each leave the account unjudged under `account=unlisted`, `account=unmeasured` or `account=timeout`, never read as room, so a setup with no usage endpoint still ends its turns; and an install carrying no orch reader or no `workflow-state` beside this hook leaves both marks unjudged under `handoff-skipped=<path>`, because a lane told to record a handoff with a command it has not got could never end a turn again. A subagent's turn end is judged on neither mark. Not run on gemini: it has no Stop event. Not run on copilot: its agentStop also fires at each subagent's end. Not run on antigravity: its Stop payload carries no `stop_hook_active`.
# summary: Hands a lane the messages its overseer sent before the turn can end, so a directive is acted on instead of waiting for the next launch. It also holds the turn end once the lane is near the end of its context window or its account's limit, until the lane records where it got to and exits, so the work resumes in a fresh session instead of stopping mid-round.
# safety: Reads the payload, the repository's branch, the lane's launch marker and the lane mailbox directory; the only write is the mailbox cursor the orch reader advances. Exit 2 names the unread count and the messages, and asks for them to be acted on, never bypassed. The reader it runs comes from its own install, never from the repository a session has open, so a repository that tracks a mailbox and an executable at that path cannot have it run. jq and cat read the payload; a payload it cannot read is refused, never passed, and so is a mailbox whose reader is missing or fails. An item name outside the alphabet a work item is spelled in, a branch that matches more than one mailbox, and a repository state git cannot report where a mailbox sits under the working directory are refused on a fresh turn and reported on a continued one, by the one rule the description states; none of them is ever passed in silence. For the handoff marks it also reads the transcript the payload names and runs `orch-env`, `lanes` and `workflow-state` from the same install as the mailbox reader, never the open repository's; it writes nothing for them. Only the last 1 MiB of the transcript is parsed, and the whole file only where that window carries no usage line, so the cost does not grow with the session. `lanes pick --lane` measures one account and renews that account's expired token, the write its own contract states; it can wait on a credentials lock and two network calls, so it runs under a 20 second ceiling that leaves the rest of the run inside this hook's 30 second budget, and a read that reaches the ceiling is reported as a gap rather than refused. Where `timeout` is not installed that read runs unbounded, and a hook the harness then kills at its budget leaves the account unjudged, the same outcome the reported gap gives without the line. Every refusal opens with `lane-mail-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 30
# harnesses: [claude, codex, pi, opencode, cursor]
# ---

set -euo pipefail

# Names are matched by byte ranges below, so the locale decides the match.
export LC_ALL=C

# What the refusal names, empty until it is known: the lane's unread lines,
# and a halt's directive with the one command that reads it.
UNREAD=""
HALT_TEXT=""
ACK_COMMAND=""
# The handoff marks: the two settings judged and the commands that end the
# refusal. Empty until each is known.
MARK=""
PCT=""
HANDOFF_INSTRUCTION=""
# What a resolution step could not settle, for the phase that asked to refuse
# or to report. Empty until one fails.
FAIL_KEY=""
FAIL_VALUE=""
# Who made the call the payload describes: lead, or subagent.
CALLER=""
# The orch scripts the marks are judged with, empty until the reader resolves.
# `refuse` reads it before then, to tell a mailbox refusal from one the handoff
# record clears.
SCRIPTS=""
# The last bytes of the transcript the context figure is taken from, and the
# seconds the account read is given.
TRANSCRIPT_WINDOW=1048576
ACCOUNT_CEILING=20
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
      handoff-skipped=*)
        echo "the handoff marks are judged with the orch scripts beside this hook, and $2 is not there; this turn end is passed unjudged rather than held, because the same install holds the one command that records a handoff and a refusal naming a command the lane has not got could never be cleared. Install the orch skill beside this hook."
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
      account=unlisted)
        echo "the directory this lane's credential lives in is no lane lanes keeps an inventory for, so the account mark is not judged and this gap is reported rather than held; the context mark is judged as usual:"
        ;;
      account=timeout)
        echo "the account read did not finish inside this hook's ceiling, so whether the account is about to wall is unknown; the gap is reported rather than held, because a lane whose account nothing can measure must still be able to end a turn. The account is not read as room:"
        ;;
      account=unmeasured)
        echo "the account this lane runs its credential out of could not be measured, so whether it is about to wall is unknown; the gap is reported rather than held, and an account nothing measured is never read as room:"
        ;;
      context=*)
        printf 'this lane has used %s tokens of its context window, at or past the ORCH_HANDOFF_CONTEXT_TOKENS mark of %s, and no handoff record stands. Hand this lane off yourself: the overseer polling a pane is a backstop and reads nothing at all on a hosted fleet.\n%s\n' \
          "$2" "$MARK" "$HANDOFF_INSTRUCTION"
        ;;
      headroom=*)
        printf 'the account this lane runs its credential out of has %s percent headroom left, at or below the ORCH_HANDOFF_HEADROOM_PCT mark of %s, and no handoff record stands. Hand this lane off yourself: the account walls mid-round otherwise.\n%s\n' \
          "$2" "$PCT" "$HANDOFF_INSTRUCTION"
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

# Every refusal below the reader resolves carries the two commands that end
# it, and the normal turn end prints none of them. So the text is built here,
# once, at the one site that prints it: the reader walk and the mailbox
# refusals above it fire with SCRIPTS still empty and carry no instruction.
refuse() { # KEY VALUE [CAUSE]
  [ -z "$SCRIPTS" ] || handoff_instruction
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

# One read of the payload: the turn-end retry flag, who made the call, and the
# transcript the harness records this session in. A subagent's call carries
# agent_id on one harness and agent_type on another; the lane lead's carries
# neither. The three are joined on TAB rather than a space, so a transcript
# path holding spaces stays one field.
READ=$(printf '%s' "$INPUT" | jq -r '
  def str(f): if f == null then "" elif (f | type) == "string" then f else error("not a string") end;
  [(.stop_hook_active == true | tostring),
   (if str(.agent_id) + str(.agent_type) == "" then "lead" else "subagent" end),
   str(.transcript_path)] | join("\t")' 2>&1) ||
  refuse payload invalid-json "$READ"
TAB=$(printf '\t')
ACTIVE=${READ%%"$TAB"*}
READ=${READ#*"$TAB"}
CALLER=${READ%%"$TAB"*}
TRANSCRIPT=${READ#*"$TAB"}

# The harness sets stop_hook_active on the turn it continued because a stop
# hook blocked. That turn skips the mailbox check whole, and everything the
# lane cannot clear is reported rather than refused on it.
CONTINUED=false
if [ "$ARM" = stop ] && [ "$ACTIVE" = "true" ]; then CONTINUED=true; fi

# Refuse on a fresh turn; on a continued one report the same line and pass.
# Only this hook's acknowledgement and the lane's own handoff record clear a
# refusal, and every other one repeats at every turn end for as long as its
# cause stands, which is the loop stop_hook_active exists to end. The handoff
# marks are not stalled: the record clears them and only the lane can write it.
stall() { # KEY VALUE [CAUSE]
  if [ "$CONTINUED" = true ]; then
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

WORK_DIR=$(mktemp -d 2>&1) || stall workdir "${TMPDIR:-/tmp}" "$WORK_DIR"
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Git reports one status for a directory that is no repository and for
# metadata it cannot read, and a lane always runs in one. So the cwd answers:
# with no mailbox under it this session is not a lane and passes; with one the
# lane cannot be named, which is never passed off as no lane.
ROOT_RC=0
ROOT=$(git rev-parse --show-toplevel 2>&1) || ROOT_RC=$?
if [ "$ROOT_RC" -ne 0 ]; then
  [ -d "tmp/lane-mail" ] || exit 0
  stall git 'rev-parse --show-toplevel' "$ROOT"
fi
MAIL_ROOT="$ROOT/tmp/lane-mail"

# A repository with no mailbox directory is not a fleet lane: a launch creates
# the lane's own directory there beside its marker, so the stat answers for the
# handoff marks as well as for the mailbox. Judged before the item, so an
# ordinary session costs one stat.
[ -d "$MAIL_ROOT" ] || exit 0

item_alphabet() { # NAME
  case "$1" in
    '' | . | ..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# `symbolic-ref -q` exits 1 for a HEAD that names no branch — detached, and
# never a lane — and 128 for a repository it cannot read, so the two are told
# apart without reading git's prose. The answer lands in a variable rather
# than a substitution's stdout, so the refusal's exit is the hook's.
BRANCH_RC=0
BRANCH=$(git symbolic-ref -q --short HEAD 2>&1) || BRANCH_RC=$?
case "$BRANCH_RC" in
  0) ;;
  1) BRANCH="" ;;
  *) stall git 'symbolic-ref -q --short HEAD' "$BRANCH" ;;
esac

# The item is what the lane's launch brief set, or the mailbox whose name is
# the branch: `worktree create` names a lane's branch after its item in lower
# case, so the branch selects it without a second copy of any id grammar.
ITEM=""
if [ -n "${LANE_MAIL_ITEM:-}" ]; then
  item_alphabet "$LANE_MAIL_ITEM" || stall item invalid
  ITEM="$LANE_MAIL_ITEM"
else
  [ -n "$BRANCH" ] || exit 0
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
[ -n "$ITEM" ] || exit 0

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
  COMMON_RC=0
  COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>&1) || COMMON_RC=$?
  [ "$COMMON_RC" -eq 0 ] || stall git 'rev-parse --git-common-dir' "$COMMON"
  LOWER=$(printf '%s' "$ITEM" | tr 'A-Z' 'a-z')
  MARKER="$COMMON/lane-mail/$LOWER"
  BOUND=""
  if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
    # Present but not a plain file: a marker this cannot judge, refused rather
    # than read as no lane.
    { [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; } || stall marker "$MARKER"
    BOUND_RC=0
    BOUND=$(cat -- "$MARKER" 2>&1) || BOUND_RC=$?
    [ "$BOUND_RC" -eq 0 ] || stall marker "$MARKER" "$BOUND"
  fi
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
  HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || return 2
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
  resolve_reader || refuse "$FAIL_KEY" "$FAIL_VALUE"

  RC=0
  PEEK=$("$READER" inbox --item "$ITEM" --peek 2>"$WORK_DIR/reader.err") || RC=$?
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
  if [ "$ARM" = halt ]; then
    HALT=$(printf '%s\n' "$UNREAD" | jq -c -s 'map(select(.halt == true)) | first // empty' 2>&1) ||
      refuse inbox envelope "$HALT"
    [ -n "$HALT" ] || exit 0
    HALT_ID=$(printf '%s' "$HALT" | jq -r '.id | strings' 2>&1) || refuse inbox envelope "$HALT_ID"
    HALT_TEXT=$(printf '%s' "$HALT" | jq -r '.text | strings' 2>&1) || refuse inbox envelope "$HALT_TEXT"
    # Only the lead acknowledges a halt: a subagent is refused whatever it runs,
    # and is never offered the command.
    if [ "$CALLER" = lead ]; then
      printf -v ACK_COMMAND '%q inbox --item %q' "$READER" "$ITEM"
      COMMAND=$(printf '%s' "$INPUT" | jq -r '(.tool_input | objects | .command | strings) // ""' 2>&1) ||
        refuse payload invalid-json "$COMMAND"
      [ "$COMMAND" != "$ACK_COMMAND" ] || exit 0
    fi
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
    "$READER" inbox --item "$ITEM" --ack "$LINES" >/dev/null 2>"$WORK_DIR/ack.err" ||
      { cat -- "$WORK_DIR/ack.err" >&2 || :; }
    exit 0
  fi
  # Peek, then acknowledge: the cursor moves only once the refusal is written, so
  # a hook killed at its budget leaves the lines unread for the next stop rather
  # than consumed unseen. An acknowledgement that fails costs a repeat, never a
  # loss, and its cause stands under the refusal.
  message unread "$COUNT"
  "$READER" inbox --item "$ITEM" --ack "$LINES" >/dev/null 2>"$WORK_DIR/ack.err" ||
    { cat -- "$WORK_DIR/ack.err" >&2 || :; }
  exit 2
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
# `workflow-state handoff-standing` answers 0 where a record no relaunch has
# resumed stands and 3 where none does; 3 rather than 1 because an install
# older than that verb answers 1 from its unknown-command arm, and reading
# that as "none stands" would refuse a lane that has already written its
# record, at every turn end, for ever.
#
# So this attributes the answer rather than negating it: only 0 and 3 are the
# verb speaking. Every other status is an install this hook cannot question,
# and the caller reports it as a gap with the reader's own words under it.
#   0  a record stands        1  none stands
#   2  the answer is not this verb's; STATE_CAUSE holds what it wrote
STATE_CAUSE=""
handoff_recorded() {
  STATE_RC=0
  STATE_CAUSE=""
  "$SCRIPTS/workflow-state" handoff-standing "$ITEM" \
    >/dev/null 2>"$WORK_DIR/state.err" || STATE_RC=$?
  case "$STATE_RC" in
    0) return 0 ;;
    3) return 1 ;;
  esac
  STATE_CAUSE=$(cat -- "$WORK_DIR/state.err")
  return 2
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
handoff_instruction() {
  INIT_LINE=""
  if ! state_exists; then
    if [ -n "$BRANCH" ]; then
      printf -v INIT_LINE '  %q init %q --branch %q\n' "$SCRIPTS/workflow-state" "$ITEM" "$BRANCH"
    else
      printf -v INIT_LINE '  %q init %q\n' "$SCRIPTS/workflow-state" "$ITEM"
    fi
  fi
  printf -v HANDOFF_INSTRUCTION \
    'Reach the next safe point first, a pushed head, a landed merge or a held PR; never interrupt a round or leave an unpushed tree. There, write the handoff record and send the notice, then end the session:\n%s  %q set %q handoff %s\n  %q notice --item %q --file [FILE NAMING WHAT IS LEFT]\nThis refusal repeats at every turn end until that record stands.' \
    "$INIT_LINE" \
    "$SCRIPTS/workflow-state" "$ITEM" \
    ''\''{"written_at":"[NOW]","merged":["[PR]"],"remaining":["[STEP]"],"branch":"[BRANCH]","worktree":"[WORKTREE_PATH]","open_pr":[PR_NUMBER_OR_NULL],"traps":["[TRAP]"]}'\''' \
    "$READER" "$ITEM"
}

# The context the transcript records: every assistant message carries the
# tokens its prompt was billed for, and the context is that count plus the
# cache the prompt was read from. The LAST such line is the window as it
# stands, so a compaction that reset it reads as the reset it is. `fromjson?`
# skips the partial line a byte window opens on and the line the harness is
# still appending as this runs.
transcript_tokens() {
  jq -Rr 'fromjson? | .message?.usage? // empty
    | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
       + (.cache_creation_input_tokens // 0))' 2>"$WORK_DIR/transcript.err" |
    tail -n 1
}

# Called plainly, so errexit is live throughout this body: a status left to it
# would exit the hook with neither 0 nor 2 and end the turn with no mark
# judged. Every status is therefore tested where it is taken.
handoff_check() {
  [ "$ARM" = stop ] && [ "$CALLER" = lead ] || return 0
  lane_launched || return 0

  # The marks are judged with the orch scripts beside the mailbox reader, from
  # this hook's own install and never the open repository's, as the reader is.
  # An install that carries none of them carries no `workflow-state` either, so
  # the lane could not record a handoff whatever it was told: the gap is
  # reported and the turn ends.
  resolve_reader || { message handoff-skipped "$FAIL_VALUE"; exit 0; }
  if [ ! -x "$SCRIPTS/workflow-state" ]; then
    message handoff-skipped "$SCRIPTS/workflow-state"
    exit 0
  fi

  # A record already standing is the lane handing itself off: it reached its
  # safe point and is exiting, so nothing below may hold it here. Judged
  # before every mark, before every read they rest on and before the scripts
  # only the marks need, so no failure of this hook's own can trap a lane that
  # has already done what it was asked. An answer this hook cannot attribute
  # to the verb is an install it cannot question, reported and passed for the
  # same reason a missing one is.
  RECORDED=0
  handoff_recorded || RECORDED=$?
  case "$RECORDED" in
    0) exit 0 ;;
    1) ;;
    *)
      message handoff-skipped "$SCRIPTS/workflow-state" "$STATE_CAUSE"
      exit 0
      ;;
  esac

  for script in orch-env lanes; do
    [ -x "$SCRIPTS/$script" ] || refuse script "$SCRIPTS/$script"
  done

  # A bounded tail first: a session transcript grows without limit and parsing
  # the whole of one at every turn end costs more than the rest of this hook
  # together. The full file answers only where that window holds no usage line
  # — a session on its first turns, or one whose recent lines are all tool
  # results. A payload naming no transcript leaves the figure empty and below
  # every mark.
  TOKENS=""
  if [ -n "$TRANSCRIPT" ]; then
    { [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; } || refuse transcript unreadable
    TOKENS=$(tail -c "$TRANSCRIPT_WINDOW" -- "$TRANSCRIPT" | transcript_tokens) ||
      refuse transcript unread "$(cat -- "$WORK_DIR/transcript.err")"
    [ -n "$TOKENS" ] || TOKENS=$(transcript_tokens <"$TRANSCRIPT") ||
      refuse transcript unread "$(cat -- "$WORK_DIR/transcript.err")"
  fi

  MARK=$("$SCRIPTS/orch-env" ORCH_HANDOFF_CONTEXT_TOKENS 500000 2>"$WORK_DIR/env.err") ||
    refuse setting ORCH_HANDOFF_CONTEXT_TOKENS "$(cat -- "$WORK_DIR/env.err")"
  whole_number "$MARK" || refuse setting-range "ORCH_HANDOFF_CONTEXT_TOKENS=$MARK"
  if [ -n "$TOKENS" ] && [ "$TOKENS" -ge "$MARK" ]; then
    refuse context "$TOKENS"
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
  # line at all. So the capability is probed, not the file, and an install
  # that has not got it is the same reported gap a missing one is.
  SOURCED=0
  if [ -r "$SCRIPTS/lib/lane-context.sh" ]; then
    # shellcheck source=../skills/orch/scripts/lib/lane-context.sh
    if . "$SCRIPTS/lib/lane-context.sh"; then SOURCED=1; fi
  fi
  if [ "$SOURCED" -eq 0 ] || ! declare -F lane_context_caller_cfg >/dev/null 2>&1; then
    message handoff-skipped "$SCRIPTS/lib/lane-context.sh"
    return 0
  fi
  # Every arm of lane_context_caller_cfg returns 0 and prints one directory,
  # and this hook reaches it only with claude or codex, so the directory is the
  # whole of its answer and there is no status to take.
  CFG=$(lane_context_caller_cfg "$HARNESS")

  PCT=$("$SCRIPTS/orch-env" ORCH_HANDOFF_HEADROOM_PCT 5 2>"$WORK_DIR/env.err") ||
    refuse setting ORCH_HANDOFF_HEADROOM_PCT "$(cat -- "$WORK_DIR/env.err")"
  percent_in_range "$PCT" || refuse setting-range "ORCH_HANDOFF_HEADROOM_PCT=$PCT"

  # `lanes pick --lane` can wait on the credentials lock, renew an expired
  # token and fetch usage, which together outlast this hook's budget; a hook
  # killed at its budget writes no line at all, so the read is bounded here
  # instead. Stock macOS ships no `timeout`, and without it the read runs
  # unbounded: a hook the harness kills then leaves the account unjudged, the
  # same outcome the reported gap gives without the line.
  BOUND_BY=()
  ! command -v timeout >/dev/null 2>&1 || BOUND_BY=(timeout "$ACCOUNT_CEILING")
  PICK_RC=0
  PICK=$(${BOUND_BY[@]+"${BOUND_BY[@]}"} "$SCRIPTS/lanes" pick --lane "$CFG" --harness "$HARNESS" \
    --min-headroom-pct "$PCT" --json 2>"$WORK_DIR/lanes.err") || PICK_RC=$?
  case "$PICK_RC" in
    0) ;;
    3)
      HEADROOM=$(printf '%s' "$PICK" | jq -r '.headroom_pct // "unknown"' 2>/dev/null) ||
        HEADROOM=unknown
      refuse headroom "$HEADROOM"
      ;;
    4) message account unlisted "$(cat -- "$WORK_DIR/lanes.err")" ;;
    124) message account timeout "the read was abandoned after $ACCOUNT_CEILING seconds" ;;
    *) message account unmeasured "$(cat -- "$WORK_DIR/lanes.err")" ;;
  esac
  return 0
}

if [ "$CONTINUED" = false ]; then
  mail_check
fi
handoff_check
exit 0
