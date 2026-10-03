#!/usr/bin/env bash
# The lane arm the critical-path-deny hook runs at a permission prompt: it
# prints `lane` where the launch marker for the session's item binds the
# session's root and the item's mailbox directory stands, else `none`, and a
# gap past the payload read is reported on stderr and passed with nothing on
# stdout. Each row asserts the exit status, stdout and the keyed first line of
# stderr. HOOK_UNDER_TEST overrides the copy the controls at the end run.
set -euo pipefail

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

echo "=== lane-mail-check: lane arm ==="

ARM_ARGS=(lane)
MAIN_PAYLOAD='{"session_id":"s1","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf \"$(echo scratch)\""},"permission_suggestions":[]}'
SUB_PAYLOAD='{"session_id":"s1","agent_id":"a1","agent_type":"general-purpose","hook_event_name":"PermissionRequest","tool_name":"Bash","tool_input":{"command":"rm -rf \"$(echo scratch)\""},"permission_suggestions":[]}'

# One world per row: NAME BRANCH SHAPE, where SHAPE is what stands beside the
# lane's root.
#   launched   the marker binds this root and the item's mailbox stands
#   unmarked   the item's mailbox stands and no marker does
#   rebound    the item's mailbox stands and the marker binds another root
#   boxless    the marker binds this root and no mailbox directory stands
#   bare       neither marker nor mailbox
#   markerdir  the item's mailbox stands and the marker path is a directory
#   norepo     the call runs from a directory git finds no repository for,
#              as in a session a global-scope install reaches outside one
world() { # NAME BRANCH SHAPE
  local marker
  CALL_DIR=""
  CALL_ENV=()
  new_lane "$1" "$2"
  marker="$LANE/.git/lane-mail/$2"
  case "$3" in
    launched) mkdir -p "$LANE/tmp/lane-mail/$2" ;;
    unmarked) mkdir -p "$LANE/tmp/lane-mail/$2"; rm -f "$marker" ;;
    rebound) mkdir -p "$LANE/tmp/lane-mail/$2"; printf '%s\n' "$TMP_ROOT/another-root" > "$marker" ;;
    boxless) ;;
    bare) unmark_lanes ;;
    markerdir) mkdir -p "$LANE/tmp/lane-mail/$2"; rm -f "$marker"; mkdir "$marker" ;;
    norepo)
      CALL_DIR="$TMP_ROOT/$1-plain"
      mkdir -p "$CALL_DIR"
      CALL_ENV=("GIT_CEILING_DIRECTORIES=$TMP_ROOT")
      ;;
  esac
}

lane_rows() {
  local name shape payload want label
  while IFS='|' read -r name shape payload want label; do
    [ -n "$name" ] || continue
    world "lane_$name" "ken-$name" "$shape"
    case "$payload" in
      main) run_payload "$MAIN_PAYLOAD" ;;
      sub) run_payload "$SUB_PAYLOAD" ;;
    esac
    assert_eq "RC=$RC stdout=$(cat -- "$TMP_ROOT/stdout") first=$(first_line)" \
      "${want//@LANE@/$LANE}" "$label"
  done <<'ROWS'
1|launched|main|RC=0 stdout=lane first=-|a launched lane's own call is named a lane
2|launched|sub|RC=0 stdout=lane first=-|a subagent's call in a launched lane is named a lane
3|unmarked|main|RC=0 stdout=none first=-|a mailbox no launch marker binds is no lane
4|rebound|main|RC=0 stdout=none first=-|a marker bound to another root is no lane
5|boxless|main|RC=0 stdout=none first=-|a marked root with no mailbox directory answers none, never the mailbox refusal
6|bare|main|RC=0 stdout=none first=-|a repository no launch reached is no lane
7|markerdir|main|RC=0 stdout= first=lane-mail-check: marker=@LANE@/.git/lane-mail/ken-7|a marker that is no plain file is reported with no answer, never read as no lane
8|norepo|main|RC=0 stdout=none first=-|a directory outside any repository is no lane
ROWS
}
lane_rows

# The must-fail controls, one per rule the arm holds, each a mutant copy run
# through the same rows. Skipped when this run is itself a control.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  control() { # NAME SED-ARGUMENT FAILED-ROW
    local out
    mutant "$1" -e "$2"
    out="$(HOOK_UNDER_TEST="$MUTANT_PATH" bash "${BASH_SOURCE[0]}" 2>&1 || true)"
    assert_eq "$(grep -Fxc -e "  FAIL  $3" <<<"$out" || true)" 1 "control $1: $3"
  }
  # The launch marker no longer consulted: a mailbox alone names a lane.
  control unlaunched 's/^  if \[ -n "\$ITEM" \] && lane_launched; then$/  if [ -n "$ITEM" ]; then/' \
    "a mailbox no launch marker binds is no lane"
  # The arm no longer reports and passes: an unreadable marker refuses.
  control unreported 's/^  true:\* | \*:halt | \*:row | \*:lane) REPORTED=true ;;$/  true:* | *:halt | *:row) REPORTED=true ;;/' \
    "a marker that is no plain file is reported with no answer, never read as no lane"
  # The arm's answer skipped outside a repository: nothing is printed there.
  control unanswered 's/^  \[ -d "\$LANE_DIR\/tmp\/lane-mail" \] || { \[ "\$ARM" != lane \] || echo none; exit 0; }$/  [ -d "$LANE_DIR\/tmp\/lane-mail" ] || exit 0/' \
    "a directory outside any repository is no lane"
  # The arm no longer skips the mailbox refusal: a boxless marked root refuses.
  control boxless 's/^if \[ "\$ARM" != row \] && \[ "\$ARM" != lane \] && /if [ "$ARM" != row ] \&\& /' \
    "a marked root with no mailbox directory answers none, never the mailbox refusal"
fi

printf '\n=== %s passed, %s failed ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
