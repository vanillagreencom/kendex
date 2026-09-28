#!/usr/bin/env bash
# tmux_pane_live, lib/tmux-server.sh: whether a `<server pid> <pane id>` key
# names a pane that still runs. A tmux stub on PATH answers `list-panes -a`
# from a file a row writes, or fails where the row writes none. A running
# server is a copy of sleep named tmux, a pid reused by another program is
# this suite's own shell, and a gone server a child that has exited.
# The must-fail controls close the file, one per rule, each on a library copy.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
LIVE=""
trap '[ -z "$LIVE" ] || kill "$LIVE" 2>/dev/null; rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo "=== tmux_pane_live ==="

STUB_BIN="$TMP_ROOT/bin"
PANES="$TMP_ROOT/panes"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/tmux" <<STUB
#!/bin/sh
[ "\$1" = list-panes ] || exit 1
[ -f "$PANES" ] || { echo "no server running" >&2; exit 1; }
cat "$PANES"
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
# The answer for SERVER PANE with the pane list LISTING, `-` for a list tmux
# cannot give.
live_rc() { # LIB SERVER PANE LISTING
  if [ "$4" = - ]; then rm -f -- "$PANES"; else printf '%s' "$4" > "$PANES"; fi
  PATH="$STUB_BIN:$PATH" bash -c '. "$1"; rc=0; tmux_pane_live "$2" "$3" || rc=$?; echo "$rc"' _ "$1" "$2" "$3"
}

OWN="$LIVE %1
$LIVE %9
"
OTHER="4242 %9
"
NL='
'
while IFS='|' read -r want server pane listing label; do
  listing="${listing//\\n/$NL}"
  assert_eq "$(live_rc "$LIB" "$server" "$pane" "$listing")" "$want" "$label"
done <<EOF
0|$LIVE|%9|$LIVE %1\n$LIVE %9|the server this shell reaches lists the pane
1|$LIVE|%4|$LIVE %1\n$LIVE %9|the server this shell reaches lists no such pane
1|$GONE|%9|4242 %9|no process runs the server pid
1|$REUSED|%9|4242 %9|the server pid runs a program that is not tmux
1|$REUSED|%9|-|the server pid runs a program that is not tmux, and no pane list answers
2|$LIVE|%9|4242 %9|the server runs and is not the one this shell reaches
2|$LIVE|%9|-|the pane list cannot be read
EOF
assert_eq "$(live_rc "$LIB" "$LIVE" "%1" "$LIVE %11")" "1" "a pane id is matched whole, never as a prefix of another"

# --- must-fail controls ------------------------------------------------------
mutant_lib() { # NAME OLD NEW
  local dir
  dir="$(mutant_scripts "mutants/$1" lib/tmux-server.sh)" || exit 1
  mutate_file "$dir/lib/tmux-server.sh" "$2" "$3"
  MUTANT_LIB="$dir/lib/tmux-server.sh"
}

mutant_lib listed-reads-gone '    *"$nl$1 $2$nl"*) return 0 ;;' '    *"$nl$1 $2$nl"*) ;;'
assert_eq "$(live_rc "$MUTANT_LIB" "$LIVE" "%9" "$OWN")" "1" \
  "control: without the listing match a live pane reads gone"

mutant_lib gone-reads-other '  comm="$(ps -o comm= -p "$1" 2>/dev/null)" || return 1' '  comm=tmux'
assert_eq "$(live_rc "$MUTANT_LIB" "$GONE" "%9" "$OTHER")" "2" \
  "control: without the process test a gone server reads as one this shell cannot ask"

mutant_lib reused-reads-other '    *) return 1 ;;' '    *) ;;'
assert_eq "$(live_rc "$MUTANT_LIB" "$REUSED" "%9" "$OTHER")" "2" \
  "control: without the tmux name test a reused pid reads as a server this shell cannot ask"

mutant_lib other-reads-gone '  [ "${panes%% *}" = "$1" ] || return 2' '  :'
assert_eq "$(live_rc "$MUTANT_LIB" "$LIVE" "%9" "$OTHER")" "1" \
  "control: without the server test a pane on another server reads gone"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
