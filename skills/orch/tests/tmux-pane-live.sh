#!/usr/bin/env bash
# tmux_pane_live, lib/tmux-server.sh: whether a `<server pid> <pane id>` key,
# bound to its server by that server's start time, names a pane that still
# runs. A tmux stub on PATH answers `list-panes -a` from a file a row writes,
# `<pid> <start> <pane>` rows, or fails where the row writes none, and
# `display-message` the same way from its own file, for tmux_server_start: the
# start a record binds its server by. A running
# server is a copy of sleep named tmux, a pid reused by another program is
# this suite's own shell, and a gone server a child that has exited.
# The must-fail controls close the file, one per rule, each on a library copy.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# mktemp alone, so set -e stops the suite on its failure: nested in the cd,
# a failed mktemp would resolve to this directory and the trap would remove it.
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)"
LIVE=""
trap '[ -z "$LIVE" ] || kill "$LIVE" 2>/dev/null; rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo "=== tmux_pane_live ==="

STUB_BIN="$TMP_ROOT/bin"
PANES="$TMP_ROOT/panes"
DISPLAY_OUT="$TMP_ROOT/display"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<STUB
#!/bin/sh
case "\$1" in
  list-panes) out="$PANES" ;;
  display-message) out="$DISPLAY_OUT" ;;
  *) exit 1 ;;
esac
[ -f "\$out" ] || { echo "no server running" >&2; exit 1; }
cat "\$out"
STUB
chmod +x "$STUB_BIN/tmux"

# The server outlives every row; the trap stops it.
mkdir -p "$TMP_ROOT/server"
cp -- "$(command -v sleep)" "$TMP_ROOT/server/tmux"
"$TMP_ROOT/server/tmux" 600 &
LIVE=$!
REUSED=$$
sleep 0 &
GONE=$!
wait "$GONE" || :

LIB="$TEST_DIR/../scripts/lib/tmux-server.sh"
# The answer for SERVER, started at START, and PANE with the pane list
# LISTING, `-` for a list tmux cannot give. S is the live server's start and
# E an earlier server's that was handed the same pid.
S=1790000000
E=1780000000
live_rc() { # LIB SERVER START PANE LISTING
  if [ "$5" = - ]; then rm -f -- "$PANES"; else printf '%s' "$5" > "$PANES"; fi
  PATH="$STUB_BIN:$PATH" bash -c '. "$1"; rc=0; tmux_pane_live "$2" "$3" "$4" || rc=$?; echo "$rc"' \
    _ "$1" "$2" "$3" "$4"
}

OWN="$LIVE $S %1
$LIVE $S %9
"
OTHER="4242 $S %9
"
NL='
'
while IFS='|' read -r want server start pane listing label; do
  listing="${listing//\\n/$NL}"
  assert_eq "$(live_rc "$LIB" "$server" "$start" "$pane" "$listing")" "$want" "$label"
done <<EOF
0|$LIVE|$S|%9|$LIVE $S %1\n$LIVE $S %9|the server this shell reaches, started at the recorded start, lists the pane
1|$LIVE|$E|%9|$LIVE $S %1\n$LIVE $S %9|the server this shell reaches was handed the recorded pid and started later
1|$LIVE|$S|%4|$LIVE $S %1\n$LIVE $S %9|the server this shell reaches lists no such pane
1|$GONE|$S|%9|4242 $S %9|no process runs the server pid
1|$REUSED|$S|%9|4242 $S %9|the server pid runs a program that is not tmux
1|$REUSED|$S|%9|-|the server pid runs a program that is not tmux, and no pane list answers
2|$LIVE|$S|%9|4242 $S %9|the server runs and is not the one this shell reaches
2|$LIVE|$S|%9|-|the pane list cannot be read
0|$LIVE||%9|$LIVE $E %1\n$LIVE $E %9|with no start, the server this shell reaches lists the pane, whatever its start
1|$LIVE||%4|$LIVE $S %1\n$LIVE $S %9|with no start, the server this shell reaches lists no such pane
1|$LIVE||%9|$LIVE $S %1\n4242 $S %9|with no start, a pane listed under another server pid is not the recorded one
2|$LIVE||%9|4242 $S %9|with no start, the server runs and is not the one this shell reaches
EOF
assert_eq "$(live_rc "$LIB" "$LIVE" "$S" "%1" "$LIVE $S %11")" "1" "a pane id is matched whole, never as a prefix of another"

# The start tmux_server_start prints for PANE on SERVER where the pane's
# server answers ANSWER, `-` for no answer, and its status.
start_of() { # LIB SERVER ANSWER
  if [ "$3" = - ]; then rm -f -- "$DISPLAY_OUT"; else printf '%s\n' "$3" > "$DISPLAY_OUT"; fi
  PATH="$STUB_BIN:$PATH" bash -c '. "$1"; rc=0; out="$(tmux_server_start %9 "$2")" || rc=$?; echo "$out/$rc"' \
    _ "$1" "$2"
}
while IFS='|' read -r want server answer label; do
  assert_eq "$(start_of "$LIB" "$server" "$answer")" "$want" "$label"
done <<EOF
$S/0|$LIVE|$LIVE $S|the start of the server holding the pane, which is the recorded one
/1|$LIVE|4242 $S|a pane read off another server gives no start
/1|$LIVE|$LIVE |a start tmux left empty is no start
/1|$LIVE|-|a pane that cannot be read gives no start
EOF

# --- must-fail controls ------------------------------------------------------
mutant_lib() { # NAME OLD NEW
  local dir
  dir="$(mutant_scripts "mutants/$1" lib/tmux-server.sh)" || exit 1
  mutate_file "$dir/lib/tmux-server.sh" "$2" "$3"
  MUTANT_LIB="$dir/lib/tmux-server.sh"
}

mutant_lib listed-reads-gone '    *"$nl$1 $2 $3$nl"*) return 0 ;;' '    *"$nl$1 $2 $3$nl"*) ;;'
assert_eq "$(live_rc "$MUTANT_LIB" "$LIVE" "$S" "%9" "$OWN")" "1" \
  "control: without the listing match a live pane reads gone"

mutant_lib unstarted-reads-gone "'\$1 == s && \$3 == p { f = 1 } END { exit !f }'" "'END { exit 1 }'"
assert_eq "$(live_rc "$MUTANT_LIB" "$LIVE" "" "%9" "$OWN")" "1" \
  "control: without the match on the server alone a record carrying no start reads its live pane gone"

mutant_lib gone-reads-other '  comm="$(ps -o comm= -p "$1" 2>/dev/null)" || return 1' '  comm=tmux'
assert_eq "$(live_rc "$MUTANT_LIB" "$GONE" "$S" "%9" "$OTHER")" "2" \
  "control: without the process test a gone server reads as one this shell cannot ask"

mutant_lib reused-reads-other '    *) return 1 ;;' '    *) ;;'
assert_eq "$(live_rc "$MUTANT_LIB" "$REUSED" "$S" "%9" "$OTHER")" "2" \
  "control: without the tmux name test a reused pid reads as a server this shell cannot ask"

mutant_lib other-reads-gone '  [ "${panes%% *}" = "$1" ] || return 2' '  :'
assert_eq "$(live_rc "$MUTANT_LIB" "$LIVE" "$S" "%9" "$OTHER")" "1" \
  "control: without the server test a pane on another server reads gone"

mutant_lib start-blind '    *"$nl$1 $2 $3$nl"*) return 0 ;;' '    *"$nl$1 "*" $3$nl"*) return 0 ;;'
assert_eq "$(live_rc "$MUTANT_LIB" "$LIVE" "$E" "%9" "$OWN")" "0" \
  "control: a match blind to the start reads a later server's pane as the recorded one"

mutant_lib start-any-server '  [ "${out%% *}" = "$2" ] || return 1' '  :'
assert_eq "$(start_of "$MUTANT_LIB" "$LIVE" "4242 $S")" "$S/0" \
  "control: without the server test a start read off another server binds the record"

mutant_lib start-any-shape "    '' | *[!0-9]*) return 1 ;;" "    '' | *[!0-9]*) ;;"
assert_eq "$(start_of "$MUTANT_LIB" "$LIVE" "$LIVE ")" "/0" \
  "control: without the digits test an empty start binds the record"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
