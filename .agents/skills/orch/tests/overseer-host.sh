#!/usr/bin/env bash
# Tests for scripts/overseer-host, the overseer-session runtime adapter, and
# scripts/overseer-host-tmux, the tmux provider behind it, over a real tmux
# server on a private socket. The dispatcher rows use a fixture provider that
# records its argv; the provider rows open, read, feed and close panes the
# way `oversee-succeed` did by hand before the adapter existed, and pin the
# window placement a succession depends on.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
HOST="$SRC_DIR/overseer-host"
PROVIDER="$SRC_DIR/overseer-host-tmux"

TMP_ROOT="$(mktemp -d)"
SOCK="overseer-host-$$"
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { tmux -L "$SOCK" "$@"; }

PASS=0
FAIL=0
check() { # NAME GOT WANT
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$1" "$3" "$2"; fi
}

echo "=== overseer-host ==="

# --- the dispatcher -----------------------------------------------------------
FIXTURE="$TMP_ROOT/provider"
cat > "$FIXTURE" <<'STUB'
#!/bin/sh
printf 'fixture %s\n' "$*"
cat
printf 'fixture-err\n' >&2
exit 7
STUB
chmod +x "$FIXTURE"
run_host() { # ENV... -- ARGS...
  local env_args=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  RC=0
  OUT="$(cd "$TMP_ROOT" && env -i HOME="$TMP_ROOT" PATH="$PATH" ${env_args[@]+"${env_args[@]}"} "$HOST" "$@" 2>&1 </dev/null)" || RC=$?
}
run_host -- resolve
check "resolve with nothing set answers tmux" "$RC|$OUT" "0|tmux"
run_host ORCH_OVERSEER_HOST=tmux -- resolve
check "resolve with the tmux word answers tmux" "$RC|$OUT" "0|tmux"
run_host ORCH_OVERSEER_HOST="$FIXTURE" -- resolve
check "resolve with a script path answers the path" "$RC|$OUT" "0|$FIXTURE"
OUT="$(cd "$TMP_ROOT" && printf 'block\n' | env -i HOME="$TMP_ROOT" PATH="$PATH" ORCH_OVERSEER_HOST="$FIXTURE" "$HOST" deliver --session %3 2>&1)" && RC=0 || RC=$?
check "a verb reaches the provider with its argv, stdin, streams and exit status unchanged" \
  "$RC|$(tr '\n' ';' <<<"$OUT")" "7|fixture deliver --session %3;block;fixture-err;"
run_host -- wait --item x
check "a verb outside the protocol is refused before any provider runs" "$RC|$OUT" \
  "2|overseer-host: verb-invalid verb=wait"
run_host ORCH_OVERSEER_HOST="$TMP_ROOT/nosuch" -- inspect --session %1
check "a provider path that is not executable is refused naming it" "$RC|$OUT" \
  "2|overseer-host: host-unavailable path=$TMP_ROOT/nosuch"
run_host ORCH_OVERSEER_HOST="$TMP_ROOT" -- inspect --session %1
check "a provider path that is a directory is refused naming it" "$RC|$OUT" \
  "2|overseer-host: host-unavailable path=$TMP_ROOT"

# --- the tmux provider ------------------------------------------------------------
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work"
tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 200 -y 40 'exec sleep 100000'
tm set-option -g renumber-windows off
tm set-option -g default-shell /bin/sh
tm set-option -g default-command "exec /bin/sh"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"
SERVER_PID="$(tm display-message -p '#{pid}')"
run_tmux() { # ARGS...
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i HOME="$TMP_ROOT" PATH="$PATH" TMUX="$TMUX_ADDR" "${PROVIDER_BIN:-$HOST}" "$@" 2>&1 </dev/null)" || RC=$?
}
layout() { tm list-windows -t fleet -F '#{window_index} #{window_name}' | awk '$1 > 0' | tr '\n' ';'; }
field() { awk -v k="$2=" 'NR == 1 { for (i = 1; i <= NF; i++) if (index($i, k) == 1) { print substr($i, length(k) + 1); exit } }' <<<"$1"; }
# A pane at INDEX running COMMAND, its pane id printed. The window is named
# for the index so a layout reads which one moved.
new_pane() { # INDEX COMMAND
  tm new-window -d -t "fleet:$1" -n "w$1" -P -F '#{pane_id}' "$2"
}
wait_for() { # PANE TEXT
  local _
  for _ in $(seq 1 50); do
    [[ "$(tm capture-pane -p -t "$1")" != *"$2"* ]] || return 0
    sleep 0.1
  done
  return 1
}

# create after a predecessor: the window lands right after the predecessor's
# index, named overseer, in the directory named, and runs the line typed.
tm kill-window -a -t fleet:0
PRED="$(new_pane 3 'exec sleep 100000')"
new_pane 5 'exec sleep 100000' >/dev/null
run_tmux create --cwd "$TMP_ROOT/work" --after "$PRED" --line "pwd > $TMP_ROOT/typed; printf 'esc to interrupt\\n'; exec sleep 100000"
SESSION="$(field "$OUT" session)"; WINDOW="$(field "$OUT" window)"
wait_for "$SESSION" 'esc to interrupt' || true
check "create --after opens the window right after the predecessor's and types the line" \
  "$RC|$(layout)|$(field "$OUT" server)|$(cat "$TMP_ROOT/typed" 2>/dev/null)|$(tm display-message -p -t "$SESSION" '#{window_id}')" \
  "0|3 w3;4 overseer;5 w5;|$SERVER_PID|$TMP_ROOT/work|$WINDOW"

# inspect --launch: the first-turn reading over the whole screen.
run_tmux inspect --launch --session "$SESSION"
check "inspect --launch reads a turn in flight as working, the screen under the keyed line" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(sed 1d <<<"$OUT" | grep -q 'esc to interrupt' && echo screen)" \
  "0|session=$SESSION window=$WINDOW server=$SERVER_PID state=working|screen"
ASK="$(new_pane 7 "printf 'Do you trust the files in this folder?\\n'; exec sleep 100000")"
wait_for "$ASK" 'trust the files' || true
run_tmux inspect --launch --session "$ASK"
check "inspect --launch reads the folder-trust dialog as asking, that line alone under the keyed one" \
  "$RC|$(tr '\n' ';' <<<"$OUT")" \
  "0|session=$ASK window=$(tm display-message -p -t "$ASK" '#{window_id}') server=$SERVER_PID state=asking;Do you trust the files in this folder?;"
IDLE="$(new_pane 8 "printf 'FIXTURE startup waiting\\n'; exec sleep 100000")"
wait_for "$IDLE" 'startup waiting' || true
run_tmux inspect --launch --session "$IDLE"
check "inspect --launch reads a screen with neither as idle" \
  "$RC|$(field "$OUT" state)|$(grep -c 'FIXTURE startup waiting' <<<"$OUT")" "0|idle|1"

# inspect settled: lib/lane-state.sh's own judge over the pane, with the
# process read a bare shell needs.
COMPOSER="$(new_pane 9 "printf '\\342\\217\\272 Watching the fleet.\\n\\342\\235\\257\\302\\240\\n'; exec sleep 100000")"
wait_for "$COMPOSER" 'Watching the fleet' || true
run_tmux inspect --session "$COMPOSER"
check "inspect reads a settled composer as idle" "$RC|$(field "$OUT" state)" "0|idle"
SHELL_PANE="$(new_pane 10 'exec /bin/sh')"
sleep 0.3
run_tmux inspect --session "$SHELL_PANE"
check "inspect reads a bare shell with nothing under it as exited" "$RC|$(field "$OUT" state)" "0|exited"
run_tmux inspect --session %999
check "inspect on a session the server does not list answers gone with no screen" \
  "$RC|$(tr '\n' ';' <<<"$OUT")" "0|session=%999 window=none server=none state=gone;"
run_tmux inspect --session fleet:3
check "inspect refuses a target that is not a pane id" "$RC|$(sed -n 1p <<<"$OUT")" \
  "2|overseer-host-tmux: invalid-session value=fleet:3"

# deliver: the block is consumed, the session's liveness is the answer.
OUT="$(cd "$TMP_ROOT/work" && printf 'a block\n' | env -i HOME="$TMP_ROOT" PATH="$PATH" TMUX="$TMUX_ADDR" "$HOST" deliver --session "$SESSION" 2>&1)" && RC=0 || RC=$?
check "deliver on a live session confirms the watch-log route" "$RC|$OUT" "0|deliver=watch-log session=$SESSION"
OUT="$(cd "$TMP_ROOT/work" && printf 'a block\n' | env -i HOME="$TMP_ROOT" PATH="$PATH" TMUX="$TMUX_ADDR" "$HOST" deliver --session %999 2>&1)" && RC=0 || RC=$?
check "deliver on a session the server does not list refuses at 4" "$RC|$(sed -n 1p <<<"$OUT")" \
  "4|overseer-host-tmux: session-gone session=%999"

# stop with a successor: the successor takes the predecessor's index in one
# client call and nothing else moves.
SUCC_WINDOW="$(tm display-message -p -t "$SESSION" '#{window_id}')"
PRED_WINDOW="$(tm display-message -p -t "$PRED" '#{window_id}')"
run_tmux stop --session "$PRED" --successor "$SESSION"
check "stop --successor swaps the successor into the predecessor's slot and closes it" \
  "$RC|$OUT|$(layout)|$(tm display-message -p -t "$SESSION" '#{window_id}')" \
  "0|stopped session=$PRED window=$PRED_WINDOW|3 overseer;5 w5;7 w7;8 w8;9 w9;10 w10;|$SUCC_WINDOW"
# The must-fail control: a provider whose stop only kills the predecessor
# leaves the successor at its own index and a gap where the caller sat.
MUTANT="$TMP_ROOT/mutant"
mkdir -p "$MUTANT/lib"
ln -s "$SRC_DIR"/lib/* "$MUTANT/lib/"
FROM='      tmux swap-window -d -s "$succ_window" -t "$window" \; kill-window -t "$window" \; select-window -t "$succ_window" \'
check "control: the swap line is one line of the provider" "$(grep -cxF -- "$FROM" "$PROVIDER")" "1"
FROM="$FROM" awk '$0 == ENVIRON["FROM"] { print "      tmux kill-window -t \"$window\" \\"; next } { print }' "$PROVIDER" > "$MUTANT/overseer-host-tmux"
chmod +x "$MUTANT/overseer-host-tmux"
check "control: the mutant differs from the provider" \
  "$(cmp -s "$PROVIDER" "$MUTANT/overseer-host-tmux" && echo same || echo differs)" "differs"
tm kill-window -a -t fleet:0
PRED2="$(new_pane 3 'exec sleep 100000')"
new_pane 5 'exec sleep 100000' >/dev/null
run_tmux create --cwd "$TMP_ROOT/work" --after "$PRED2" --line "exec sleep 100000"
SUCC2="$(field "$OUT" session)"
PROVIDER_BIN="$MUTANT/overseer-host-tmux" run_tmux stop --session "$PRED2" --successor "$SUCC2"
check "control: without the swap the successor keeps index 4 and the predecessor's slot is a gap" \
  "$RC|$(layout)" "0|4 overseer;5 w5;"

# stop alone, then on a session already gone: the second is a stop with
# nothing left to do, never a failure.
SUCC2_WINDOW="$(tm display-message -p -t "$SUCC2" '#{window_id}')"
run_tmux stop --session "$SUCC2"
check "stop closes the session's window" "$RC|$OUT|$(layout)" "0|stopped session=$SUCC2 window=$SUCC2_WINDOW|5 w5;"
run_tmux stop --session "$SUCC2"
check "stop on a session the server no longer lists is already done" "$RC|$OUT" "0|stopped session=$SUCC2 window=none"

# create into a session: appended after its last window, and a session tmux
# does not hold is refused before anything opens.
run_tmux create --cwd "$TMP_ROOT/work" --session fleet --name overseer --line "exec sleep 100000"
FIRST="$(field "$OUT" session)"
check "create --session appends the window after the session's last" "$RC|$(layout)" "0|5 w5;6 overseer;"
run_tmux create --cwd "$TMP_ROOT/work" --session fleetz --line "exec sleep 100000"
check "create into a session tmux does not hold refuses naming it" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(layout)" "1|overseer-host-tmux: tmux-session-missing session=fleetz|5 w5;6 overseer;"
# A has-session answer that is not "can't find session" is the call failing,
# not a missing session: TMUX pointed at a socket with no server refuses
# tmux-failed, not tmux-session-missing.
OUT="$(cd "$TMP_ROOT/work" && env -i HOME="$TMP_ROOT" PATH="$PATH" TMUX="$TMP_ROOT/dead-socket,1,0" "$HOST" create --cwd "$TMP_ROOT/work" --session fleet --line "exec sleep 1" 2>&1)" && RC=0 || RC=$?
check "create against a socket with no server refuses tmux-failed, not a missing session" \
  "$RC|$(sed -n 1p <<<"$OUT")" "1|overseer-host-tmux: tmux-failed operation=has-session session=fleet"
run_tmux create --cwd "$TMP_ROOT/work" --session fleet --after "$FIRST" --line "exec sleep 100000"
check "create refuses two placements" "$RC|$(sed -n 1p <<<"$OUT")" "2|overseer-host-tmux: option-conflict verb=create"
run_tmux create --cwd "$TMP_ROOT/work" --session fleet
check "create refuses a missing line" "$RC|$(sed -n 1p <<<"$OUT")" "2|overseer-host-tmux: option-missing option=--line verb=create"
run_tmux create --cwd "$TMP_ROOT/work" --line "exec sleep 1"
check "create refuses no placement at all" "$RC|$(sed -n 1p <<<"$OUT")" \
  "2|overseer-host-tmux: option-missing option=--after,--session verb=create"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
