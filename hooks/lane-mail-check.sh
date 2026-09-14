#!/usr/bin/env bash
# ---
# name: lane-mail-check
# event: Stop
# matcher:
# description: Blocks a lane's turn end while its overseer mailbox holds unread lines, so a directive or a ruling reaches the lane without a keystroke, a pane or a question tool. The lane is the work item `LANE_MAIL_ITEM` names, or the one directory under `<repo>/tmp/lane-mail/` whose name lowercases to the current branch; a session with neither is not a lane and passes silently, as does a lane whose mailbox holds no unread line and a directory git reports no repository for and that holds no mailbox of its own. A mailbox belongs to a lane only where a launch recorded one: `open-terminal` and `lane-host create` write the lane's root to `lane-mail/<item in lower case>` under the repository's common git directory, and a mailbox with no marker bound to this root passes silently. Unread lines are peeked through the orch skill's own `lane-mail inbox --peek`, the one reader of the mailbox and its cursor, and acknowledged with `inbox --ack` only once the refusal is written, so a hook killed at its budget leaves them unread and a line acknowledged here is never handed over twice. That reader is resolved from this hook's own install, walking up to the home directory for `skills/orch/scripts/lane-mail` or the shared `.agents/skills/orch/scripts/lane-mail` beside it, then the home's own shared tree for a harness root relocated out of it; the open repository's `.agents/skills/orch/scripts/lane-mail` is used only where this hook is installed in that repository, and a reader outside that containment is refused rather than run. The refusal opens with `lane-mail-check: unread=<count>` and carries one JSON envelope per line under it; the turn then continues with them. `stop_hook_active` true passes.
# summary: Hands a lane the messages its overseer sent before the turn can end, so a directive is acted on instead of waiting for the next launch.
# safety: Reads the payload, the repository's branch, the lane's launch marker and the lane mailbox directory; the only write is the mailbox cursor the orch reader advances. Exit 2 names the unread count and the messages, and asks for them to be acted on, never bypassed. The reader it runs comes from its own install, never from the repository a session has open, so a repository that tracks a mailbox and an executable at that path cannot have it run. jq and cat read the payload; a payload it cannot read is refused, never passed, and so is a mailbox whose reader is missing or fails, an item name outside the alphabet a work item is spelled in, a branch that matches more than one mailbox, and a repository state git cannot report where a mailbox sits under the working directory. Every refusal opens with `lane-mail-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 30
# harnesses: [claude-code, codex, pi]
# ---

set -euo pipefail

# Names are matched by byte ranges below, so the locale decides the match.
export LC_ALL=C

# What the refusal names, empty until it is known: the lane's unread lines.
UNREAD=""
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
      inbox=header)
        echo "the lane mailbox reader's --peek output did not open with its count line, so whether messages are waiting is unknown"
        ;;
      inbox=*)
        echo "the lane mailbox reader exited $2, so whether messages are waiting is unknown:"
        ;;
      unread=*)
        printf 'the overseer sent these messages to this lane; act on each, then finish:\n%s\n' "$UNREAD"
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

ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active == true | tostring' 2>&1) ||
  refuse payload invalid-json "$ACTIVE"

# The harness sets stop_hook_active on the turn it continued because a stop
# hook blocked. Refusing that turn as well is the loop the flag exists to end.
if [ "$ACTIVE" = "true" ]; then
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

# A lane never written to has no file to read, and reading one that is there
# is the orch reader's job: it owns the cursor, so neither this hook nor a
# workflow wait point hands the same line over twice.
# Anything present at that path, a directory or a dangling link included, goes
# on to the reader, whose component rule refuses what it cannot read.
[ -e "$MAIL_ROOT/$ITEM/to-lane.jsonl" ] || [ -L "$MAIL_ROOT/$ITEM/to-lane.jsonl" ] || exit 0

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
[ -n "$UNREAD" ] || exit 0

COUNT=$(printf '%s\n' "$UNREAD" | awk 'END { print NR + 0 }')
# Peek, then acknowledge: the cursor moves only once the refusal is written, so
# a hook killed at its budget leaves the lines unread for the next stop rather
# than consumed unseen. An acknowledgement that fails costs a repeat, never a
# loss, and its cause stands under the refusal.
message unread "$COUNT"
"$READER" inbox --item "$ITEM" --ack "$LINES" >/dev/null 2>"$WORK_DIR/ack.err" ||
  { cat -- "$WORK_DIR/ack.err" >&2 || :; }
exit 2
