# shellcheck shell=bash
#
# Ends an orch waiter's sleep when the lane's mailbox gains a line. The mailbox
# and reading it are lane-mail's; this lib only watches the file grow.

_ORCH_LANE_MAIL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANE_MAIL_WAITER=""
LANE_MAIL_FILE=""
LANE_MAIL_SEEN=0

# lane_mail_resolve WAITER ITEM: an empty ITEM reads the issue id from the
# branch, and no item leaves every nap a plain sleep. Lines already in the
# mailbox, such as the answer to an earlier ask, never wake the wait.
lane_mail_resolve() {
  local item="$2" root
  LANE_MAIL_WAITER="$1"
  if [ -z "$item" ]; then
    item="$("$_ORCH_LANE_MAIL_DIR/../git-context" issue-from-branch . 2>/dev/null)" || item=""
  fi
  [ -n "$item" ] || return 0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  LANE_MAIL_FILE="$root/tmp/lane-mail/$item/to-lane.jsonl"
  LANE_MAIL_SEEN="$(lane_mail_lines)"
}

# Complete lines in the mailbox; 0 while the lane has not opened it.
lane_mail_lines() {
  local n
  n="$(tr -dc '\n' 2>/dev/null <"$LANE_MAIL_FILE" | wc -c)" || n=0
  printf '%s\n' "$((n))"
}

# lane_mail_nap SECONDS: sleep in slices; a line added since resolve prints
# `<waiter>: mail=<count>` as the only stdout and exits 5 with no result.
lane_mail_nap() {
  local left="$1" slice added
  if [ -z "$LANE_MAIL_FILE" ]; then
    sleep "$left"
    return 0
  fi
  while :; do
    added=$(($(lane_mail_lines) - LANE_MAIL_SEEN))
    if [ "$added" -gt 0 ]; then
      printf '%s: mail=%s\n' "$LANE_MAIL_WAITER" "$added"
      exit 5
    fi
    [ "$left" -gt 0 ] || return 0
    slice=5
    [ "$left" -ge "$slice" ] || slice="$left"
    sleep "$slice"
    left=$((left - slice))
  done
}
