#!/usr/bin/env bash
# ---
# name: lane-mail-check
# event: Stop
# matcher:
# description: Blocks a lane's turn end while its overseer mailbox holds unread lines, so a directive or a ruling reaches the lane without a keystroke, a pane or a question tool. The lane is the work item `LANE_MAIL_ITEM` names, or the one directory under `<repo>/tmp/lane-mail/` whose name lowercases to the current branch; a session with neither is not a lane and passes silently, as does a lane whose mailbox holds no unread line and a directory git reports no repository for and that holds no mailbox of its own. Unread lines are read through the orch skill's own `.agents/skills/orch/scripts/lane-mail inbox`, the one reader of the mailbox and its cursor, so a line handed over here is never handed over twice. The refusal opens with `lane-mail-check: unread=<count>` and carries one JSON envelope per line under it; the turn then continues with them. `stop_hook_active` true passes.
# summary: Hands a lane the messages its overseer sent before the turn can end, so a directive is acted on instead of waiting for the next launch.
# safety: Reads the payload, the repository's branch and the lane mailbox directory; the only write is the mailbox cursor the orch reader advances. Exit 2 names the unread count and the messages, and asks for them to be acted on, never bypassed. jq and cat read the payload; a payload it cannot read is refused, never passed, and so is a mailbox whose reader is missing or fails, an item name outside the alphabet a work item is spelled in, a branch that matches more than one mailbox, and a repository state git cannot report where a mailbox sits under the working directory. Every refusal opens with `lane-mail-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 30
# harnesses: [claude-code, codex, pi]
# ---

set -euo pipefail

# Item names and branch names are matched by byte ranges below; a locale that
# reads them as something else changes which mailbox a branch selects.
export LC_ALL=C

# What the refusal names, empty until it is known: the lane's unread lines.
UNREAD=""

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `lane-mail-check: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing commands,
# why the payload could not be read, the item that is not one, the git
# subcommand that failed, the reader that is not there, the reader's own exit
# status, or how many messages are waiting. The English explanation follows it,
# and never a bypass.
refuse() { # KEY VALUE [CAUSE]
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
      workdir=*)
        echo "a scratch directory for the reader's own words could not be made under $2"
        ;;
      reader=*)
        echo "the lane mailbox holds messages and $2 is not an executable reader, so they cannot be handed over; install the orch skill in this repository"
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
  exit 2
}

# The two commands that read the payload come first and alone. The flag that
# ends a stop hook's retry is in that payload, so a refusal for any other
# absence has to wait until the flag has been read; refusing ahead of it would
# refuse the retry as well, which is the loop the flag exists to end.
MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent.
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
# metadata it cannot read, and a lane always runs in a repository. So the cwd
# answers instead: with no mailbox under it this session is not a lane and
# passes, and with one the lane cannot be named, which is refused rather than
# passed.
ROOT_RC=0
ROOT=$(git rev-parse --show-toplevel 2>&1) || ROOT_RC=$?
if [ "$ROOT_RC" -ne 0 ]; then
  [ -d "tmp/lane-mail" ] || exit 0
  refuse git 'rev-parse --show-toplevel' "$ROOT"
fi
MAIL_ROOT="$ROOT/tmp/lane-mail"

# A repository with no mailbox directory at all is not a fleet lane, whatever
# else the session is doing. Judged before the item, so an ordinary session in
# an ordinary checkout costs one stat.
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
# case, so the branch selects the item without this hook holding a second
# spelling of any tracker's id grammar. A branch matching none is not a lane.
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

# A lane that has never been written to has no file to read, and reading one
# that is there is the orch reader's job: it owns the cursor, so a line handed
# over here is the same line `lane-mail inbox` would hand a workflow wait
# point, and neither hands it over twice.
[ -f "$MAIL_ROOT/$ITEM/to-lane.jsonl" ] || exit 0

READER="$ROOT/.agents/skills/orch/scripts/lane-mail"
[ -x "$READER" ] || refuse reader "$READER"

RC=0
UNREAD=$("$READER" inbox --item "$ITEM" 2>"$WORK_DIR/reader.err") || RC=$?
[ "$RC" -eq 0 ] || refuse inbox "$RC" "$(cat -- "$WORK_DIR/reader.err")"
[ -n "$UNREAD" ] || exit 0

COUNT=$(printf '%s\n' "$UNREAD" | awk 'END { print NR + 0 }')
refuse unread "$COUNT"
