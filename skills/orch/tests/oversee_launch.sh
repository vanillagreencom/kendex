#!/usr/bin/env bash
# Tests for scripts/oversee: `launch`, a fleet's first overseer opened through
# the overseer-host adapter from OUTSIDE tmux, and `register`, the session
# record for a session a person opened by hand. Run over a real tmux server at
# the person's default socket under a private TMUX_TMPDIR, so a run with no
# $TMUX and ORCH_TMUX_SESSION set reaches it the way lib/tmux-server.sh says a
# verb outside tmux reaches the person's own server. claude, codex and
# copilot are stubs on PATH, and `lanes pick` answers from the lanes-fixture
# usage bodies.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/copilot-context-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/copilot-context-world.sh"
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
# The env words an overseer line opens with, clearing the launching session's
# identity (LANE_LAUNCH_SCRUB) and keeping the owner's live desktop session
# (lane_launch_keep_live_session), since the overseer is not a lane.
SCRUB_ENV="$(lane_launch_keep_live_session && printf ' -u %s' "${LANE_LAUNCH_SCRUB[@]}")"
SCRUB_ENV="env$SCRUB_ENV"
BYPASS="$(launch_choice_permission_write claude)" || { echo "fixture: no claude permission word in the launch table" >&2; exit 1; }
# The word that takes claude's question tool away, from the same table: an
# unset ORCH_QUESTION_TOOL is off, so a first launch carries it.
QUESTION_OFF="$(launch_choice_question_off claude)"
[[ -n "$QUESTION_OFF" && "$QUESTION_OFF" != *" "* ]] || { echo "fixture: claude's question-tool words are not one word in the launch table" >&2; exit 1; }
# The word that turns claude's compaction off, which every overseer launch on
# a model with a named window carries.
COMPACT="$(launch_choice_compaction_off claude)"
[[ -n "$COMPACT" && "$COMPACT" != *" "* ]] || { echo "fixture: claude's compaction words are not one word in the launch table" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)" || { echo "oversee_launch: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "oversee_launch: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "oversee_launch: scratch=resolve-failed" >&2; exit 1; }
TMUX_DIR="$TMP_ROOT/tmux"
BIN="$TMP_ROOT/bin"
mkdir -p "$TMUX_DIR" "$BIN"
FIXTURE_SOCKETS=()
FIXTURE_CHILDREN=()
# Each label identifies one lifetime. Short labels fit macOS's temp paths.
fixture_server_allocate() { # SIDE MODE PHASE
  if [[ "$2" == default ]]; then
    FIXTURE_NAME=default
  else
    FIXTURE_NAME="$1-${2:0:1}-${3:0:1}"
  fi
  local uid
  uid="$(id -u)" || return 1
  FIXTURE_SOCKET="$TMUX_DIR/tmux-$uid/$FIXTURE_NAME"
}
fixture_server_start() {
  env PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" ORCH_STATE_DIR="$TMP_ROOT/work/tmp" tmux -L "$FIXTURE_NAME" -f /dev/null \
    new-session -d -s fleet -x 200 -y 40 'exec sleep 100000' || return 1
  FIXTURE_SOCKETS+=("$FIXTURE_SOCKET")
  tmux -S "$FIXTURE_SOCKET" set-option -g default-shell /bin/sh || return 1
  tmux -S "$FIXTURE_SOCKET" set-option -g default-command "PATH=$BIN:\$PATH; export PATH; exec /bin/sh" || return 1
  FIXTURE_ADDR="$(tmux -S "$FIXTURE_SOCKET" display-message -p '#{socket_path},#{pid},0')" || return 1
  printf 'fixture-socket=%s\n' "${FIXTURE_ADDR%%,*}"
}
fixture_server_stop() { # SOCKET
  local i
  for ((i=0; i<${#FIXTURE_SOCKETS[@]}; i++)); do
    [[ "${FIXTURE_SOCKETS[i]}" == "$1" ]] || continue
    tmux -S "$1" kill-server || return 1
    FIXTURE_SOCKETS[i]=''
    return 0
  done
  echo "fixture: socket=not-owned value=[$1]" >&2
  return 1
}
cleanup() {
  local socket child
  for child in ${FIXTURE_CHILDREN[@]+"${FIXTURE_CHILDREN[@]}"}; do
    [[ -n "$child" ]] || continue
    kill "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  done
  [[ ! -f "$TMP_ROOT/work/tmp/oversee-watch.pid" ]] || fixture_watch_stop "$TMP_ROOT/work/tmp/workflow-state-oversee.json" || true
  for socket in ${FIXTURE_SOCKETS[@]+"${FIXTURE_SOCKETS[@]}"}; do
    [[ -z "$socket" ]] || tmux -S "$socket" kill-server 2>/dev/null || true
  done
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { TMUX_TMPDIR="$TMUX_DIR" tmux -L default "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

fixture_distinct_sockets() {
  local duplicates
  duplicates="$(sort "$@" | uniq -d)" || return 1
  assert_eq "$duplicates" "" "fixture lifetimes own distinct tmux sockets"
  [[ -z "$duplicates" ]]
}
fixture_worker() { # ROLE BARRIERS
  local role="$1" barriers="$2" first
  fixture_server_allocate b worker initial
  fixture_server_start || return 1
  first="${FIXTURE_ADDR%%,*}"
  printf '%s\n' "$first" > "$barriers/$role.sockets.tmp"
  mv "$barriers/$role.sockets.tmp" "$barriers/$role.sockets"
  printf '%s\n' "$FIXTURE_ADDR" > "$barriers/$role.ready.tmp"
  mv "$barriers/$role.ready.tmp" "$barriers/$role.ready"
  if [[ "$role" == a ]]; then
    await_marker "$barriers/a.stop" || return 1
    fixture_server_stop "$first" || return 1
    touch "$barriers/a.stopped"
  else
    await_marker "$barriers/b.check" || return 1
    tmux -S "$first" display-message -p '#{socket_path},#{pid},0' > "$barriers/b.answered.tmp" || return 1
    mv "$barriers/b.answered.tmp" "$barriers/b.answered"
  fi
  await_marker "$barriers/$role.restart" || return 1
  [[ "$role" == a ]] || fixture_server_stop "$first" || return 1
  fixture_server_allocate b worker register
  # Compare before acquisition too: base reuse must fail on ownership,
  # even while kill-server's asynchronous shutdown is still in progress.
  printf '%s\n' "$first" "$FIXTURE_SOCKET" > "$barriers/$role.sockets.tmp"
  mv "$barriers/$role.sockets.tmp" "$barriers/$role.sockets"
  fixture_distinct_sockets "$barriers/$role.sockets" || return 1
  fixture_server_start || return 1
  assert_eq "${FIXTURE_ADDR%%,*}" "$FIXTURE_SOCKET" "restarted fixture answers on its allocated fresh socket"
  printf '%s\n' "$FIXTURE_ADDR" > "$barriers/$role.restarted.tmp"
  mv "$barriers/$role.restarted.tmp" "$barriers/$role.restarted"
  await_marker "$barriers/release" || return 1
  fixture_server_stop "$FIXTURE_SOCKET" || return 1
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
if [[ "${1:-}" == --fixture-worker ]]; then
  [[ $# -eq 3 && ( "$2" == a || "$2" == b ) ]] || exit 2
  fixture_worker "$2" "$3"
  exit
fi
[[ $# -eq 0 ]] || exit 2

test_concurrent_fixtures() {
  local barriers="$TMP_ROOT/concurrent" run status a_addr b_addr a_pid b_pid control answer delayed
  mkdir -p "$barriers"
  echo "=== concurrent tmux fixture ownership ==="
  for run in a b; do
    "$BASH" "$TEST_DIR/oversee_launch.sh" --fixture-worker "$run" "$barriers" > "$barriers/$run.log" 2>&1 &
    FIXTURE_CHILDREN+=("$!")
  done
  for run in a b; do
    await_marker "$barriers/$run.ready" || { cat "$barriers/$run.log"; return 1; }
  done
  a_addr="$(cat "$barriers/a.ready")" || return 1
  b_addr="$(cat "$barriers/b.ready")" || return 1
  fixture_distinct_sockets "$barriers/a.sockets" "$barriers/b.sockets" || return 1
  a_pid="${a_addr#*,}" a_pid="${a_pid%%,*}"
  b_pid="${b_addr#*,}" b_pid="${b_pid%%,*}"
  assert_eq "$([[ "$a_pid" != "$b_pid" ]] && echo distinct || echo shared)" distinct "concurrent fixtures own distinct live server PIDs"
  answer="$(tmux -S "${a_addr%%,*}" display-message -p '#{socket_path},#{pid},0')" || return 1
  assert_eq "$answer" "$a_addr" "A answers while B is live"
  answer="$(tmux -S "${b_addr%%,*}" display-message -p '#{socket_path},#{pid},0')" || return 1
  assert_eq "$answer" "$b_addr" "B answers while A is live"
  touch "$barriers/a.stop"
  await_marker "$barriers/a.stopped" || { cat "$barriers/a.log"; return 1; }
  touch "$barriers/b.check"
  await_marker "$barriers/b.answered" || { cat "$barriers/b.log"; return 1; }
  answer="$(cat "$barriers/b.answered")" || return 1
  assert_eq "$answer" "$b_addr" "B still answers after A stops its own server"
  touch "$barriers/a.restart" "$barriers/b.restart"
  for run in a b; do
    await_marker "$barriers/$run.restarted" || { cat "$barriers/$run.log"; return 1; }
  done
  fixture_distinct_sockets "$barriers/a.sockets" "$barriers/b.sockets" || return 1
  touch "$barriers/release"
  for run in 0 1; do
    status=0
    wait "${FIXTURE_CHILDREN[run]}" || status=$?
    FIXTURE_CHILDREN[run]=''
    assert_eq "$status" 0 "concurrent fixture worker $run passes"
  done
  FIXTURE_CHILDREN=()
  cat "$barriers/a.log" "$barriers/b.log"

  control="$TMP_ROOT/control/oversee_launch.sh"
  mkdir -p "${control%/*}" "$TMP_ROOT/control-barriers"
  cp "$TEST_DIR/oversee_launch.sh" "$control"
  for helper in git-env.sh copilot-context-world.sh lanes-fixture.sh growth-state.sh assertions.sh; do
    mutate_file "$control" 'source "$(dirname "${BASH_SOURCE[0]}")/lib/'"$helper"'"' \
      "source $(printf '%q' "$TEST_DIR/lib/$helper")"
  done
  mutate_file "$control" $'\nTEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
    "$(printf '\nTEST_DIR=%q' "$TEST_DIR")"
  delayed="$TMP_ROOT/control/delayed.sh"
  cp "$control" "$delayed"
  mutate_file "$delayed" "tmux -S \"\$first\" display-message -p '#{socket_path},#{pid},0' > \"\$barriers/b.answered.tmp\"" \
    "{ touch \"\$barriers/b.writing\"; await_marker \"\$barriers/b.write\" || return 1; tmux -S \"\$first\" display-message -p '#{socket_path},#{pid},0'; } > \"\$barriers/b.answered.tmp\""
  for run in atomic direct; do
    barriers="$TMP_ROOT/$run-barriers"
    mkdir -p "$barriers"
    if [[ "$run" == direct ]]; then
      mutate_file "$delayed" $'> "$barriers/b.answered.tmp" || return 1\n    mv "$barriers/b.answered.tmp" "$barriers/b.answered"' \
        '> "$barriers/b.answered" || return 1'
    fi
    "$BASH" "$delayed" --fixture-worker b "$barriers" > "$barriers/b.log" 2>&1 &
    FIXTURE_CHILDREN+=("$!")
    await_marker "$barriers/b.ready" || { cat "$barriers/b.log"; return 1; }
    touch "$barriers/b.check"
    await_marker "$barriers/b.writing" || { cat "$barriers/b.log"; return 1; }
    answer=unpublished
    [[ ! -f "$barriers/b.answered" ]] || answer="$(cat "$barriers/b.answered")"
    if [[ "$run" == atomic ]]; then
      assert_eq "$answer" unpublished "parent cannot read a marker before its content is complete"
    else
      assert_eq "$answer" "" "control: direct publication lets the parent read an empty answer"
    fi
    touch "$barriers/b.write"
    await_marker "$barriers/b.answered" || { cat "$barriers/b.log"; return 1; }
    if [[ "$run" == atomic ]]; then
      assert_eq "$(cat "$barriers/b.answered")" "$(cat "$barriers/b.ready")" "published delayed marker holds the complete answer"
    fi
    touch "$barriers/b.restart" "$barriers/release"
    wait "${FIXTURE_CHILDREN[0]}" || { cat "$barriers/b.log"; return 1; }
    FIXTURE_CHILDREN=()
  done
  mutate_file "$control" $'\n    FIXTURE_NAME="$1-${2:0:1}-${3:0:1}"' $'\n    FIXTURE_NAME="$1-${2:0:1}-i"'
  barriers="$TMP_ROOT/control-barriers"
  "$BASH" "$control" --fixture-worker a "$barriers" > "$barriers/a.log" 2>&1 &
  FIXTURE_CHILDREN+=("$!")
  await_marker "$barriers/a.ready" || { cat "$barriers/a.log"; return 1; }
  touch "$barriers/a.stop"
  await_marker "$barriers/a.stopped" || { cat "$barriers/a.log"; return 1; }
  touch "$barriers/a.restart"
  status=0
  wait "${FIXTURE_CHILDREN[0]}" || status=$?
  FIXTURE_CHILDREN=()
  assert_eq "$status" 1 "control: base socket reuse fails the fixture worker"
  status=0
  (fixture_distinct_sockets "$barriers/a.sockets") > "$barriers/comparison.log" || status=$?
  assert_eq "$status" 1 "control: the same ownership comparison rejects base socket reuse"
}
test_concurrent_fixtures

source "$TEST_DIR/lib/watch-fixture.sh"
QUIET_SCRIPTS="$(mutant_scripts fixture-watch oversee)" || exit 1
OVERSEE="$QUIET_SCRIPTS/oversee"
fixture_watch_neighbor "$OVERSEE"
mkdir -p "$BIN/processes" "$TMP_ROOT/work/tmp"
for harness in claude codex copilot; do
  cp "$(command -v sleep)" "$BIN/processes/$harness"
done
# The work directory is the overseer's checkout, current with its origin, so a
# launch's fast-forward has nothing to move or refuse until a row says so.
# shellcheck source=lib/overseer-checkout.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/overseer-checkout.sh"
checkout_world "$TMP_ROOT/work" || { echo "fixture: the work checkout could not be made" >&2; exit 1; }
cat > "$BIN/claude" <<STUB
#!/bin/sh
{ printf 'lane=%s\n' "\${CLAUDE_CONFIG_DIR:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.claude"
$(checkout_stub_line)
if [ -f "$TMP_ROOT/idle" ]; then echo 'FIXTURE overseer startup waiting'; else echo 'esc to interrupt'; fi
# With the row flag, the SessionStart row its hook would write, in the rows
# file for this pane under the directory it started in (lib/session-rows.sh).
if [ -f "$TMP_ROOT/row" ]; then
  box="\$PWD/tmp/lane-mail/overseer"
  mkdir -p "\$box"
  printf '{"at":%s,"event":"SessionStart","harness":"claude","source":"startup"}\n' "\$(date +%s)" \
    >> "\$box/session-\$(tmux display-message -p '#{pid}')-\${TMUX_PANE#%}.jsonl"
fi
exec "$BIN/processes/claude" 100000
STUB
# The codex harness, recording its home and argv as the claude stub does.
cat > "$BIN/codex" <<STUB
#!/bin/sh
{ printf 'home=%s\n' "\${CODEX_HOME:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.codex"
echo 'esc to interrupt'
exec "$BIN/processes/codex" 100000
STUB
chmod +x "$BIN/claude" "$BIN/codex"
cat > "$BIN/kendex" <<'STUB'
#!/bin/sh
case "$1" in
  list)
    [ "${FIXTURE_HOOK_STATE:-enabled}" != fail ] || { echo 'fixture inventory unread' >&2; exit 3; }
    [ "${FIXTURE_HOOK_STATE:-enabled}" != missing ] || exit 0
    # The hook is the install of one checkout: asked from anywhere else,
    # kendex lists none of it.
    [ -z "${FIXTURE_HOOK_DIR:-}" ] || [ "$(pwd -P)" = "$FIXTURE_HOOK_DIR" ] || exit 0
    # kendex's current name column: event, matcher and the hook's own name.
    printf 'hook Stop:*:lane-mail-check %s project' "$3" >&2
    [ "${FIXTURE_HOOK_STATE:-enabled}" != disabled ] || printf ' switched off' >&2
    printf '\n' >&2
    ;;
  hooks-off) printf '{"switched_off_by":null}\n' ;;
  tier-model) exec "$0-tier-model" "$@" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/kendex"
ln -s "$TEST_DIR/fixtures/tier-model/kendex" "$BIN/kendex-tier-model"
# Repository lookup belongs to the fixture. With no answer, the existing
# directory fallback case remains independent of credentials and network.
cat > "$BIN/gh" <<'STUB'
#!/bin/sh
[ "$*" = 'repo view --json nameWithOwner -q .nameWithOwner' ] || exit 2
[ -n "${FIXTURE_REPO:-}" ] || exit 1
printf '%s\n' "$FIXTURE_REPO"
STUB
chmod +x "$BIN/gh"
# A pane whose foreground process names claude, for `register` to read the
# harness off: a copy of sleep, since a script or a shell named for the
# harness can reset the process name tmux reads.
cp "$(command -v sleep)" "$BIN/hclaude"

new_home fleet
make_lane "$H" claude
make_lane "$H" eclaude
make_codex_lane "$H/.codex"
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"

fixture_server_allocate default default initial
fixture_server_start
KEEP_WINDOW="$(tm display-message -p -t fleet:0 '#{window_id}')"
tm set-option -g renumber-windows off
SERVER_PID="$(tm display-message -p '#{pid}')"
SERVER_START="$(tm display-message -p '#{start_time}')"
SOCKET="$TMUX_DIR/tmux-$(id -u)/default"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"

# run_oversee ENV=VAL... -- ARGS... — the script under an explicit, whole
# environment with no $TMUX, from the work directory workflow-state resolves
# `tmp` under, or from RUN_DIR where a row sets it. ORCH_OVERSEER_PREFERENCE is
# claude:fable:high, or LAUNCH_PREF where a row sets it, `unset` exporting none.
# Sets OUT (both streams) and RC.
run_oversee() {
  fixture_watch_neighbor "${OVERSEE_BIN:-$OVERSEE}"
  tm set-environment -g ORCH_STATE_DIR "${RUN_DIR:-$TMP_ROOT/work}/tmp"
  local env_args=() pref=(ORCH_OVERSEER_PREFERENCE="${LAUNCH_PREF:-claude:fable:high}")
  [[ "${LAUNCH_PREF:-}" != unset ]] || pref=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  rm -f "${TMP_ROOT:?}"/argv.*
  RC=0
  OUT="$(cd "${RUN_DIR:-$TMP_ROOT/work}" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" \
    ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude:$H/.eclaude" ORCH_LANES_USAGE_TTL=0 \
    ${pref[@]+"${pref[@]}"} ORCH_TMUX_SESSION=fleet \
    ${env_args[@]+"${env_args[@]}"} "${OVERSEE_BIN:-$OVERSEE}" "$@" 2>&1 </dev/null)" || RC=$?
  fixture_watch_stop "${RUN_DIR:-$TMP_ROOT/work}/tmp/workflow-state-oversee.json"
  [[ "${RUN_DIR:-$TMP_ROOT/work}" == "$TMP_ROOT/work" ]] || fixture_watch_stop "$TMP_ROOT/work/tmp/workflow-state-oversee.json"
}
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
recorded() { jq -r ".overseer.$1 // \"none\"" "$FLEET_STATE" 2>/dev/null || echo unreadable; }
keyed() { awk -v k="oversee: $1" 'index($0, k) == 1 { found = 1 } found' <<<"$2"; }
# first_line — OUT's first line, kendex's model-resolution warning passed
# over: it precedes any refusal of a launch that classified a model.
first_line() { sed -n '/^model-resolution: /!{p;q;}' <<<"$OUT"; }
field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$(sed -n 1p <<<"$1")"; }
layout() { tm list-windows -t fleet -F '#{window_id} #{window_index} #{window_name}' | awk -v keep="$KEEP_WINDOW" '$1 != keep { print $2, $3 }' | tr '\n' ';'; }
overseers() { tm list-windows -t fleet -F '#{window_name}' | awk '$0 == "overseer"' | wc -l | tr -d ' '; }
listed() { tm list-panes -a -F '#{pane_id}' | grep -cxF -- "$1" || true; }
recorded_argv() { if [[ -f "$TMP_ROOT/argv.claude" ]]; then tr '\n' ';' < "$TMP_ROOT/argv.claude"; else printf 'none'; fi; }
BRIEF='Read .agents/skills/orch/SKILL.md and follow .agents/skills/orch/workflows/oversee-takeover.md with the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'

echo "=== oversee ==="

# A first launch from outside tmux: the window at the end of the named
# session, the harness on the picked lane with the entry's model and effort
# and claude's full-bypass, compaction and question-tool words, and the record written
# with generation 1.
run_oversee -- launch --wait-secs 20
LAUNCHED="$(keyed overseer-launched "$OUT" | sed -n 1p)"
SESSION="$(field "$LAUNCHED" session)"
assert_eq "$RC|$(sed -n 's/window=@[0-9]*/window=@N/; s/session=%[0-9]*/session=%N/p' <<<"$LAUNCHED")|$(layout)|$(recorded_argv)" \
  "0|oversee: overseer-launched session=%N window=@N server=$SOCKET generation=1 lane=$H/.claude|0 overseer;|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$BYPASS;$COMPACT;$QUESTION_OFF;$BRIEF;" \
  "a first launch from outside tmux opens the overseer at the base index and records it"
assert_eq "$(recorded runtime)|$(recorded server)|$(recorded server_start)|$(recorded pane)|$(recorded window)|$(recorded account)|$(recorded generation)|$(recorded launch_line)" \
  "tmux|$SERVER_PID|$SERVER_START|$SESSION|$(tm display-message -p -t "$SESSION" '#{window_id}')|$H/.claude|1|$SCRUB_ENV CLAUDE_CONFIG_DIR='$H/.claude' CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT=1 CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1 claude -n overseer --model fable --effort high $BYPASS $(printf '%q' "$COMPACT") $(printf '%q' "$QUESTION_OFF") '$BRIEF'" \
  "the session record names the runtime, server and its start, pane, window, account, line and generation"
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
assert_eq "$RC|$(first_line)|$(overseers)|$(recorded generation)" \
  "1|oversee: overseer-live session=$SESSION server=$SOCKET generation=1|1|1" \
  "a launch beside a live recorded overseer refuses naming it and opens nothing"
# A record carrying no server start, the shape a writer that recorded none
# left, names no session, but its pane live on the recorded server pid may be
# the running overseer, so the launch refuses rather than open a second one.
cp -- "$FLEET_STATE" "$TMP_ROOT/state.live"
jq 'del(.overseer.server_start)' "$TMP_ROOT/state.live" > "$FLEET_STATE" || exit 1
run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(first_line)|$(overseers)|$(recorded generation)" \
  "1|oversee: overseer-live session=$SESSION server=$SOCKET generation=1|1|1" \
  "a launch beside a live pane a record with no server start names refuses and opens nothing"
# Yet that record names no predecessor: its pane may be one a later server
# handed the same pid and pane id, so --predecessor on it refuses and the
# succession stops nothing.
run_oversee -- launch --predecessor "$SESSION" --wait-secs 20
assert_eq "$RC|$(first_line)|$(overseers)|$(listed "$SESSION")|$(recorded generation)" \
  "1|oversee: predecessor-not-live session=$SESSION live=none server=$SOCKET|1|1|1" \
  "a --predecessor naming the live pane a record with no server start names is refused and left running"
mv -- "$TMP_ROOT/state.live" "$FLEET_STATE"
# A tmux that answers every call but the server start read
# (lib/tmux-server.sh § tmux_server_start) of the pane the nostart-pane file
# names, for the rows where that read fails.
NOSTART_BIN="$TMP_ROOT/nostart-bin"
mkdir -p "$NOSTART_BIN"
REAL_TMUX="$(command -v tmux)"
cat > "$NOSTART_BIN/tmux" <<STUB
#!/bin/sh
pane="\$(cat '$TMP_ROOT/nostart-pane')"
start=0 target=0
for a in "\$@"; do
  [ "\$a" = '#{pid} #{start_time}' ] && start=1
  [ "\$a" = "\$pane" ] && target=1
done
[ "\$start\$target" = 11 ] && exit 1
exec '$REAL_TMUX' "\$@"
STUB
chmod +x "$NOSTART_BIN/tmux"
NOSTART_PATH="$NOSTART_BIN:$BIN:$PATH"
printf '%s\n' "$SESSION" > "$TMP_ROOT/nostart-pane"
# A live recorded pane whose server start cannot be read may be that
# overseer, so the launch refuses rather than open a second one beside it.
run_oversee PATH="$NOSTART_PATH" -- launch --wait-secs 20
assert_eq "$RC|$(first_line)|$(overseers)|$(recorded generation)" \
  "1|oversee: launch-failed step=server-start session=$SESSION server=$SOCKET|1|1" \
  "a launch beside a live recorded pane whose server start cannot be read refuses and opens nothing"
# The overseer stopped: the next launch takes the next generation.
tm kill-window -t "$SESSION"
run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(field "$(keyed overseer-launched "$OUT" | sed -n 1p)" generation)|$(recorded generation)|$(overseers)" \
  "0|2|2|1" \
  "a launch after the recorded overseer's session is gone opens the next generation"
tm kill-window -t "$(recorded window)"

# A launch whose session never works: closed, the prior record put back.
touch "$TMP_ROOT/idle"
run_oversee -- launch --wait-secs 2
rm -f "$TMP_ROOT/idle"
assert_eq "$RC|$(keyed overseer-not-working "$OUT" | sed -n 1p | sed 's/session=%[0-9]*/session=%N/; s/waited=[0-9]*/waited=N/')|$(grep -c 'FIXTURE overseer startup waiting' <<<"$OUT")|$(overseers)|$(recorded generation)" \
  "1|oversee: overseer-not-working session=%N waited=N|1|0|2" \
  "a session that never shows a working turn is closed and the record put back"

# No configured session: the repository name is the default, not tmux's current.
RUN_DIR="$TMP_ROOT/fleet"
mkdir -p "$RUN_DIR"
PRIOR_FLEET_STATE="$FLEET_STATE"
FLEET_STATE="$RUN_DIR/tmp/workflow-state-oversee.json"
run_oversee ORCH_TMUX_SESSION= -- launch --wait-secs 20
DEFAULT_SESSION="$(recorded pane)"
assert_eq "$RC|$(tm display-message -p -t "$DEFAULT_SESSION" '#{session_name} #{window_index} #{window_name}')" \
  "0|fleet 0 overseer" "an unresolved repository falls back to the checkout directory at the base index"
tm kill-window -t "$DEFAULT_SESSION"
# Issue worktrees have directory names different from the repository slug.
RUN_DIR="$TMP_ROOT/issue-worktree"
mkdir -p "$RUN_DIR"
git -C "$RUN_DIR" init -q
git -C "$RUN_DIR" config gc.auto 0
git -C "$RUN_DIR" config maintenance.auto false
FLEET_STATE="$RUN_DIR/tmp/workflow-state-oversee.json"
run_oversee ORCH_TMUX_SESSION= FIXTURE_REPO=owner/fleet -- launch --wait-secs 20
DEFAULT_SESSION="$(recorded pane)"
assert_eq "$RC|$(tm display-message -p -t "$DEFAULT_SESSION" '#{session_name} #{window_index} #{window_name}')" \
  '0|fleet 0 overseer' "a resolved repository selects its named session rather than the issue directory"
tm kill-window -t "$DEFAULT_SESSION"
RUN_DIR=""
FLEET_STATE="$PRIOR_FLEET_STATE"

# The refusals before anything opens.
for row in \
  "ORCH_OVERSEER_PREFERENCE=|preference-empty setting=ORCH_OVERSEER_PREFERENCE|an empty preference" \
  "ORCH_OVERSEER_PREFERENCE=claude:Opus:high|invalid-preference entry=claude:Opus:high|an entry outside the shape" \
  "ORCH_TMUX_SESSION=|tmux-session-missing session=work server=$SOCKET|the default repository session is absent" \
  "ORCH_TMUX_SESSION=fleetz|tmux-session-missing session=fleetz server=$SOCKET|a session tmux does not hold" \
  "ORCH_OVERSEER_HOST=$TMP_ROOT/other|runtime-unsupported host=$TMP_ROOT/other|a runtime other than tmux" \
  "ORCH_OVERSEER_HEADROOM_PCT=101|invalid-headroom-trigger ORCH_OVERSEER_HEADROOM_PCT=101|a headroom trigger past 100" \
  ; do
  IFS='|' read -r row_env row_want row_what <<<"$row"
  run_oversee "$row_env" -- launch --wait-secs 5
  assert_eq "$RC|$(first_line)|$(overseers)" \
    "1|oversee: $row_want|0" \
    "$row_what: refused, nothing opened"
done
# A model kendex cannot classify refuses before anything opens, kendex's
# words after the keyed line.
mv -- "${BIN:?}/kendex-tier-model" "$BIN/kendex-tier-model.real"
printf '#!/bin/sh\necho "Error: invalid manifest" >&2\nexit 1\n' >"$BIN/kendex-tier-model"
chmod +x "$BIN/kendex-tier-model"
LAUNCH_PREF=claude:standard:high run_oversee -- launch --wait-secs 5
assert_eq "$RC|$(first_line)|$(tail -n 1 <<<"$OUT")|$(overseers)" \
  "1|oversee: preference-class-unread entry=claude:standard:high|Error: invalid manifest|0" \
  "a model kendex cannot classify: refused with kendex's words, nothing opened"
mv -f -- "${BIN:?}/kendex-tier-model.real" "$BIN/kendex-tier-model"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
run_oversee -- launch --wait-secs 5
assert_eq "$RC|$(first_line)|$(overseers)|$(grep -c 'class ladder' <<<"$OUT" || :)" \
  "3|oversee: no-lane-qualifies entries=1 walled=2 unmeasured=0|0|0" \
  "no lane above the trigger: refused at 3 with the walk's counts and no kendex words beside them"
# An overseer opens through overseer-host on this machine, under this machine's
# copy of the account, so the walk reads that copy even on a fleet whose
# provider reports the same account with room. Run from a repository of its
# own, since lane-host takes its project from the working directory.
HOSTED_WORK="$TMP_ROOT/hosted-work"
mkdir -p "$HOSTED_WORK/tmp"
git -C "$HOSTED_WORK" init -q -b main
printf 'account=%s\tharness=claude\tsession-5h-pct=5\tweekly-pct=5\tmodel-pct=5\tmodel-label=Fable 5.1\n' "$H/.claude" > "$TMP_ROOT/accounts-room.tsv"
HOSTED_ENV=(ORCH_LANE_HOST="$TEST_DIR/fixtures/lane-host" LANE_HOST_STUB_ACCOUNTS="$TMP_ROOT/accounts-room.tsv" LANE_HOST_STUB_LOG="$TMP_ROOT/host.log")
RUN_DIR="$HOSTED_WORK" run_oversee "${HOSTED_ENV[@]}" -- launch --wait-secs 5
assert_eq "$RC|$(first_line)|$(overseers)" \
  "3|oversee: no-lane-qualifies entries=1 walled=2 unmeasured=0|0" \
  "a provider row with room for an account this machine reads walled opens no overseer on it"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"

# A has-session answer that is not "can't find session" is the call failing,
# not a missing session: pointed at a TMUX_TMPDIR with no server running, the
# launch refuses tmux-failed naming that socket, not tmux-session-missing whose
# advice is to start the session.
EMPTY_TMUX="$TMP_ROOT/empty-tmux"
mkdir -p "$EMPTY_TMUX"
EMPTY_SOCKET="$EMPTY_TMUX/tmux-$(id -u)/default"
run_oversee TMUX_TMPDIR="$EMPTY_TMUX" -- launch --wait-secs 5
assert_eq "$RC|$(first_line)|$(overseers)" \
  "1|oversee: tmux-failed operation=has-session server=$EMPTY_SOCKET|0" \
  "launch against a socket with no server refuses tmux-failed, not a missing session"

# register: the record for a hand-opened pane, its generation one past the
# record's, kept where the record already names that pane.
HAND="$(tm new-window -d -t fleet:4 -n hand -P -F '#{pane_id}' "exec '$BIN/hclaude' 100000")"
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(first_line)|$(keyed registered "$OUT" | sed -n 1p)|$(recorded runtime)|$(recorded account)|$(recorded launch_line)|$(recorded server_start)" \
  "0|oversee: identity-fallback session=$HAND cause=no-start-row|oversee: registered session=$HAND window=$(tm display-message -p -t "$HAND" '#{window_id}') server=$SERVER_PID generation=3 account=$H/.eclaude retained=none fresh=account,cwd,generation,harness,home,pane,runtime,server,server_socket,server_start,session_rows,window|tmux|$H/.eclaude|none|$SERVER_START" \
  "register with no SessionStart row reads the pane as the named fallback, says so, writes the record one generation past it with its server's start, and drops the launch line the record held"
HAND_IDENTITY="claude|$H/.eclaude|$H/.eclaude|none|none|$(tm display-message -p -t "$HAND" '#{pane_current_path}')|"
assert_eq "$(identity)" "$HAND_IDENTITY" \
  "register records the harness the pane runs, its account and directory, and no model or effort"
# A server start that cannot be read writes nothing: a record with no start
# would name no session.
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
BOUND_RECORD="$(jq -c .overseer "$FLEET_STATE")"
printf '%s\n' "$HAND" > "$TMP_ROOT/nostart-pane"
run_oversee PATH="$NOSTART_PATH" TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(keyed record-unwritten "$OUT" | sed -n 1p)|$(jq -c .overseer "$FLEET_STATE")" \
  "1|oversee: record-unwritten field=overseer|$BOUND_RECORD" \
  "a register whose server start cannot be read refuses and leaves the record as it stood"
# register from the session's own SessionStart row (lib/session-rows.sh), in
# the shape Claude Code 2.1.283's hook emits it: the harness, account and
# model the row states, not the environment's, and the rows file recorded.
HAND_ROWS="$WORK_REAL/tmp/lane-mail/overseer/session-$SERVER_PID-${HAND#%}.jsonl"
mkdir -p "${HAND_ROWS%/*}"
hand_start_row() {
  jq -cn --arg account "$H/.claude" --arg cwd "$WORK_REAL" '{at: 1, event: "SessionStart",
    harness: "claude", session_id: "5f0c", transcript_path: "/t/5f0c.jsonl", cwd: $cwd,
    source: "startup", model: "claude-fable-5-1", account: $account}' > "$HAND_ROWS"
}
hand_start_row
cp -- "$FLEET_STATE" "$TMP_ROOT/state.before-row"
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | cut -d' ' -f1-2)|$(identity)$(recorded session_rows)" \
  "0|oversee: registered|claude|$H/.claude|$H/.claude|claude-fable-5-1|none|$WORK_REAL|$HAND_ROWS" \
  "register takes the identity its SessionStart row states and records the rows file"
mv -- "$TMP_ROOT/state.before-row" "$FLEET_STATE"
: > "$HAND_ROWS"
jq '.overseer.session_id = "before-resume"' "$FLEET_STATE" > "$TMP_ROOT/bound-before-resume"
mv -- "$TMP_ROOT/bound-before-resume" "$FLEET_STATE"
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" -- register --account "$H/.claude"
assert_eq "$(recorded session_id)" none 'register in the same pane clears the native binding for a resumed session'
BINDINGCTL="$(mutant_scripts bindingctl lib/overseer-launch.sh)" || exit 1
mutate_file "$BINDINGCTL/lib/overseer-launch.sh" 'del(.pending, .exit, .session_id)' 'del(.pending, .exit)'
jq '.overseer.session_id = "before-resume"' "$FLEET_STATE" > "$TMP_ROOT/bound-before-resume"
mv -- "$TMP_ROOT/bound-before-resume" "$FLEET_STATE"
OVERSEE_BIN="$BINDINGCTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" -- register --account "$H/.claude"
assert_eq "$(recorded session_id)" before-resume 'control: retaining the old native binding fails the register reset assertion'
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" -- register --account "$H/.claude"
assert_eq "$RC|$(recorded generation)|$(recorded account)" \
  "0|3|$H/.claude" \
  "registering the same pane again keeps its generation and takes --account"
run_oversee -- register
assert_eq "$RC|$(first_line)" \
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
  "0|4|absent|$WORK_REAL" \
  "launch --cwd from outside the fleet directory records into that directory's state and starts there"
tm kill-window -t "$(recorded window)"

# ORCH_QUESTION_TOOL=overseer keeps the overseer's question tool: the launch
# line carries no question-off word. With the default-off rows above, a
# launcher that stops reading the setting fails one side.
run_oversee ORCH_QUESTION_TOOL=overseer -- launch --wait-secs 20
assert_eq "$RC|$(recorded_argv)" \
  "0|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$BYPASS;$COMPACT;$BRIEF;" \
  "ORCH_QUESTION_TOOL=overseer launches the overseer with its question tool"
tm kill-window -t "$(recorded window)"

# A fleet whose settings name no preference: the first launch walks the default
# order and opens on its standard Opus alias.
LAUNCH_PREF=unset run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(recorded model)|$(recorded class)|$(recorded_argv)" \
  "0|opus|standard|lane=$H/.claude;-n;overseer;--model;opus;--effort;high;$BYPASS;$COMPACT;$QUESTION_OFF;$BRIEF;" \
  "an unset preference launches the first overseer on the standard class, Opus, and records both"
tm kill-window -t "$(recorded window)"
DEFAULTCTL="$(mutant_scripts defaultctl lib/overseer-launch.sh)" || exit 1
mutate_file "$DEFAULTCTL/lib/overseer-launch.sh" \
  'OL_DEFAULT_PREFERENCE="claude:standard:high,codex:standard:high"' 'OL_DEFAULT_PREFERENCE="claude:light:high,codex:standard:high"'
OVERSEE_BIN="$DEFAULTCTL/oversee" LAUNCH_PREF=unset run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(recorded model)|$(recorded_argv)" \
  "0|sonnet|lane=$H/.claude;-n;overseer;--model;sonnet;--effort;high;$BYPASS;$COMPACT;$QUESTION_OFF;$BRIEF;" \
  "control: the Sonnet default breaks the unset launch's Opus contract"
control_status=0
(FAIL=0; assert_eq "$(recorded model)" opus "unset launch model"; [[ "$FAIL" -eq 0 ]]) \
  > "$TMP_ROOT/default-control.log" || control_status=$?
assert_eq "$control_status" 1 "control: the Opus assertion rejects the Sonnet launch"
tm kill-window -t "$(recorded window)"

# A pi entry ahead of a claude entry with room: the launch table names no
# permission word to open pi unattended, so the first launch skips it before
# its pick and opens on the claude entry.
pi_first_row() { # [OVERSEE_BIN]
  OVERSEE_BIN="${1:-}" LAUNCH_PREF='pi:openai/gpt-5:high,claude:fable:high' run_oversee -- launch --wait-secs 20
  assert_eq "$RC|$(keyed entry-permission-unwritable "$OUT" | sed -n 1p)|$(recorded harness)|$(recorded model)" \
  "0|oversee: entry-permission-unwritable entry=pi:openai/gpt-5:high harness=pi|claude|fable" \
  "a first launch skips a pi entry and opens on the claude entry after it"
}
pi_first_row
tm kill-window -t "$(recorded window)"
# Its control bypasses eligibility and must fail the same skip assertion.
PIFIRSTCTL="$(mutant_scripts pifirstctl lib/overseer-launch.sh)" || exit 1
mutate_file "$PIFIRSTCTL/lib/overseer-launch.sh" '    [[ "$posture" != no-word ]] && launch_choice_permission_write "$OL_HARNESS" >/dev/null && return 0' '    return 0'
PIFIRST_SAVED_FAIL="$FAIL"; FAIL=0
pi_first_row "$PIFIRSTCTL/oversee" > "$TMP_ROOT/pi-first-control.out"
PIFIRST_CONTROL="$FAIL"; FAIL="$PIFIRST_SAVED_FAIL"
assert_eq "$PIFIRST_CONTROL" 1 "control: bypassing eligibility fails the first-launch skip assertion"
[[ "$RC" != 0 ]] || tm kill-window -t "$(recorded window)"

# A first launch on a copilot entry: `lanes pick --harness copilot` judges a
# Copilot account on its monthly pool, so the overseer opens on the account
# the pick names, under COPILOT_HOME, with the model and effort the entry
# names and copilot's full-bypass word. The installed extension records the
# overseer's context reading.
cat > "$BIN/copilot" <<STUB
#!/bin/sh
{ printf 'home=%s\n' "\${COPILOT_HOME:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.copilot"
echo 'esc to interrupt'
exec "$BIN/processes/copilot" 100000
STUB
chmod +x "$BIN/copilot"
mkdir -p "$H/.1copilot"
printf '{"copilot_tokens":"gho_fixture"}\n' > "$H/.1copilot/config.json"
printf '{}\n' > "$H/.1copilot/settings.json"
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":900}}}' > "$FIXTURE_DIR/.1copilot.json"
copilot_first_row() { # [OVERSEE_BIN]
  OVERSEE_BIN="${1:-}" LAUNCH_PREF='copilot:gpt-5.3-codex:high' \
    run_oversee ORCH_LANE_DIRS="$H/.claude:$H/.eclaude:$H/.1copilot" -- launch --wait-secs 20
}
copilot_first_row
assert_eq "$RC|$(recorded harness)|$(recorded account)|$(recorded model)|$(recorded effort)|$(sed -n 1p "$TMP_ROOT/argv.copilot" 2>/dev/null)|$(grep -cx -e --model -e gpt-5.3-codex -e --reasoning-effort -e high -e "$(launch_choice_permission_write copilot)" "$TMP_ROOT/argv.copilot" 2>/dev/null)" \
  "0|copilot|$H/.1copilot|gpt-5.3-codex|high|home=$H/.1copilot|5" \
  "a first launch on a copilot entry opens on the picked copilot account with its model and effort"
copilot_context_flow "$TMP_ROOT/work" "$H" "$H/.1copilot" "$SRC_DIR" \
  TMUX="$TMUX_ADDR" TMUX_PANE="$(recorded pane)" TMUX_TMPDIR="$TMUX_DIR" \
  ORCH_LANES_FETCH_CMD="$FETCHER" FIXTURE_DIR="$FIXTURE_DIR"
assert_eq "$FLOW_RECORD|$(jq -r '.decision' <<<"$FLOW_STOP")|$(sed -n 's/^oversee-succeed: mark-reached kind=\([^ ]*\).*/\1/p' <<<"$FLOW_VERDICT")" \
  '199000:217600|block|context' "oversee launch records the first turn and the real judge reaches succession"
rm -rf -- "${H:?}/.1copilot/extensions"
# A hand-opened Copilot session can lack both supported context readers.
printf '{}\n' > "$H/.1copilot/settings.json"
copilot_context_flow "$TMP_ROOT/work" "$H" "$H/.1copilot" "$SRC_DIR" \
  TMUX="$TMUX_ADDR" TMUX_PANE="$(recorded pane)" TMUX_TMPDIR="$TMUX_DIR" \
  ORCH_LANES_FETCH_CMD="$FETCHER" FIXTURE_DIR="$FIXTURE_DIR"
assert_eq "$(jq -r '.additionalContext | split("\n")[0] | startswith("lane-mail-check: context-reader=missing ")' <<<"$FLOW_START")" \
  true "SessionStart reports the fleet overseer's missing reader as context without a mailbox file"
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
# The successor-up wait asks for a working turn: a SessionStart row is written
# at startup, before any turn runs, so a session whose screen never shows one
# is refused whatever rows it wrote.
tm kill-window -t "$(recorded window)"
touch "$TMP_ROOT/idle" "$TMP_ROOT/row"
run_oversee -- launch --wait-secs 3
rm -f "$TMP_ROOT/idle" "$TMP_ROOT/row"
assert_eq "$RC|$(keyed overseer-not-working "$OUT" | sed -n 1p | cut -d' ' -f1-2)|$(overseers)" \
  "1|oversee: overseer-not-working|0" \
  "a session whose SessionStart row stands and whose turn never runs is refused"
run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(keyed overseer-launched "$OUT" | sed -n 1p | cut -d' ' -f1-2)|$(overseers)" \
  "0|oversee: overseer-launched|1" \
  "a session whose turn runs is up"
# The launch line runs under overseer-run: a harness that ends, here killed
# before any hook of its own could run, leaves its exit status on the record.
harness_ended() { # -> the recorded exit status, once overseer-run wrote one
  local run_pid harness_pid waited=0
  run_pid="$(pgrep -P "$(tm display-message -p -t "$(recorded pane)" '#{pane_pid}')")" || return 1
  harness_pid="$(pgrep -P "$run_pid")" || return 1
  harness_pid="${harness_pid%%$'\n'*}"
  kill -TERM "$harness_pid"
  # A real wait: the wrapper writes the record after its child is reaped.
  until [[ "$(recorded exit.status)" != none || "$waited" -ge 50 ]]; do sleep 0.1; waited=$((waited + 1)); done
  recorded exit.status
}
assert_eq "$(harness_ended)|$(recorded exit.at | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" "143|1" \
  "a harness that ends leaves its exit status and time on the session record"
tm kill-window -t "$(recorded window)"
# register on a Copilot pane. Its command reads node, the npm loader, here a
# copy of bash under that name whose child carries Copilot's Linux name,
# MainThread, a copy of sleep. The account is --account's, else the
# COPILOT_HOME that process was started with, never the Claude or Codex
# variable the session happens to carry.
CP="$TMP_ROOT/copilot-bin"
mkdir -p "$CP"
cp "$(command -v bash)" "$CP/node"
cp "$(command -v bash)" "$CP/wrap"
cp "$(command -v sleep)" "$CP/MainThread"
printf '%s\n' "'$CP/MainThread' 100000; :" > "$CP/binary.sh"
printf '%s\n' "'$CP/wrap' '$CP/binary.sh'; :" > "$CP/tool.sh"
printf '%s\n' "'$CP/wrap' '$CP/tool.sh'; :" > "$CP/deep.sh"
# copilot_pane NAME PROGRAM SCRIPT — a pane whose own process is PROGRAM
# running SCRIPT.
copilot_pane() { tm new-window -d -t "fleet:$1" -n "cp$1" -P -F '#{pane_id}' "export COPILOT_HOME='$H/.1copilot'; exec '$CP/$2' '$CP/$3'"; }
COPILOT_PANE="$(copilot_pane 7 node binary.sh)"
# A Claude overseer behind a wrapper with a Copilot run under it: the pane
# reads wrap, which names no harness and is no Copilot pane.
WRAPPED_PANE="$(copilot_pane 8 wrap binary.sh)"
# A Codex overseer's pane also reads node, and a Copilot run it starts sits
# three levels down, under its tool shell.
DEEP_PANE="$(copilot_pane 9 node deep.sh)"
# A second Copilot pane, which no record has ever named.
FRESH_PANE="$(copilot_pane 10 node binary.sh)"
register_on() { # PANE [OVERSEE_BIN] [ARGS...]
  local pane="$1" bin="${2:-}"
  shift 2
  # Identity cases do not claim a second overseer while its holder runs.
  if [[ "$(recorded pane)" != "$pane" ]]; then
    jq '.overseer.server_start = 0' "$FLEET_STATE" > "$FLEET_STATE.identity"
    mv -- "$FLEET_STATE.identity" "$FLEET_STATE"
  fi
  OVERSEE_BIN="$bin" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$pane" CLAUDE_CONFIG_DIR="$H/.claude" -- register "$@"
}
# A real wait: each pane's program starts its children a moment after the
# window opens, and the process read must find them there.
sleep 0.5
rm -rf -- "${H:?}/.1copilot/extensions" "${TMP_ROOT:?}/work/.github"
printf '{}\n' > "$H/.1copilot/settings.json"
register_on "$COPILOT_PANE" '' --account "$H/.1copilot"
assert_eq "$(grep -c '^oversee: turn-end-hook=missing harness=copilot .*fix=' <<<"$OUT")|$(grep -c '^oversee: context-reader=next-start ' <<<"$OUT")" '1|1' \
  "register warns about absent Copilot coverage and the next-start reader"
# Registration configures the running home's reader. The next session start
# loads it, then its first turn end uses the real succession judge.
copilot_context_flow "$TMP_ROOT/work" "$H" "$H/.1copilot" "$SRC_DIR" \
  TMUX="$TMUX_ADDR" TMUX_PANE="$COPILOT_PANE" TMUX_TMPDIR="$TMUX_DIR" \
  ORCH_LANES_FETCH_CMD="$FETCHER" FIXTURE_DIR="$FIXTURE_DIR"
assert_eq "$FLOW_RECORD|$(jq -r '.decision' <<<"$FLOW_STOP")" '199000:217600|block' \
  "registered Copilot loads the reader at the next start and records its first turn"
rm -f -- "$TMP_ROOT/work/tmp/lane-mail/overseer/session-$SERVER_PID-${COPILOT_PANE#%}.jsonl"
assert_eq "$RC|$(recorded harness)|$(recorded account)|$(recorded home)" \
  "0|copilot|$H/.1copilot|$H/.1copilot" \
  "register on a copilot pane records harness copilot, read off the process under it, on --account"
register_on "$COPILOT_PANE" ''
assert_eq "$RC|$(recorded harness)|$(recorded account)|$(recorded home)" \
  "0|copilot|$H/.1copilot|$H/.1copilot" \
  "register on the same copilot pane with no --account keeps its proven account, never the claude one its session carries"
# A host with no per-process environment to read names the harness and no
# account (lib/lane-context.sh § lane_context_pane_shape).
FRESH_ACCOUNT=none
! lane_process_env_readable || FRESH_ACCOUNT="$H/.1copilot"
register_on "$FRESH_PANE" ''
assert_eq "$RC|$(recorded pane)|$(recorded harness)|$(recorded account)" "0|$FRESH_PANE|copilot|$FRESH_ACCOUNT" \
  "register on a copilot pane no record names, with no --account, records the account its Copilot process runs on"
register_on "$WRAPPED_PANE" ''
assert_eq "$RC|$(recorded harness)" "0|none" \
  "a pane reading neither node nor copilot is no copilot pane, whatever runs under it"
register_on "$DEEP_PANE" ''
assert_eq "$RC|$(recorded harness)" "0|none" \
  "a node pane whose Copilot run sits three levels down is not a copilot pane"
# A running home whose EXTENSIONS flag is false and that sets no statusLine
# takes no reader: register warns and still records the session.
cp -- "$H/.1copilot/settings.json" "$TMP_ROOT/settings.before-disabled"
printf '{"enabledFeatureFlags":{"EXTENSIONS":false}}\n' > "$H/.1copilot/settings.json"
register_on "$COPILOT_PANE" '' --account "$H/.1copilot"
assert_eq "$RC|$(grep -c '^oversee: context-reader=missing .*detail=disabled ' <<<"$OUT")|$(recorded pane)|$(recorded harness)|$(recorded account)" \
  "0|1|$COPILOT_PANE|copilot|$H/.1copilot" \
  "register on a copilot home with extensions off and no statusLine warns context-reader=missing and records the session"
mv -- "$TMP_ROOT/settings.before-disabled" "$H/.1copilot/settings.json"
# A Copilot overseer's own SessionStart row, written by session-start-row
# from Copilot's camelCase payload, names the account its session runs under,
# its COPILOT_HOME: register with no --account takes it, in a pane that reads
# no Copilot process, and installs the context reader in that home.
rm -rf -- "${H:?}/.1copilot/extensions"
jq -cn --arg account "$H/.1copilot" --arg cwd "$WORK_REAL" '{at: 1, event: "SessionStart",
  harness: "copilot", session_id: "c0p1", transcript_path: "/t/c0p1/events.jsonl", cwd: $cwd,
  account: $account}' > "$HAND_ROWS"
cp -- "$FLEET_STATE" "$TMP_ROOT/state.before-copilot-row"
register_on "$HAND" ''
assert_eq "$RC|$(identity)|$(grep -c '^oversee: context-reader=next-start ' <<<"$OUT" || true)" \
  "0|copilot|$H/.1copilot|$H/.1copilot|none|none|$WORK_REAL||1" \
  "register takes a Copilot overseer's account from its SessionStart row and installs the context reader there"
mv -- "$TMP_ROOT/state.before-copilot-row" "$FLEET_STATE"
: > "$HAND_ROWS"

# A hand-opened pane with no SessionStart hook, whose current command names
# no harness, is register's fallback producer. Only the exact server, start
# and pane binding lets its unread identity and launch line survive.
UNNAMED_PANE="$(tm new-window -d -t fleet -n unnamed -P -F '#{pane_id}' 'exec sleep 100000')"
UNNAMED_CWD="$(tm display-message -p -t "$UNNAMED_PANE" '#{pane_current_path}')"
UNNAMED_LINE="env COPILOT_HOME='$H/.1copilot' copilot --model gpt-5.3-codex --reasoning-effort high"
cp -- "$FLEET_STATE" "$TMP_ROOT/state.before-preservation"
jq --arg server "$SERVER_PID" --argjson start "$SERVER_START" --arg pane "$UNNAMED_PANE" \
  --arg account "$H/.1copilot" --arg cwd "$UNNAMED_CWD" --arg line "$UNNAMED_LINE" \
  '.overseer = {runtime: "tmux", server: $server, server_start: $start, pane: $pane,
    generation: 20, harness: "copilot", account: $account, home: $account,
    model: "gpt-5.3-codex", effort: "high", cwd: $cwd, launch_line: $line,
    pending: {harness: "claude"}, exit: {status: 0}}' \
  "$FLEET_STATE" > "$TMP_ROOT/state.full"
for row in \
  "$SERVER_PID|$SERVER_START|$UNNAMED_PANE|copilot|gpt-5.3-codex|high|$UNNAMED_LINE|20|effort,harness,launch_line,model|same pane" \
  "$SERVER_PID|$SERVER_START|$COPILOT_PANE|none|none|none|none|21|none|different pane" \
  "1|$SERVER_START|$UNNAMED_PANE|none|none|none|none|21|none|different server" \
  "$SERVER_PID|$((SERVER_START - 3600))|$UNNAMED_PANE|none|none|none|none|21|none|different server start" \
  "$SERVER_PID|null|$UNNAMED_PANE|none|none|none|none|21|none|no server start"; do
  IFS='|' read -r prior_server prior_start prior_pane want_harness want_model want_effort want_line want_gen want_retained what <<<"$row"
  jq --arg server "$prior_server" --argjson start "$prior_start" --arg pane "$prior_pane" \
    '.overseer.server = $server | .overseer.server_start = $start | .overseer.pane = $pane' \
    "$TMP_ROOT/state.full" > "$FLEET_STATE"
  register_on "$UNNAMED_PANE" ''
  assert_eq "$RC|$(identity)$(recorded launch_line)|$(recorded generation)|$(recorded pending)|$(recorded exit)|$(field "$(keyed registered "$OUT")" retained)|$(field "$(keyed registered "$OUT")" fresh)" \
    "0|$want_harness|$H/.claude|$H/.claude|$want_model|$want_effort|$UNNAMED_CWD|$want_line|$want_gen|none|none|$want_retained|account,cwd,generation,home,pane,runtime,server,server_socket,server_start,session_rows,window" \
    "register with no start row over $what replaces proven fields and retains only that pane's unread fields"
done
mv -- "$TMP_ROOT/state.before-preservation" "$FLEET_STATE"
tm kill-window -t "$UNNAMED_PANE"

# --- a succession through the launch verb --------------------------------
# --predecessor names the live recorded overseer: the successor opens beside
# it, takes its window slot once its turn runs, and the record names it one
# generation on, with no pending successor left.
run_oversee -- launch --wait-secs 20
PRED="$(recorded pane)"
PRED_GEN="$(recorded generation)"
PRED_INDEX="$(tm show-options -Av -t fleet base-index)"
run_oversee -- launch --predecessor "$PRED" --wait-secs 20
SUCCEEDED="$(keyed overseer-launched "$OUT" | sed -n 1p)"
SUCC="$(field "$SUCCEEDED" session)"
assert_eq "$RC|$(sed 's/window=@[0-9]*/window=@N/; s/session=%[0-9]*/session=%N/' <<<"$SUCCEEDED")|$(overseers)|$(recorded pane)|$(recorded generation)|$(recorded pending)|$(tm display-message -p -t "$SUCC" '#{window_index}')|$(listed "$PRED")" \
  "0|oversee: overseer-launched session=%N window=@N server=$SOCKET generation=$((PRED_GEN + 1)) lane=$H/.claude predecessor=$PRED|1|$SUCC|$((PRED_GEN + 1))|none|$PRED_INDEX|0" \
  "a launch naming the live overseer as predecessor opens its successor at the base index, stops it and records the next generation"
# A predecessor other than the live recorded overseer is refused before
# anything opens, naming the live one, or none where none is recorded: a pane
# the fleet never recorded, which the succession would otherwise stop.
OTHER="$(tm new-window -d -t fleet -n other -P -F '#{pane_id}' 'exec sleep 100000')"
run_oversee -- launch --predecessor "$OTHER" --wait-secs 20
assert_eq "$RC|$(first_line)|$(overseers)" \
  "1|oversee: predecessor-not-live session=$OTHER live=$SUCC server=$SOCKET|1" \
  "a predecessor beside a live recorded overseer is refused naming the live one"
tm kill-window -t "$(recorded window)"
run_oversee -- launch --predecessor "$OTHER" --wait-secs 20
assert_eq "$RC|$(first_line)|$(overseers)|$(listed "$OTHER")" \
  "1|oversee: predecessor-not-live session=$OTHER live=none server=$SOCKET|0|1" \
  "a predecessor the fleet does not record as its live overseer is refused and left running"
tm kill-window -t "$OTHER"
run_oversee -- launch --session fleet --predecessor "$SUCC" --wait-secs 5
assert_eq "$RC|$(first_line)|$(overseers)" \
  "2|oversee: option-conflict command=launch session=fleet predecessor=$SUCC|0" \
  "--session beside --predecessor is refused, nothing opened"

# The successor is the record's pending member before its window opens, read
# here while a tmux on the run's PATH holds the successor's new-window until
# the row releases it, and gone with the abandoned launch, whose first turn
# never comes.
run_oversee -- launch --wait-secs 20
PRED="$(recorded pane)"
PRIOR_RECORD="$(jq -cS .overseer "$FLEET_STATE")"
PRIOR_LINE="$(recorded launch_line)"
HOLD_BIN="$TMP_ROOT/hold-create-bin"
mkdir -p "$HOLD_BIN"
cat > "$HOLD_BIN/tmux" <<STUB
#!/bin/sh
if [ "\$1" = new-window ]; then
  : > '$TMP_ROOT/create-held'
  while [ ! -e '$TMP_ROOT/create-released' ]; do sleep 0.1; done
fi
exec '$REAL_TMUX' "\$@"
STUB
chmod +x "$HOLD_BIN/tmux"
pending_seen() { # [OVERSEE_BIN] — the pending line a --predecessor launch writes
  local pid seen=none
  rm -f "$TMP_ROOT/create-held" "$TMP_ROOT/create-released"
  touch "$TMP_ROOT/idle"
  OVERSEE_BIN="${1:-}" run_oversee PATH="$HOLD_BIN:$BIN:$PATH" -- launch --predecessor "$PRED" --wait-secs 4 &
  pid=$!
  # A real wait, for the launch to reach the successor's new-window, where the
  # held tmux keeps it until the release below; a launch that ends first
  # never reached that point and leaves none read.
  while [[ ! -e "$TMP_ROOT/create-held" ]] && kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
  [[ ! -e "$TMP_ROOT/create-held" ]] || seen="$(recorded pending.launch_line)"
  touch "$TMP_ROOT/create-released"
  wait "$pid" || true
  rm -f "$TMP_ROOT/idle"
  PENDING_SEEN="$seen"
}
pending_seen
assert_eq "$PENDING_SEEN|$(jq -cS .overseer "$FLEET_STATE")|$(overseers)|$(listed "$PRED")|$(tm display-message -p -t "$PRED" '#{window_index}')" \
  "$PRIOR_LINE|$PRIOR_RECORD|1|1|0" \
  "a --predecessor launch records its successor as pending before it opens, and the abandoned launch puts the record back"
# A stop the host refuses at the commit point closes the successor and puts
# the record back: the predecessor keeps running and stays the recorded
# overseer, never two overseers and never a successor recorded beside it. A
# tmux on the run's PATH refuses the swap `stop --successor` makes.
STOP_BIN="$TMP_ROOT/stop-refused-bin"
mkdir -p "$STOP_BIN"
printf '#!/bin/sh\n[ "$1 $3" != "kill-window %s" ] || { echo "fixture: stop refused" >&2; exit 1; }\nexec %s "$@"\n' \
  "$(recorded window)" "$(command -v tmux)" > "$STOP_BIN/tmux"
chmod +x "$STOP_BIN/tmux"
stop_refused() { # [OVERSEE_BIN]
  PRED_GEN="$(recorded generation)"
  OVERSEE_BIN="${1:-}" run_oversee PATH="$STOP_BIN:$BIN:$PATH" -- launch --predecessor "$PRED" --wait-secs 20
}
stop_refused
assert_eq "$RC|$(keyed close-failed "$OUT" | sed -n 1p)|$(overseers)|$(listed "$PRED")|$(recorded pane)|$(recorded generation)|$(recorded pending)" \
  "1|oversee: close-failed predecessor=$PRED|1|1|$PRED|$PRED_GEN|none" \
  "a stop the host refuses closes the successor and keeps the predecessor running and recorded"
# A pending write the state refuses stops the succession before anything
# opens: the predecessor keeps running and stays the recorded overseer.
pendfail_stub() { # SCRIPTS_DIR — a workflow-state there that refuses the pending write
  rm -f -- "${1:?}/workflow-state"
  cat > "$1/workflow-state" <<STUB
#!/usr/bin/env bash
if [[ "\${BASH_SOURCE[0]}" != "\$0" ]]; then source "$SRC_DIR/workflow-state"; return \$?; fi
[[ "\$1 \$2 \$4 \$5 \$6" != "update-report oversee --arg operation pending" ]] || { echo 'fixture: pending write refused' >&2; exit 1; }
exec "$SRC_DIR/workflow-state" "\$@"
STUB
  chmod +x "$1/workflow-state"
}
pending_refused() { # OVERSEE_BIN
  PRED_GEN="$(recorded generation)"
  OVERSEE_BIN="$1" run_oversee -- launch --predecessor "$PRED" --wait-secs 20
}
PENDFAIL="$(mutant_scripts pendfail workflow-state)" || exit 1
pendfail_stub "$PENDFAIL"
pending_refused "$PENDFAIL/oversee"
assert_eq "$RC|$(first_line)|$(overseers)|$(listed "$PRED")|$(recorded pane)|$(recorded generation)" \
  "1|oversee: record-unwritten field=overseer step=pending|1|1|$PRED|$PRED_GEN" \
  "a pending write the state refuses stops the succession, the predecessor running and recorded"
# A session record write the state refuses refuses the launch too: the stub
# refuses the first write of the record and lets the put-back through. With
# --predecessor the predecessor keeps running and stays recorded.
recordfail_stub() { # SCRIPTS_DIR
  rm -f -- "${1:?}/workflow-state" "${TMP_ROOT:?}/record-refused"
  cat > "$1/workflow-state" <<STUB
#!/usr/bin/env bash
if [[ "\${BASH_SOURCE[0]}" != "\$0" ]]; then source "$SRC_DIR/workflow-state"; return \$?; fi
if [[ ( "\$1 \$2 \$3" == "set oversee overseer" || "\$1 \$2 \$4 \$5 \$6" == "update-report oversee --arg operation current" ) && ! -e "$TMP_ROOT/record-refused" ]]; then
  touch "$TMP_ROOT/record-refused"; echo 'fixture: record write refused' >&2; exit 1
fi
exec "$SRC_DIR/workflow-state" "\$@"
STUB
  chmod +x "$1/workflow-state"
}
RECFAIL="$(mutant_scripts recfail workflow-state)" || exit 1
recordfail_stub "$RECFAIL"
PRED_GEN="$(recorded generation)"
OVERSEE_BIN="$RECFAIL/oversee" run_oversee -- launch --predecessor "$PRED" --wait-secs 20
assert_eq "$RC|$(keyed record-unwritten "$OUT" | sed -n 1p)|$(overseers)|$(listed "$PRED")|$(recorded pane)|$(recorded generation)" \
  "1|oversee: record-unwritten field=overseer step=write|1|1|$PRED|$PRED_GEN" \
  "a record write the state refuses stops the succession, the predecessor running and recorded"
tm kill-window -t "$(recorded window)"
# A first launch under the same refusal opens no overseer and leaves the
# prior record in place.
FIRST_PRIOR="$(jq -cS .overseer "$FLEET_STATE")"
recordfail_stub "$RECFAIL"
OVERSEE_BIN="$RECFAIL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(keyed record-unwritten "$OUT" | sed -n 1p)|$(overseers)|$(jq -cS .overseer "$FLEET_STATE")" \
  "1|oversee: record-unwritten field=overseer step=write|0|$FIRST_PRIOR" \
  "a first launch whose record write the state refuses opens no overseer and keeps the prior record"

# A record from an earlier tmux server naming a pane id this server reuses is
# no live overseer: the launch opens the next generation over it, and a
# --predecessor naming that pane is refused, the pane left running. One row
# per way the record tells that server from this one: another server pid, and
# this pid bound to an earlier server's start, a server a restart handed the
# same pid.
STALE="$(tm new-window -d -t fleet -n stale -P -F '#{pane_id}' 'exec sleep 100000')"
EARLIER_START=$((SERVER_START - 3600))
stale_record() { # SERVER START
  jq --arg pane "$STALE" --arg server "$1" --arg start "$2" '.overseer.pane = $pane | .overseer.server = $server
    | .overseer.server_start = ($start | tonumber)' "$FLEET_STATE" > "$FLEET_STATE.tmp" \
    && mv -- "$FLEET_STATE.tmp" "$FLEET_STATE"
}
for row in "1|$SERVER_START|another server pid" "$SERVER_PID|$EARLIER_START|this server pid bound to an earlier start"; do
  IFS='|' read -r row_server row_start row_what <<<"$row"
  stale_record "$row_server" "$row_start"
  STALE_GEN="$(recorded generation)"
  run_oversee -- launch --predecessor "$STALE" --wait-secs 20
  assert_eq "$RC|$(first_line)|$(overseers)|$(listed "$STALE")" \
    "1|oversee: predecessor-not-live session=$STALE live=none server=$SOCKET|0|1" \
    "a --predecessor naming a pane an earlier server's record names by $row_what is refused and left running"
  run_oversee -- launch --wait-secs 20
  assert_eq "$RC|$(recorded generation)|$(overseers)|$(listed "$STALE")" \
    "0|$((STALE_GEN + 1))|1|1" \
    "a launch over an earlier server's record naming $row_what opens the next generation"
  tm kill-window -t "$(recorded window)"
done
tm kill-window -t "$STALE"

# A first launch on a codex entry: the entry's model and effort, codex's
# full-bypass words, its launch settings, its compaction words and its
# question-tool words, under a folder-trust home built in the account.
codex_usage() { # USED_PCT
  jq -n --argjson u "$1" '{rate_limit: {primary_window: {used_percent: $u, reset_at: 1785000000, limit_window_seconds: 18000}, secondary_window: null}}' \
    > "$FIXTURE_DIR/.codex.json"
}
codex_usage 20
LAUNCH_PREF=codex:gpt-5.6-sol:high run_oversee ORCH_LANE_DIRS="$H/.claude:$H/.eclaude:$H/.codex" -- launch --wait-secs 20
codex_words() { # the table's words for a codex launch, one per line
  printf '%s\n' -m gpt-5.6-sol -c model_reasoning_effort=high
  eval "printf '%s\n' $(launch_choice_permission_write codex)"
  printf '%s\n' $(launch_choice_row codex | cut -d'|' -f8) $(launch_choice_compaction_off codex) \
    $(launch_choice_question_off codex)
}
assert_eq "$RC|$(recorded harness)|$(recorded account)|$(sed -n 1p "$TMP_ROOT/argv.codex" | sed "s|^home=$H/.codex/.*|home=codex-account|")|$(sed 1d "$TMP_ROOT/argv.codex" | tr '\n' ';')" \
  "0|codex|$H/.codex|home=codex-account|$(codex_words | tr '\n' ';')$BRIEF;" \
  "a first launch on a codex entry carries the table's model, bypass, settings, compaction and question-tool words"
tm kill-window -t "$(recorded window)"

# Committed consumer settings still emit the numeric account form. Both
# launch verbs use the same-harness default preference model, under either
# account command form. Only the eclaude account has room in these rows.
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
for row in 'prefix|fresh' 'prefix|predecessor' 'launcher|fresh' 'launcher|predecessor'; do
  IFS='|' read -r form verb <<<"$row"
  if [[ "$form" == launcher ]]; then
    cat > "$BIN/eclaude" <<STUB
#!/bin/sh
export CLAUDE_CONFIG_DIR="$H/.eclaude"
exec "$BIN/claude" "\$@"
STUB
    chmod +x "$BIN/eclaude"
    want_form="launcher:$BIN/eclaude"
  else
    rm -f -- "$BIN/eclaude"
    want_form=prefix
  fi
  predecessor=()
  if [[ "$verb" == predecessor ]]; then
    run_oversee -- launch --wait-secs 20
    assert_eq "$RC" 0 "the numeric $form row has a live predecessor"
    predecessor=(--predecessor "$(recorded pane)")
  fi
  LAUNCH_PREF=claude:1:high run_oversee -- launch ${predecessor[@]+"${predecessor[@]}"} --wait-secs 20
  assert_eq "$RC|$(overseers)|$(recorded harness)|$(recorded account)|$(recorded model)|$(recorded effort)|$(recorded_argv)" \
    "0|1|claude|$H/.eclaude|opus|high|lane=$H/.eclaude;-n;overseer;--model;opus;--effort;high;$BYPASS;$COMPACT;$QUESTION_OFF;$BRIEF;" \
    "a numeric $verb preference uses the default preference model under $form"
  conversion="$(grep '^preference-deprecated-conversion ' <<<"$OUT")"
  assert_eq "$(grep -c '^preference-deprecated ' <<<"$OUT")|$(field "$conversion" entry)|$(field "$conversion" replacement)|$(field "$(keyed overseer-launch "$OUT")" form)" \
    "1|claude:1:high|claude:standard:high|$want_form" \
    "the numeric $verb warning names its conversion and the launch reports $form"
  tm kill-window -t "$(recorded window)"
done
rm -- "$BIN/eclaude"
# The migration diagnostic pairs the original consumer entry with its own
# conversion before an account or permission refusal can skip that entry.
for row in \
  'later-account|claude:1:high,codex:2:high|95|20|0|codex|claude:1:high|claude:standard:high|' \
  'all-walled|claude:1:high,codex:2:high|95|99|3|none|claude:1:high|claude:standard:high|' \
  'permission-skip|pi:1:high,claude:2:high|60|99|0|claude|pi:1:high||harness-default'; do
  IFS='|' read -r case_name preference claude_used codex_used expected_rc selected original replacement native_model <<<"$row"
  claude_usage "$claude_used" 20 5 Opus > "$FIXTURE_DIR/.claude.json"
  claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
  codex_usage "$codex_used"
  LAUNCH_PREF="$preference" run_oversee ORCH_LANE_DIRS="$H/.claude:$H/.eclaude:$H/.codex" -- launch --wait-secs 20
  conversion="$(grep '^preference-deprecated-conversion ' <<<"$OUT")"
  chosen_harness=none
  if [[ "$RC" == 0 ]]; then chosen_harness="$(recorded harness)"; fi
  assert_eq "$RC|$chosen_harness|$(grep -c '^preference-deprecated ' <<<"$OUT")|$(grep -c '^preference-deprecated-conversion ' <<<"$OUT")|$(field "$(grep '^preference-deprecated ' <<<"$OUT")" entry)|$(field "$conversion" entry)|$(field "$conversion" replacement)|$(field "$conversion" model)" \
    "$expected_rc|$selected|1|1|$original|$original|$replacement|$native_model" \
    "$case_name keeps the original and resolved conversion paired before the skip"
  if [[ "$RC" == 0 ]]; then tm kill-window -t "$(recorded window)"; fi
done
codex_usage 20
claude_usage 60 20 5 Opus > "$FIXTURE_DIR/.claude.json"
claude_usage 95 20 5 Opus > "$FIXTURE_DIR/.eclaude.json"
# A numeric Copilot entry has no same-harness default preference. It still
# launches with effort and permission words and reports the harness default.
LAUNCH_PREF=copilot:1:high run_oversee ORCH_LANE_DIRS="$H/.1copilot" -- launch --wait-secs 20
conversion="$(grep '^preference-deprecated-conversion ' <<<"$OUT")"
assert_eq "$RC|$(recorded harness)|$(recorded account)|$(recorded model)|$(recorded effort)|$(grep -cx -e --reasoning-effort -e high -e "$(launch_choice_permission_write copilot)" "$TMP_ROOT/argv.copilot")|$(grep -cxF -- --model "$TMP_ROOT/argv.copilot" || true)|$(field "$conversion" entry)|$(field "$conversion" harness)|$(field "$conversion" model)" \
  "0|copilot|$H/.1copilot|none|high|3|0|copilot:1:high|copilot|harness-default" \
  "a numeric Copilot preference launches and reports that the harness default model runs"
tm kill-window -t "$(recorded window)"
echo "=== the checkout a launch opens in ==="
# A clean checkout of the base branch one commit behind its origin starts the
# overseer at origin's head (lib/overseer-launch.sh § ol_checkout_sync).
work_head() { git -C "$TMP_ROOT/work" rev-parse HEAD; }
unsynced() { grep -c "^oversee: checkout-unsynced cause=$1 path=$WORK_REAL fix=[^ ]" <<<"$OUT" || true; }
# The fleet log rows naming CAUSE, each without the path the stderr line
# carries.
logged() {
  jq -r --arg key "oversee: checkout-unsynced cause=$1 " \
    '[(.fleet_log // [])[] | select((.text | startswith($key)) and (.text | contains(" path=") | not))] | length' "$FLEET_STATE"
}
WANT="$(checkout_advance)" || exit 1
checkout_started_clear
run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(work_head)|$(checkout_started)|$(unsynced '[^ ]*')" "0|$WANT|$WANT|0" \
  "a first launch fast-forwards a clean checkout behind origin to origin's head before it opens"
tm kill-window -t "$(recorded window)"
# A checkout the fast-forward refuses: the launch goes on, on the tree as it
# stands, with one keyed line naming the cause and its fix, and that line in
# the fleet log for the overseer to read. Each row sets its tree up, behind a
# fresh origin commit where it advances one, and puts it back after.
# base-mismatch is a local commit on a base origin has not moved: git's merge
# answers `Already up to date.` on stderr before sync-base's keyed line.
for row in \
  $'dirty\tcheckout_advance >/dev/null && printf "local\\n" >> "$TMP_ROOT/work/README"\tgit -C "$TMP_ROOT/work" checkout -q -- README' \
  $'fast-forward-failed\tcheckout_advance >/dev/null && checkout_commit "$TMP_ROOT/work" >/dev/null\tgit -C "$TMP_ROOT/work" reset -q --hard origin/main' \
  $'base-mismatch\tcheckout_commit "$TMP_ROOT/work" >/dev/null\tgit -C "$TMP_ROOT/work" reset -q --hard origin/main' \
  $'off-base\tcheckout_advance >/dev/null && git -C "$TMP_ROOT/work" switch -q -c side\tgit -C "$TMP_ROOT/work" switch -q main && git -C "$TMP_ROOT/work" branch -q -D side' \
  $'off-base\tcheckout_advance >/dev/null && git -C "$TMP_ROOT/work" switch -q --detach\tgit -C "$TMP_ROOT/work" switch -q main'; do
  IFS=$'\t' read -r cause setup restore <<<"$row"
  eval "$setup" || exit 1
  BEFORE="$(work_head)"
  LOGGED="$(logged "$cause")"
  run_oversee -- launch --wait-secs 20
  assert_eq "$RC|$(work_head)|$(unsynced "$cause")|$(unsynced '[^ ]*')|$(($(logged "$cause") - LOGGED))" "0|$BEFORE|1|1|1" \
    "a checkout refused as $cause ($setup) leaves the launch running and prints one keyed line naming the fix, also in the fleet log"
  tm kill-window -t "$(recorded window)"
  eval "$restore" || exit 1
done
# A sync-base that stalls past the bound, as one fetching from an origin that
# accepts the connection and never answers: the launch goes on, on the tree
# as it stands, with one keyed line naming the timeout. The stub sleeps 5
# seconds, the stall itself, which a 1 second bound cuts off.
STALL="$(mutant_scripts stall sync-base)" || exit 1
printf '#!/bin/sh\nsleep 5\n' > "$STALL/sync-base" || exit 1
BEFORE="$(work_head)"
LOGGED="$(logged sync-timeout)"
OVERSEE_BIN="$STALL/oversee" run_oversee ORCH_OVERSEER_SYNC_TIMEOUT_S=1 -- launch --wait-secs 20
assert_eq "$RC|$(overseers)|$(work_head)|$(unsynced sync-timeout)|$(unsynced '[^ ]*')|$(($(logged sync-timeout) - LOGGED))" \
  "0|1|$BEFORE|1|1|1" \
  "a sync-base that outlasts its bound leaves the launch running and prints one keyed line naming the timeout, also in the fleet log"
tm kill-window -t "$(recorded window)"
echo "=== register asks kendex's inventory for other harnesses ==="
# SessionStart is the producer of a harness other than the fallback's three.
# The inventory table comes from kendex, never a harness-specific hook file.
for harness in claude codex pi; do
  jq -cn --arg harness "$harness" --arg cwd "$WORK_REAL" --arg account "$H/.claude" \
    '{at:1,event:"SessionStart",harness:$harness,cwd:$cwd,account:$account}' > "$HAND_ROWS"
  for state in enabled missing disabled fail; do
    run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" FIXTURE_HOOK_STATE="$state" -- register
    want=1
    [[ "$state" != enabled ]] || want=0
    assert_eq "$RC|$(recorded harness)|$(grep -c '^oversee: turn-end-hook=missing .*fix=' <<<"$OUT" || true)" \
      "0|$harness|$want" "register $harness checks inventory state $state and still registers"
  done
done
# The start row's cwd is the session's working directory, which need not be
# the checkout whose install carries the hook: one outside it, one gone since.
# The inventory is the checkout's, so the installed hook reads present.
for row_cwd in "$TMP_ROOT" "$TMP_ROOT/gone"; do
  jq -cn --arg cwd "$row_cwd" --arg account "$H/.claude" \
    '{at:1,event:"SessionStart",harness:"claude",cwd:$cwd,account:$account}' > "$HAND_ROWS"
  run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" FIXTURE_HOOK_DIR="$WORK_REAL" -- register
  assert_eq "$RC|$(recorded cwd)|$(grep -c '^oversee: turn-end-hook=missing ' <<<"$OUT" || true)" "0|$row_cwd|0" \
    "register asks the checkout's inventory, not the start row's cwd $row_cwd, and finds the installed hook"
done
test_register_live_holder() {
  local holder candidate before
  cp -- "$FLEET_STATE" "$TMP_ROOT/register-live.saved"
  jq '.overseer = null' "$FLEET_STATE" > "$TMP_ROOT/register-live.state"
  mv -- "$TMP_ROOT/register-live.state" "$FLEET_STATE"
  holder="$(tm new-window -d -t fleet -n register-holder -P -F '#{pane_id}' 'exec sleep 100000')"
  candidate="$(tm new-window -d -t fleet -n register-candidate -P -F '#{pane_id}' 'exec sleep 100000')"
  run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$holder" -- register
  assert_eq "$RC|$(recorded pane)|$(recorded generation)" "0|$holder|1" "register records the first holder"
  before="$(cat "$FLEET_STATE")"
  run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$candidate" -- register
  assert_eq "$RC|$(field "$(keyed overseer-live "$OUT")" session)|$(field "$(keyed overseer-live "$OUT")" generation)|$(cat "$FLEET_STATE")" \
    "1|$holder|1|$before" "register refuses the live holder and leaves the whole state unchanged"
  run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$holder" -- register
  assert_eq "$RC|$(recorded pane)|$(recorded generation)" "0|$holder|1" "the recorded live pane registers again without a new generation"
  tm kill-pane -t "$holder"
  run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$candidate" -- register
  assert_eq "$RC|$(recorded pane)|$(recorded generation)" "0|$candidate|2" "register succeeds after the recorded pane ends"
  tm kill-pane -t "$candidate"
  mv -- "$TMP_ROOT/register-live.saved" "$FLEET_STATE"
}
test_register_live_holder

test_recorded_server() {
  local a_addr b_addr b_server holder candidate before verb mode="${1:-register}" decoy panes form snapshot fail_bin real_ps
  local a_name b_name a_socket b_socket side
  cp -- "$FLEET_STATE" "$TMP_ROOT/two-server.saved"
  for side in a b; do
    fixture_server_allocate "$side" "$mode" initial
    fixture_server_start
    if [[ "$side" == a ]]; then
      a_name="$FIXTURE_NAME" a_socket="$FIXTURE_SOCKET"
    else
      b_name="$FIXTURE_NAME" b_socket="$FIXTURE_SOCKET"
    fi
  done
  a_addr="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$a_name" display-message -p '#{socket_path},#{pid},0')"
  b_addr="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" display-message -p '#{socket_path},#{pid},0')"
  b_server="${b_addr#*,}" b_server="${b_server%%,*}"
  holder="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$a_name" display-message -p '#{pane_id}')"
  candidate="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" display-message -p '#{pane_id}')"
  assert_eq "$holder" "$candidate" "the two servers reuse the same pane id"
  jq '.overseer = null' "$FLEET_STATE" > "$TMP_ROOT/two-server.state"
  mv -- "$TMP_ROOT/two-server.state" "$FLEET_STATE"
  run_oversee TMUX="$a_addr" TMUX_PANE="$holder" -- "$mode" --wait-secs 20
  holder="$(recorded pane)"
  assert_eq "$RC|$(recorded server_socket)" "0|${a_addr%%,*}" "$mode stores the overseer's socket"
  before="$(cat "$FLEET_STATE")"
  if [[ "$mode" == launch ]]; then
    decoy="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" new-window -d -t fleet -n foreign-predecessor -P -F '#{pane_id}' 'exec sleep 100000')"
    assert_eq "$decoy" "$holder" "B's unrelated pane repeats A's launched overseer number"
    run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- launch --predecessor "$holder" --wait-secs 20
    panes="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" list-panes -a -F '#{pane_id}')"
    assert_eq "$RC|$(field "$(keyed predecessor-not-live "$OUT")" live)|$(cat "$FLEET_STATE")|$(grep -cxF -- "$decoy" <<<"$panes" || true)" \
      "1|none|$before|1" "a foreign recorded predecessor cannot authorize creation or stop on B"
  fi
  for verb in register launch; do
    run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- "$verb" --wait-secs 20
    assert_eq "$RC|$(field "$(keyed overseer-live "$OUT")" session)|$(cat "$FLEET_STATE")" \
      "1|$holder|$before" "$verb from B refuses while A lives and preserves the record"
  done
  fail_bin="$TMP_ROOT/process-fail-$mode"
  mkdir -p "$fail_bin"
  real_ps="$(command -v ps)"
  cat > "$fail_bin/ps" <<STUB
#!/bin/sh
case "\$*" in '-A -o pid= -o comm=') echo process-read=failed >&2; exit 2 ;; esac
exec "$real_ps" "\$@"
STUB
  chmod +x "$fail_bin/ps"
  for verb in register launch; do
    for form in legacy process-failed; do
      snapshot="$before"
      [[ "$form" != legacy ]] || snapshot="$(jq 'del(.overseer.server_socket)' <<<"$before")"
      printf '%s\n' "$snapshot" > "$FLEET_STATE"
      if [[ "$form" == legacy ]]; then
        run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- "$verb" --wait-secs 20
      else
        run_oversee PATH="$fail_bin:$BIN:$PATH" TMUX="$b_addr" TMUX_PANE="$candidate" -- "$verb" --wait-secs 20
      fi
      assert_eq "$RC|$(field "$(keyed launch-failed "$OUT")" step)|$(cat "$FLEET_STATE")" \
        "1|inspect|$snapshot" "$verb from B preserves A's $form record when evidence cannot be read" "$OUT"
    done
  done
  printf '%s\n' "$before" > "$FLEET_STATE"
  # A changed tmux start is a different server identity even at a live pid.
  jq '.overseer.server_start = 0' <<<"$before" > "$FLEET_STATE"
  run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- register
  assert_eq "$RC|$(recorded server)" "0|$b_server" "a different recorded server start permits takeover"
  fixture_server_stop "$a_socket"
  for verb in register launch; do
    # A fresh B repeats A's launched pane number when it opens its overseer.
    fixture_server_stop "$b_socket"
    fixture_server_allocate b "$mode" "$verb"
    fixture_server_start
    b_name="$FIXTURE_NAME" b_socket="$FIXTURE_SOCKET"
    b_addr="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" display-message -p '#{socket_path},#{pid},0')"
    b_server="${b_addr#*,}" b_server="${b_server%%,*}"
    candidate="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" display-message -p '#{pane_id}')"
    for form in socket legacy; do
      snapshot="$before"
      [[ "$form" != legacy ]] || snapshot="$(jq 'del(.overseer.server_socket)' <<<"$before")"
      printf '%s\n' "$snapshot" > "$FLEET_STATE"
      run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- "$verb" --wait-secs 20
      assert_eq "$RC|$(recorded server)|$(recorded server_socket)" \
        "0|$b_server|${b_addr%%,*}" "$verb from B succeeds after A's server stops with a $form record" "$OUT"
      if [[ "$verb" == launch && "$RC" == 0 && "$form" == socket && "$mode" == launch ]]; then
        assert_eq "$(recorded pane)" "$holder" "fresh launch verifies its own pane when the prior server used the same number"
      fi
      [[ "$verb" != launch || "$RC" != 0 || "$form" != socket ]] || TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" kill-window -t "$(recorded window)"
    done
    if [[ "$verb" == launch && "$RC" == 0 ]]; then
      TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" kill-window -t "$(recorded window)"
    fi
  done
  fixture_server_stop "$b_socket"
  mv -- "$TMP_ROOT/two-server.saved" "$FLEET_STATE"
}
for recorded_mode in register launch; do test_recorded_server "$recorded_mode"; done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
