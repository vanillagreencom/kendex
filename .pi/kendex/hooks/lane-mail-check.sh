#!/usr/bin/env bash
# ---
# name: lane-mail-check
# event: Stop
# matcher:
# description: Blocks a lane's turn end while its overseer mailbox holds unread lines, so a directive or a ruling reaches the lane without a keystroke, a pane or a question tool. The lane is the work item `LANE_MAIL_ITEM` names, or the one directory under `<repo>/tmp/lane-mail/` whose name lowercases to the current branch; a session with neither is not a lane and passes silently, as does a lane whose mailbox holds no unread line and a directory git reports no repository for and that holds no mailbox of its own. A mailbox belongs to a lane only where a launch recorded one: `open-terminal` and `lane-host create` write the lane's root to `lane-mail/<item in lower case>` under the repository's common git directory, and a mailbox with no marker bound to this root passes silently. Unread lines are peeked through the orch skill's own `lane-mail inbox --peek`, the one reader of the mailbox and its cursor, and acknowledged with `inbox --ack` only once the refusal is written, so a hook killed at its budget leaves them unread and a line acknowledged here is never handed over twice. That reader is resolved from this hook's own install, walking up to the home directory for `skills/orch/scripts/lane-mail` or the shared `.agents/skills/orch/scripts/lane-mail` beside it, then the home's own shared tree for a harness root relocated out of it; the open repository's `.agents/skills/orch/scripts/lane-mail` is used only where this hook is installed in that repository, and a reader outside that containment is refused rather than run. The refusal opens with `lane-mail-check: unread=<count>` and carries one JSON envelope per line under it; the turn then continues with them. Run with the argument `deliver` by the lane-mail-deliver hook after a tool call, it exits 0 with the harness's JSON on stdout, whose `additionalContext` carries the same lines. Run with `halt` by the lane-mail-halt hook before one, it acknowledges nothing and refuses the call while an unread directive sent with `lane-mail send --halt` stands, opening `lane-mail-check: halt=<id>` with the directive and the one `lane-mail inbox` command that reads it; that command alone passes. A call a subagent makes, whose payload carries a non-empty `agent_id` or `agent_type`, is handed no mail and acknowledges none, and while a halt stands it is refused without that command. `stop_hook_active` true passes the mailbox check on the turn-end run alone. The same turn-end run hands the lane off before it runs out, so the handoff never waits on an overseer reading a pane. It reads this session's context use from the `transcript_path` the payload names, the last assistant usage the harness itself recorded, and refuses the turn end at or past `ORCH_HANDOFF_CONTEXT_TOKENS` (default 500000). It reads the account the credential this session runs on still has through the orch skill's own `lanes pick --lane`, and refuses at or below `ORCH_HANDOFF_HEADROOM_PCT` (default 5). Either refusal opens `lane-mail-check: context=<tokens>` or `lane-mail-check: headroom=<percent>` and carries one instruction: reach the next safe point, write the record with `workflow-state set <item> handoff`, send a `handoff` notice, and exit. It repeats at every turn end, `stop_hook_active` included, until the item's workflow state carries a `.handoff` object no relaunch has resumed; only the lane can write that record, so a single refusal it declines to act on would end the session with nothing recorded. Two measured gaps: a payload naming no transcript leaves the context unread, which is every harness but claude, since codex, pi, opencode and cursor name no transcript on their Stop payload; and an account `lanes` keeps no inventory for, every harness but claude and codex, leaves the account unnamed. An account `lanes` does have an inventory for and could not read is refused, never read as room. A subagent's turn end is judged on neither mark. Not run on gemini: it has no Stop event. Not run on copilot: its agentStop also fires at each subagent's end. Not run on antigravity: its Stop payload carries no `stop_hook_active`.
# summary: Hands a lane the messages its overseer sent before the turn can end, so a directive is acted on instead of waiting for the next launch. It also holds the turn end once the lane is near the end of its context window or its account's limit, until the lane records where it got to and exits, so the work resumes in a fresh session instead of stopping mid-round.
# safety: Reads the payload, the repository's branch, the lane's launch marker and the lane mailbox directory; the only write is the mailbox cursor the orch reader advances. Exit 2 names the unread count and the messages, and asks for them to be acted on, never bypassed. The reader it runs comes from its own install, never from the repository a session has open, so a repository that tracks a mailbox and an executable at that path cannot have it run. jq and cat read the payload; a payload it cannot read is refused, never passed, and so is a mailbox whose reader is missing or fails, an item name outside the alphabet a work item is spelled in, a branch that matches more than one mailbox, and a repository state git cannot report where a mailbox sits under the working directory. For the handoff marks it also reads the transcript the payload names and runs `orch-env`, `lanes` and `workflow-state` from the same install as the mailbox reader, never the open repository's; it writes nothing for them. `lanes pick --lane` measures one account and renews that account's expired token, the write its own contract states. Every refusal opens with `lane-mail-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
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
# The handoff marks: the two settings judged, the commands that end the
# refusal, and what a failed state read wrote. Empty until each is known.
MARK=""
PCT=""
HANDOFF_INSTRUCTION=""
HANDOFF_CAUSE=""
# Who made the call the payload describes: lead, or subagent.
CALLER=""
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
        echo "the lane mailbox holds messages and $2 is not an executable reader, so they cannot be handed over; install the orch skill beside this hook"
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
      script=*)
        echo "the handoff marks are judged with $2 from this hook's own install, and it is not an executable there; install the orch skill beside this hook"
        ;;
      setting=*)
        echo "the effective value of $2 could not be read, so the handoff mark it sets is unknown:"
        ;;
      transcript=unreadable)
        echo "the payload's transcript_path $TRANSCRIPT is not a readable file, so this lane's context use is unknown; refusing rather than letting it run past its handoff mark"
        ;;
      transcript=unread)
        echo "the transcript $TRANSCRIPT could not be read, so this lane's context use is unknown:"
        ;;
      account=unmeasured)
        echo "the account this lane runs its credential out of could not be measured, so whether it is about to wall is unknown; an account nothing measured is never room:"
        ;;
      context=*)
        printf 'this lane has used %s tokens of its context window, at or past the ORCH_HANDOFF_CONTEXT_TOKENS mark of %s, and no handoff record stands. Hand this lane off yourself: the overseer polling a pane is a backstop and reads nothing at all on a hosted fleet.\n%s\n' \
          "$2" "$MARK" "$HANDOFF_INSTRUCTION"
        [ -z "$HANDOFF_CAUSE" ] || printf '%s\n' "$HANDOFF_CAUSE"
        ;;
      headroom=*)
        printf 'the account this lane runs its credential out of has %s percent headroom left, at or below the ORCH_HANDOFF_HEADROOM_PCT mark of %s, and no handoff record stands. Hand this lane off yourself: the account walls mid-round otherwise.\n%s\n' \
          "$2" "$PCT" "$HANDOFF_INSTRUCTION"
        [ -z "$HANDOFF_CAUSE" ] || printf '%s\n' "$HANDOFF_CAUSE"
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

# Lane mail belongs to the lane lead: a subagent's finished call is handed none
# and acknowledges none, so the lead's own run still finds it unread.
if [ "$ARM" = deliver ] && [ "$CALLER" = subagent ]; then
  exit 0
fi

MISSING=""
for dependency in git tr awk mktemp; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

WORK_DIR=$(mktemp -d 2>&1) || refuse workdir "${TMPDIR:-/tmp}" "$WORK_DIR"
trap 'rm -rf -- "$WORK_DIR"' EXIT

# Git reports one status for a directory that is no repository and for
# metadata it cannot read, and a lane always runs in one. So the cwd answers:
# with no mailbox under it this session is not a lane and passes; with one the
# lane cannot be named, which is refused rather than passed.
ROOT_RC=0
ROOT=$(git rev-parse --show-toplevel 2>&1) || ROOT_RC=$?
if [ "$ROOT_RC" -ne 0 ]; then
  [ -d "tmp/lane-mail" ] || exit 0
  refuse git 'rev-parse --show-toplevel' "$ROOT"
fi
MAIL_ROOT="$ROOT/tmp/lane-mail"

# A repository with no mailbox directory is not a fleet lane. Judged before
# the item, so an ordinary session costs one stat.
[ -d "$MAIL_ROOT" ] || exit 0

item_alphabet() { # NAME
  case "$1" in
    '' | . | ..) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The item is what the lane's launch brief set, or the mailbox whose name is
# the branch: `worktree create` names a lane's branch after its item in lower
# case, so the branch selects it without a second copy of any id grammar.
ITEM=""
if [ -n "${LANE_MAIL_ITEM:-}" ]; then
  item_alphabet "$LANE_MAIL_ITEM" || refuse item invalid
  ITEM="$LANE_MAIL_ITEM"
else
  # `symbolic-ref -q` exits 1 for a HEAD that names no branch — detached, and
  # never a lane — and 128 for a repository it cannot read, so the two are told
  # apart without reading git's prose. The answer lands in a variable rather
  # than a substitution's stdout, so the refusal's exit is the hook's.
  BRANCH_RC=0
  BRANCH=$(git symbolic-ref -q --short HEAD 2>&1) || BRANCH_RC=$?
  case "$BRANCH_RC" in
    0) ;;
    1) exit 0 ;;
    *) refuse git 'symbolic-ref -q --short HEAD' "$BRANCH" ;;
  esac
  BRANCH=$(printf '%s' "$BRANCH" | tr 'A-Z' 'a-z')
  MATCHES=0
  for candidate in "$MAIL_ROOT"/*; do
    [ -d "$candidate" ] || continue
    name=${candidate##*/}
    item_alphabet "$name" || continue
    [ "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" = "$BRANCH" ] || continue
    ITEM="$name"
    MATCHES=$((MATCHES + 1))
  done
  [ "$MATCHES" -le 1 ] || refuse item ambiguous
fi
[ -n "$ITEM" ] || exit 0

# A launch makes a lane: open-terminal and lane-host create write the lane's
# root to lane-mail/<item in lower case> under the common git directory, which
# no checkout carries, so a mailbox a repository commits never poses as one.
COMMON_RC=0
COMMON=$(git rev-parse --path-format=absolute --git-common-dir 2>&1) || COMMON_RC=$?
[ "$COMMON_RC" -eq 0 ] || refuse git 'rev-parse --git-common-dir' "$COMMON"
LOWER=$(printf '%s' "$ITEM" | tr 'A-Z' 'a-z')
MARKER="$COMMON/lane-mail/$LOWER"
BOUND=""
if [ -e "$MARKER" ] || [ -L "$MARKER" ]; then
  # Present but not a plain file: a marker this cannot judge, refused rather
  # than read as no lane.
  { [ -f "$MARKER" ] && [ ! -L "$MARKER" ]; } || refuse marker "$MARKER"
  BOUND_RC=0
  BOUND=$(cat -- "$MARKER" 2>&1) || BOUND_RC=$?
  [ "$BOUND_RC" -eq 0 ] || refuse marker "$MARKER" "$BOUND"
fi
[ "$BOUND" = "$ROOT" ] || exit 0

# The reader comes from this hook's own install, never from whichever
# repository the session has open: a repository can track a mailbox and an
# executable at .agents/skills/orch/scripts/lane-mail, and running that hands
# it a command at every turn end with no prompt. The walk is the one
# hooks/command-safety.sh makes for the commit-guards library, and the
# repository's own copy is read only where this hook is installed in it.
# Two skill roots per level: a harness's own skills directory and the shared
# `.agents/skills` tree several read. The walk stops at the home directory, the
# far edge of a global install: Pi's hook sits four directories under it.
READER=""
HOOK_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P) || refuse reader unlocatable
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
    *) refuse reader-outside "$ROOT/.agents/skills/orch/scripts/lane-mail" ;;
  esac
fi
[ -x "$READER" ] || refuse reader "$READER"
SCRIPTS=${READER%/*}

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
# A handoff refusal is made on `stop_hook_active` turns too, unlike the mailbox
# check. The two escapes differ: this hook's own acknowledgement clears unread
# mail, so repeating that refusal is the loop the flag exists to end, while only
# the LANE can write the handoff record, and a single refusal it declines to act
# on ends the session with nothing recorded.

# The record the watch reads, and the same live test it makes: a `.handoff` a
# relaunch resumed belongs to an earlier life of the item and is not one. A
# state file that is not there and a read that failed are both no record
# standing — the conservative direction either way — and what the reader wrote
# stands under the refusal that follows.
handoff_recorded() {
  STATE_RC=0
  RECORD=$("$SCRIPTS/workflow-state" get "$ITEM" \
    '.handoff | select(type == "object" and .resumed_at == null) | tojson' \
    2>"$WORK_DIR/state.err") || STATE_RC=$?
  HANDOFF_CAUSE=""
  [ "$STATE_RC" -eq 0 ] || HANDOFF_CAUSE=$(cat -- "$WORK_DIR/state.err")
  [ -n "$RECORD" ]
}

handoff_pass() {
  if [ "$ARM" = stop ] && [ "$CALLER" = lead ]; then
    # The marks are judged with the orch scripts beside the mailbox reader, from
    # this hook's own install and never the open repository's, as the reader is.
    for script in orch-env lanes workflow-state; do
      [ -x "$SCRIPTS/$script" ] || refuse script "$SCRIPTS/$script"
    done

    # A record already standing is the lane handing itself off: it reached its
    # safe point and is exiting, so nothing below may hold it here. Judged
    # before every mark and every read they rest on, so no failure of this
    # hook's own can trap a lane that has already done what it was asked.
    if handoff_recorded; then exit 0; fi

    # The context figure the HARNESS itself wrote, never a pane: every assistant
    # message in the transcript carries the tokens its prompt was billed for, and
    # the context is that count plus the cache the prompt was read from. The LAST
    # such line is the window as it stands, so a compaction that reset it reads
    # as the reset it is. `fromjson?` skips a final line the harness is still
    # appending as this runs, and a transcript with no usage line yet — a session
    # on its first turn — leaves the figure empty and below every mark.
    TOKENS=""
    if [ -n "$TRANSCRIPT" ]; then
      { [ -f "$TRANSCRIPT" ] && [ -r "$TRANSCRIPT" ]; } || refuse transcript unreadable
      TOKENS=$(jq -Rr 'fromjson? | .message?.usage? // empty
        | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
           + (.cache_creation_input_tokens // 0))' <"$TRANSCRIPT" 2>"$WORK_DIR/transcript.err" |
        tail -n 1) || refuse transcript unread "$(cat -- "$WORK_DIR/transcript.err")"
    fi

    printf -v HANDOFF_INSTRUCTION \
      'Reach the next safe point first, a pushed head, a landed merge or a held PR; never interrupt a round or leave an unpushed tree. There, write the handoff record and send the notice, then end the session:\n  %q set %q handoff %s\n  %q notice --item %q --file [FILE NAMING WHAT IS LEFT]\nThis refusal repeats at every turn end until that record stands.' \
      "$SCRIPTS/workflow-state" "$ITEM" \
      ''\''{"written_at":"[NOW]","merged":["[PR]"],"remaining":["[STEP]"],"branch":"[BRANCH]","worktree":"[WORKTREE_PATH]","open_pr":[PR_NUMBER_OR_NULL],"traps":["[TRAP]"]}'\''' \
      "$READER" "$ITEM"

    MARK=$("$SCRIPTS/orch-env" ORCH_HANDOFF_CONTEXT_TOKENS 500000 2>"$WORK_DIR/env.err") ||
      refuse setting ORCH_HANDOFF_CONTEXT_TOKENS "$(cat -- "$WORK_DIR/env.err")"
    if [ -n "$TOKENS" ] && [ "$TOKENS" -ge "$MARK" ]; then
      refuse context "$TOKENS"
    fi

    # The account the credential THIS session runs on still has, judged by the
    # one script that measures a lane and against the one setting that marks a
    # lane for handoff. `pick --lane` answers about that directory alone: 0 has
    # room, 3 is at or below the mark, and 4 is a directory that is no configured
    # lane of this harness, which is nothing to judge rather than a wall. Every
    # other exit is an account nothing measured, which is never room.
    #
    # Which harness this session is comes from this hook's own install, the one
    # place that records it: `crates/core/src/render` writes the claude copy under
    # `.claude/hooks` and the codex copy under `.codex/hooks`. A harness `lanes`
    # keeps no inventory for leaves the account unnamed, and its lanes are judged
    # on the context mark alone.
    case "$HOOK_DIR" in
      */.claude/hooks) HARNESS=claude ;;
      */.codex/hooks) HARNESS=codex ;;
      *) HARNESS="" ;;
    esac
    CFG=""
    if [ -n "$HARNESS" ]; then
      [ -r "$SCRIPTS/lib/lane-context.sh" ] || refuse script "$SCRIPTS/lib/lane-context.sh"
      # Every status in this function is tested where it is taken, never left
      # to errexit: the two `|| handoff_pass` call sites below put the whole
      # body in a `||` list, where bash suspends errexit.
      # shellcheck source=../skills/orch/scripts/lib/lane-context.sh
      . "$SCRIPTS/lib/lane-context.sh" || refuse script "$SCRIPTS/lib/lane-context.sh"
      CFG=$(lane_context_caller_cfg "$HARNESS" 2>"$WORK_DIR/cfg.err") ||
        refuse account unmeasured "$(cat -- "$WORK_DIR/cfg.err")"
    fi
    if [ -n "$CFG" ]; then
      PCT=$("$SCRIPTS/orch-env" ORCH_HANDOFF_HEADROOM_PCT 5 2>"$WORK_DIR/env.err") ||
        refuse setting ORCH_HANDOFF_HEADROOM_PCT "$(cat -- "$WORK_DIR/env.err")"
      PICK_RC=0
      PICK=$("$SCRIPTS/lanes" pick --lane "$CFG" --harness "$HARNESS" \
        --min-headroom-pct "$PCT" --json 2>"$WORK_DIR/lanes.err") || PICK_RC=$?
      case "$PICK_RC" in
        0 | 4) ;;
        3)
          HEADROOM=$(printf '%s' "$PICK" | jq -r '.headroom_pct // "unknown"' 2>/dev/null) ||
            HEADROOM=unknown
          refuse headroom "$HEADROOM"
          ;;
        *) refuse account unmeasured "$(cat -- "$WORK_DIR/lanes.err")" ;;
      esac
    fi
  fi
  exit 0
}

# The harness sets stop_hook_active on the turn it continued because a stop
# hook blocked. Handing the mailbox over again there is the loop the flag exists
# to end, so that turn goes straight to the handoff marks, whose own escape is
# the record and not this hook.
if [ "$ARM" = stop ] && [ "$ACTIVE" = "true" ]; then
  handoff_pass
fi



# A lane never written to has no file to read, and reading one that is there
# is the orch reader's job: it owns the cursor, so neither this hook nor a
# workflow wait point hands the same line over twice.
# Anything present at that path, a directory or a dangling link included, goes
# on to the reader, whose component rule refuses what it cannot read.
[ -e "$MAIL_ROOT/$ITEM/to-lane.jsonl" ] || [ -L "$MAIL_ROOT/$ITEM/to-lane.jsonl" ] || handoff_pass

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
[ -n "$UNREAD" ] || handoff_pass

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
