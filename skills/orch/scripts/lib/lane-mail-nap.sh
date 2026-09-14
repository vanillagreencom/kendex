# shellcheck shell=bash
#
# Lane mail for the orch waiters. A lane blocks in a waiter for many minutes;
# this lib ends that wait as soon as the overseer's mail is unread, so a
# directive reaches the lane while it can still act on it. It counts only: the
# mailbox layout and its read cursor are lane-mail's, and nothing here reads
# the mail or advances the cursor.
#
# Sourced, never run. A waiter calls lane_mail_resolve once its arguments parse
# and waits through lane_mail_nap wherever it would `sleep`.

_ORCH_LANE_MAIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_MAIL_WAITER=""
LANE_MAIL_BOX=""

# lane_mail_resolve WAITER ITEM: ITEM is the --item value, or empty to take the
# issue id from the current branch. With no item, or no git root to hold a
# mailbox, LANE_MAIL_BOX stays empty and every nap is a plain sleep.
lane_mail_resolve() {
  local item="$2" root
  LANE_MAIL_WAITER="$1"
  if [ -z "$item" ]; then
    item="$("$_ORCH_LANE_MAIL_DIR/../git-context" issue-from-branch . 2>/dev/null)" || item=""
  fi
  [ -n "$item" ] || return 0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  # lane-mail's BOX for a lane rooted at its own worktree.
  LANE_MAIL_BOX="$root/tmp/lane-mail/$item"
}

# Prints the complete lines of to-lane.jsonl past to-lane.cursor, the count
# `lane-mail inbox` would hand over. An unreadable file or a cursor that is not
# a count prints 0: the wait goes on, and `lane-mail inbox` names the fault at
# the lane's next wait point instead of this waiter returning on every slice.
lane_mail_unread() {
  local lines seen=0
  [ -f "$LANE_MAIL_BOX/to-lane.jsonl" ] || { printf '0\n'; return 0; }
  lines="$(tr -dc '\n' <"$LANE_MAIL_BOX/to-lane.jsonl" | wc -c)" || { printf '0\n'; return 0; }
  if [ -f "$LANE_MAIL_BOX/to-lane.cursor" ]; then
    seen="$(cat -- "$LANE_MAIL_BOX/to-lane.cursor")" || seen=invalid
  fi
  case "$seen" in
    '') seen=0 ;;
    *[!0-9]*) printf '0\n'; return 0 ;;
  esac
  printf '%s\n' "$((lines - seen))"
}

# lane_mail_nap SECONDS: sleep SECONDS in slices, checking the mailbox around
# each. Unread mail prints `<waiter>: mail=<count>` as the only stdout line and
# exits 5 with no result object, because the waited-for state is still unknown.
lane_mail_nap() {
  local left="$1" slice unread
  if [ -z "$LANE_MAIL_BOX" ]; then
    sleep "$left"
    return 0
  fi
  while :; do
    unread="$(lane_mail_unread)"
    if [ "$unread" -gt 0 ]; then
      printf '%s: mail=%s\n' "$LANE_MAIL_WAITER" "$unread"
      exit 5
    fi
    [ "$left" -gt 0 ] || return 0
    # The slice bounds how late a directive is seen.
    slice=5
    [ "$left" -ge "$slice" ] || slice="$left"
    sleep "$slice"
    left=$((left - slice))
  done
}
