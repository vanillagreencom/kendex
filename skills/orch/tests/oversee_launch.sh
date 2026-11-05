#!/usr/bin/env bash
# Tests for scripts/oversee: `register`, the session record for a session a
# person opened by hand, over a real tmux server at the person's default
# socket under a private TMUX_TMPDIR, so a run with no $TMUX and
# ORCH_TMUX_SESSION set reaches it the way lib/tmux-server.sh says a verb
# outside tmux reaches the person's own server. The records the rows read
# over stand as a launch writes them: a `start-controller` request composed as
# the first section of workflows/oversee.md composes it, performed by the runtime stand-in's
# start performer (lib/runtime-stub.sh), since these suites run where no
# runtime is built. claude, codex and copilot are stubs on PATH.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/named-process.sh"
# shellcheck source=lib/copilot-context-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/copilot-context-world.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/lanes-fixture.sh"
# mutant_scripts and mutate_file, the two halves of the controls.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
OVERSEE="$SRC_DIR/oversee"
# The launch table the permission readback rows spell their lines from.
# shellcheck source=../scripts/lib/lane-launch.sh
source "$SRC_DIR/lib/lane-launch.sh"

TMP_ROOT="$(mktemp -d)" || { echo "oversee_launch: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "oversee_launch: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "oversee_launch: scratch=resolve-failed" >&2; exit 1; }
TMUX_DIR="$TMP_ROOT/tmux"
BIN="$TMP_ROOT/bin"
mkdir -p "$TMUX_DIR" "$BIN"
FIXTURE_SOCKETS=()
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
  local socket
  for socket in ${FIXTURE_SOCKETS[@]+"${FIXTURE_SOCKETS[@]}"}; do
    [[ -z "$socket" ]] || tmux -S "$socket" kill-server 2>/dev/null || true
  done
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { TMUX_TMPDIR="$TMUX_DIR" tmux -L default "$@"; }

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

mkdir -p "$BIN/processes" "$TMP_ROOT/work/tmp"
# The orch runtime stand-in, standing in for the binary these suites cannot
# build: `op --fleet --request FILE` hands a `start-controller` request to the
# start performer lib/runtime-stub.sh writes beside it, which opens the
# request's controller as a window of the fleet session in its cwd and
# writes the record as the runtime's confirmed arm does. SCRIPT_DIR and
# PROJECT_ROOT are the performer's.
# shellcheck source=lib/runtime-stub.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/runtime-stub.sh"
fixture_runtime_start_perform "$BIN"
cat > "$BIN/orch-runtime" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[[ "$*" == "op --fleet --request "* ]] || { printf 'orch-runtime: fixture-unexpected argv=%s\n' "$*" >&2; exit 2; }
exec "$(cd -- "$(dirname -- "$0")" && pwd -P)/.orch-runtime-start" "$4"
STUB
chmod +x "$BIN/orch-runtime"
for harness in claude codex copilot; do
  fixture_named_process "$BIN/processes/$harness"
done
# The work directory is a checkout, so a register run from it reads that
# checkout's install.
git -C "$TMP_ROOT/work" init -q
git -C "$TMP_ROOT/work" config gc.auto 0
git -C "$TMP_ROOT/work" config maintenance.auto false
cat > "$BIN/claude" <<STUB
#!/bin/sh
{ printf 'lane=%s\n' "\${CLAUDE_CONFIG_DIR:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.claude"
echo 'esc to interrupt'
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
# No repository lookup answers here: nothing a register runs needs one, and
# a gh on PATH keeps the rows off the network.
cat > "$BIN/gh" <<'STUB'
#!/bin/sh
exit 1
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
tm set-option -g renumber-windows off
SERVER_PID="$(tm display-message -p '#{pid}')"
SERVER_START="$(tm display-message -p '#{start_time}')"
TMUX_ADDR="$(tm display-message -p '#{socket_path},#{pid},0')"
WORK_REAL="$(cd "$TMP_ROOT/work" && pwd -P)"
tm set-environment -g ORCH_STATE_DIR "$TMP_ROOT/work/tmp"

# run_oversee ENV=VAL... -- ARGS... — the script under an explicit, whole
# environment with no $TMUX, from the work directory workflow-state resolves
# `tmp` under. Sets OUT (both streams) and RC.
run_oversee() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  RC=0
  OUT="$(cd "$TMP_ROOT/work" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" \
    ORCH_TMUX_SESSION=fleet ${env_args[@]+"${env_args[@]}"} "${OVERSEE_BIN:-$OVERSEE}" "$@" 2>&1 </dev/null)" || RC=$?
}
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
recorded() { jq -r ".overseer.$1 // \"none\"" "$FLEET_STATE" 2>/dev/null || echo unreadable; }
keyed() { awk -v k="oversee: $1" 'index($0, k) == 1 { found = 1 } found' <<<"$2"; }
field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$(sed -n 1p <<<"$1")"; }
identity() { printf '%s|' "$(recorded harness)" "$(recorded account)" "$(recorded home)" "$(recorded model)" "$(recorded effort)" "$(recorded cwd)"; }
BRIEF='Read .agents/skills/orch/SKILL.md and follow .agents/skills/orch/workflows/oversee-takeover.md with the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'

# fixture_launch HARNESS ACCOUNT MODEL LINE — the record a launch writes: the
# `start-controller` request the first section of workflows/oversee.md composes (the
# controller, the brief file under the fleet state's intents/), with LINE as
# the display line the stand-in's performer runs, handed to the stand-in's
# `op --fleet`. Refuses where the performer did not record the controller.
fixture_launch() {
  local harness="$1" account="$2" model="$3" line="$4" request brief rc=0 out
  [[ -f "$FLEET_STATE" ]] || (cd "$TMP_ROOT/work" && "$SRC_DIR/workflow-state" init oversee >/dev/null) || return 1
  brief="$TMP_ROOT/work/tmp/intents/start-controller.$$.$RANDOM.brief"
  mkdir -p "${brief%/*}"
  printf '%s\n' "$BRIEF" > "$brief"
  request="$(mktemp)" || return 1
  jq -cn --arg harness "$harness" --arg account "$account" --arg model "$model" --arg cwd "$WORK_REAL" \
    --arg line "$line" --arg brief "$brief" '{op: "start-controller", controller: {harness: $harness,
    account: $account, home: $account, model: $model, effort: "high", cwd: $cwd, permission: "bypass",
    launch_line: $line}, brief_file: $brief, watch: null}' > "$request"
  out="$(cd "$TMP_ROOT/work" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$H" PATH="$BIN:$PATH" \
    TMUX_TMPDIR="$TMUX_DIR" SCRIPT_DIR="$SRC_DIR" PROJECT_ROOT="$WORK_REAL" ORCH_TMUX_SESSION=fleet \
    ORCH_TMUX_VERIFY_SECS=20 "$BIN/orch-runtime" op --fleet --request "$request" 2>&1 </dev/null)" || rc=$?
  rm -f -- "$request"
  [[ "$rc" == 0 && "$(jq -r '.result.effect.report.intent.outcome // empty' <<<"$out")" == confirmed ]] \
    || { printf 'fixture: launch failed rc=%s\n%s\n' "$rc" "$out" >&2; return 1; }
}
CLAUDE_LINE="env CLAUDE_CONFIG_DIR='$H/.claude' claude --model fable --effort high"

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

echo "=== oversee register ==="

# The record a launch wrote, generation 1, then its overseer stopped: the
# record the register rows below count their generation past.
fixture_launch claude "$H/.claude" fable "$CLAUDE_LINE" || exit 1
tm kill-window -t "$(recorded window)"

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

# register: the record for a hand-opened pane, its generation one past the
# record's, kept where the record already names that pane.
HAND="$(tm new-window -d -t fleet:4 -n hand -P -F '#{pane_id}' "exec '$BIN/hclaude' 100000")"
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(keyed registered "$OUT" | sed -n 1p)|$(recorded runtime)|$(recorded account)|$(recorded launch_line)|$(recorded server_start)" \
  "0|oversee: identity-fallback session=$HAND cause=no-start-row|oversee: registered session=$HAND window=$(tm display-message -p -t "$HAND" '#{window_id}') server=$SERVER_PID generation=2 account=$H/.eclaude retained=none fresh=account,cwd,generation,harness,home,pane,runtime,server,server_socket,server_start,session_rows,window|tmux|$H/.eclaude|none|$SERVER_START" \
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
assert_eq "$(recorded session_id)" before-resume 'control: retaining the prior native binding fails the register reset assertion'
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" -- register --account "$H/.claude"
assert_eq "$RC|$(recorded generation)|$(recorded account)" \
  "0|2|$H/.claude" \
  "registering the same pane again keeps its generation and takes --account"
run_oversee -- register
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee: tmux-missing var=TMUX_PANE" \
  "register outside a pane refuses"
run_oversee -- launch
assert_eq "$RC|$(sed -n 1,2p <<<"$OUT")" \
  "2|oversee: unknown-command command=launch
The command is register. A fleet's first overseer and a successor open through the runtime: orch-runtime successor --fleet, then op --fleet, as the first section of workflows/oversee.md spells it." \
  "a command other than register is refused, its text naming the route a launch takes for the person who typed it"

# A Copilot overseer a launch opened on its account, the record the turn
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
fixture_launch copilot "$H/.1copilot" gpt-5.3-codex "env COPILOT_HOME='$H/.1copilot' copilot --model gpt-5.3-codex" || exit 1
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
tm kill-window -t "$CODEX_PANE"
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
# The Copilot panes end: the record names one of them, which the next
# register reads gone and takes the next generation over.
for pane in "$COPILOT_PANE" "$WRAPPED_PANE" "$DEEP_PANE" "$FRESH_PANE"; do
  tm kill-window -t "$pane"
done

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
  run_oversee TMUX="$a_addr" TMUX_PANE="$holder" -- register
  holder="$(recorded pane)"
  assert_eq "$RC|$(recorded server_socket)" "0|${a_addr%%,*}" "register stores the overseer's socket"
  before="$(cat "$FLEET_STATE")"
  run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- register
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
  for form in socketless process-failed; do
    snapshot="$before"
    [[ "$form" != socketless ]] || snapshot="$(jq 'del(.overseer.server_socket)' <<<"$before")"
    printf '%s\n' "$snapshot" > "$FLEET_STATE"
    if [[ "$form" == socketless ]]; then
      run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- register
    else
      run_oversee PATH="$fail_bin:$BIN:$PATH" TMUX="$b_addr" TMUX_PANE="$candidate" -- register
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
  for form in socket socketless; do
    snapshot="$before"
    [[ "$form" != socketless ]] || snapshot="$(jq 'del(.overseer.server_socket)' <<<"$before")"
    printf '%s\n' "$snapshot" > "$FLEET_STATE"
    run_oversee TMUX="$b_addr" TMUX_PANE="$candidate" -- register
    assert_eq "$RC|$(recorded server)|$(recorded server_socket)" \
      "0|$b_server|${b_addr%%,*}" "register from B succeeds after A's server stops with a $form record" "$OUT"
  done
  fixture_server_stop "$b_socket"
  mv -- "$TMP_ROOT/two-server.saved" "$FLEET_STATE"
}
test_recorded_server

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
