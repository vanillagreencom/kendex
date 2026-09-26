#!/usr/bin/env bash
# Tests for scripts/oversee: `launch`, a fleet's first overseer opened through
# the overseer-host adapter from OUTSIDE tmux, and `register`, the session
# record for a session a person opened by hand. Run over a real tmux server at
# the person's default socket under a private TMUX_TMPDIR, so a run with no
# $TMUX and ORCH_TMUX_SESSION set reaches it the way lib/tmux-server.sh says a
# verb outside tmux reaches the person's own server. claude and kendex are
# stubs on PATH, and `lanes pick` answers from the lanes-fixture usage bodies.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
OVERSEE="$SRC_DIR/oversee"

TMP_ROOT="$(mktemp -d)"
TMUX_DIR="$TMP_ROOT/tmux"
mkdir -p "$TMUX_DIR"
cleanup() {
  TMUX_TMPDIR="$TMUX_DIR" tmux -L default kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { TMUX_TMPDIR="$TMUX_DIR" tmux -L default "$@"; }

PASS=0
FAIL=0
check() { # NAME GOT WANT
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$1" "$3" "$2"; fi
}

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN" "$TMP_ROOT/work/tmp"
cat > "$BIN/claude" <<STUB
#!/bin/sh
{ printf 'lane=%s\n' "\${CLAUDE_CONFIG_DIR:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.claude"
if [ -f "$TMP_ROOT/idle" ]; then echo 'FIXTURE overseer startup waiting'; else echo 'esc to interrupt'; fi
exec sleep 100000
STUB
cat > "$BIN/kendex" <<'STUB'
#!/bin/sh
case "$1:$2:$3" in
  tier-model:claude:1) echo fable ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$BIN/claude" "$BIN/kendex"

new_home fleet
make_lane "$H" claude
make_lane "$H" eclaude
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"

env PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" tmux -L default -f /dev/null new-session -d -s fleet -x 200 -y 40 'exec sleep 100000'
tm set-option -g renumber-windows off
tm set-option -g default-shell /bin/sh
tm set-option -g default-command "PATH=$BIN:\$PATH; export PATH; exec /bin/sh"
SERVER_PID="$(tm display-message -p '#{pid}')"
SOCKET="$TMUX_DIR/tmux-$(id -u)/default"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"

# run_oversee ENV=VAL... -- ARGS... — the script under an explicit, whole
# environment with no $TMUX, from the work directory workflow-state resolves
# `tmp` under. Sets OUT (both streams) and RC.
run_oversee() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  rm -f "${TMP_ROOT:?}"/argv.*
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i HOME="$H" PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" \
    ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude:$H/.eclaude" ORCH_LANES_USAGE_TTL=0 \
    ORCH_OVERSEER_PREFERENCE="claude:1:high" ORCH_TMUX_SESSION=fleet \
    ${env_args[@]+"${env_args[@]}"} "${OVERSEE_BIN:-$OVERSEE}" "$@" 2>&1 </dev/null)" || RC=$?
}
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
recorded() { jq -r ".overseer.$1 // \"none\"" "$FLEET_STATE" 2>/dev/null || echo unreadable; }
keyed() { awk -v k="oversee: $1" 'index($0, k) == 1 { found = 1 } found' <<<"$2"; }
field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$(sed -n 1p <<<"$1")"; }
layout() { tm list-windows -t fleet -F '#{window_index} #{window_name}' | awk '$1 > 0' | tr '\n' ';'; }
overseers() { tm list-windows -t fleet -F '#{window_name}' | awk '$0 == "overseer"' | wc -l | tr -d ' '; }
recorded_argv() { if [[ -f "$TMP_ROOT/argv.claude" ]]; then tr '\n' ';' < "$TMP_ROOT/argv.claude"; else printf 'none'; fi; }
BRIEF='Read .agents/skills/orch/SKILL.md and execute the orch oversee workflow after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'

echo "=== oversee ==="

# A first launch from outside tmux: the window at the end of the named
# session, the harness on the picked lane with the entry's model and effort
# and claude's full-bypass word, and the record written with generation 1.
run_oversee -- launch --wait-secs 20
LAUNCHED="$(keyed overseer-launched "$OUT" | sed -n 1p)"
SESSION="$(field "$LAUNCHED" session)"
check "a first launch from outside tmux opens the overseer at the end of the named session and records it" \
  "$RC|$(sed -n 's/window=@[0-9]*/window=@N/; s/session=%[0-9]*/session=%N/p' <<<"$LAUNCHED")|$(layout)|$(recorded_argv)" \
  "0|oversee: overseer-launched session=%N window=@N server=$SOCKET generation=1 lane=$H/.claude|1 overseer;|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;--dangerously-skip-permissions;$BRIEF;"
check "the session record names the runtime, server, pane, window, account, line and generation" \
  "$(recorded runtime)|$(recorded server)|$(recorded pane)|$(recorded window)|$(recorded account)|$(recorded generation)|$(recorded launch_line)" \
  "tmux|$SERVER_PID|$SESSION|$(tm display-message -p -t "$SESSION" '#{window_id}')|$H/.claude|1|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer --model fable --effort high --dangerously-skip-permissions '$BRIEF'"
check "the launch line names the form and the session before the record" \
  "$(keyed overseer-launch "$OUT" | sed -n 1p | sed 's/session=%[0-9]*/session=%N/; s/window=@[0-9]*/window=@N/')" \
  "oversee: overseer-launch form=prefix lane=$H/.claude trust=none session=%N window=@N server=$SOCKET"

# A second launch while that overseer is live is refused: two overseers never
# act at once, and the record tells them apart.
run_oversee -- launch --wait-secs 20
check "a launch beside a live recorded overseer refuses naming it and opens nothing" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded generation)" \
  "1|oversee: overseer-live session=$SESSION server=$SOCKET generation=1|1|1"
# The must-fail control: a launcher that skips the liveness check opens a
# second overseer beside the first.
LIVECTL="$TMP_ROOT/livectl"
mkdir -p "$LIVECTL"
ln -s "$SRC_DIR"/* "$LIVECTL/"
rm -f -- "${LIVECTL:?}/oversee"
LIVE_LINE='  if grep -qxF -- "$live_server $live_pane" <<<"$panes"; then'
check "control: the liveness check is one line of the launcher" "$(grep -cxF -- "$LIVE_LINE" "$OVERSEE")" "1"
FROM="$LIVE_LINE" awk '$0 == ENVIRON["FROM"] { print "  if false; then"; next } { print }' "$OVERSEE" > "$LIVECTL/oversee"
chmod +x "$LIVECTL/oversee"
OVERSEE_BIN="$LIVECTL/oversee" run_oversee -- launch --wait-secs 20
check "control: without the liveness check a second overseer opens beside the first" \
  "$RC|$(overseers)|$(recorded generation)" "0|2|2"
tm kill-window -t "$(recorded window)"

# The overseer stopped: the next launch takes the next generation.
tm kill-window -t "$SESSION"
run_oversee -- launch --wait-secs 20
check "a launch after the recorded overseer's session is gone opens the next generation" \
  "$RC|$(field "$(keyed overseer-launched "$OUT" | sed -n 1p)" generation)|$(recorded generation)|$(overseers)" "0|3|3|1"
tm kill-window -t "$(recorded window)"

# A launch whose session never works: closed, the prior record put back.
touch "$TMP_ROOT/idle"
run_oversee -- launch --wait-secs 2
rm -f "$TMP_ROOT/idle"
check "a session that never shows a working turn is closed and the record put back" \
  "$RC|$(keyed overseer-not-working "$OUT" | sed -n 1p | sed 's/session=%[0-9]*/session=%N/; s/waited=[0-9]*/waited=N/')|$(grep -c 'FIXTURE overseer startup waiting' <<<"$OUT")|$(overseers)|$(recorded generation)" \
  "1|oversee: overseer-not-working session=%N waited=N|1|0|3"

# The refusals before anything opens.
for row in \
  "ORCH_OVERSEER_PREFERENCE=|preference-empty setting=ORCH_OVERSEER_PREFERENCE|an empty preference" \
  "ORCH_OVERSEER_PREFERENCE=claude:one:high|invalid-preference entry=claude:one:high|an entry outside the shape" \
  "ORCH_TMUX_SESSION=|session-unresolved consulted=--session,ORCH_TMUX_SESSION|no session named" \
  "ORCH_TMUX_SESSION=fleetz|tmux-session-missing session=fleetz server=$SOCKET|a session tmux does not hold" \
  "ORCH_OVERSEER_HOST=$TMP_ROOT/other|runtime-unsupported host=$TMP_ROOT/other|a runtime other than tmux" \
  "ORCH_OVERSEER_HEADROOM_PCT=101|invalid-headroom-trigger ORCH_OVERSEER_HEADROOM_PCT=101|a headroom trigger past 100" \
  ; do
  IFS='|' read -r row_env row_want row_what <<<"$row"
  run_oversee "$row_env" -- launch --wait-secs 5
  check "$row_what: refused, nothing opened" "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" "1|oversee: $row_want|0"
done
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
run_oversee -- launch --wait-secs 5
check "no lane above the trigger: refused at 3 with the walk's counts" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" "3|oversee: no-lane-qualifies entries=1 walled=2 unmeasured=0|0"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"

# register: the record for a hand-opened pane, its generation one past the
# record's, kept where the record already names that pane.
HAND="$(tm new-window -d -t fleet:4 -n hand -P -F '#{pane_id}' 'exec sleep 100000')"
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
check "register writes the record for the caller's pane, one generation past the record" \
  "$RC|$(sed -n 1p <<<"$OUT")|$(recorded runtime)|$(recorded account)" \
  "0|oversee: registered session=$HAND window=$(tm display-message -p -t "$HAND" '#{window_id}') server=$SERVER_PID generation=4 account=$H/.eclaude|tmux|$H/.eclaude"
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" -- register --account "$H/.claude"
check "registering the same pane again keeps its generation and takes --account" \
  "$RC|$(recorded generation)|$(recorded account)" "0|4|$H/.claude"
run_oversee -- register
check "register outside a pane refuses" "$RC|$(sed -n 1p <<<"$OUT")" "1|oversee: tmux-missing var=TMUX_PANE"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
