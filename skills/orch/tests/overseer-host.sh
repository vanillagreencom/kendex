#!/usr/bin/env bash
# Tests for scripts/overseer-host, the overseer-session runtime adapter, and
# scripts/overseer-host-tmux, the tmux provider behind it, over a real tmux
# server on a private socket. The dispatcher rows use a fixture provider that
# records its argv; the provider rows open, read, feed and close panes the
# way `oversee-succeed` did by hand before the adapter existed, and pin the
# window placement a succession depends on.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# mutant_scripts and mutate_file, the two halves of the stop verb's control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
HOST="$SRC_DIR/overseer-host"
PROVIDER="$SRC_DIR/overseer-host-tmux"

TMP_ROOT="$(mktemp -d)" || { echo "overseer-host: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "overseer-host: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "overseer-host: scratch=resolve-failed" >&2; exit 1; }
SOCK="overseer-host-$$"
cleanup() {
  tmux -L "$SOCK" kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { tmux -L "$SOCK" "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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
assert_eq "$RC|$OUT" \
  "0|tmux" \
  "resolve with nothing set answers tmux"
run_host ORCH_OVERSEER_HOST=tmux -- resolve
assert_eq "$RC|$OUT" \
  "0|tmux" \
  "resolve with the tmux word answers tmux"
run_host ORCH_OVERSEER_HOST="$FIXTURE" -- resolve
assert_eq "$RC|$OUT" \
  "0|$FIXTURE" \
  "resolve with a script path answers the path"
OUT="$(cd "$TMP_ROOT" && printf 'block\n' | env -i HOME="$TMP_ROOT" PATH="$PATH" ORCH_OVERSEER_HOST="$FIXTURE" "$HOST" deliver --session %3 2>&1)" && RC=0 || RC=$?
assert_eq "$RC|$(tr '\n' ';' <<<"$OUT")" \
  "7|fixture deliver --session %3;block;fixture-err;" \
  "a verb reaches the provider with its argv, stdin, streams and exit status unchanged"
run_host -- wait --item x
assert_eq "$RC|$OUT" \
  "2|overseer-host: verb-invalid verb=wait" \
  "a verb outside the protocol is refused before any provider runs"
run_host ORCH_OVERSEER_HOST="$TMP_ROOT/nosuch" -- inspect --session %1
assert_eq "$RC|$OUT" \
  "2|overseer-host: host-unavailable path=$TMP_ROOT/nosuch" \
  "a provider path that is not executable is refused naming it"
run_host ORCH_OVERSEER_HOST="$TMP_ROOT" -- inspect --session %1
assert_eq "$RC|$OUT" \
  "2|overseer-host: host-unavailable path=$TMP_ROOT" \
  "a provider path that is a directory is refused naming it"

# --- the tmux provider ------------------------------------------------------------
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work"
tmux -L "$SOCK" -f /dev/null new-session -d -s fleet -x 200 -y 40 'exec sleep 100000'
tm set-option -g renumber-windows off
tm set-option -g default-shell /bin/sh
tm set-option -g default-command "exec /bin/sh"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"
SERVER_PID="$(tm display-message -p '#{pid}')"
KEEP_WINDOW="$(tm display-message -p -t fleet:0 '#{window_id}')"
run_tmux() { # ARGS...
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i HOME="$TMP_ROOT" PATH="${RUN_PATH:-$PATH}" TMUX="$TMUX_ADDR" "${PROVIDER_BIN:-$HOST}" "$@" 2>&1 </dev/null)" || RC=$?
}
layout() { tm list-windows -t fleet -F '#{window_id} #{window_name}' | awk -v keep="$KEEP_WINDOW" '$1 != keep { print $2 }' | sort | tr '\n' ';'; }
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

# create after a predecessor: the window starts at the base index, named
# overseer, in the directory named, and runs the line typed.
tm kill-window -a -t "$KEEP_WINDOW"
tm move-window -r -t fleet
PRED="$(new_pane 3 'exec sleep 100000')"
new_pane 5 'exec sleep 100000' >/dev/null
run_tmux create --cwd "$TMP_ROOT/work" --after "$PRED" --line "pwd > $TMP_ROOT/typed; printf 'esc to interrupt\\n'; exec sleep 100000"
SESSION="$(field "$OUT" session)"; WINDOW="$(field "$OUT" window)"
wait_for "$SESSION" 'esc to interrupt' || true
assert_eq "$RC|$(layout)|$(field "$OUT" server)|$(cat "$TMP_ROOT/typed" 2>/dev/null)|$(tm display-message -p -t "$SESSION" '#{window_id}')" \
  "0|overseer;w3;w5;|$SERVER_PID|$TMP_ROOT/work|$WINDOW" \
  "create --after opens the window at the base index and types the line"
assert_eq "$(tm display-message -p -t "$SESSION" '#{window_index} #{window_name}')" "0 overseer" \
  "create --after reads back the actual base-index placement"

# inspect --launch: the first-turn reading over the whole screen.
run_tmux inspect --launch --session "$SESSION"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(sed 1d <<<"$OUT" | grep -q 'esc to interrupt' && echo screen)" \
  "0|session=$SESSION window=$WINDOW server=$SERVER_PID state=working|screen" \
  "inspect --launch reads a turn in flight as working, the screen under the keyed line"
ASK="$(new_pane 7 "printf 'Do you trust the files in this folder?\\n'; exec sleep 100000")"
wait_for "$ASK" 'trust the files' || true
run_tmux inspect --launch --session "$ASK"
assert_eq "$RC|$(tr '\n' ';' <<<"$OUT")" \
  "0|session=$ASK window=$(tm display-message -p -t "$ASK" '#{window_id}') server=$SERVER_PID state=asking;Do you trust the files in this folder?;" \
  "inspect --launch reads the folder-trust dialog as asking, that line alone under the keyed one"
IDLE="$(new_pane 8 "printf 'FIXTURE startup waiting\\n'; exec sleep 100000")"
wait_for "$IDLE" 'startup waiting' || true
run_tmux inspect --launch --session "$IDLE"
assert_eq "$RC|$(field "$OUT" state)|$(grep -c 'FIXTURE startup waiting' <<<"$OUT")" \
  "0|idle|1" \
  "inspect --launch reads a screen with neither as idle"

# inspect settled: lib/lane-state.sh's own judge over the pane, with the
# process read a bare shell needs.
COMPOSER="$(new_pane 9 "printf '\\342\\217\\272 Watching the fleet.\\n\\342\\235\\257\\302\\240\\n'; exec sleep 100000")"
wait_for "$COMPOSER" 'Watching the fleet' || true
run_tmux inspect --session "$COMPOSER"
assert_eq "$RC|$(field "$OUT" state)" \
  "0|idle" \
  "inspect reads a settled composer as idle"
SHELL_PANE="$(new_pane 10 'exec /bin/sh')"
sleep 0.3
run_tmux inspect --session "$SHELL_PANE"
assert_eq "$RC|$(field "$OUT" state)" \
  "0|exited" \
  "inspect reads a bare shell with nothing under it as exited"
run_tmux inspect --session %999
assert_eq "$RC|$(tr '\n' ';' <<<"$OUT")" \
  "0|session=%999 window=none server=none state=gone;" \
  "inspect on a session the server does not list answers gone with no screen"
# A pane that closes during any read after the listing is gone, never an
# unreadable session: the window a succession's stop closes while its caller's
# wait reads. A tmux on PATH closes the pane at one read: just before the
# capture, which then fails; at the process read, which a closing pane can
# answer empty at exit 0; or just after the capture, which answered, the last
# read `--launch` makes.
RACE_BIN="$TMP_ROOT/race-bin"
mkdir -p "$RACE_BIN"
race_pane() { # INDEX before|empty|after — a pane the tmux on RACE_BIN closes at that read
  local real
  real="$(command -v tmux)"
  RACE="$(new_pane "$1" 'exec sleep 100000')"
  case "$2" in
    before) printf '#!/bin/sh\n[ "$1" != capture-pane ] || %s kill-pane -t %s 2>/dev/null\nexec %s "$@"\n' \
              "$real" "$RACE" "$real" ;;
    empty) printf '#!/bin/sh\ncase "$*" in *"#{pane_pid} "*) %s kill-pane -t %s 2>/dev/null; echo; exit 0 ;; esac\nexec %s "$@"\n' \
              "$real" "$RACE" "$real" ;;
    after) printf '#!/bin/sh\n[ "$1" = capture-pane ] || exec %s "$@"\n%s "$@"; rc=$?\n%s kill-pane -t %s 2>/dev/null\nexit $rc\n' \
              "$real" "$real" "$real" "$RACE" ;;
  esac > "$RACE_BIN/tmux"
  chmod +x "$RACE_BIN/tmux"
}
for read in before empty after; do
  race_pane 11 "$read"
  launch=()
  [[ "$read" != after ]] || launch=(--launch)
  RUN_PATH="$RACE_BIN:$PATH" run_tmux inspect ${launch[@]+"${launch[@]}"} --session "$RACE"
  assert_eq "$RC|$(tr '\n' ';' <<<"$OUT")" \
    "0|session=$RACE window=none server=none state=gone;" \
    "inspect on a session that closes at its read ($read) answers gone"
done
# Its control: a provider that refuses every failed read as unreadable.
RACECTL="$(mutant_scripts racectl overseer-host-tmux)" || exit 1
mutate_file "$RACECTL/overseer-host-tmux" 'inspect_unread() { # FIELD=VALUE...
  local detail
  detail="$(cat -- "$DEP_ERR")" || detail=""' \
  'inspect_unread() { # FIELD=VALUE...
  local detail
  detail="$(cat -- "$DEP_ERR")" || detail=""
  die session-unreadable "session=$SESSION" "$@"'
race_pane 12 before
PROVIDER_BIN="$RACECTL/overseer-host-tmux" RUN_PATH="$RACE_BIN:$PATH" run_tmux inspect --session "$RACE"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|overseer-host-tmux: session-unreadable session=$RACE field=capture" \
  "control: without the second listing a pane closed during the read is unreadable"
# The empty answer's control: a read held to its shape with no second listing.
SHAPECTL="$(mutant_scripts shapectl overseer-host-tmux)" || exit 1
mutate_file "$SHAPECTL/overseer-host-tmux" '    inspect_unread "field=$2" "value=${out:-none}"' \
  '    die session-unreadable "session=$SESSION" "field=$2" "value=${out:-none}"'
race_pane 13 empty
PROVIDER_BIN="$SHAPECTL/overseer-host-tmux" RUN_PATH="$RACE_BIN:$PATH" run_tmux inspect --session "$RACE"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|overseer-host-tmux: session-unreadable session=$RACE field=pane_pid value=none" \
  "control: an empty answer with no second listing is unreadable"
# The answered read's control: no listing once the judgement is made.
SETTLECTL="$(mutant_scripts settlectl overseer-host-tmux)" || exit 1
mutate_file "$SETTLECTL/overseer-host-tmux" 'inspect_settled() { pane_listed "$SESSION" || inspect_gone; }' \
  'inspect_settled() { :; }'
race_pane 14 after
PROVIDER_BIN="$SETTLECTL/overseer-host-tmux" RUN_PATH="$RACE_BIN:$PATH" run_tmux inspect --launch --session "$RACE"
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | grep -c ' server=none state=gone$' || true)" "0|0" \
  "control: with no listing after the judgement a pane closed after its capture is judged as if live"
# A child probe that cannot run is named with its own exit status: a pgrep
# on PATH that fails as a broken probe does, under a bare shell.
PROBE_BIN="$TMP_ROOT/probe-bin"
mkdir -p "$PROBE_BIN"
printf '#!/bin/sh\nexit 3\n' > "$PROBE_BIN/pgrep"
chmod +x "$PROBE_BIN/pgrep"
RUN_PATH="$PROBE_BIN:$PATH" run_tmux inspect --session "$SHELL_PANE"
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | grep -o ' cause=.*')" \
  "0| cause=process-probe probe=3" \
  "inspect names a child probe that could not run and its exit status"
# Both scans failing on one pass are both named: the probe as above and a grep
# that fails on the usage-limit pattern alone.
# shellcheck source=../scripts/lib/lane-state.sh
LIMIT_RE="$(source "$SRC_DIR/lib/lane-state.sh" && printf '%s' "$USAGE_LIMIT_RE")"
cat > "$PROBE_BIN/grep" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do [[ "\$arg" != $(printf '%q' "$LIMIT_RE") ]] || exit 2; done
exec $(command -v grep) "\$@"
STUB
chmod +x "$PROBE_BIN/grep"
both_causes() { # [PROVIDER_BIN]
  PROVIDER_BIN="${1:-}" RUN_PATH="$PROBE_BIN:$PATH" run_tmux inspect --session "$SHELL_PANE"
  BOTH="$RC|$(sed -n 1p <<<"$OUT" | grep -o ' cause=.*')"
}
both_causes
assert_eq "$BOTH" "0| cause=limit-scan,process-probe probe=3" \
  "inspect names both scans where both fail, the probe with its exit status"
BOTHCTL="$(mutant_scripts bothctl overseer-host-tmux)" || exit 1
mutate_file "$BOTHCTL/overseer-host-tmux" '[[ "$LANE_PROBE_RC" -le 1 ]] || cause=' \
  '[[ "$LANE_PROBE_RC" -le 1 || -n "$cause" ]] || cause='
both_causes "$BOTHCTL/overseer-host-tmux"
assert_eq "$BOTH" "0| cause=limit-scan" "control: a provider that names one scan drops the probe beside the limit scan"
rm -f -- "${PROBE_BIN:?}/grep"
PROBECTL="$(mutant_scripts probectl overseer-host-tmux)" || exit 1
mutate_file "$PROBECTL/overseer-host-tmux" 'cause="$cause,process-probe probe=$LANE_PROBE_RC"' 'cause="$cause,process-probe"'
PROVIDER_BIN="$PROBECTL/overseer-host-tmux" RUN_PATH="$PROBE_BIN:$PATH" run_tmux inspect --session "$SHELL_PANE"
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | grep -o ' cause=.*')" "0| cause=process-probe" \
  "control: a provider that drops the probe status names the cause alone"
run_tmux inspect --session fleet:3
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "2|overseer-host-tmux: invalid-session value=fleet:3" \
  "inspect refuses a target that is not a pane id"

# deliver: the block is consumed, the session's liveness is the answer.
OUT="$(cd "$TMP_ROOT/work" && printf 'a block\n' | env -i HOME="$TMP_ROOT" PATH="$PATH" TMUX="$TMUX_ADDR" "$HOST" deliver --session "$SESSION" 2>&1)" && RC=0 || RC=$?
assert_eq "$RC|$OUT" \
  "0|deliver=watch-log session=$SESSION" \
  "deliver on a live session confirms the watch-log route"
OUT="$(cd "$TMP_ROOT/work" && printf 'a block\n' | env -i HOME="$TMP_ROOT" PATH="$PATH" TMUX="$TMUX_ADDR" "$HOST" deliver --session %999 2>&1)" && RC=0 || RC=$?
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "4|overseer-host-tmux: session-gone session=%999" \
  "deliver on a session the server does not list refuses at 4"

# stop with a successor: close the predecessor without moving the successor
# away from the base index create gave it.
SUCC_WINDOW="$(tm display-message -p -t "$SESSION" '#{window_id}')"
PRED_WINDOW="$(tm display-message -p -t "$PRED" '#{window_id}')"
run_tmux stop --session "$PRED" --successor "$SESSION"
assert_eq "$RC|$OUT|$(layout)|$(tm display-message -p -t "$SESSION" '#{window_id}')" \
  "0|stopped session=$PRED window=$PRED_WINDOW|overseer;w10;w5;w7;w8;w9;|$SUCC_WINDOW" \
  "stop --successor closes the predecessor and keeps the successor's window"
assert_eq "$(tm display-message -p -t "$SESSION" '#{window_index} #{window_name}')" "0 overseer" \
  "stop --successor keeps the base-index placement"
# The must-fail control restores the swap that moves the successor away
# from the base index after create.
MUTANT="$(mutant_scripts mutant overseer-host-tmux)" || exit 1
mutate_file "$MUTANT/overseer-host-tmux" \
  '      tmux kill-window -t "$window" \; set-option -wu -t "$succ_window" @orch_overseer_displaced \; select-window -t "$succ_window" \' \
  '      tmux swap-window -d -s "$succ_window" -t "$window" \; kill-window -t "$window" \; set-option -wu -t "$succ_window" @orch_overseer_displaced \; select-window -t "$succ_window" \'
tm kill-window -a -t "$KEEP_WINDOW"
tm move-window -r -t fleet
PRED2="$(new_pane 3 'exec sleep 100000')"
new_pane 5 'exec sleep 100000' >/dev/null
run_tmux create --cwd "$TMP_ROOT/work" --after "$PRED2" --line "exec sleep 100000"
SUCC2="$(field "$OUT" session)"
PROVIDER_BIN="$MUTANT/overseer-host-tmux" run_tmux stop --session "$PRED2" --successor "$SUCC2"
assert_eq "$RC|$(layout)" "0|overseer;w5;" "control: the swapped successor still exists"
MISPLACED_INDEX="$(tm display-message -p -t "$SUCC2" '#{window_index}')"
if [[ "$MISPLACED_INDEX" == 0 ]]; then MISPLACED_AT_BASE=yes; else MISPLACED_AT_BASE=no; fi
assert_eq "$MISPLACED_AT_BASE" no \
  "control: the swap moves the successor away from the base index"

# stop alone, then on a session already gone: the second is a stop with
# nothing left to do, never a failure.
SUCC2_WINDOW="$(tm display-message -p -t "$SUCC2" '#{window_id}')"
run_tmux stop --session "$SUCC2"
assert_eq "$RC|$OUT|$(layout)" \
  "0|stopped session=$SUCC2 window=$SUCC2_WINDOW|w5;" \
  "stop closes the session's window"
run_tmux stop --session "$SUCC2"
assert_eq "$RC|$OUT" \
  "0|stopped session=$SUCC2 window=none" \
  "stop on a session the server no longer lists is already done"

# create into a session: the configured base index, and a session tmux
# does not hold is refused before anything opens.
tm set-option -t fleet base-index 2
run_tmux create --cwd "$TMP_ROOT/work" --session fleet --name overseer --line "exec sleep 100000"
FIRST="$(field "$OUT" session)"
assert_eq "$RC|$(layout)|$(tm display-message -p -t "$FIRST" '#{window_index} #{window_name}')" \
  "0|overseer;w5;|2 overseer" \
  "create --session reads back the configured base index"
run_tmux create --cwd "$TMP_ROOT/work" --session fleetz --line "exec sleep 100000"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(layout)" \
  "1|overseer-host-tmux: tmux-session-missing session=fleetz|overseer;w5;" \
  "create into a session tmux does not hold refuses naming it"
# Both abandon and failed pane-write cleanup undo insertion. The retained
# overseer occupies the base index, with an adjacent window and a later gap.
ADJACENT="$(tm new-window -d -t fleet:3 -n adjacent -P -F '#{window_id}' 'exec sleep 100000')"
ROLLBACK_LAYOUT="$(tm list-windows -t fleet -F '#{window_id} #{window_index}')"
ROLLBACKCTL="$(mutant_scripts rollbackctl overseer-host-tmux)" || exit 1
mutate_file "$ROLLBACKCTL/overseer-host-tmux" \
  '    args+=(swap-window -d -s "$1" -t "$displaced" \;)' \
  '    if false; then args+=(swap-window -d -s "$1" -t "$displaced" \;); fi'
REAL_TMUX="$(command -v tmux)"
cat > "$BIN/tmux" <<SHIM
#!/bin/sh
[ "\$1" != paste-buffer ] || exit 1
exec "$REAL_TMUX" "\$@"
SHIM
chmod +x "$BIN/tmux"
for rollback in abandon pane-write; do
  for implementation in production control; do
    provider="$HOST"
    [[ "$implementation" != control ]] || provider="$ROLLBACKCTL/overseer-host-tmux"
    if [[ "$rollback" == abandon ]]; then
      PROVIDER_BIN="$provider" run_tmux create --cwd "$TMP_ROOT/work" --after "$FIRST" --line 'exec sleep 100000'
      ABANDONED="$(field "$OUT" session)"
      PROVIDER_BIN="$provider" run_tmux stop --session "$ABANDONED"
      assert_eq "$RC" 0 "$implementation: abandonment closes the inserted window"
    else
      PROVIDER_BIN="$provider" RUN_PATH="$BIN:$PATH" run_tmux create --cwd "$TMP_ROOT/work" --after "$FIRST" --line 'exec sleep 100000'
      assert_eq "$RC|$(sed -n 1p <<<"$OUT" | sed 's/window=@[0-9]*/window=@N/')" \
        '1|overseer-host-tmux: create-failed step=pane-write window=@N' \
        "$implementation: failed pane write closes the inserted window"
    fi
    actual="$(tm list-windows -t fleet -F '#{window_id} #{window_index}')"
    if [[ "$implementation" == production ]]; then
      assert_eq "$actual" "$ROLLBACK_LAYOUT" "$rollback restores every prior window index and gap"
    else
      if [[ "$actual" == "$ROLLBACK_LAYOUT" ]]; then restored=yes; else restored=no; fi
      assert_eq "$restored" no "$rollback control: disabled swaps fail the placement assertion"
      tm move-window -s "$FIRST" -t fleet:2
      tm move-window -s "$ADJACENT" -t fleet:3
    fi
  done
done
rm -f -- "${BIN:?}/tmux"
# A has-session answer that is not "can't find session" is the call failing,
# not a missing session: TMUX pointed at a socket with no server refuses
# tmux-failed, not tmux-session-missing.
OUT="$(cd "$TMP_ROOT/work" && env -i HOME="$TMP_ROOT" PATH="$PATH" TMUX="$TMP_ROOT/dead-socket,1,0" "$HOST" create --cwd "$TMP_ROOT/work" --session fleet --line "exec sleep 1" 2>&1)" && RC=0 || RC=$?
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|overseer-host-tmux: tmux-failed operation=has-session session=fleet" \
  "create against a socket with no server refuses tmux-failed, not a missing session"
tm kill-window -a -t "$FIRST"
CREATECTL="$(mutant_scripts createctl overseer-host-tmux)" || exit 1
mutate_file "$CREATECTL/overseer-host-tmux" 'tmux new-window -d -b -t "$target"' 'tmux new-window -d -a -t "$target"'
PROVIDER_BIN="$CREATECTL/overseer-host-tmux" run_tmux create --cwd "$TMP_ROOT/work" --session fleet --line "exec sleep 100000"
MISPLACED="$(field "$OUT" session)"
assert_eq "$RC|$(tm display-message -p -t "$MISPLACED" '#{window_index}')" "0|3" \
  "control: insertion after the base window moves the new overseer away from the base index"
run_tmux stop --session "$MISPLACED"
run_tmux create --cwd "$TMP_ROOT/work" --session fleet --after "$FIRST" --line "exec sleep 100000"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "2|overseer-host-tmux: option-conflict verb=create" \
  "create refuses two placements"
run_tmux create --cwd "$TMP_ROOT/work" --session fleet
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "2|overseer-host-tmux: option-missing option=--line verb=create" \
  "create refuses a missing line"
run_tmux create --cwd "$TMP_ROOT/work" --line "exec sleep 1"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "2|overseer-host-tmux: option-missing option=--after,--session verb=create" \
  "create refuses no placement at all"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
