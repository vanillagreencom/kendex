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
exec sleep 100000
STUB
# The codex harness, recording its home and argv as the claude stub does.
cat > "$BIN/codex" <<STUB
#!/bin/sh
{ printf 'home=%s\n' "\${CODEX_HOME:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.codex"
echo 'esc to interrupt'
exec sleep 100000
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
  *) exit 2 ;;
esac
STUB
chmod +x "$BIN/kendex"
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

env PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" tmux -L default -f /dev/null new-session -d -s fleet -x 200 -y 40 'exec sleep 100000'
KEEP_WINDOW="$(tm display-message -p -t fleet:0 '#{window_id}')"
tm set-option -g renumber-windows off
tm set-option -g default-shell /bin/sh
tm set-option -g default-command "PATH=$BIN:\$PATH; export PATH; exec /bin/sh"
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
  local env_args=() pref=(ORCH_OVERSEER_PREFERENCE="${LAUNCH_PREF:-claude:fable:high}")
  [[ "${LAUNCH_PREF:-}" != unset ]] || pref=()
  while [[ $# -gt 0 && "$1" != -- ]]; do env_args+=("$1"); shift; done
  shift
  rm -f "${TMP_ROOT:?}"/argv.*
  RC=0
  OUT="$(cd "${RUN_DIR:-$TMP_ROOT/work}" && env -i HOME="$H" PATH="$BIN:$PATH" TMUX_TMPDIR="$TMUX_DIR" \
    LANES_HOME="$H" FIXTURE_DIR="$FIXTURE_DIR" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" \
    ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_DIRS="$H/.claude:$H/.eclaude" ORCH_LANES_USAGE_TTL=0 \
    ${pref[@]+"${pref[@]}"} ORCH_TMUX_SESSION=fleet \
    ${env_args[@]+"${env_args[@]}"} "${OVERSEE_BIN:-$OVERSEE}" "$@" 2>&1 </dev/null)" || RC=$?
}
FLEET_STATE="$TMP_ROOT/work/tmp/workflow-state-oversee.json"
recorded() { jq -r ".overseer.$1 // \"none\"" "$FLEET_STATE" 2>/dev/null || echo unreadable; }
keyed() { awk -v k="oversee: $1" 'index($0, k) == 1 { found = 1 } found' <<<"$2"; }
field() { sed -n "s/.* $2=\([^ ]*\).*/\1/p" <<<"$(sed -n 1p <<<"$1")"; }
layout() { tm list-windows -t fleet -F '#{window_id} #{window_index} #{window_name}' | awk -v keep="$KEEP_WINDOW" '$1 != keep { print $2, $3 }' | tr '\n' ';'; }
overseers() { tm list-windows -t fleet -F '#{window_name}' | awk '$0 == "overseer"' | wc -l | tr -d ' '; }
listed() { tm list-panes -a -F '#{pane_id}' | grep -cxF -- "$1" || true; }
recorded_argv() { if [[ -f "$TMP_ROOT/argv.claude" ]]; then tr '\n' ';' < "$TMP_ROOT/argv.claude"; else printf 'none'; fi; }
BRIEF='Read .agents/skills/orch/SKILL.md and execute the orch oversee workflow after reading the overseer handoff at tmp/handoffs/OVERSEER-HANDOFF.md'

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
  "tmux|$SERVER_PID|$SERVER_START|$SESSION|$(tm display-message -p -t "$SESSION" '#{window_id}')|$H/.claude|1|env CLAUDE_CONFIG_DIR='$H/.claude' claude -n overseer --model fable --effort high $BYPASS $(printf '%q' "$COMPACT") $(printf '%q' "$QUESTION_OFF") '$BRIEF'" \
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
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded generation)" \
  "1|oversee: overseer-live session=$SESSION server=$SOCKET generation=1|1|1" \
  "a launch beside a live recorded overseer refuses naming it and opens nothing"
# A record carrying no server start, the shape a writer that recorded none
# left, names no session, but its pane live on the recorded server pid may be
# the running overseer, so the launch refuses rather than open a second one.
cp -- "$FLEET_STATE" "$TMP_ROOT/state.live"
jq 'del(.overseer.server_start)' "$TMP_ROOT/state.live" > "$FLEET_STATE" || exit 1
run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded generation)" \
  "1|oversee: overseer-live session=$SESSION server=$SOCKET generation=1|1|1" \
  "a launch beside a live pane a record with no server start names refuses and opens nothing"
# Yet that record names no predecessor: its pane may be one a later server
# handed the same pid and pane id, so --predecessor on it refuses and the
# succession stops nothing.
run_oversee -- launch --predecessor "$SESSION" --wait-secs 20
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(listed "$SESSION")|$(recorded generation)" \
  "1|oversee: predecessor-not-live session=$SESSION live=none server=$SOCKET|1|1|1" \
  "a --predecessor naming the live pane a record with no server start names is refused and left running"
# Its control: a predecessor check that takes a startless record's live pane
# stops that pane. It runs over a pane of its own, since the succession stops
# it and $SESSION serves the rows below.
cp -- "$FLEET_STATE" "$TMP_ROOT/state.startless"
STARTLESS_PANE="$(tm new-window -d -t fleet -n startless -P -F '#{pane_id}' 'exec sleep 100000')"
jq --arg pane "$STARTLESS_PANE" '.overseer.pane = $pane' "$TMP_ROOT/state.startless" > "$FLEET_STATE" || exit 1
STARTLESSPREDCTL="$(mutant_scripts startlesspredctl oversee)" || exit 1
mutate_file "$STARTLESSPREDCTL/oversee" \
  '[[ -z "$PREDECESSOR" || "$named_pane" == "$PREDECESSOR" ]] \' '[[ -z "$PREDECESSOR" || "$live_pane" == "$PREDECESSOR" ]] \'
OVERSEE_BIN="$STARTLESSPREDCTL/oversee" run_oversee -- launch --predecessor "$STARTLESS_PANE" --wait-secs 20
assert_eq "$RC|$(listed "$STARTLESS_PANE")" "0|0" \
  "control: a predecessor check that takes a startless record's live pane stops it"
tm kill-window -t "$(recorded window)"
mv -- "$TMP_ROOT/state.startless" "$FLEET_STATE"
# Its control: a liveness check that takes a startless record as naming no
# session opens a second overseer beside the first.
STARTLESSCTL="$(mutant_scripts startlessctl oversee)" || exit 1
mutate_file "$STARTLESSCTL/oversee" \
  'ol_owns($server; $start; $pane)]' 'ol_names($server; $start; $pane)]'
OVERSEE_BIN="$STARTLESSCTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(overseers)" "0|2" \
  "control: a launch that judges a startless record as naming no session opens a second overseer"
tm kill-window -t "$(recorded window)"
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
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(recorded generation)" \
  "1|oversee: launch-failed step=server-start session=$SESSION server=$SOCKET|1|1" \
  "a launch beside a live recorded pane whose server start cannot be read refuses and opens nothing"
# Its control: an unread start judged as no start reads the live overseer's
# bound record as another session's and opens a second overseer.
NOSTARTCTL="$(mutant_scripts nostartctl oversee)" || exit 1
mutate_file "$NOSTARTCTL/oversee" \
  '      || die launch-failed step=server-start "session=$live_pane" "server=$SERVER_SOCKET"' '      || live_start=""'
cp -- "$FLEET_STATE" "$TMP_ROOT/state.live"
OVERSEE_BIN="$NOSTARTCTL/oversee" run_oversee PATH="$NOSTART_PATH" -- launch --wait-secs 20
assert_eq "$RC|$(overseers)" "0|2" \
  "control: a launch that judges an unread start as none opens a second overseer beside the first"
tm kill-window -t "$(recorded window)"
mv -- "$TMP_ROOT/state.live" "$FLEET_STATE"
# The must-fail control: a launcher that skips the liveness check opens a
# second overseer beside the first.
LIVECTL="$(mutant_scripts livectl oversee)" || exit 1
mutate_file "$LIVECTL/oversee" '[[ -z "$live_pane" || -n "$PREDECESSOR" ]] \' 'true \'
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
DEFAULTCTL="$(mutant_scripts defaultctl oversee)" || exit 1
# shellcheck source=lib/shared-skill-libs.sh
source "$TEST_DIR/lib/shared-skill-libs.sh"
orch_fixture_shared_libs "$TMP_ROOT/defaultctl"
mutate_file "$DEFAULTCTL/oversee" '1) SESSION_NAME="${PROJECT_ROOT##*/}" ;;' '1) SESSION_NAME="wrong-repository" ;;'
OVERSEE_BIN="$DEFAULTCTL/oversee" run_oversee ORCH_TMUX_SESSION= -- launch --wait-secs 20
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee: tmux-session-missing session=wrong-repository server=$SOCKET" \
  "control: the wrong default session refuses the same launch"
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
RESOLVEDCTL="$(mutant_scripts resolvedctl oversee)" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/resolvedctl"
mutate_file "$RESOLVEDCTL/oversee" '0) SESSION_NAME="${repo_name#*/}" ;;' \
  '0) if false; then SESSION_NAME="${repo_name#*/}"; else SESSION_NAME="${PROJECT_ROOT##*/}"; fi ;;'
OVERSEE_BIN="$RESOLVEDCTL/oversee" run_oversee ORCH_TMUX_SESSION= FIXTURE_REPO=owner/fleet -- launch --wait-secs 20
assert_eq "$RC|$(sed -n 1p <<<"$OUT")" \
  "1|oversee: tmux-session-missing session=issue-worktree server=$SOCKET" \
  "control: using the issue directory instead of the resolved repository refuses the launch"
RUN_DIR=""
FLEET_STATE="$PRIOR_FLEET_STATE"

# The refusals before anything opens.
for row in \
  "ORCH_OVERSEER_PREFERENCE=|preference-empty setting=ORCH_OVERSEER_PREFERENCE|an empty preference" \
  "ORCH_OVERSEER_PREFERENCE=claude:Opus:high|invalid-preference entry=claude:Opus:high|an entry outside the shape" \
  "ORCH_OVERSEER_PREFERENCE=claude:claude-sonnet-4-6:high|model-window-unknown entry=claude:claude-sonnet-4-6:high model=claude-sonnet-4-6|a claude model the adapter names no window for" \
  "ORCH_TMUX_SESSION=|tmux-session-missing session=work server=$SOCKET|the default repository session is absent" \
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
printf 'account=%s\tharness=claude\tsession-5h-pct=5\tweekly-pct=5\tmodel-pct=5\tmodel-label=Fable 5.1\n' "$H/.claude" > "$TMP_ROOT/accounts-room.tsv"
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
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(keyed registered "$OUT" | sed -n 1p)|$(recorded runtime)|$(recorded account)|$(recorded launch_line)|$(recorded server_start)" \
  "0|oversee: identity-fallback session=$HAND cause=no-start-row|oversee: registered session=$HAND window=$(tm display-message -p -t "$HAND" '#{window_id}') server=$SERVER_PID generation=4 account=$H/.eclaude retained=none fresh=account,cwd,generation,harness,home,pane,runtime,server,server_start,session_rows,window|tmux|$H/.eclaude|none|$SERVER_START" \
  "register with no SessionStart row reads the pane as the named fallback, says so, writes the record one generation past it with its server's start, and drops the launch line the record held"
HAND_IDENTITY="claude|$H/.eclaude|$H/.eclaude|none|none|$(tm display-message -p -t "$HAND" '#{pane_current_path}')|"
assert_eq "$(identity)" "$HAND_IDENTITY" \
  "register records the harness the pane runs, its account and directory, and no model or effort"
# register's control: a harness read that names none leaves the record without one.
# No proven prior harness may mask the missing fresh reading in this control.
jq 'del(.overseer.harness)' "$FLEET_STATE" > "$FLEET_STATE.tmp" && mv -- "$FLEET_STATE.tmp" "$FLEET_STATE"
REGCTL="$(mutant_scripts regctl oversee)" || exit 1
mutate_file "$REGCTL/oversee" '    claude) harness=claude ;;' '    claude) ;;'
OVERSEE_BIN="$REGCTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(recorded harness)" "0|none" \
  "control: a register that reads no harness records none"
# The start's control: a writer that drops the server start records none.
STARTCTL="$(mutant_scripts startctl lib/overseer-launch.sh)" || exit 1
mutate_file "$STARTCTL/lib/overseer-launch.sh" 'server_start: ($start | tonumber)}' 'server_start: null}'
cp -- "$FLEET_STATE" "$TMP_ROOT/state.bound"
OVERSEE_BIN="$STARTCTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(recorded server_start)" "0|none" \
  "control: a register whose writer drops the server start records none"
mv -- "$TMP_ROOT/state.bound" "$FLEET_STATE"
# A server start that cannot be read writes nothing: a record with no start
# would name no session.
run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
BOUND_RECORD="$(jq -c .overseer "$FLEET_STATE")"
printf '%s\n' "$HAND" > "$TMP_ROOT/nostart-pane"
run_oversee PATH="$NOSTART_PATH" TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(keyed record-unwritten "$OUT" | sed -n 1p)|$(jq -c .overseer "$FLEET_STATE")" \
  "1|oversee: record-unwritten field=overseer|$BOUND_RECORD" \
  "a register whose server start cannot be read refuses and leaves the record as it stood"
# Its control: a writer that takes an unread start as none records the pane
# with no start.
UNREADCTL="$(mutant_scripts unreadctl lib/overseer-launch.sh)" || exit 1
mutate_file "$UNREADCTL/lib/overseer-launch.sh" \
  '    if ! start="$(ol_session_start "$4" "$2")"; then' '    if ! start="$(ol_session_start "$4" "$2")" && false; then'
mutate_file "$UNREADCTL/lib/overseer-launch.sh" \
  'server_start: ($start | tonumber)}' 'server_start: (if $start == "" then null else $start | tonumber end)}'
cp -- "$FLEET_STATE" "$TMP_ROOT/state.bound"
OVERSEE_BIN="$UNREADCTL/oversee" run_oversee PATH="$NOSTART_PATH" TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(recorded server_start)" "0|none" \
  "control: a register that takes an unread start as none records the pane with no start"
mv -- "$TMP_ROOT/state.bound" "$FLEET_STATE"
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
ROWCTL="$(mutant_scripts rowctl oversee)" || exit 1
mutate_file "$ROWCTL/oversee" '  if (( start_rc == 0 )) && [[ -n "$SR_HARNESS" && -n "$SR_CWD" ]]; then' '  if false; then'
OVERSEE_BIN="$ROWCTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.eclaude" -- register
assert_eq "$RC|$(recorded model)" "0|none" \
  "control: a register that reads no row records the pane's identity, with no model"
: > "$HAND_ROWS"
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
  "0|lane=$H/.claude;-n;overseer;--model;fable;--effort;high;$BYPASS;$COMPACT;$BRIEF;" \
  "ORCH_QUESTION_TOOL=overseer launches the overseer with its question tool"
tm kill-window -t "$(recorded window)"

# A fleet whose settings name no preference: the first launch walks the default
# ladder and opens on its Opus rung.
LAUNCH_PREF=unset run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(recorded model)|$(recorded_argv)" \
  "0|claude-opus-5-5|lane=$H/.claude;-n;overseer;--model;claude-opus-5-5;--effort;high;$BYPASS;$COMPACT;$QUESTION_OFF;$BRIEF;" \
  "an unset preference launches the first overseer on the default ladder's Opus rung"
tm kill-window -t "$(recorded window)"

# A pi entry ahead of a claude entry with room: the launch table names no
# permission word to open pi unattended, so the first launch skips it before
# its pick and opens on the claude entry.
pi_first_row() { # [OVERSEE_BIN]
  OVERSEE_BIN="${1:-}" LAUNCH_PREF='pi:openai/gpt-5:high,claude:fable:high' run_oversee -- launch --wait-secs 20
}
pi_first_row
assert_eq "$RC|$(keyed entry-permission-unwritable "$OUT" | sed -n 1p)|$(recorded harness)|$(recorded model)" \
  "0|oversee: entry-permission-unwritable entry=pi:openai/gpt-5:high harness=pi|claude|fable" \
  "a first launch skips a pi entry and opens on the claude entry after it"
tm kill-window -t "$(recorded window)"
# Its control: a walk that chooses the pi entry refuses the whole launch.
PIFIRSTCTL="$(mutant_scripts pifirstctl lib/overseer-launch.sh)" || exit 1
mutate_file "$PIFIRSTCTL/lib/overseer-launch.sh" '    launch_choice_permission_write "$OL_HARNESS" >/dev/null && return 0' '    return 0'
pi_first_row "$PIFIRSTCTL/oversee"
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | awk '{print $2, $3}')|$(overseers)" "1|launch-choice-failed entry=pi:openai/gpt-5:high|0" \
  "control: a first launch that chooses the pi entry refuses and opens nothing"

# A first launch on a copilot entry: `lanes pick --harness copilot` judges a
# Copilot account on its monthly pool, so the overseer opens on the account
# the pick names, under COPILOT_HOME, with the model and effort the entry
# names and copilot's full-bypass word. The installed extension records the
# overseer's context reading.
cat > "$BIN/copilot" <<STUB
#!/bin/sh
{ printf 'home=%s\n' "\${COPILOT_HOME:-}"; printf '%s\n' "\$@"; } > "$TMP_ROOT/argv.copilot"
echo 'esc to interrupt'
exec sleep 100000
STUB
chmod +x "$BIN/copilot"
COP_SL="$TMP_ROOT/sl/copilot-statusline"
mkdir -p "$TMP_ROOT/sl" "$H/.1copilot"
printf '#!/bin/sh\n' > "$COP_SL"
chmod +x "$COP_SL"
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
tm kill-window -t "$(recorded window)"
# Main's admission checks only the statusLine setting and installs no reader.
# Restore that behavior on a disposable copy, with an executable statusLine
# that emits no reading. The real hook and --check-marks stay unchanged.
DROPINSTALL="$(mutant_scripts dropinstall lib/overseer-launch.sh)" || exit 1
mutate_file "$DROPINSTALL/lib/overseer-launch.sh" \
  '    if [[ "$OL_HARNESS" == copilot ]] && ! copilot_context_install "$OL_PICKED_DIR"; then' \
  '    if [[ "$OL_HARNESS" == copilot ]] && ! lane_adapter_copilot_status_line "$OL_PICKED_DIR"; then'
rm -rf -- "${H:?}/.1copilot/extensions"
printf '{"statusLine":{"type":"command","command":"%s","refreshInterval":30}}\n' "$COP_SL" > "$H/.1copilot/settings.json"
copilot_first_row "$DROPINSTALL/oversee"
assert_eq "$RC" 0 "control reaches the launch, not an unrelated refusal"
copilot_context_flow "$TMP_ROOT/work" "$H" "$H/.1copilot" "$SRC_DIR" \
  TMUX="$TMUX_ADDR" TMUX_PANE="$(recorded pane)" TMUX_TMPDIR="$TMUX_DIR" \
  ORCH_LANES_FETCH_CMD="$FETCHER" FIXTURE_DIR="$FIXTURE_DIR"
assert_eq "$FLOW_RECORD|$(grep -c '^oversee-succeed: mark-reached ' <<<"$FLOW_VERDICT" || true)" \
  'none|0' "control: main's missing installer produces no context succession verdict"
# A configured statusLine is a reader even if this fixture emits no record.
# Remove it to exercise SessionStart's independent missing-reader rule.
printf '{}\n' > "$H/.1copilot/settings.json"
copilot_context_flow "$TMP_ROOT/work" "$H" "$H/.1copilot" "$SRC_DIR" \
  TMUX="$TMUX_ADDR" TMUX_PANE="$(recorded pane)" TMUX_TMPDIR="$TMUX_DIR" \
  ORCH_LANES_FETCH_CMD="$FETCHER" FIXTURE_DIR="$FIXTURE_DIR"
assert_eq "$(jq -r '.additionalContext | split("\n")[0] | startswith("lane-mail-check: context-reader=missing ")' <<<"$FLOW_START")" \
  true "SessionStart reports the fleet overseer's missing reader as context without a mailbox file"
# The start notice's control keeps the real mark judge and changes only the
# missing-reader report in a private copy of the hook.
cp "$TEST_DIR/../../../hooks/lane-mail-check.sh" "$TMP_ROOT/no-start-reader.sh"
mutate_file "$TMP_ROOT/no-start-reader.sh" \
  '    if ! "$BASH" -euo pipefail -c '\''. "$1/lib/lane-context.sh" && copilot_context_reader "$2"' \
  '    if false && ! "$BASH" -euo pipefail -c '\''. "$1/lib/lane-context.sh" && copilot_context_reader "$2"'
FLOW_JUDGE="$TMP_ROOT/no-start-reader.sh" copilot_context_flow "$TMP_ROOT/work" "$H" "$H/.1copilot" "$SRC_DIR" \
  TMUX="$TMUX_ADDR" TMUX_PANE="$(recorded pane)" TMUX_TMPDIR="$TMUX_DIR" \
  ORCH_LANES_FETCH_CMD="$FETCHER" FIXTURE_DIR="$FIXTURE_DIR"
assert_eq "$FLOW_START" '' "control: suppressing the missing-reader check loses its SessionStart context"
tm kill-window -t "$(recorded window)"
# Its control: a preference parse naming no copilot refuses the entry and
# opens nothing.
COPILOTFIRSTCTL="$(mutant_scripts copilotfirstctl lib/overseer-launch.sh)" || exit 1
mutate_file "$COPILOTFIRSTCTL/lib/overseer-launch.sh" \
  '    elif ! [[ "$entry" =~ ^(claude|codex|copilot):[a-z][a-z0-9.-]*:[a-z]+$ \' \
  '    elif ! [[ "$entry" =~ ^(claude|codex):[a-z][a-z0-9.-]*:[a-z]+$ \'
copilot_first_row "$COPILOTFIRSTCTL/oversee"
assert_eq "$RC|$(sed -n 1p <<<"$OUT" | awk '{print $2, $3}')|$(overseers)" "1|invalid-preference entry=copilot:gpt-5.3-codex:high|0" \
  "control: a preference parse naming no copilot refuses the copilot entry and opens nothing"

# The writer's control: a record write that leaves the launch identity out,
# over a fleet with no prior record, records a session nothing says the
# harness or model of.
WRITECTL="$(mutant_scripts writectl lib/overseer-launch.sh)" || exit 1
mutate_file "$WRITECTL/lib/overseer-launch.sh" '($identity | nonempty) as $known' '({} | nonempty) as $known'
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
REGISTERHOOKCTL="$(mutant_scripts registerhookctl oversee)" || exit 1
mutate_file "$REGISTERHOOKCTL/oversee" '    if ! copilot_hooks_gate "$cwd" "$home"; then' \
  '    if false && ! copilot_hooks_gate "$cwd" "$home"; then'
register_on "$COPILOT_PANE" "$REGISTERHOOKCTL/oversee" --account "$H/.1copilot"
assert_eq "$RC|$(grep -c '^oversee: turn-end-hook=missing harness=copilot ' <<<"$OUT" || true)" '0|0' \
  "control: register without its Copilot hook gate loses the missing-hook notice"
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
# One control per rule: the process read, the account, the command gate and
# the depth bound, each through the shared reader register calls.
COPILOTCTL="$(mutant_scripts copilotctl lib/lane-context.sh)" || exit 1
mutate_file "$COPILOTCTL/lib/lane-context.sh" '      if [[ -n "$found" ]]; then' '      if false; then'
register_on "$COPILOT_PANE" "$COPILOTCTL/oversee" --account "$H/.1copilot"
assert_eq "$RC|$(recorded harness)" "0|none" \
  "control: a register that reads no process under the pane records no harness for copilot"
ACCTCTL="$(mutant_scripts acctctl oversee)" || exit 1
mutate_file "$ACCTCTL/oversee" '      ACCOUNT="${ACCOUNT:-$LANE_PANE_ACCOUNT}"' '      ACCOUNT="${ACCOUNT:-$(lane_context_caller_cfg claude)}"'
register_on "$FRESH_PANE" "$ACCTCTL/oversee"
assert_eq "$RC|$(recorded account)" "0|$H/.claude" \
  "control: a register that takes the derived account records the claude one for a copilot pane"
GATECTL="$(mutant_scripts gatectl lib/lane-context.sh)" || exit 1
mutate_file "$GATECTL/lib/lane-context.sh" '    node | copilot)' '    *)'
register_on "$WRAPPED_PANE" "$GATECTL/oversee"
assert_eq "$RC|$(recorded harness)" "0|copilot" \
  "control: without the command gate a wrapper pane with a Copilot run under it reads copilot"
DEPTHCTL="$(mutant_scripts depthctl lib/lane-context.sh)" || exit 1
mutate_file "$DEPTHCTL/lib/lane-context.sh" '"$name_re" 1 2 pids)' '"$name_re" 1 "" pids)'
register_on "$DEEP_PANE" "$DEPTHCTL/oversee"
assert_eq "$RC|$(recorded harness)" "0|copilot" \
  "control: without the depth bound a Copilot run deep under a node pane reads copilot"
# A running home whose EXTENSIONS flag is false and that sets no statusLine
# takes no reader: register warns and still records the session.
cp -- "$H/.1copilot/settings.json" "$TMP_ROOT/settings.before-disabled"
printf '{"enabledFeatureFlags":{"EXTENSIONS":false}}\n' > "$H/.1copilot/settings.json"
register_on "$COPILOT_PANE" '' --account "$H/.1copilot"
assert_eq "$RC|$(grep -c '^oversee: context-reader=missing .*detail=disabled ' <<<"$OUT")|$(recorded pane)|$(recorded harness)|$(recorded account)" \
  "0|1|$COPILOT_PANE|copilot|$H/.1copilot" \
  "register on a copilot home with extensions off and no statusLine warns context-reader=missing and records the session"
MISSINGCTL="$(mutant_scripts missingctl oversee)" || exit 1
mutate_file "$MISSINGCTL/oversee" '      message context-reader=missing "home=$home"' '      : context-reader=missing "home=$home"'
register_on "$COPILOT_PANE" "$MISSINGCTL/oversee" --account "$H/.1copilot"
assert_eq "$RC|$(grep -c '^oversee: context-reader=missing ' <<<"$OUT" || true)|$(recorded harness)" "0|0|copilot" \
  "control: register without its missing-reader message loses the warning"
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
cp -- "$TMP_ROOT/state.before-copilot-row" "$FLEET_STATE"
rm -rf -- "${H:?}/.1copilot/extensions"
OVERSEE_BIN="$ROWCTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" CLAUDE_CONFIG_DIR="$H/.claude" -- register
assert_eq "$RC|$(recorded harness)|$(grep -c '^oversee: context-reader=' <<<"$OUT" || true)" "0|none|0" \
  "control: a register that reads no row takes no harness from the pane and installs no Copilot reader"
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
    "0|$want_harness|$H/.claude|$H/.claude|$want_model|$want_effort|$UNNAMED_CWD|$want_line|$want_gen|none|none|$want_retained|account,cwd,generation,home,pane,runtime,server,server_start,session_rows,window" \
    "register with no start row over $what replaces proven fields and retains only that pane's unread fields"
done
# The control reinstates the blanking writer's merge: empty identity values
# and an unpassed launch line erase a proven record of the same pane.
PRESERVECTL="$(mutant_scripts preservectl lib/overseer-launch.sh)" || exit 1
mutate_file "$PRESERVECTL/lib/overseer-launch.sh" '($base + $fresh)' \
  '(($p | del(.pending, .exit, .launch_line)) + $identity + ($fresh | del(.launch_line)))'
cp -- "$TMP_ROOT/state.full" "$FLEET_STATE"
register_on "$UNNAMED_PANE" "$PRESERVECTL/oversee"
assert_eq "$RC|$(recorded harness)|$(recorded model)|$(recorded effort)|$(recorded launch_line)" "0|none|none|none|none" \
  "control: the blanking writer loses the same pane's harness, model, effort and launch line"
# The same writer's other direction: retaining without a binding hands a
# different pane the old pane's launch identity and command.
INHERITCTL="$(mutant_scripts inheritctl lib/overseer-launch.sh)" || exit 1
mutate_file "$INHERITCTL/lib/overseer-launch.sh" \
  '(if $same then $p | del(.pending, .exit) else $identity | map_values(null) end) as $base' \
  '($p | del(.pending, .exit)) as $base'
jq --arg pane "$COPILOT_PANE" '.overseer.pane = $pane' "$TMP_ROOT/state.full" > "$FLEET_STATE"
register_on "$UNNAMED_PANE" "$INHERITCTL/oversee"
assert_eq "$RC|$(recorded harness)|$(recorded model)|$(recorded effort)|$(recorded launch_line)" \
  "0|copilot|gpt-5.3-codex|high|$UNNAMED_LINE" \
  "control: a writer with no binding check gives another pane the old identity and launch line"
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
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "1|oversee: predecessor-not-live session=$OTHER live=$SUCC server=$SOCKET|1" \
  "a predecessor beside a live recorded overseer is refused naming the live one"
tm kill-window -t "$(recorded window)"
run_oversee -- launch --predecessor "$OTHER" --wait-secs 20
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(listed "$OTHER")" \
  "1|oversee: predecessor-not-live session=$OTHER live=none server=$SOCKET|0|1" \
  "a predecessor the fleet does not record as its live overseer is refused and left running"
# Its control: without the check the launch stops that pane.
PREDCTL="$(mutant_scripts predctl oversee)" || exit 1
mutate_file "$PREDCTL/oversee" '[[ -z "$PREDECESSOR" || "$named_pane" == "$PREDECESSOR" ]] \' 'true \'
OVERSEE_BIN="$PREDCTL/oversee" run_oversee -- launch --predecessor "$OTHER" --wait-secs 20
assert_eq "$RC|$(listed "$OTHER")" "0|0" \
  "control: a launch without the predecessor check stops a pane the fleet never recorded"
tm kill-window -t "$(recorded window)"
run_oversee -- launch --session fleet --predecessor "$SUCC" --wait-secs 5
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
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
PENDCTL="$(mutant_scripts pendctl lib/overseer-launch.sh)" || exit 1
mutate_file "$PENDCTL/lib/overseer-launch.sh" \
  '  if [[ "$pending" == pending ]] && ! ol_record_pending "$line" "$identity"; then' '  if false; then'
pending_seen "$PENDCTL/oversee"
assert_eq "$PENDING_SEEN" "none" "control: a succession that skips the pending write leaves none to read"
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
# Its control: a refused stop passed over leaves the successor running beside
# the predecessor and recorded in its place.
STOP_PRIOR="$(jq -c .overseer "$FLEET_STATE")"
STOPCTL="$(mutant_scripts stopctl oversee)" || exit 1
mutate_file "$STOPCTL/oversee" '      stop-failed) abandon close-failed "predecessor=$PREDECESSOR" ;;' '      stop-failed) ;;'
stop_refused "$STOPCTL/oversee"
assert_eq "$RC|$(overseers)|$(listed "$PRED")" "0|2|1" \
  "control: a refused stop passed over runs two overseers"
tm kill-window -t "$(recorded window)"
jq --argjson prior "$STOP_PRIOR" '.overseer = $prior' "$FLEET_STATE" > "$FLEET_STATE.tmp" \
  && mv -- "$FLEET_STATE.tmp" "$FLEET_STATE"

# A pending write the state refuses stops the succession before anything
# opens: the predecessor keeps running and stays the recorded overseer.
pendfail_stub() { # SCRIPTS_DIR — a workflow-state there that refuses the pending write
  rm -f -- "${1:?}/workflow-state"
  cat > "$1/workflow-state" <<STUB
#!/usr/bin/env bash
[[ "\$1 \$2 \$3" != "set oversee overseer.pending" ]] || { echo 'fixture: pending write refused' >&2; exit 1; }
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
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(listed "$PRED")|$(recorded pane)|$(recorded generation)" \
  "1|oversee: record-unwritten field=overseer step=pending|1|1|$PRED|$PRED_GEN" \
  "a pending write the state refuses stops the succession, the predecessor running and recorded"
# Its control: a caller hook that lets the failed write pass stops the
# predecessor with nothing recording its successor.
HOOKCTL="$(mutant_scripts hookctl oversee)" || exit 1
mutate_file "$HOOKCTL/oversee" '    pending-unrecorded | record-unwritten) return 1 ;;' \
  '    pending-unrecorded | record-unwritten) return 0 ;;'
pendfail_stub "$HOOKCTL"
pending_refused "$HOOKCTL/oversee"
assert_eq "$RC|$(listed "$PRED")" "0|0" \
  "control: a hook that lets a failed pending write pass stops the predecessor anyway"
PRED="$(recorded pane)"

# A session record write the state refuses refuses the launch too: the stub
# refuses the first write of the record and lets the put-back through. With
# --predecessor the predecessor keeps running and stays recorded.
recordfail_stub() { # SCRIPTS_DIR
  rm -f -- "${1:?}/workflow-state" "${TMP_ROOT:?}/record-refused"
  cat > "$1/workflow-state" <<STUB
#!/usr/bin/env bash
if [[ "\$1 \$2 \$3" == "set oversee overseer" && ! -e "$TMP_ROOT/record-refused" ]]; then
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
recordfail_stub "$HOOKCTL"
OVERSEE_BIN="$HOOKCTL/oversee" run_oversee -- launch --predecessor "$PRED" --wait-secs 20
assert_eq "$RC|$(listed "$PRED")" "0|0" \
  "control: a hook that lets a failed record write pass stops the predecessor anyway"
tm kill-window -t "$(tm list-windows -t fleet -F '#{window_id} #{window_name}' | awk '$2 == "overseer" { print $1; exit }')"
# A first launch under the same refusal opens no overseer and leaves the
# prior record in place.
FIRST_PRIOR="$(jq -cS .overseer "$FLEET_STATE")"
recordfail_stub "$RECFAIL"
OVERSEE_BIN="$RECFAIL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(keyed record-unwritten "$OUT" | sed -n 1p)|$(overseers)|$(jq -cS .overseer "$FLEET_STATE")" \
  "1|oversee: record-unwritten field=overseer step=write|0|$FIRST_PRIOR" \
  "a first launch whose record write the state refuses opens no overseer and keeps the prior record"
FIRSTCTL="$(mutant_scripts firstctl oversee)" || exit 1
mutate_file "$FIRSTCTL/oversee" '    || abandon record-unwritten field=overseer step=write' '    || :'
recordfail_stub "$FIRSTCTL"
OVERSEE_BIN="$FIRSTCTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(overseers)" "0|1" \
  "control: a first launch that goes on past a refused record write opens an overseer nothing records"
tm kill-window -t "$(tm list-windows -t fleet -F '#{window_id} #{window_name}' | awk '$2 == "overseer" { print $1; exit }')"

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
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)|$(listed "$STALE")" \
    "1|oversee: predecessor-not-live session=$STALE live=none server=$SOCKET|0|1" \
    "a --predecessor naming a pane an earlier server's record names by $row_what is refused and left running"
  run_oversee -- launch --wait-secs 20
  assert_eq "$RC|$(recorded generation)|$(overseers)|$(listed "$STALE")" \
    "0|$((STALE_GEN + 1))|1|1" \
    "a launch over an earlier server's record naming $row_what opens the next generation"
  tm kill-window -t "$(recorded window)"
done
# The controls, one per clause of ol_names that tells the servers apart: a
# liveness check whose test ignores the server pid, or the server start,
# takes that row's record for a live overseer and refuses.
stale_control() { # NAME OLD NEW SERVER START WHAT
  local ctl
  ctl="$(mutant_scripts "$1" lib/overseer-launch.sh)" || exit 1
  mutate_file "$ctl/lib/overseer-launch.sh" "$2" "$3"
  stale_record "$4" "$5"
  STALE_GEN="$(recorded generation)"
  OVERSEE_BIN="$ctl/oversee" run_oversee -- launch --wait-secs 20
  assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
    "1|oversee: overseer-live session=$STALE server=$SOCKET generation=$STALE_GEN|0" \
    "control: a liveness check that ignores the $6 refuses over an earlier server's record"
}
stale_control serverctl \
  '  def ol_names($server; $start; $session): type == "object" and (.server // "") == $server' \
  '  def ol_names($server; $start; $session): type == "object"' 1 "$SERVER_START" "server pid"
stale_control startctl-live \
  '    and (.server_start | tostring) == $start;' '    and true;' \
  "$SERVER_PID" "$EARLIER_START" "server start"
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

# Committed consumer settings still emit the numeric account form. A first
# launch has no caller model, so the harness keeps its default model.
LAUNCH_PREF=claude:1:high run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(sed -n '/^preference-deprecated /p' <<<"$OUT")|$(overseers)|$(recorded harness)|$(recorded account)|$(recorded model)|$(recorded effort)|$(recorded_argv)" \
  "0|preference-deprecated entry=claude:1:high form=harness:model:effort|1|claude|$H/.claude|none|high|lane=$H/.claude;-n;overseer;--effort;high;$BYPASS;$QUESTION_OFF;$BRIEF;" \
  "a numeric preference warns once and launches on the picked account at the supplied effort"
assert_contains "$OUT" "oversee: overseer-launched session=" "the numeric preference reaches a recorded launch"
tm kill-window -t "$(recorded window)"
# Restoring the numeric refusal must turn that warning-and-launch row red.
NUMERICCTL="$(mutant_scripts numericctl lib/overseer-launch.sh)" || exit 1
mutate_file "$NUMERICCTL/lib/overseer-launch.sh" \
  '    if [[ "$entry" =~ ^(claude|codex|copilot|pi):[1-9][0-9]*:[a-z]+$ ]]; then' \
  '    if false && [[ "$entry" =~ ^(claude|codex|copilot|pi):[1-9][0-9]*:[a-z]+$ ]]; then'
LAUNCH_PREF=claude:1:high OVERSEE_BIN="$NUMERICCTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(sed -n 1p <<<"$OUT")|$(overseers)" \
  "1|oversee: invalid-preference entry=claude:1:high|0" \
  "control: numeric refusal turns the warning-and-launch assertion red"
# With no caller model, effort still needs flag writing and permission
# assembly. Each control removes one rule from the numeric launch above.
for row in \
  $'effortctl\tlib/lane-launch.sh\t  [[ -n "$2" || -n "$3" ]] || return 0\t  [[ -n "$2" ]] || return 0\tnone\t1' \
  $'empty-modelctl\tlib/overseer-launch.sh\t  if [[ -z "$model" && -z "$effort" ]]; then\t  if [[ -z "$model" ]]; then\thigh\t0'; do
  IFS=$'\t' read -r name file old new effort permissions <<<"$row"
  EFFORTCTL="$(mutant_scripts "$name" "$file")" || exit 1
  mutate_file "$EFFORTCTL/$file" "$old" "$new"
  LAUNCH_PREF=claude:1:high OVERSEE_BIN="$EFFORTCTL/oversee" run_oversee -- launch --wait-secs 20
  assert_eq "$RC|$(recorded effort)|$(overseers)|$(grep -cxF -- "$BYPASS" "$TMP_ROOT/argv.claude" || true)" \
    "0|$effort|1|$permissions" \
    "control: $name turns the numeric launch assertion red"
  tm kill-window -t "$(recorded window)"
done

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
# Its control: a launcher that opens without the sync leaves the checkout
# behind.
SYNCCTL="$(mutant_scripts syncctl lib/overseer-launch.sh)" || exit 1
mutate_file "$SYNCCTL/lib/overseer-launch.sh" '  ol_checkout_sync "$1" || ol_checkout_notice' '  :'
BEHIND="$(work_head)"
checkout_advance >/dev/null || exit 1
OVERSEE_BIN="$SYNCCTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(work_head)" "0|$BEHIND" "control: a launch without the sync leaves the checkout behind"
tm kill-window -t "$(recorded window)"
# Its control for the order: a launcher that syncs after the session opens
# leaves the checkout synced once it returns, and the harness started on the
# tree behind it.
LATECTL="$(checkout_late_sync latesyncctl)" || exit 1
WANT="$(checkout_advance)" || exit 1
checkout_started_clear
OVERSEE_BIN="$LATECTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(work_head)|$(checkout_started)" "0|$WANT|$BEHIND" \
  "control: a launch that syncs after it opens starts the harness on the tree behind origin"
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
# Its control: a sync that runs sync-base on another branch moves the base
# branch's ref, not the checked-out side branch or its tree, and says
# nothing.
OFFCTL="$(mutant_scripts offbasectl lib/overseer-launch.sh)" || exit 1
mutate_file "$OFFCTL/lib/overseer-launch.sh" '      0) [[ "$branch" == "$base" ]] || OL_SYNC_CAUSE=off-base ;;' '      0) ;;'
git -C "$TMP_ROOT/work" switch -q -c side || exit 1
checkout_advance >/dev/null || exit 1
BEFORE="$(work_head)"
OVERSEE_BIN="$OFFCTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(work_head)|$(unsynced '[^ ]*')" "0|$BEFORE|0" \
  "control: a sync without the base-branch check leaves an off-base checkout behind unreported"
tm kill-window -t "$(recorded window)"
git -C "$TMP_ROOT/work" switch -q main && git -C "$TMP_ROOT/work" branch -q -D side || exit 1
# Its control for a detached head: a sync that lets one through moves the
# base branch's ref to origin's head and leaves the detached tree behind,
# unreported.
DETACHCTL="$(mutant_scripts detachctl lib/overseer-launch.sh)" || exit 1
mutate_file "$DETACHCTL/lib/overseer-launch.sh" '      1) OL_SYNC_CAUSE=off-base branch="a detached head" ;;' '      1) ;;'
WANT="$(checkout_advance)" || exit 1
git -C "$TMP_ROOT/work" switch -q --detach || exit 1
BEFORE="$(work_head)"
OVERSEE_BIN="$DETACHCTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(work_head)|$(git -C "$TMP_ROOT/work" rev-parse main)|$(unsynced '[^ ]*')" "0|$BEFORE|$WANT|0" \
  "control: a sync without the detached-head check leaves a detached checkout behind unreported"
tm kill-window -t "$(recorded window)"
git -C "$TMP_ROOT/work" switch -q main || exit 1
# Its control for the relay of sync-base's key: a parse that finds no key
# reports a dirty checkout as sync-failed, so the dirty row's pin turns red.
KEYCTL="$(mutant_scripts keyctl lib/overseer-launch.sh)" || exit 1
mutate_file "$KEYCTL/lib/overseer-launch.sh" 'sub(/ .*/, ""); print; exit }' 'sub(/ .*/, ""); exit }'
checkout_advance >/dev/null || exit 1
printf 'local\n' >> "$TMP_ROOT/work/README"
OVERSEE_BIN="$KEYCTL/oversee" run_oversee -- launch --wait-secs 20
assert_eq "$RC|$(unsynced dirty)|$(unsynced sync-failed)" "0|0|1" \
  "control: a sync that drops sync-base's key reports a dirty checkout as sync-failed"
tm kill-window -t "$(recorded window)"
git -C "$TMP_ROOT/work" checkout -q -- README || exit 1
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
# Its control: a sync whose bounded call takes 0 seconds, which the runner
# reads as no bound, waits the stall out, and the stub's success reports
# nothing.
STALLCTL="$(mutant_scripts stallctl lib/overseer-launch.sh)" || exit 1
mutate_file "$STALLCTL/lib/overseer-launch.sh" 'kendex_github_run_bounded "$seconds" \' 'kendex_github_run_bounded 0 \'
rm -- "$STALLCTL/sync-base" && printf '#!/bin/sh\nsleep 5\n' > "$STALLCTL/sync-base" && chmod +x "$STALLCTL/sync-base" || exit 1
OVERSEE_BIN="$STALLCTL/oversee" run_oversee ORCH_OVERSEER_SYNC_TIMEOUT_S=1 -- launch --wait-secs 20
assert_eq "$RC|$(unsynced '[^ ]*')" "0|0" "control: a sync with no bound waits out a stalled sync-base and reports no timeout"
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
INVENTORYCTL="$(mutant_scripts inventoryctl oversee)" || exit 1
mutate_file "$INVENTORYCTL/oversee" '    if [[ "$inventory_rc" != 0 ]] || ! awk -v h="$harness"' \
  '    if false && [[ "$inventory_rc" != 0 ]] || false && ! awk -v h="$harness"'
OVERSEE_BIN="$INVENTORYCTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" FIXTURE_HOOK_STATE=missing -- register
assert_eq "$RC|$(grep -c '^oversee: turn-end-hook=missing ' <<<"$OUT" || true)" '0|0' \
  "control: without the inventory check a missing hook goes unreported"
NAMECTL="$(mutant_scripts namectl oversee)" || exit 1
mutate_file "$NAMECTL/oversee" 'n = $2; sub(/.*:/, "", n);' 'n = $2;'
OVERSEE_BIN="$NAMECTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" FIXTURE_HOOK_STATE=enabled -- register
assert_eq "$RC|$(grep -c '^oversee: turn-end-hook=missing ' <<<"$OUT" || true)" '0|1' \
  "control: matching the whole name column misses the installed hook kendex lists as event:matcher:name"
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
CWDCTL="$(mutant_scripts cwdctl oversee)" || exit 1
mutate_file "$CWDCTL/oversee" 'inventory="$(cd -- "$PROJECT_ROOT" && kendex list' 'inventory="$(cd -- "$cwd" && kendex list'
OVERSEE_BIN="$CWDCTL/oversee" run_oversee TMUX="$TMUX_ADDR" TMUX_PANE="$HAND" FIXTURE_HOOK_DIR="$WORK_REAL" -- register
assert_eq "$RC|$(grep -c '^oversee: turn-end-hook=missing harness=claude exit=1 ' <<<"$OUT" || true)" '0|1' \
  "control: an inventory asked from the start row's cwd reads the installed hook as missing"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
