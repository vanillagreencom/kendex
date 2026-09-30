#!/usr/bin/env bash
# Drive the launcher over a real private tmux server. Local launches deliver a
# working screen; a hosted provider holds preparation so its replacement can
# be observed before the background job tries to dial SSH. Both paths must
# leave one resolvable window and preserve the other session's same-name lane.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
source "$TEST_DIR/lib/open-terminal-stubs.sh"
source "$TEST_DIR/lib/lanes-fixture.sh"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-window-replacement: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-window-replacement: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-window-replacement: scratch=resolve-failed" >&2; exit 1; }
SOCK="$TMP_ROOT/tmux.sock"
JOB=""
cleanup() {
  [[ -z "$JOB" ]] || kill -TERM -- "-$JOB" 2>/dev/null || true
  tmux -S "$SOCK" kill-server 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
tm() { env -i HOME="$TMP_ROOT/home" PATH="$BIN:$PATH" REAL_TMUX="$REAL_TMUX" "$REAL_TMUX" -S "$SOCK" "$@"; }

# Copies resolve their project configuration in this isolated repository.
LIVE="$(mutant_scripts repo open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/repo"
git -C "$TMP_ROOT/repo" init -q
git -C "$TMP_ROOT/repo" config gc.auto 0
git -C "$TMP_ROOT/repo" config maintenance.auto false
BIN="$TMP_ROOT/bin"
ot_stub_bin "$BIN"
rm -- "$BIN/tmux"
# The wrapper only plants dependency failures. Every normal call reaches tmux.
REAL_TMUX="$(command -v tmux)"
cat > "$BIN/tmux" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${REPLACEMENT_FAIL:-}" == discovery && "$1" == list-windows && " $* " == *' -f '* ]]; then exit 1; fi
if [[ "${REPLACEMENT_FAIL:-}" == close && "$1" == kill-window ]]; then exit 1; fi
exec "$REAL_TMUX" "$@"
STUB
cat > "$BIN/claude" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'Working (esc to interrupt)\n'
exec sleep 100000
STUB
chmod +x "$BIN/tmux" "$BIN/claude"
HOST="$TEST_DIR/fixtures/lane-host"
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
standard_home home
RUN_SEQ=0

# Each row starts with the dead windows a relaunch can encounter. SPLIT adds
# the extra pane a manually split lane can leave. SOLE removes the controller
# window, so replacement must keep the session itself alive.
run_row() { # LAUNCHER HOST COUNT SPLIT SOLE [FAILURE] [MODE]
  local launcher="$1" host="$2" count="$3" split="$4" sole="$5" failure="${6:-}" mode="${7:---relaunch}" i old pane
  RUN="$TMP_ROOT/run-$((++RUN_SEQ))"
  mkdir -p "$RUN/state" "$RUN/remote"
  if tm has-session -t =fleet 2>/dev/null; then tm kill-session -t =fleet; fi
  if tm has-session -t =fleet-extra 2>/dev/null; then tm kill-session -t =fleet-extra; fi
  tm -f /dev/null new-session -d -s fleet -n CC-10 -x 200 -y 40 'exec /bin/sh'
  tm set-option -g default-shell /bin/sh
  tm set-option -g default-command 'exec /bin/sh'
  tm set-option -g automatic-rename off
  tm set-option -g renumber-windows on
  SIBLING="$(tm new-session -d -s fleet-extra -n CC-1 -P -F '#{pane_id}' 'exec /bin/sh')"
  NEIGHBOUR="$(tm display-message -p -t fleet:CC-10 '#{pane_id}')"
  OLD=""
  i=0
  while [[ "$i" -lt "$count" ]]; do
    old="$(tm new-window -d -t fleet -n CC-1 -P -F '#{pane_id}' 'exec /bin/sh')"
    OLD+="$old "
    if [[ "$split" == yes ]]; then
      old="$(tm split-window -d -t "$old" -P -F '#{pane_id}' 'exec /bin/sh')"
      OLD+="$old "
    fi
    i=$((i + 1))
  done
  [[ "$sole" != yes ]] || tm kill-window -t "$NEIGHBOUR"
  ADDR="$(tm display-message -p -t fleet '#{socket_path},#{pid},0')"
  "$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" init oversee >/dev/null
  "$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" update oversee \
    '.lanes = [{item: "CC-1", harness: "claude", status: "running"}]' >/dev/null
  local host_env=() host_args=()
  if [[ "$host" == hosted ]]; then
    host_args=(--host "$HOST" --repo o/r --lane "$H/.eclaude")
    host_env=(LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" FIXTURE_DIR="$FIXTURE_DIR" ORCH_LANE_MAX_PCT=95
      LANE_HOST_STUB_DIR="$RUN/remote" LANE_HOST_STUB_LOG="$RUN/host.log"
      LANE_HOST_STUB_CREATE_LINE=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc\tstate=preparing'
      LANE_HOST_STUB_WAIT_GATE="$RUN/gate")
  fi
  RC=0
  OUT="$(env -i HOME="$TMP_ROOT/home" PATH="$BIN:$PATH" REAL_TMUX="$REAL_TMUX" \
    TMUX="$ADDR" ORCH_TMUX_SESSION=fleet ORCH_LANE_HOST=local ORCH_OVERSEER_LANES=1000 \
    WORKTREE_CLI="$BIN/worktree" OT_WT_LOG="$RUN/worktree.log" \
    REPLACEMENT_FAIL="$failure" ${host_env[@]+"${host_env[@]}"} \
    "$launcher" --state-dir "$RUN/state" --harness claude --cmd "claude --model opus --effort high --disallowedTools=AskUserQuestion,EnterPlanMode --settings='{\"env\":{\"DISABLE_AUTO_COMPACT\":\"1\"}}'" \
    ${host_args[@]+"${host_args[@]}"} "$mode" CC-1 2>&1)" || RC=$?
  [[ "$RC" == 0 ]] || printf '%s\n' "$OUT"
  JOB="$("$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" get oversee \
    '[.lanes[]? | select(.item == "CC-1") | .prepare.pid // empty] | first // ""')"
  # Local command delivery is asynchronous. Poll the real screen rather than
  # assume the shell has executed the paste when open-terminal returns.
  STATE=""
  for i in $(seq 50); do
    STATE="$(env -i HOME="$TMP_ROOT/home" PATH="$BIN:$PATH" REAL_TMUX="$REAL_TMUX" TMUX="$ADDR" \
      "$SCRIPTS_DIR/lanes" state fleet:CC-1)"
    [[ "$host" != local || "$RC" != 0 || "$STATE" == working || "$mode" != --relaunch ]] && break
    sleep 0.1
  done
  WINDOWS="$(tm list-windows -t =fleet -f '#{==:#{window_name},CC-1}' -F '#{window_id}')"
  COUNT="$(grep -c . <<<"$WINDOWS" || true)"
  PANES="$(tm list-panes -a -F '#{pane_id}')"
  RETAINED=0
  for pane in $OLD; do
    if grep -qxF -- "$pane" <<<"$PANES"; then RETAINED=$((RETAINED + 1)); fi
  done
  RECORD="$("$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" get oversee \
    '[.lanes[]? | select(.item == "CC-1") | "\(.status) \(.window // "")"] | first')"
  if [[ -n "$JOB" ]]; then kill -TERM -- "-$JOB"; JOB=""; fi
}

# Local and hosted relaunches reach the same window creator, including the
# hosted launch_handoff path that opens a window before its host is ready.
for row in 'local|0|no|no|working' 'local|1|no|no|working' 'local|2|no|no|working' \
  'local|1|yes|no|working' 'local|1|no|yes|working' \
  'hosted|0|no|no|exited' 'hosted|1|no|no|exited' 'hosted|2|no|no|exited' \
  'hosted|1|yes|no|exited' 'hosted|1|no|yes|exited'; do
  IFS='|' read -r host count split sole expect <<<"$row"
  run_row "$LIVE" "$host" "$count" "$split" "$sole"
  KEPT="$(tm display-message -p -t "$SIBLING" '#{pane_id}')"
  if [[ "$sole" == yes ]]; then neighbour=removed; want_neighbour=removed
  else neighbour="$(tm display-message -p -t "$NEIGHBOUR" '#{pane_id}')"; want_neighbour="$NEIGHBOUR"; fi
  record='running fleet:CC-1'
  [[ "$host" != hosted ]] || record='preparing fleet:CC-1'
  assert_eq "$RC|$COUNT|$RETAINED|$STATE|$RECORD|$KEPT|$neighbour" \
    "0|1|0|$expect|$record|$SIBLING|$want_neighbour" \
    "$row: replace old panes, keep one judged lane and preserve the sibling and neighbour"
done

# Plain launches retain their insertion semantics; replacement is opt-in.
run_row "$LIVE" local 1 no no '' --tmux
assert_eq "$RC|$COUNT|$RETAINED" '0|2|1' 'a launch without --relaunch does not kill an existing window'

for row in 'discovery|1|list-windows' 'close|2|kill-window'; do
  IFS='|' read -r failure count operation <<<"$row"
  run_row "$LIVE" local "$count" no no "$failure"
  assert_eq "$RC|$COUNT|$RETAINED|$(grep -cF "open-terminal: tmux-failed operation=$operation item=CC-1" <<<"$OUT")" \
    "1|$count|$count|1" "a failed $operation refuses replacement without starting another window"
done

# A private production mutant disables the replacement option but keeps the
# discovery and its text. The same full launch then leaves an ambiguous name.
MUTANT="$(mutant_scripts mutant open-terminal)/open-terminal"
orch_fixture_shared_libs "$TMP_ROOT/mutant"
git -C "$TMP_ROOT/mutant" init -q
git -C "$TMP_ROOT/mutant" config gc.auto 0
git -C "$TMP_ROOT/mutant" config maintenance.auto false
mutate_file "$MUTANT" '[[ -z "$replace_idx" ]] || window_args=(-k -t' '[[ -n "$replace_idx" ]] || window_args=(-k -t'
run_row "$MUTANT" local 1 no no
assert_eq "$RC|$COUNT|$RETAINED|$STATE" '0|2|1|unjudged' \
  'control: without replacement the same test sees two windows and lanes state is unjudged'

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
