# shellcheck shell=bash
#
# Ends an orch waiter's sleep when the lane's mailbox gains a line. The mailbox
# and reading it are lane-mail's; this lib only watches the file grow.

LANE_MAIL_WAITER=""
LANE_MAIL_FILE=""
LANE_MAIL_SEEN=0

# lane_mail_resolve WAITER ITEM: an empty ITEM leaves every nap a plain sleep.
# Lines already in the mailbox, such as the answer to an earlier ask, never
# wake the wait.
lane_mail_resolve() {
  local root
  LANE_MAIL_WAITER="$1"
  [ -n "$2" ] || return 0
  root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
  LANE_MAIL_FILE="$root/tmp/lane-mail/$2/to-lane.jsonl"
  LANE_MAIL_SEEN="$(lane_mail_lines)" || lane_mail_unreadable
}

# Complete lines in the mailbox. A path that is not a regular file is 0, as
# lane-mail reads it; a mailbox that exists but cannot be read fails.
lane_mail_lines() {
  local n
  [ -f "$LANE_MAIL_FILE" ] || { printf '0\n'; return 0; }
  n="$(tr -dc '\n' 2>/dev/null <"$LANE_MAIL_FILE" | wc -c)" || return 1
  printf '%s\n' "$((n))"
}

lane_mail_unreadable() {
  printf '%s: mail-unreadable=%s\n' "$LANE_MAIL_WAITER" "$LANE_MAIL_FILE"
  exit 5
}

# lane_mail_nap SECONDS: sleep in slices. A line added since resolve prints
# `<waiter>: mail=<count>`, an unreadable mailbox `<waiter>: mail-unreadable=
# <path>`; either is the only stdout and exits 5 with no result.
lane_mail_nap() {
  local left="$1" slice lines
  if [ -z "$LANE_MAIL_FILE" ]; then
    sleep "$left"
    return 0
  fi
  while :; do
    lines="$(lane_mail_lines)" || lane_mail_unreadable
    if [ "$((lines - LANE_MAIL_SEEN))" -gt 0 ]; then
      printf '%s: mail=%s\n' "$LANE_MAIL_WAITER" "$((lines - LANE_MAIL_SEEN))"
      exit 5
    fi
    [ "$left" -gt 0 ] || return 0
    slice=5
    [ "$left" -ge "$slice" ] || slice="$left"
    sleep "$slice"
    left=$((left - slice))
  done
}
