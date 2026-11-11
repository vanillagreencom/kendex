#!/usr/bin/env bash
# Tests for scripts/overseer-host, the overseer-session adapter whose
# `inspect` a Jarvis session reads a recorded session through, and
# scripts/overseer-host-tmux, the tmux provider behind `inspect`, over a
# real tmux server on a private socket. The dispatcher rows use a fixture
# provider that records its argv; the provider rows read panes as Jarvis's
# live check does.
# Inputs: skills/agent-runtime/, skills/agent-runtime/scripts/, skills/change-scope/references/,
# skills/change-scope/scripts/, skills/communication/references/reports.md, skills/mailbox/scripts/,
# skills/orch/runtime/, skills/orch/scripts/, skills/orch/tests/.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# mutant_scripts and mutate_file, the two halves of the controls.
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
IDENTITY_GUARD=""
cleanup() {
  if [[ -n "$IDENTITY_GUARD" ]]; then kill "$IDENTITY_GUARD" 2>/dev/null || true; wait "$IDENTITY_GUARD" 2>/dev/null || true; fi
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
  OUT="$(cd "$TMP_ROOT" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$TMP_ROOT" PATH="$PATH" ${env_args[@]+"${env_args[@]}"} "$HOST" "$@" 2>&1 </dev/null)" || RC=$?
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
OUT="$(cd "$TMP_ROOT" && printf 'block\n' | env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$TMP_ROOT" PATH="$PATH" ORCH_OVERSEER_HOST="$FIXTURE" "$HOST" inspect --session %3 2>&1)" && RC=0 || RC=$?
assert_eq "$RC|$(tr '\n' ';' <<<"$OUT")" \
  "7|fixture inspect --session %3;block;fixture-err;" \
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
run_tmux() { # ARGS...
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$TMP_ROOT" PATH="${RUN_PATH:-$PATH}" TMUX="$TMUX_ADDR" "${PROVIDER_BIN:-$HOST}" "$@" 2>&1 </dev/null)" || RC=$?
}
field() { awk -v k="$2=" 'NR == 1 { for (i = 1; i <= NF; i++) if (index($i, k) == 1) { print substr($i, length(k) + 1); exit } }' <<<"$1"; }
# A pane at INDEX running COMMAND, its pane id printed, its window named
# for the index.
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

# inspect --launch: the first-turn reading over the whole screen.
SESSION="$(new_pane 3 "printf 'esc to interrupt\\n'; exec sleep 100000")"
wait_for "$SESSION" 'esc to interrupt' || exit 1
WINDOW="$(tm display-message -p -t "$SESSION" '#{window_id}')"
run_tmux inspect --launch --session "$SESSION"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(sed 1d <<<"$OUT" | grep -q 'esc to interrupt' && echo screen)" \
  "0|session=$SESSION window=$WINDOW server=$SERVER_PID state=working harness_state=unknown harness_cause=record-unreadable|screen" \
  "inspect --launch reads a turn in flight as working, the screen under the keyed line"
ASK="$(new_pane 7 "printf 'Do you trust the files in this folder?\\n'; exec sleep 100000")"
wait_for "$ASK" 'trust the files' || true
run_tmux inspect --launch --session "$ASK"
assert_eq "$RC|$(tr '\n' ';' <<<"$OUT")" \
  "0|session=$ASK window=$(tm display-message -p -t "$ASK" '#{window_id}') server=$SERVER_PID state=asking harness_state=unknown harness_cause=record-unreadable;Do you trust the files in this folder?;" \
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
SERVER_START="$(tm display-message -p '#{start_time}')"
PROBE_BIN="$TMP_ROOT/probe-bin"
mkdir -p "$PROBE_BIN"
REAL_TMUX="$(command -v tmux)"
REAL_PS="$(command -v ps)"
cat > "$PROBE_BIN/tmux" <<STUB
#!/bin/sh
if [ "\$*" = 'list-panes -a -F #{pid} #{start_time} #{pane_id}' ]; then
  echo pane-list-read=failed >&2
  exit 2
fi
exec "$REAL_TMUX" "\$@"
STUB
cat > "$PROBE_BIN/ps" <<STUB
#!/bin/sh
if [ "\$*" = '-A -o pid= -o comm=' ]; then
  echo process-read=failed >&2
  exit 2
fi
exec "$REAL_PS" "\$@"
STUB
chmod +x "$PROBE_BIN/tmux" "$PROBE_BIN/ps"
PS_BIN="$TMP_ROOT/ps-bin"
LIST_BIN="$TMP_ROOT/list-bin"
mkdir -p "$PS_BIN" "$LIST_BIN"
cp "$PROBE_BIN/ps" "$PS_BIN/ps"
cp "$PROBE_BIN/tmux" "$LIST_BIN/tmux"
# A closed Unix listener leaves a real refused socket, beside a missing one.
python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$TMP_ROOT/refused"
while IFS='|' read -r name start socket run_path want_rc want_state want_error; do
  RUN_PATH="$run_path" run_tmux inspect --session "$SHELL_PANE" --server-socket "$socket" \
    --server "$SERVER_PID" --server-start "$start"
  category="$(sed -n '1s/^overseer-host-tmux: \([^ ]*\).*/\1/p' <<<"$OUT")"
  assert_eq "$RC|$(field "$OUT" state)|$category" "$want_rc|$want_state|$want_error" \
    "recorded server inspect: $name" "$OUT"
  if [[ "$want_error" == session-unreadable ]]; then
    assert_eq "$(field "$OUT" server)" "$SERVER_PID" "unreadable $name names the recorded server"
    assert_eq "$(grep -cF -- "$name=failed" <<<"$OUT" || true)" "1" "unreadable $name keeps its cause"
  fi
done <<EOF
same-start|$SERVER_START|${TMUX_ADDR%%,*}|$PATH|0|exited|
different-start|0|${TMUX_ADDR%%,*}|$PATH|0|gone|
process-read|$SERVER_START|${TMUX_ADDR%%,*}|$PS_BIN:$PATH|1||session-unreadable
pane-list-read|$SERVER_START|${TMUX_ADDR%%,*}|$LIST_BIN:$PATH|1||session-unreadable
missing-socket|$SERVER_START|$TMP_ROOT/missing|$PATH|0|gone|
refused-socket|$SERVER_START|$TMP_ROOT/refused|$PATH|0|gone|
EOF
UNREADCTL="$(mutant_scripts inspect-unread-control overseer-host-tmux)" || exit 1
mutate_file "$UNREADCTL/overseer-host-tmux" \
  '[[ "$probe" -eq 0 ]] || die session-unreadable "session=$SESSION" "server=$RECORDED_SERVER"' \
  'true || [[ "$probe" -eq 0 ]] || die session-unreadable "session=$SESSION" "server=$RECORDED_SERVER"'
PROVIDER_BIN="$UNREADCTL/overseer-host-tmux" RUN_PATH="$LIST_BIN:$PATH" run_tmux inspect --session "$SHELL_PANE" \
  --server-socket "${TMUX_ADDR%%,*}" --server "$SERVER_PID" --server-start "$SERVER_START"
assert_eq "$RC|$(field "$OUT" state)" '0|exited' "control: disabling only the probe refusal lets later working reads accept unreadable evidence"
SOCKETCTL="$(mutant_scripts inspect-dead-socket-control lib/tmux-server.sh)" || exit 1
mutate_file "$SOCKETCTL/lib/tmux-server.sh" \
  '      case "$panes" in' '      TMUX_PANE_DETAIL="$panes"; return 2
      case "$panes" in'
PROVIDER_BIN="$SOCKETCTL/overseer-host-tmux" run_tmux inspect --session "$SHELL_PANE" \
  --server-socket "$TMP_ROOT/missing" --server "$SERVER_PID" --server-start "$SERVER_START"
assert_eq "$RC|$(sed -n '1s/^overseer-host-tmux: \([^ ]*\).*/\1/p' <<<"$OUT")" \
  '1|session-unreadable' "control: without dead-socket classification a reused live tmux pid blocks takeover"
STARTCTL="$(mutant_scripts inspect-start-control overseer-host-tmux)" || exit 1
mutate_file "$STARTCTL/overseer-host-tmux" \
  'tmux_pane_live "$RECORDED_SERVER" "$RECORDED_START" "$SESSION"' \
  'tmux_pane_live "$RECORDED_SERVER" "" "$SESSION"'
PROVIDER_BIN="$STARTCTL/overseer-host-tmux" run_tmux inspect --session "$SHELL_PANE" \
  --server-socket "${TMUX_ADDR%%,*}" --server "$SERVER_PID" --server-start 0
assert_eq "$RC|$(field "$OUT" state)" '0|exited' "control: ignoring the recorded start reads a different server identity as live"
run_tmux inspect --session %999
assert_eq "$RC|$(tr '\n' ';' <<<"$OUT")" \
  "0|session=%999 window=none server=none state=gone harness_state=unknown harness_cause=pane-gone;" \
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
    "0|session=$RACE window=none server=none state=gone harness_state=unknown harness_cause=pane-gone;" \
    "inspect on a session that closes at its read ($read) answers gone"
done
# Its control: a provider that refuses every failed read as unreadable.
RACECTL="$(mutant_scripts racectl lib/overseer-pane.sh)" || exit 1
mutate_file "$RACECTL/lib/overseer-pane.sh" '  otp_settled || return 1
  [[ "$OTP_STATE" != gone ]] || return 0
  printf' '  otp_error "$@"; return 1
  otp_settled || return 1
  [[ "$OTP_STATE" != gone ]] || return 0
  printf'
race_pane 12 before
PROVIDER_BIN="$RACECTL/overseer-host-tmux" RUN_PATH="$RACE_BIN:$PATH" run_tmux inspect --session "$RACE"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|overseer-host-tmux: session-unreadable session=$RACE field=capture" \
  "control: without the second listing a pane closed during the read is unreadable"
# The empty answer's control: a read held to its shape with no second listing.
SHAPECTL="$(mutant_scripts shapectl lib/overseer-pane.sh)" || exit 1
mutate_file "$SHAPECTL/lib/overseer-pane.sh" '    otp_unread "field=$2" "value=${out:-none}"' \
  '    otp_error "field=$2" "value=${out:-none}"'
race_pane 13 empty
PROVIDER_BIN="$SHAPECTL/overseer-host-tmux" RUN_PATH="$RACE_BIN:$PATH" run_tmux inspect --session "$RACE"
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|overseer-host-tmux: session-unreadable session=$RACE field=pane_pid value=none" \
  "control: an empty answer with no second listing is unreadable"
# The answered read's control: no listing once the judgement is made.
SETTLECTL="$(mutant_scripts settlectl overseer-host-tmux)" || exit 1
mutate_file "$SETTLECTL/overseer-host-tmux" '      inspect_read otp_settled
      printf '"'"'session=%s window=%s server=%s state=%s%s harness_state=' \
  '      : # inspect_read otp_settled
      printf '"'"'session=%s window=%s server=%s state=%s%s harness_state='
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
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | sed 's/ harness_state=.*//' | grep -o ' cause=.*')" \
  "0| cause=process-probe probe=3" \
  "inspect names a child probe that could not run and its exit status"
# Both scans failing on one pass are both named: the probe as above and a grep
# that fails on the combined usage and authentication scan.
# shellcheck source=../scripts/lib/lane-state.sh
LIMIT_RE="$(source "$SRC_DIR/lib/lane-state.sh" && printf '%s' "$USAGE_LIMIT_RE|$AUTH_FAILURE_RE")"
cat > "$PROBE_BIN/grep" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do [[ "\$arg" != $(printf '%q' "$LIMIT_RE") ]] || exit 2; done
exec $(command -v grep) "\$@"
STUB
chmod +x "$PROBE_BIN/grep"
both_causes() { # [PROVIDER_BIN]
  PROVIDER_BIN="${1:-}" RUN_PATH="$PROBE_BIN:$PATH" run_tmux inspect --session "$SHELL_PANE"
  BOTH="$RC|$(sed -n 1p <<<"$OUT" | sed 's/ harness_state=.*//' | grep -o ' cause=.*')"
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
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | sed 's/ harness_state=.*//' | grep -o ' cause=.*')" "0| cause=process-probe" \
  "control: a provider that drops the probe status names the cause alone"
run_tmux inspect --session fleet:3
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "2|overseer-host-tmux: invalid-session value=fleet:3" \
  "inspect refuses a target that is not a pane id"

# The Python parent holds the exited child unreaped through the identity
# observations. Every liveness read names a process this suite still owns.
mkdir -p "$TMP_ROOT/identity-state"
IDENTITY_STATE="$TMP_ROOT/identity-state/workflow-state-oversee.json"
mkfifo "$TMP_ROOT/identity-release"
python3 - "$TMP_ROOT" <<'PYIDENTITY' &
import os, signal, sys, time
from pathlib import Path
root = Path(sys.argv[1])
ended = False
def child_ended(*_):
    global ended
    ended = True
def stop(*_):
    raise SystemExit(1)
signal.signal(signal.SIGCHLD, child_ended)
signal.signal(signal.SIGTERM, stop)
pid = os.fork()
if pid == 0:
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    (root / "identity-pid").write_text(str(os.getpid()))
    with (root / "identity-release").open() as release:
        release.read()
    os._exit(0)
try:
    deadline = time.monotonic() + 120
    while not ended and time.monotonic() < deadline:
        time.sleep(0.01)
    if not ended:
        raise RuntimeError("child exit deadline")
    (root / "identity-ended").touch()
    while not (root / "identity-reap").exists() and time.monotonic() < deadline:
        time.sleep(0.01)
finally:
    if not ended:
        os.kill(pid, signal.SIGKILL)
    os.waitpid(pid, 0)
PYIDENTITY
IDENTITY_GUARD=$!
await_marker "$TMP_ROOT/identity-pid" || exit 1
DEAD_PID="$(cat "$TMP_ROOT/identity-pid")"
DEAD_START="$(source "$SRC_DIR/lib/lane-state.sh" && lane_process_start "$DEAD_PID")"
printf 'exit\n' > "$TMP_ROOT/identity-release"
await_marker "$TMP_ROOT/identity-ended" || exit 1
LIVE_PANE="$(new_pane 15 'printf "person-program-ready\n"; exec sleep 100000')"
wait_for "$LIVE_PANE" person-program-ready || exit 1
LIVE_PID="$(tm display-message -p -t "$LIVE_PANE" '#{pane_pid}')"
LIVE_START="$(source "$SRC_DIR/lib/lane-state.sh" && lane_process_start "$LIVE_PID")"
ENDED_PANE="$(new_pane 16 'exec /bin/sh')"
identity_record() { # PANE MODE
  jq -n --arg server "$SERVER_PID" --argjson start "$SERVER_START" --arg pane "$1" \
    --arg pid "$LIVE_PID" --arg process_start "$LIVE_START" --arg dead "$DEAD_PID" --arg dead_start "$DEAD_START" --arg mode "$2" '
    {server: $server, server_start: $start, pane: $pane, generation: 1} as $base
    | ($base + {harness_pid: $dead, harness_start: $dead_start}) as $done
    | {issue_id: "oversee", overseer: ($base +
      (if $mode == "live" or $mode == "old-exit" then {harness_pid: $pid, harness_start: $process_start}
       elif $mode == "dead" then {harness_pid: $dead, harness_start: $dead_start}
       elif $mode == "reused" then {harness_pid: $pid, harness_start: "earlier start"}
       else {} end)
      + (if $mode == "exit" or $mode == "old-exit" then {exit: {status: 0, run: $done}} else {} end))}' > "$IDENTITY_STATE"
}
identity_inspect() { # PANE [PROVIDER]
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$TMP_ROOT" PATH="${RUN_PATH:-$PATH}" \
    ORCH_STATE_DIR="$TMP_ROOT/identity-state" TMUX="$TMUX_ADDR" "${2:-$PROVIDER}" inspect --session "$1" 2>&1)" || RC=$?
}
while IFS='|' read -r label pane mode want_state want_cause; do
  identity_record "$pane" "$mode"
  identity_inspect "$pane"
  assert_eq "$RC|$(field "$OUT" harness_state)|$(field "$OUT" harness_cause)" \
    "0|$want_state|$want_cause" "recorded harness: $label" "$OUT"
done <<EOF
live recorded process|$LIVE_PANE|live|running|
old exit beside live identity|$LIVE_PANE|old-exit|running|
ended recorded process and shells only|$ENDED_PANE|dead|stopped|
bound completion and shells only|$ENDED_PANE|exit|stopped|
reused recorded PID and shells only|$ENDED_PANE|reused|stopped|
person program after bound completion|$LIVE_PANE|exit|unknown|pane-not-exited
person program after killed harness|$LIVE_PANE|dead|unknown|pane-not-exited
unrecorded harness|$LIVE_PANE|none|unknown|identity-unrecorded
EOF
identity_record "$ENDED_PANE" live
RUN_PATH="$PROBE_BIN:$PATH" identity_inspect "$ENDED_PANE"
assert_eq "$RC|$(field "$OUT" harness_state)|$(field "$OUT" harness_cause)" '0|unknown|process-probe-failed' 'failed pane probe lowers a live identity to unknown'
for mode in missing broken; do
  if [[ "$mode" == missing ]]; then rm -f -- "${IDENTITY_STATE:?}"
  else printf 'broken json' > "$IDENTITY_STATE"; fi
  identity_inspect "$LIVE_PANE"
  reason=record-unreadable
  assert_eq "$RC|$(field "$OUT" harness_state)|$(field "$OUT" harness_cause)" "0|unknown|$reason" "$mode identity record is unknown"
done
identity_record "$LIVE_PANE" live
mkdir -p "$TMP_ROOT/identity-bin"
cat > "$TMP_ROOT/identity-bin/ps" <<STUB
#!/bin/sh
[ "\$*" != '-o lstart= -p $LIVE_PID' ] || exit 2
exec "$REAL_PS" "\$@"
STUB
chmod +x "$TMP_ROOT/identity-bin/ps"
RUN_PATH="$TMP_ROOT/identity-bin:$PATH" identity_inspect "$LIVE_PANE"
assert_eq "$RC|$(field "$OUT" harness_state)|$(field "$OUT" harness_cause)" '0|unknown|start-read-failed' 'failed identity start read is unknown'
STATE_READ_CTL="$(mutant_scripts state-read-fixture lib/lane-state.sh)" || exit 1
mutate_file "$STATE_READ_CTL/lib/lane-state.sh" 'lane_proc_readable() { [[ -d /proc/self ]]; }' 'lane_proc_readable() { return 1; }'
cat > "$TMP_ROOT/identity-bin/ps" <<STUB
#!/bin/sh
[ "\$*" != '-o stat= -p $LIVE_PID' ] || exit 2
exec "$REAL_PS" "\$@"
STUB
RUN_PATH="$TMP_ROOT/identity-bin:$PATH" identity_inspect "$LIVE_PANE" "$STATE_READ_CTL/overseer-host-tmux"
assert_eq "$RC|$(field "$OUT" harness_state)|$(field "$OUT" harness_cause)" '0|unknown|state-read-failed' 'failed identity state read is unknown'

PERSON_CTL="$(mutant_scripts person-control overseer-host-tmux)" || exit 1
mutate_file "$PERSON_CTL/overseer-host-tmux" '  lane_identity_status "$pid" "$process_start" || rc=$?' \
  '  lane_identity_status "$pid" "$process_start" || rc=$?
  if [[ "$2" != exited ]]; then rc=0; fi'
identity_record "$LIVE_PANE" exit
identity_inspect "$LIVE_PANE" "$PERSON_CTL/overseer-host-tmux"
assert_eq "$(field "$OUT" harness_state)" running 'control: substituting pane presence fails the person-program unknown assertion'
: > "$TMP_ROOT/identity-reap"
wait "$IDENTITY_GUARD"
IDENTITY_GUARD=""

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
