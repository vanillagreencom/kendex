#!/usr/bin/env bash
# Tests for scripts/oversee: `launch`, the shell entry that asks the orch
# runtime for an overseer and relays its answer, here against a runtime
# stand-in that answers the successor the walk chose and performs a start as
# the runtime's confirmed arm records it (lib/runtime-stub.sh), run from
# OUTSIDE tmux; and `register`, the session record for a session a person
# opened by hand. Run over a real tmux server at the person's default socket
# under a private TMUX_TMPDIR, so a run with no $TMUX and ORCH_TMUX_SESSION set
# reaches it the way lib/tmux-server.sh says a verb outside tmux reaches the
# person's own server. claude, codex and copilot are stubs on PATH.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/named-process.sh"
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
  for helper in git-env.sh named-process.sh copilot-context-world.sh lanes-fixture.sh growth-state.sh assertions.sh; do
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
# The orch runtime the launcher asks, named through ORCH_RUNTIME_CLI, standing
# in for the binary these suites cannot build. It appends every call's argv,
# a request and its brief file's text to RUNTIME_LOG, so a row reads what the
# launcher composed, and the successor reply it answered beside it. It refuses
# as the shipped wrapper does where OL_RUNTIME_SETUP_REQUIRED is set (its
# `setup-required` line, exit 69). `state exists|init|get --fleet` answer
# through the store beside the launcher under test. `successor --fleet`
# answers the reply planted at OL_RUNTIME_SUCCESSOR, else the walk's choice of
# the suite's preference entry, claude:fable:high on the account `.claude`
# under LANES_HOME, in the --cwd it is asked for, with the takeover brief in
# its harness's form naming --handoff. `op --fleet` answers the
# reply planted at OL_RUNTIME_REPLY, or with OL_RUNTIME_OP_EXIT set prints
# OL_RUNTIME_OP_LINE on stderr and exits with that status, else hands a start
# to the shared
# performer lib/runtime-stub.sh writes beside it, which performs it as the
# runtime's confirmed arm records it and answers `confirmed`. SCRIPT_DIR and
# PROJECT_ROOT are the launcher's exports, so a mutant launcher's own libs
# and workflow-state answer for it.
RUNTIME_LOG="$TMP_ROOT/runtime.log"
# shellcheck source=lib/runtime-stub.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/runtime-stub.sh"
fixture_runtime_start_perform "$BIN"
cat > "$BIN/orch-runtime" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
request="" cwd="" handoff=tmp/handoffs/OVERSEER-HANDOFF.md
for ((i = 1; i <= $#; i++)); do
  j=$((i + 1))
  [[ "${!i}" != --request ]] || request="${!j}"
  [[ "${!i}" != --cwd ]] || cwd="${!j}"
  [[ "${!i}" != --handoff ]] || handoff="${!j}"
done
if [[ -n "${OL_RUNTIME_LOG:-}" ]]; then
  printf 'argv %s\n' "$*" >> "$OL_RUNTIME_LOG"
  if [[ -n "$request" ]]; then
    cat -- "$request" >> "$OL_RUNTIME_LOG"
    brief="$(jq -r '.brief_file // empty' "$request")"
    [[ -z "$brief" ]] || printf 'brief %s\n' "$(cat -- "$brief")" >> "$OL_RUNTIME_LOG"
  fi
fi
if [[ -n "${OL_RUNTIME_SETUP_REQUIRED:-}" ]]; then
  printf 'orch-runtime: setup-required key=fixture run=%s/setup\n' "${SCRIPT_DIR:-.}" >&2
  exit 69
fi
store="${SCRIPT_DIR:?}/workflow-state"
case "$*" in
  "state exists --fleet")
    exists=false
    ! "$store" exists oversee >/dev/null 2>&1 || exists=true
    jq -cn --arg path "$("$store" path oversee)" --argjson exists "$exists" \
      '{protocol: "orch-runtime-v1", ok: true, result: {issue_id: "oversee", path: $path, exists: $exists}}'
    exit 0 ;;
  "state init --fleet")
    "$store" init oversee >/dev/null
    printf '{"protocol":"orch-runtime-v1","ok":true,"result":{}}\n'
    exit 0 ;;
  "state get --fleet /overseer")
    jq -c '{protocol: "orch-runtime-v1", ok: true, result: {pointer: "/overseer", value: .overseer}}' \
      "$("$store" path oversee)"
    exit 0 ;;
  "successor --fleet --cwd "*)
    if [[ -n "${OL_RUNTIME_SUCCESSOR:-}" ]]; then reply="$(cat -- "$OL_RUNTIME_SUCCESSOR")"; else
      reply="$(jq -cn --arg account "${LANES_HOME:?}/.claude" --arg cwd "$cwd" '
        {harness: "claude", account: $account, model: "fable", effort: "high", class: "top"} as $chosen
        | {protocol: "orch-runtime-v1", ok: true, result: {
            walk: {answer: "lane", walk: "claude:fable:high", entries: 1, chosen: ($chosen + {entry: "claude:fable:high"}),
              skipped: [], walled: 0, unmeasured: 0, unread: [], last_choice: null, room: null, deprecated: []},
            successor: ($chosen + {cwd: $cwd, permission: "bypass"}), expected: null}}')"
    fi
    reply="$(jq -c --arg handoff "$handoff" 'if .result | has("brief") then . else .result.brief =
      (.result.successor.harness // null | if . == null then null
        elif . == "pi" then "/skill:orch follow .agents/skills/orch/workflows/oversee-takeover.md with the overseer handoff at " + $handoff
        else "Read .agents/skills/orch/SKILL.md and follow .agents/skills/orch/workflows/oversee-takeover.md with the overseer handoff at " + $handoff end) end' <<<"$reply")"
    [[ -z "${OL_RUNTIME_LOG:-}" ]] || printf '%s\n' "$reply" > "$OL_RUNTIME_LOG.successor"
    printf '%s\n' "$reply"
    exit 0 ;;
esac
if [[ -n "${OL_RUNTIME_REPLY:-}" && -n "$request" ]]; then cat -- "$OL_RUNTIME_REPLY"; exit 0; fi
if [[ -n "${OL_RUNTIME_OP_EXIT:-}" && -n "$request" ]]; then
  [[ -z "${OL_RUNTIME_OP_LINE:-}" ]] || printf '%s\n' "$OL_RUNTIME_OP_LINE" >&2
  exit "$OL_RUNTIME_OP_EXIT"
fi
[[ -n "$request" && "$(jq -r '.op' "$request")" == start-controller ]] \
  || { printf 'orch-runtime: fixture-unexpected argv=%s\n' "$*" >&2; exit 2; }
exec "$(cd -- "$(dirname -- "$0")" && pwd -P)/.orch-runtime-start" "$request"
STUB
chmod +x "$BIN/orch-runtime"
for harness in claude codex copilot; do
  fixture_named_process "$BIN/processes/$harness"
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
# harness off: a native fixture, since a script or a shell named for the
# harness can reset the process name tmux reads.
fixture_named_process "$BIN/hclaude"

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
# The runtime is the fixture above, its log emptied first, so RUNTIME_LOG holds
# this run's calls alone. Sets OUT (both streams) and RC.
run_oversee() {
  fixture_watch_neighbor "${OVERSEE_BIN:-$OVERSEE}"
  tm set-environment -g ORCH_STATE_DIR "${RUN_DIR:-$TMP_ROOT/work}/tmp"
  local env_args=() pref=(ORCH_OVERSEER_PREFERENCE="${LAUNCH_PREF:-claude:fable:high}")
  [[ "${LAUNCH_PREF:-}" != unset ]] || pref=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  rm -f "${TMP_ROOT:?}"/argv.*
  : > "$RUNTIME_LOG"
  RC=0
  OUT="$(cd "${RUN_DIR:-$TMP_ROOT/work}" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" \
    ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude:$H/.eclaude" ORCH_LANES_USAGE_TTL=0 \
    ORCH_RUNTIME_CLI="$BIN/orch-runtime" OL_RUNTIME_LOG="$RUNTIME_LOG" \
    ${pref[@]+"${pref[@]}"} ORCH_TMUX_SESSION=fleet \
    ${env_args[@]+"${env_args[@]}"} "${OVERSEE_BIN:-$OVERSEE}" "$@" 2>&1 </dev/null)" || RC=$?
  fixture_watch_stop "${RUN_DIR:-$TMP_ROOT/work}/tmp/workflow-state-oversee.json"
  [[ "${RUN_DIR:-$TMP_ROOT/work}" == "$TMP_ROOT/work" ]] || fixture_watch_stop "$TMP_ROOT/work/tmp/workflow-state-oversee.json"
}
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
recorded() { jq -r ".overseer.$1 // \"none\"" "$FLEET_STATE" 2>/dev/null || echo unreadable; }
keyed() { awk -v k="oversee: $1" 'index($0, k) == 1 { found = 1 } found' <<<"$2"; }
# first_line — OUT's first line, kendex's model-resolution warning passed
# over: it precedes a refusal that comes after the walk classified a model.
first_line() { sed -n '/^model-resolution: /!{p;q;}' <<<"$OUT"; }
field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$(sed -n 1p <<<"$1")"; }
layout() { tm list-windows -t fleet -F '#{window_id} #{window_index} #{window_name}' | awk -v keep="$KEEP_WINDOW" '$1 != keep { print $2, $3 }' | tr '\n' ';'; }
overseers() { tm list-windows -t fleet -F '#{window_name}' | awk '$0 == "overseer"' | wc -l | tr -d ' '; }
listed() { tm list-panes -a -F '#{pane_id}' | grep -cxF -- "$1" || true; }
recorded_argv() { if [[ -f "$TMP_ROOT/argv.claude" ]]; then tr '\n' ';' < "$TMP_ROOT/argv.claude"; else printf 'none'; fi; }
# The last start-controller request the run handed the runtime fixture, read
# by jq FILTER (`requested`), the argv of that call (`requested_argv`) and the
# brief file's text (`requested_brief`); `none` where the run made no call.
requested() { # FILTER
  local request
  request="$(grep -v -e '^argv ' -e '^brief ' "$RUNTIME_LOG" | tail -n 1)"
  [[ -n "$request" ]] || { printf 'none'; return; }
  jq -r "$1" <<<"$request"
}
requested_argv() { grep '^argv .* --request ' "$RUNTIME_LOG" | tail -n 1 | cut -d' ' -f2- | awk '{ print $1, $2, $3 }'; }
requested_brief() { grep '^brief ' "$RUNTIME_LOG" | tail -n 1 | cut -d' ' -f2-; }
BRIEF='Read .agents/skills/orch/SKILL.md and follow .agents/skills/orch/workflows/oversee-takeover.md with the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'

# Recorded commands must read back both forms the shared account launcher emits.
recorded_launcher_permission_rows() {
  source "${1:-$SRC_DIR}/lib/overseer-launch.sh"
  local SCRIPT_DIR="$SRC_DIR" DEP_ERR="$TMP_ROOT/readback.err"
  local bin="$TMP_ROOT/readback/bin" harness shape posture launch_home word var cmd form line record status flags
  local PATH="$TMP_ROOT/readback/bin:$PATH"
  mkdir -p "$bin"
  for harness in codex copilot; do
    printf '#!/bin/sh\nexit 1\n' > "$bin/1$harness"
    chmod +x "$bin/1$harness"
    word="$(launch_choice_permission_write "$harness")" || exit 1
    var="$(lane_env_prefix "$harness" -)" || exit 1
    var="${var%%=*}"
    for shape in prefix launcher; do
      launch_home="$TMP_ROOT/readback/.$harness"
      [[ "$shape" != launcher ]] || launch_home="$TMP_ROOT/readback/.1$harness"
      mkdir -p "$launch_home"
      for posture in recorded prompt-only; do
        cmd="$harness"
        [[ "$posture" != recorded ]] || cmd+=" $word"
        [[ "$harness" != copilot ]] || cmd+=' -i'
        cmd+=" 'prompt mentions $word'"
        form="$(lane_launch_form "$cmd" "$harness" "$launch_home")" || return 1
        line="$(lane_launch_line "$cmd" "$harness" "$var" "$launch_home" "$form")" || return 1
        record="$(jq -cn --arg home "$launch_home" --arg line "$line" '{home:$home,account:$home,launch_line:$line}')" || return 1
        status=0
        ol_record_permission "$record" "$harness" || status=$?
        flags="${OL_PERMISSION_FLAGS[*]+${OL_PERMISSION_FLAGS[*]}}"
        local want_form=prefix want_status=1 want_flags=""
        [[ "$shape" != launcher ]] || want_form="launcher:$bin/1$harness"
        [[ "$posture" != recorded ]] || { want_status=0; want_flags="$word"; }
        assert_eq "$form|$status|$flags" "$want_form|$want_status|$want_flags" \
          "$harness $shape $posture permission reads back from the shared producer" "$DEP_ERR"
      done
    done
  done
}
recorded_launcher_permission_rows
READBACKCTL="$(mutant_scripts readbackctl lib/overseer-launch.sh)" || exit 1
mutate_file "$READBACKCTL/lib/overseer-launch.sh" \
  '|| "$form" == "launcher:${LAUNCH_CHOICE_ARGV[i]}"' \
  '|| ( "$form" == "launcher:${LAUNCH_CHOICE_ARGV[i]}" && 0 == 1 )'
saved_fail="$FAIL"
FAIL=0
recorded_launcher_permission_rows "$READBACKCTL" > "$TMP_ROOT/readback-control.out"
control_fail="$FAIL"
FAIL="$saved_fail"
assert_eq "$((control_fail > 0))" 1 'control: omitting account executable readback fails the producer rows' "$TMP_ROOT/readback-control.out"

echo "=== oversee ==="

# A first launch from outside tmux asks the runtime for the successor the
# walk chose and hands it to one start-controller request: the stand-in opens
# the window and records it, and the launcher reports the record the runtime
# wrote with generation 1.
WORK_REAL="$(cd "$TMP_ROOT/work" && pwd -P)"
run_oversee FIXTURE_REPO=owner/fleet -- launch --wait-secs 20
LAUNCHED="$(keyed overseer-launched "$OUT" | sed -n 1p)"
SESSION="$(field "$LAUNCHED" session)"
assert_eq "$RC|$(sed -n 's/window=@[0-9]*/window=@N/; s/session=%[0-9]*/session=%N/p' <<<"$LAUNCHED")" \
  "0|oversee: overseer-launched session=%N window=@N server=$SOCKET generation=1 lane=$H/.claude" \
  "a first launch prints the record the runtime wrote"
# The request: the runtime's successor as the controller, as the runtime
# answered it, with the line the record keeps for the readers that replay it
# (the stand-in runs that line); the brief file holding the takeover brief;
# the watch words:
# the runtime wrapper beside the launcher, `watch run --file` the fleet state,
# `--since` this launch's time (no lane record stands) and the checkout's
# repository.
LAUNCH_LINE="$SCRUB_ENV CLAUDE_CONFIG_DIR='$H/.claude' CLAUDE_CODE_DISABLE_INLINE_SHELL_RM_PROMPT=1 CLAUDE_CODE_DISABLE_SUBSTITUTION_RM_PROMPT=1 CLAUDE_CODE_EVEN_MORE_DANGEROUSLY_SKIP_PERMISSIONS=1 claude -n overseer --model fable --effort high $BYPASS $(printf '%q' "$COMPACT") $(printf '%q' "$QUESTION_OFF") '$BRIEF'"
assert_eq "$(requested_argv)|$(requested '.op')|$(requested '.controller | del(.launch_line)' | jq -cS .)|$(requested '.controller.launch_line')|$(requested_brief)" \
  "op --fleet --request|start-controller|$(jq -cS .result.successor "$RUNTIME_LOG.successor")|$LAUNCH_LINE|$BRIEF" \
  "the request carries the runtime's successor as its controller with the record's line, and the takeover brief"
assert_eq "$(requested '.watch | join(" ")' | sed 's/--since [^ ]*/--since T/')" \
  "$BIN/orch-runtime watch run --file $WORK_REAL/tmp/workflow-state-oversee.json --interval 240 --since T --repo owner/fleet" \
  "the request's watch is the runtime's own words: the wrapper, the fleet state and the repository"
assert_eq "$(requested '.watch[] | select(startswith("20"))' | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')" 1 \
  "with no lane record the watch's --since is this launch's time"
identity() { printf '%s|' "$(recorded harness)" "$(recorded account)" "$(recorded home)" "$(recorded model)" "$(recorded effort)" "$(recorded cwd)"; }

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
# The overseer stopped: the next launch takes the next generation, the one
# the register rows below count on.
tm kill-window -t "$SESSION"
run_oversee -- launch --wait-secs 20
tm kill-window -t "$(recorded window)"

# A runtime that is not set up refuses the launch with the wrapper's own line
# under the keyed one, and nothing is opened in its place: no window, the
# record as it stood. The fleet state read meets the wrapper first, so no
# start request is composed.
run_oversee OL_RUNTIME_SETUP_REQUIRED=1 -- launch --wait-secs 5
assert_eq "$RC|$(first_line)|$(grep -c '^orch-runtime: setup-required key=fixture run=' <<<"$OUT")|$(overseers)|$(recorded generation)|$(requested '.op')" \
  "1|oversee: start-refused key=setup-required exit=69|1|0|2|none" \
  "a runtime not set up refuses the launch with its setup-required line and opens no session"
# A start the runtime recorded and could not confirm is reported with the
# note and cause the effect holds it under, at the refusal's exit.
jq -cn '{protocol: "orch-runtime-v1", ok: true, result: {effect: {kind: "fleet", report: {op: "record-outcome",
  intent: {id: "fixture-held", outcome: "unconfirmed", observation: {note: "watch-launch-failed", cause: "job-unit: launch-failed status=1"}}}}}}' \
  > "$TMP_ROOT/held-reply.json"
run_oversee OL_RUNTIME_REPLY="$TMP_ROOT/held-reply.json" -- launch --wait-secs 5
assert_eq "$RC|$(first_line)|$(overseers)" \
  "1|oversee: controller-unconfirmed intent=fixture-held note=watch-launch-failed cause=job-unit: launch-failed status=1|0" \
  "a start the runtime holds unconfirmed is reported with its note and cause"
# The runtime's answer contract: a refusal naming the intent it persisted,
# and an end with no refusal (a panic's 101, a signal), may have acted, so
# each is unconfirmed naming the intent, unread where none was named; a
# refusal that names none is a refusal, nothing opened.
run_oversee OL_RUNTIME_OP_EXIT=1 OL_RUNTIME_OP_LINE='orch-runtime: job-unclaimed intent_id=fixture-held persisted_intent=fixture-held' -- launch --wait-secs 5
assert_eq "$RC|$(first_line)|$(overseers)" \
  "1|oversee: controller-unconfirmed intent=fixture-held note=job-unclaimed cause=exit-1|0" \
  "a refusal after the start's intent was persisted is unconfirmed, naming the intent"
run_oversee OL_RUNTIME_OP_EXIT=101 OL_RUNTIME_OP_LINE="thread 'main' panicked at src/main.rs:1:1:" -- launch --wait-secs 5
assert_eq "$RC|$(first_line)|$(overseers)" \
  "1|oversee: controller-unconfirmed intent=unread note=none cause=exit-101|0" \
  "a runtime that panicked on the start is unconfirmed with the intent unread"
run_oversee OL_RUNTIME_OP_EXIT=1 OL_RUNTIME_OP_LINE='orch-runtime: overseer-live pane=%9' -- launch --wait-secs 5
assert_eq "$RC|$(first_line)|$(overseers)" \
  "1|oversee: start-refused key=overseer-live exit=1|0" \
  "a refusal that names no persisted intent stays a refusal"
# Control: a launcher whose request names no watch fails the watch-words row,
# in a fleet of its own so the main record's generations stand.
WATCHCTL="$(mutant_scripts watchctl oversee)" || exit 1
mutate_file "$WATCHCTL/oversee" 'brief_file: $brief, watch: $watch}' 'brief_file: $brief, watch: null}'
RUN_DIR="$TMP_ROOT/watchctl-fleet"
mkdir -p "$RUN_DIR"
checkout_world "$RUN_DIR" || exit 1
WATCHCTL_STATE="$RUN_DIR/tmp/workflow-state-oversee.json"
OVERSEE_BIN="$WATCHCTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(requested '.watch')|$(requested '.controller.account')" "0|null|$H/.claude" \
  "control: a request composed without the watch carries the controller and no watch words"
[[ "$RC" != 0 ]] || tm kill-window -t "$(FLEET_STATE="$WATCHCTL_STATE" recorded window)"
RUN_DIR=""

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

# A walk that chose none refuses at 3 with the walk's counts, and no start is
# composed.
jq -cn '{protocol: "orch-runtime-v1", ok: true, result: {walk: {answer: "none", walk: "claude:fable:high",
  entries: 1, chosen: null, skipped: [], walled: 2, unmeasured: 0, unread: [], last_choice: null, room: null,
  deprecated: []}, successor: null, expected: null}}' > "$TMP_ROOT/none-reply.json"
run_oversee OL_RUNTIME_SUCCESSOR="$TMP_ROOT/none-reply.json" -- launch --wait-secs 5
assert_eq "$RC|$(keyed no-lane-qualifies "$OUT" | sed -n 1p)|$(overseers)|$(requested '.op')" \
  "3|oversee: no-lane-qualifies entries=1 walled=2 unmeasured=0|0|none" \
  "a walk that chose none refuses at 3 with the walk's counts and composes no start"
# --session beside --predecessor is refused before the runtime is asked.
run_oversee -- launch --session fleet --predecessor %1 --wait-secs 5
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(requested '.op')" \
  "2|oversee: option-conflict command=launch session=fleet predecessor=%1|0|none" \
  "--session beside --predecessor is refused, nothing opened"

# register: the record for a hand-opened pane, its generation one past the
# record's, kept where the record already names that pane.
HAND="$(tm new-window -d -t fleet:4 -n hand -P -F '#{pane_id}' "exec '$BIN/hclaude' 100000")"
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(keyed registered "$OUT" | sed -n 1p)|$(recorded runtime)|$(recorded account)|$(recorded launch_line)|$(recorded server_start)" \
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
  "0|4|absent|$WORK_REAL" \
  "launch --cwd from outside the fleet directory records into that directory's state and starts there"
tm kill-window -t "$(recorded window)"


# A Copilot overseer the runtime opened on its account, the record the turn
# end below reads.
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
jq -cn --arg account "$H/.1copilot" --arg cwd "$WORK_REAL" '
  {harness: "copilot", account: $account, model: "gpt-5.3-codex", effort: "high"} as $chosen
  | {protocol: "orch-runtime-v1", ok: true, result: {
      walk: {answer: "lane", walk: "copilot:gpt-5.3-codex:high", entries: 1,
        chosen: ($chosen + {entry: "copilot:gpt-5.3-codex:high"}), skipped: [], walled: 0, unmeasured: 0,
        unread: [], last_choice: null, room: null, deprecated: []},
      successor: ($chosen + {cwd: $cwd, permission: "bypass"}), expected: null}}' > "$TMP_ROOT/copilot-reply.json"
run_oversee OL_RUNTIME_SUCCESSOR="$TMP_ROOT/copilot-reply.json" -- launch --wait-secs 20
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
# native fixture named codex, since only that exact name reads as codex.
mkdir -p "$TMP_ROOT/codex-bin"
fixture_named_process "$TMP_ROOT/codex-bin/codex"
PRIVATE_HOME="$H/.codex/lane-launch/work-1/home"
CODEX_PANE="$(tm new-window -d -t fleet:6 -n codexhand -P -F '#{pane_id}' "exec '$TMP_ROOT/codex-bin/codex' 100000")"
register_codex() { # [OVERSEE_BIN]
  OVERSEE_BIN="${1:-}" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$CODEX_PANE" CODEX_HOME="$PRIVATE_HOME" -- register
}
register_codex
assert_eq "$RC|$(recorded harness)|$(recorded account)|$(recorded home)" \
  "0|codex|$H/.codex|$PRIVATE_HOME" \
  "register on a codex pane records its account and its private CODEX_HOME apart"
tm kill-window -t "$(recorded window)"
run_oversee -- launch --wait-secs 20
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
# MainThread, a native fixture. The account is --account's, else the
# COPILOT_HOME that process was started with, never the Claude or Codex
# variable the session happens to carry.
CP="$TMP_ROOT/copilot-bin"
mkdir -p "$CP"
cp "$(command -v bash)" "$CP/node"
cp "$(command -v bash)" "$CP/wrap"
fixture_named_process "$CP/MainThread"
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
assert_eq "$FLOW_RECORD" '199000:217600' \
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
  local a_addr b_addr b_server holder candidate before form snapshot fail_bin real_ps
  local a_name b_name a_socket b_socket side
  cp -- "$FLEET_STATE" "$TMP_ROOT/two-server.saved"
  for side in a b; do
    fixture_server_allocate "$side" register initial
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
  run_oversee TMUX="$a_addr" TMUX_PANE="$holder" -- register --wait-secs 20
  holder="$(recorded pane)"
  assert_eq "$RC|$(recorded server_socket)" "0|${a_addr%%,*}" "register stores the overseer's socket"
  before="$(cat "$FLEET_STATE")"
  run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- register --wait-secs 20
  assert_eq "$RC|$(field "$(keyed overseer-live "$OUT")" session)|$(cat "$FLEET_STATE")" \
    "1|$holder|$before" "register from B refuses while A lives and preserves the record"
  fail_bin="$TMP_ROOT/process-fail-register"
  mkdir -p "$fail_bin"
  real_ps="$(command -v ps)"
  cat > "$fail_bin/ps" <<STUB
#!/bin/sh
case "\$*" in '-A -o pid= -o comm=') echo process-read=failed >&2; exit 2 ;; esac
exec "$real_ps" "\$@"
STUB
  chmod +x "$fail_bin/ps"
  for form in legacy process-failed; do
    snapshot="$before"
    [[ "$form" != legacy ]] || snapshot="$(jq 'del(.overseer.server_socket)' <<<"$before")"
    printf '%s\n' "$snapshot" > "$FLEET_STATE"
    if [[ "$form" == legacy ]]; then
      run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- register --wait-secs 20
    else
      run_oversee PATH="$fail_bin:$BIN:$PATH" TMUX="$b_addr" TMUX_PANE="$candidate" -- register --wait-secs 20
    fi
    assert_eq "$RC|$(field "$(keyed launch-failed "$OUT")" step)|$(cat "$FLEET_STATE")" \
      "1|inspect|$snapshot" "register from B preserves A's $form record when evidence cannot be read" "$OUT"
  done
  printf '%s\n' "$before" > "$FLEET_STATE"
  # A changed tmux start is a different server identity even at a live pid.
  jq '.overseer.server_start = 0' <<<"$before" > "$FLEET_STATE"
  run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- register
  assert_eq "$RC|$(recorded server)" "0|$b_server" "a different recorded server start permits takeover"
  fixture_server_stop "$a_socket"
  # A fresh B repeats A's recorded pane number.
  fixture_server_stop "$b_socket"
  fixture_server_allocate b register register
  fixture_server_start
  b_name="$FIXTURE_NAME" b_socket="$FIXTURE_SOCKET"
  b_addr="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" display-message -p '#{socket_path},#{pid},0')"
  b_server="${b_addr#*,}" b_server="${b_server%%,*}"
  candidate="$(TMUX_TMPDIR="$TMUX_DIR" tmux -L "$b_name" display-message -p '#{pane_id}')"
  for form in socket legacy; do
    snapshot="$before"
    [[ "$form" != legacy ]] || snapshot="$(jq 'del(.overseer.server_socket)' <<<"$before")"
    printf '%s\n' "$snapshot" > "$FLEET_STATE"
    run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- register --wait-secs 20
    assert_eq "$RC|$(recorded server)|$(recorded server_socket)" \
      "0|$b_server|${b_addr%%,*}" "register from B succeeds after A's server stops with a $form record" "$OUT"
  done
  fixture_server_stop "$b_socket"
  mv -- "$TMP_ROOT/two-server.saved" "$FLEET_STATE"
}
test_recorded_server


printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
