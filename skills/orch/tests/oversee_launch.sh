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
# mutant_scripts and mutate_file, the two halves of the launch verb's control.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
OVERSEE="$SRC_DIR/oversee"
# The permission word a claude launch carries, read from the launch table the
# launcher itself writes it from, so the rows assert the word reaches the
# harness without this file spelling it.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$SRC_DIR/lib/lane-launch.sh"
BYPASS="$(launch_choice_permission_write claude)" || { echo "fixture: no claude permission word in the launch table" >&2; exit 1; }
# The word that takes claude's question tool away, from the same table: an
# unset ORCH_QUESTION_TOOL is off, so a first launch carries it.
QUESTION_OFF="$(launch_choice_question_off claude)"
[[ -n "$QUESTION_OFF" && "$QUESTION_OFF" != *" "* ]] || { echo "fixture: claude's question-tool words are not one word in the launch table" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)"
TMUX_DIR="$TMP_ROOT/tmux"
mkdir -p "$TMUX_DIR"
cleanup() {
  TMUX_TMPDIR="$TMUX_DIR" tmux -L default kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { TMUX_TMPDIR="$TMUX_DIR" tmux -L default "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

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
# A pane whose foreground process names claude, for `register` to read the
# harness off: a copy of sleep, since a script or a shell named for the
# harness can reset the process name tmux reads.
cp "$(command -v sleep)" "$BIN/hclaude"

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
# `tmp` under, or from RUN_DIR where a row sets it. Sets OUT (both streams)
# and RC.
run_oversee() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  rm -f "${TMP_ROOT:?}"/argv.*
  RC=0
  OUT="$(cd "${RUN_DIR:-$TMP_ROOT/work}" && env -i HOME="$H" PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" \
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
# and claude's full-bypass and question-tool words, and the record written
# with generation 1.
run_oversee -- launch --wait-secs 20
LAUNCHED="$(keyed overseer-launched "$OUT" | sed -n 1p)"
SESSION="$(field "$LAUNCHED" session)"
assert_eq "$RC|$(sed -n 's/window=@[0-9]*/window=@N/; s/session=%[0-9]*/session=%N/p' <<<"$LAUNCHED")|$(layout)|$(recorded_argv)" \
  "0|oversee: overseer-launched session=%N window=@N server=$SOCKET generation=1 lane=$H/.claude|1 overseer;|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$BYPASS;$QUESTION_OFF;$BRIEF;" \
  "a first launch from outside tmux opens the overseer at the end of the named session and records it"
assert_eq "$(recorded runtime)|$(recorded server)|$(recorded pane)|$(recorded window)|$(recorded account)|$(recorded generation)|$(recorded launch_line)" \
  "tmux|$SERVER_PID|$SESSION|$(tm display-message -p -t "$SESSION" '#{window_id}')|$H/.claude|1|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer --model fable --effort high $BYPASS $(printf '%q' "$QUESTION_OFF") '$BRIEF'" \
  "the session record names the runtime, server, pane, window, account, line and generation"
WORK_REAL="$(cd "$TMP_ROOT/work" && pwd -P)"
identity() { printf '%s|' "$(recorded harness)" "$(recorded account)" "$(recorded home)" "$(recorded model)" "$(recorded effort)" "$(recorded cwd)"; }
assert_eq "$(identity)" "claude|$H/.claude|$H/.claude|fable|high|$WORK_REAL|" \
  "the session record carries the launch identity the command was built with"
assert_eq "$(keyed overseer-launch "$OUT" | sed -n 1p | sed 's/session=%[0-9]*/session=%N/; s/window=@[0-9]*/window=@N/')" \
  "oversee: overseer-launch form=prefix lane=$H/.claude trust=account-config session=%N window=@N server=$SOCKET" \
  "the launch line names the form and the session before the record"

# A second launch while that overseer is live is refused: two overseers never
# act at once, and the record tells them apart.
run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded generation)" \
  "1|oversee: overseer-live session=$SESSION server=$SOCKET generation=1|1|1" \
  "a launch beside a live recorded overseer refuses naming it and opens nothing"
# The must-fail control: a launcher that skips the liveness check opens a
# second overseer beside the first.
LIVECTL="$(mutant_scripts livectl oversee)" || exit 1
mutate_file "$LIVECTL/oversee" '  if grep -qxF -- "$live_server $live_pane" <<<"$panes"; then' '  if false; then'
OVERSEE_BIN="$LIVECTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(overseers)|$(recorded generation)" \
  "0|2|2" \
  "control: without the liveness check a second overseer opens beside the first"
tm kill-window -t "$(recorded window)"

# The overseer stopped: the next launch takes the next generation.
tm kill-window -t "$SESSION"
run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(field "$(keyed overseer-launched "$OUT" | sed -n 1p)" generation)|$(recorded generation)|$(overseers)" \
  "0|3|3|1" \
  "a launch after the recorded overseer's session is gone opens the next generation"
tm kill-window -t "$(recorded window)"

# A launch whose session never works: closed, the prior record put back.
touch "$TMP_ROOT/idle"
run_oversee -- launch --wait-secs 2
rm -f "$TMP_ROOT/idle"
assert_eq "$RC|$(keyed overseer-not-working "$OUT" | sed -n 1p | sed 's/session=%[0-9]*/session=%N/; s/waited=[0-9]*/waited=N/')|$(grep -c 'FIXTURE overseer startup waiting' <<<"$OUT")|$(overseers)|$(recorded generation)" \
  "1|oversee: overseer-not-working session=%N waited=N|1|0|3" \
  "a session that never shows a working turn is closed and the record put back"

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
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
    "1|oversee: $row_want|0" \
    "$row_what: refused, nothing opened"
done
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
run_oversee -- launch --wait-secs 5
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "3|oversee: no-lane-qualifies entries=1 walled=2 unmeasured=0|0" \
  "no lane above the trigger: refused at 3 with the walk's counts"
# An overseer opens through overseer-host on this machine, under this machine's
# copy of the account, so the walk reads that copy even on a fleet whose
# provider reports the same account with room. Run from a repository of its
# own, since lane-host takes its project from the working directory.
HOSTED_WORK="$TMP_ROOT/hosted-work"
mkdir -p "$HOSTED_WORK/tmp"
git -C "$HOSTED_WORK" init -q -b main
printf 'account=%s\tharness=claude\tsession-5h-pct=5\tweekly-pct=5\n' "$H/.claude" > "$TMP_ROOT/accounts-room.tsv"
HOSTED_ENV=(ORCH_LANE_HOST="$TEST_DIR/fixtures/lane-host" LANE_HOST_STUB_ACCOUNTS="$TMP_ROOT/accounts-room.tsv" LANE_HOST_STUB_LOG="$TMP_ROOT/host.log")
RUN_DIR="$HOSTED_WORK" run_oversee "${HOSTED_ENV[@]}" -- launch --wait-secs 5
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "3|oversee: no-lane-qualifies entries=1 walled=2 unmeasured=0|0" \
  "a provider row with room for an account this machine reads walled opens no overseer on it"
# Control: a walk that inherits the fleet's provider launches on the host row.
HOSTCTL="$(mutant_scripts hostctl lib/overseer-launch.sh)" || exit 1
mutate_file "$HOSTCTL/lib/overseer-launch.sh" 'OL_PICK_RECORD="$(ol_lanes pick' 'OL_PICK_RECORD="$("$SCRIPT_DIR/lanes" pick'
RUN_DIR="$HOSTED_WORK" OVERSEE_BIN="$HOSTCTL/oversee" run_oversee "${HOSTED_ENV[@]}" -- launch --wait-secs 20
assert_eq "$RC|$(overseers)" "0|1" \
  "control: a walk reading the provider's row opens the overseer on the account this machine reads walled"
tm kill-window -t fleet:overseer
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"

# A has-session answer that is not "can't find session" is the call failing,
# not a missing session: pointed at a TMUX_TMPDIR with no server running, the
# launch refuses tmux-failed naming that socket, not tmux-session-missing whose
# advice is to start the session.
EMPTY_TMUX="$TMP_ROOT/empty-tmux"
mkdir -p "$EMPTY_TMUX"
EMPTY_SOCKET="$EMPTY_TMUX/tmux-$(id -u)/default"
run_oversee TMUX_TMPDIR="$EMPTY_TMUX" -- launch --wait-secs 5
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "1|oversee: tmux-failed operation=has-session server=$EMPTY_SOCKET|0" \
  "launch against a socket with no server refuses tmux-failed, not a missing session"

# register: the record for a hand-opened pane, its generation one past the
# record's, kept where the record already names that pane.
HAND="$(tm new-window -d -t fleet:4 -n hand -P -F '#{pane_id}' "exec '$BIN/hclaude' 100000")"
PRIOR_LINE="$(recorded launch_line)"
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(recorded runtime)|$(recorded account)|$(recorded launch_line)" \
  "0|oversee: registered session=$HAND window=$(tm display-message -p -t "$HAND" '#{window_id}') server=$SERVER_PID generation=4 account=$H/.eclaude|tmux|$H/.eclaude|none" \
  "register writes the record for the caller's pane, one generation past the record, and drops the launch line the record held"
# The line's control: a writer that keeps the prior's fields whole leaves the
# launched session's line on the hand-opened one, and a death of the latter
# would replay the former's command. The line the real register just dropped
# is put back first, so the control meets the record that register met.
[[ "$PRIOR_LINE" != none ]] || fail "control premise: the record held no launch line before register"
jq --arg line "$PRIOR_LINE" '.overseer.launch_line = $line' "$FLEET_STATE" > "$FLEET_STATE.tmp" && mv -- "$FLEET_STATE.tmp" "$FLEET_STATE"
LINECTL="$(mutant_scripts linectl lib/overseer-launch.sh)" || exit 1
mutate_file "$LINECTL/lib/overseer-launch.sh" '($p | del(.pending, .launch_line))' '($p | del(.pending))'
OVERSEE_BIN="$LINECTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(recorded launch_line)" "0|$PRIOR_LINE" \
  "control: a register that keeps the prior fields whole carries the launched session's line"
HAND_IDENTITY="claude|$H/.eclaude|$H/.eclaude|none|none|$(tm display-message -p -t "$HAND" '#{pane_current_path}')|"
assert_eq "$(identity)" "$HAND_IDENTITY" \
  "register records the harness the pane runs, its account and directory, and no model or effort"
# register's control: a harness read that names none leaves the record without one.
REGCTL="$(mutant_scripts regctl oversee)" || exit 1
mutate_file "$REGCTL/oversee" '    claude) harness=claude ;;' '    claude) ;;'
OVERSEE_BIN="$REGCTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(recorded harness)" "0|none" \
  "control: a register that reads no harness records none"
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" -- register --account "$H/.claude"
assert_eq "$RC|$(recorded generation)|$(recorded account)" \
  "0|4|$H/.claude" \
  "registering the same pane again keeps its generation and takes --account"
run_oversee -- register
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee: tmux-missing var=TMUX_PANE" \
  "register outside a pane refuses"

# A launch typed outside the fleet directory, --cwd naming it: the run moves
# there first, so the record goes into THAT directory's fleet state, the one
# the launched overseer's hooks, watch and succession read, and the session
# starts there. The typing directory gets no state of its own.
tm kill-window -t "$(recorded window)"
ELSEWHERE="$TMP_ROOT/elsewhere"
mkdir -p "$ELSEWHERE"
elsewhere_state() { if [[ -e "$ELSEWHERE/tmp/workflow-state-oversee.json" ]]; then echo written; else echo absent; fi; }
RUN_DIR="$ELSEWHERE" run_oversee -- launch --cwd "$TMP_ROOT/work" --wait-secs 20
assert_eq "$RC|$(recorded generation)|$(elsewhere_state)|$(tm display-message -p -t "$(recorded pane)" '#{pane_current_path}')" \
  "0|5|absent|$WORK_REAL" \
  "launch --cwd from outside the fleet directory records into that directory's state and starts there"
tm kill-window -t "$(recorded window)"

# ORCH_QUESTION_TOOL=overseer keeps the overseer's question tool: the launch
# line carries no question-off word. With the default-off rows above, a
# launcher that stops reading the setting fails one side.
run_oversee ORCH_QUESTION_TOOL=overseer -- launch --wait-secs 20
assert_eq "$RC|$(recorded_argv)" \
  "0|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$BYPASS;$BRIEF;" \
  "ORCH_QUESTION_TOOL=overseer launches the overseer with its question tool"
tm kill-window -t "$(recorded window)"

# The writer's control: a record write that leaves the launch identity out,
# over a fleet with no prior record, records a session nothing says the
# harness or model of.
WRITECTL="$(mutant_scripts writectl lib/overseer-launch.sh)" || exit 1
mutate_file "$WRITECTL/lib/overseer-launch.sh" '      + $identity' '      + {}'
jq 'del(.overseer)' "$FLEET_STATE" > "$FLEET_STATE.tmp" && mv -- "$FLEET_STATE.tmp" "$FLEET_STATE"
OVERSEE_BIN="$WRITECTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(recorded harness)|$(recorded model)" "0|none|none" \
  "control: a record write without the launch identity records none of it"
tm kill-window -t "$(recorded window)"

# register on a codex pane running under a private CODEX_HOME: the account is
# the folder that home was built under, and the home is kept apart from it. A
# copy of sleep named codex, since only that exact name reads as codex.
mkdir -p "$TMP_ROOT/codex-bin"
cp "$(command -v sleep)" "$TMP_ROOT/codex-bin/codex"
PRIVATE_HOME="$H/.codex/lane-launch/work-1/home"
CODEX_PANE="$(tm new-window -d -t fleet:6 -n codexhand -P -F '#{pane_id}' "exec '$TMP_ROOT/codex-bin/codex' 100000")"
register_codex() { # [OVERSEE_BIN]
  OVERSEE_BIN="${1:-}" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$CODEX_PANE" CODEX_HOME="$PRIVATE_HOME" -- register
}
register_codex
assert_eq "$RC|$(recorded harness)|$(recorded account)|$(recorded home)" \
  "0|codex|$H/.codex|$PRIVATE_HOME" \
  "register on a codex pane records its account and its private CODEX_HOME apart"
CODEXCTL="$(mutant_scripts codexctl oversee)" || exit 1
mutate_file "$CODEXCTL/oversee" 'codex) harness=codex; home="${CODEX_HOME:-$ACCOUNT}" ;;' 'codex) harness=codex ;;'
register_codex "$CODEXCTL/oversee"
assert_eq "$RC|$(recorded home)" "0|$H/.codex" \
  "control: a register that takes the account for the home loses the private CODEX_HOME"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
