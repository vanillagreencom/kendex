#!/usr/bin/env bash
# open-terminal's relaunch route on a hosted lane: relaunch_route decides
# between the native resume and the start brief, start_cmd renders that verdict,
# and open_tmux counts the lane as launched only once its pane shows a harness.
#
# A hosted claude relaunch renders `--continue` with the start brief behind it,
# which runs where claude exits 1, its answer where the host holds no session. A
# relaunch whose harness differs from the one the fleet record names renders the
# start brief alone. Claude verifies its brief; Codex and Pi share the same
# harness-screen wait as a resume-or-fresh launch. A
# pane that shows no harness screen is no launched lane: its window closes and
# only then does its fleet record read stopped. A relaunch that has not taken,
# recorded preparing or stopped, leaves the harness the record names.
#
# tmux, worktree and gh are the shared open-terminal stubs, and the host is the
# lane-host fixture. The rendered remote command is also run for real, against
# stub harnesses, which show that the start brief runs in the same call.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export ORCH_LANE_HOST=local ORCH_OVERSEER_LANES=1000
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANE_COPILOT_POOL ORCH_LANES_USAGE_TTL CODEX_HOME
unset ORCH_LANES_CLAUDE_CLIENT_ID ORCH_LANES_TOKEN_CMD ORCH_LANES_CLAUDE_TOKEN_URL
unset PI_CODING_AGENT_DIR PI_CODING_AGENT_SESSION_DIR
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
OPEN_TERMINAL="$SCRIPTS_DIR/open-terminal"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-relaunch-route: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-relaunch-route: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-relaunch-route: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/lanes-fixture.sh
source "$TEST_DIR/lib/lanes-fixture.sh"
# shellcheck source=lib/open-terminal-stubs.sh
source "$TEST_DIR/lib/open-terminal-stubs.sh"
# mutant_scripts and mutate_file, the two halves of each control.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

# Every launch runs on the fixture's measured eclaude account, named `work`.
FETCHER="$TMP_ROOT/fetch"
make_fetcher "$FETCHER"
standard_home home
OT_STUB_BIN="$TMP_ROOT/ot-bin"
ot_stub_bin "$OT_STUB_BIN"
HOST_STUB="$TEST_DIR/fixtures/lane-host"
# The screen a working claude draws, which pane_harness_up reads as a harness.
HARNESS_SCREEN="$TMP_ROOT/harness-screen"
printf 'Working (esc to interrupt)\n' > "$HARNESS_SCREEN"
PI_SCREEN="$TEST_DIR/fixtures/oversee-watch/pi-working.txt"

# A claude that logs its argv, one line per run. A `--continue` run exits
# $CLAUDE_CONTINUE_RC after the words claude prints where it finds no session;
# any other run exits 0.
HARNESS_BIN="$TMP_ROOT/harness-bin"
mkdir -p "$HARNESS_BIN"
cat > "$HARNESS_BIN/claude" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLAUDE_LOG"
case " $* " in *' --continue '*) echo 'No conversation found to continue' >&2; exit "$CLAUDE_CONTINUE_RC" ;; esac
exit 0
EOF
chmod +x "$HARNESS_BIN/claude"

RUN_SEQ=0
# run_ot RECORDED SCREEN HARNESS — one hosted relaunch of KEN-1 on HARNESS into
# a fleet whose record for KEN-1 names RECORDED and reads running, with the
# entries SEED_LANES holds after it; RECORDED `-` runs on the fleet state the
# previous run left. SCREEN is the harness screen file, `-` for a pane that
# never draws one. RUN_ENV holds any further stub settings for the run. Sets
# OUT, RC and RUN.
RUN_ENV=() SEED_LANES='[]' SELECT_KIND=-
run_ot() {
  local recorded="$1" screen="$2" harness="$3" flags='--model opus --effort high' prev="${RUN:-}" lane=work pool=""
  [[ "$harness" != codex ]] || flags='-m gpt-6-astra -c model_reasoning_effort=high'
  if [[ "$harness" == pi ]]; then
    flags='--model github-copilot/claude-sonnet-5 --thinking high'
    lane=auto pool="$TMP_ROOT/pi-pool=1/10"
    mkdir -p "$TMP_ROOT/pi-pool"
  fi
  [[ "$screen" != - ]] || screen=""
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN/remote/srv/lane"
  printf 'gitdir: /srv/clone/.git/worktrees/lane\n' > "$RUN/remote/srv/lane/.git"
  local create_line=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc'
  if [[ "$harness" == pi ]]; then
    create_line+=$'\tpi-root=/srv/pi'
    mkdir -p "$RUN/remote/srv/pi/packages/@vanillagreen/pi-hooks/extensions"
    printf '{"compaction":{"enabled":false}}\n' > "$RUN/remote/srv/pi/settings.json"
    printf '{"pi":{"extensions":["./extensions/hooks.ts","./extensions/lane-mail-wake.ts"]}}\n' > "$RUN/remote/srv/pi/packages/@vanillagreen/pi-hooks/package.json"
    printf 'export const f = { context_window: 1 };\n' > "$RUN/remote/srv/pi/packages/@vanillagreen/pi-hooks/extensions/vocab.ts"
  fi
  # A seeded state's overseer record names the checkout the launch runs from,
  # the directory the overseer binding reads the fleet's repository off.
  if [[ "$recorded" == - ]]; then
    cp -R "$prev/state" "$RUN/state" || { echo "open-terminal-relaunch-route: seed-failed run=$RUN" >&2; exit 1; }
  elif ! mkdir -p "$RUN/state" || ! "$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" init oversee >/dev/null \
    || ! "$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" update oversee --arg h "$recorded" --argjson extra "$SEED_LANES" --arg cwd "$PWD" \
      '.overseer = {cwd: $cwd} | .lanes = [{item: "KEN-1", harness: $h, model: "last-model", account: "last-account", session_id: "last-session", status: "running"}] + $extra' >/dev/null; then
    echo "open-terminal-relaunch-route: seed-failed run=$RUN" >&2
    exit 1
  fi
  local -a selection_env=(LANE_HOST_STUB_SELECTION=resume)
  if [[ "$SELECT_KIND" != - ]]; then
    selection_env=(LANE_HOST_STUB_SELECTION= OT_REPLAY_LIB="$TEST_DIR/lib/open-terminal-stubs.sh"
      OT_REPLAY_SCRIPTS="${OPEN_TERMINAL%/*}" OT_REPLAY_RUN="$RUN/inline" OT_REPLAY_HARNESS="$harness"
      OT_REPLAY_KIND="$SELECT_KIND" OT_REPLAY_SANDBOX="$RUN/remote/srv/lane" OT_REPLAY_ITEM=KEN-1)
    mkdir -p "$RUN/inline"
  fi
  OUT="$(env LINEAR_TEAM= LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_MAX_PCT=95 ORCH_LANE_ALIASES=eclaude=work ORCH_LANE_COPILOT_POOL="$pool" \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' LANE_HOST_STUB_DIR="$RUN/remote" LANE_HOST_STUB_LOG="$RUN/host.log" LANE_HOST_STUB_CREATE_LINE="$create_line" \
    ORCH_TMUX_VERIFY_SECS=1 ORCH_LANE_SSH_PROMPT_SECS=1 OT_HARNESS_SCREEN="$screen" "${selection_env[@]}" ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    TMUX=stub,1,0 ORCH_TMUX_SESSION=stub OT_TMUX_LOG="$RUN/tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$RUN/panes" \
    OT_WT_LOG="$RUN/worktree.log" OVERSEE_WATCH_STATE_DIR="$RUN/state" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    "$OPEN_TERMINAL" --state-dir "$RUN/state" --host "$HOST_STUB" --repo o/r --relaunch \
    --harness "$harness" --lane "$lane" --launch-flags "$flags" KEN-1 2>&1)"
  RC=$?
  printf '%s\n' "$OUT" > "$RUN/launcher.out"
}
# The remote command the run typed into its ssh session.
remote() { grep -m1 '^exec bash -lc ' "$RUN/tmux.log" || echo none; }
said() { grep -c -- "$1" <<<"$OUT" || true; }
launched() { sed -n 's/.*summary launched=\([0-9]*\).*/\1/p' <<<"$OUT"; }
closed() { grep -c '^kill-window ' "$RUN/tmux.log" || true; }
status() { "$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" get oversee '[.lanes[]? | objects | select(.item == "KEN-1") | .status] | first // "none"'; }
recorded() { "$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" get oversee '[.lanes[]? | objects | select(.item == "KEN-1") | "\(.status) \(.harness)"] | first // "none"'; }
# settled — recorded once the background job has left preparing. The job runs
# after open-terminal returns, so this polls, 20 seconds at most.
settled() {
  local now=""
  for _ in $(seq 80); do
    now="$(recorded)"
    [[ "$now" == preparing* ]] || break
    sleep 0.25
  done
  printf '%s' "$now"
}
# prepared_fail RECORDED HARNESS — a relaunch of KEN-1 on HARNESS over a record
# naming RECORDED whose host answers state=preparing and whose wait then fails.
# Sets HELD, the record while the job waits at its gate, and SETTLED, the
# record once the job wrote its outcome.
PREPARING_LINE=$'ssh-target=lane.example\tpath=/srv/lane\tremote-prefix=exec bash -lc\tstate=preparing'
prepared_fail() {
  local gate="$TMP_ROOT/gate-$((RUN_SEQ + 1))"
  RUN_ENV=(LANE_HOST_STUB_CREATE_LINE="$PREPARING_LINE" LANE_HOST_STUB_WAIT_GATE="$gate" LANE_HOST_STUB_WAIT_STATUS=1)
  run_ot "$1" - "$2"
  RUN_ENV=()
  HELD="$(recorded)"
  touch "$gate"
  SETTLED="$(settled)"
}
# replay RC — runs the typed remote command against the stub claude, its
# `--continue` exiting RC, in a sandbox of its own, and prints each claude run
# it made as `continue` or `fresh`, joined by `,`.
replay() {
  local sandbox="$RUN/sandbox" line
  mkdir -p "$sandbox"
  : > "$RUN/claude.log"
  line="$(remote | sed -e 's/^exec bash -lc /bash -c /' -e "s#cd /srv/lane #cd $sandbox #")"
  env -i PATH="$HARNESS_BIN:$PATH" HOME="$RUN" CLAUDE_LOG="$RUN/claude.log" CLAUDE_CONTINUE_RC="$1" bash -c "$line" 2>/dev/null
  awk '/ --continue / { r = r s "continue"; s = "," ; next } /^-n KEN-1 .*\/orch start KEN-1 / { r = r s "fresh"; s = "," ; next } { r = r s "other"; s = "," } END { print (r == "" ? "none" : r) }' "$RUN/claude.log"
}

echo "=== a hosted claude relaunch continues, and runs the start brief where claude finds no session ==="
run_ot claude "$HARNESS_SCREEN" claude
assert_eq "rc=$RC launched=$(launched) continue=$(remote | grep -c -- "--continue '" ) fallback=$(remote | grep -cF "|| [ \$? -ne 1 ] || exec claude -n KEN-1 ")" \
  "rc=0 launched=1 continue=1 fallback=1" \
  "a hosted claude relaunch renders --continue with the start brief behind it, and counts once its pane shows a harness"
# One row per status claude can end --continue with: 1 is its no-session exit,
# 0 a lane quit by hand, 143 a lane stopped by a signal.
for row in '1|continue,fresh' '0|continue' '143|continue'; do
  assert_eq "$(replay "${row%%|*}")" "${row#*|}" \
    "a --continue that exits ${row%%|*} runs: ${row#*|}"
done

echo "=== a pane that shows no harness is no launched lane ==="
# The bound is twice ORCH_TMUX_VERIFY_SECS, one for each claude start.
run_ot claude - claude
assert_eq "rc=$RC launched=$(launched) missing=$(said '^open-terminal: harness-screen-missing item=KEN-1 seconds=2') closed=$(closed) status=$(status)" \
  "rc=1 launched=0 missing=1 closed=1 status=stopped" \
  "a hosted relaunch whose pane shows no harness is harness-screen-missing, not launched, its window closed and its record stopped"

echo "=== hosted Codex and Pi select a session or the start brief on the host ==="
# Native Codex resume --last and Pi -c silently start fresh on an empty store.
# Each row executes the command start_cmd rendered, with the real host lookup.
for harness_screen in "codex|$HARNESS_SCREEN" "pi|$PI_SCREEN"; do
  harness="${harness_screen%%|*}" screen="${harness_screen#*|}"
  for row in 'none|0|rc=0 runs=1 resume=0 fresh=1 target=0' \
    'foreign|0|rc=0 runs=1 resume=0 fresh=1 target=0' \
    'empty|0|rc=0 runs=1 resume=0 fresh=1 target=0' \
    'matching|0|rc=0 runs=1 resume=1 fresh=0 target=1' \
    'matching|1|rc=1 runs=1 resume=1 fresh=0 target=1' \
    'matching|143|rc=143 runs=1 resume=1 fresh=0 target=1' \
    'newer-foreign|0|rc=0 runs=1 resume=1 fresh=0 target=1' \
    'newer-worker|0|rc=0 runs=1 resume=1 fresh=0 target=1' \
    'worker-only|0|rc=0 runs=1 resume=0 fresh=1 target=0' \
    'newer-exec|0|rc=0 runs=1 resume=1 fresh=0 target=1' \
    'exec-only|0|rc=0 runs=1 resume=0 fresh=1 target=0' \
    'newer-parent|0|rc=0 runs=1 resume=1 fresh=0 target=1' \
    'parent-only|0|rc=0 runs=1 resume=0 fresh=1 target=0' \
    'scan-failed|0|rc=2 runs=0 resume=0 fresh=0 target=0'; do
    kind="${row%%|*}" rest="${row#*|}" exit_status="${rest%%|*}" expected="${rest#*|}"
    [[ "$harness" != pi || ! "$kind" =~ (worker|exec|parent) ]] || continue
    if [[ "$exit_status" == 0 && ( "$kind" == none || "$kind" == matching ) ]]; then
      SELECT_KIND="$kind" run_ot "$harness" "$screen" "$harness"
      assert_eq "rc=$RC launched=$(launched) closed=$(closed) status=$(status)" \
        'rc=0 launched=1 closed=0 status=running' \
        "$harness $kind keeps a healthy harness screen running" "$RUN/launcher.out"
      assert_eq "$(cat "$RUN/inline/replay.out")" "$expected" \
        "$harness $kind executes the host's actual selection before reporting success"
      lineless=0
      [[ "$harness:$kind" != codex:matching ]] || lineless=1
      assert_eq "lineless=$(said '^open-terminal: resume-lineless item=KEN-1 harness=codex$') continuation=$(tr '\0' '\n' < "$RUN/inline/harness.log" | grep -c 'Resume the orch workflow' || true)" \
        "lineless=$lineless continuation=$([[ "$harness:$kind" == pi:matching ]] && echo 1 || echo 0)" \
        "$harness $kind owes a paste only for an actual promptless Codex resume" "$RUN/launcher.out"
    fi
    replay_run="$RUN/replay-$kind-$exit_status"
    assert_eq "$(ot_replay_relaunch "$(remote)" "${OPEN_TERMINAL%/*}" "$replay_run" "$harness" "$kind" "$exit_status" KEN-1)" \
      "$expected" "$harness $kind exit=$exit_status selects the host session or start brief" "$replay_run/replay.err"
  done
  run_ot "$harness" - "$harness"
  assert_eq "rc=$RC launched=$(launched) missing=$(said '^open-terminal: harness-screen-missing item=KEN-1 seconds=2') closed=$(closed) status=$(status)" \
    'rc=1 launched=0 missing=1 closed=1 status=stopped' \
    "$harness at a shell is not launched and its lane stops"
  RUN_ENV=(ORCH_TMUX_VERIFY_SECS=abc)
  run_ot "$harness" "$screen" "$harness"
  RUN_ENV=()
  assert_eq "rc=$RC invalid=$(said '^open-terminal: verify-seconds-invalid setting=ORCH_TMUX_VERIFY_SECS value=abc')" \
    'rc=1 invalid=1' "$harness relaunch refuses an invalid screen-wait bound"
done
# A pane this machine cannot read is the local tmux failure it is, never a
# harness that showed no screen. The first capture is the ssh prompt wait's.
CAPTURE_FAILS=(OT_TMUX_FAIL_NTH=capture-pane:2)
RUN_ENV=("${CAPTURE_FAILS[@]}")
run_ot claude "$HARNESS_SCREEN" claude
RUN_ENV=()
assert_eq "rc=$RC launched=$(launched) failed=$(said '^open-terminal: tmux-failed operation=capture-pane item=KEN-1') missing=$(said 'harness-screen-missing')" \
  "rc=1 launched=0 failed=1 missing=0" \
  "a harness-screen read that fails reports tmux-failed, not harness-screen-missing"
# A window that cannot be closed may still run a harness, so its record keeps
# what it read. A relaunch that took and could not be recorded keeps its window.
RUN_ENV=(OT_TMUX_FAIL=kill-window)
run_ot claude - claude
RUN_ENV=()
assert_eq "rc=$RC failed=$(said '^open-terminal: tmux-failed operation=kill-window item=KEN-1') status=$(status)" \
  "rc=1 failed=1 status=running" \
  "a failed relaunch whose window close fails leaves its record running"
SEED_LANES='[42]'
run_ot claude "$HARNESS_SCREEN" claude
SEED_LANES='[]'
assert_eq "rc=$RC unrecorded=$(said '^open-terminal: record-write-failed item=KEN-1 ') closed=$(closed) status=$(status)" \
  "rc=1 unrecorded=1 closed=0 status=running" \
  "a relaunch that took and could not be recorded keeps its window and its record"

echo "=== a relaunch across a harness switch renders the start brief alone ==="
run_ot codex "$HARNESS_SCREEN" claude
assert_eq "rc=$RC switched=$(said '^open-terminal: harness-switched item=KEN-1 harness=claude recorded=codex') continue=$(remote | grep -c -- '--continue') fresh=$(remote | grep -c "exec claude -n KEN-1 .*/orch start KEN-1")" \
  "rc=0 switched=1 continue=0 fresh=1" \
  "a record naming codex under a claude relaunch renders the start brief and no --continue"
# That switched relaunch carries its brief, so a pane that never shows a
# harness fails the brief check, which the harness-screen wait does not cover.
run_ot codex - claude
assert_eq "rc=$RC launched=$(launched) stuck=$(said '^open-terminal: composer-stuck item=KEN-1 ') closed=$(closed) status=$(status)" \
  "rc=1 launched=0 stuck=1 closed=1 status=stopped" \
  "a switched claude relaunch whose pane shows no harness fails its brief check, closed and stopped"
# That claude never ran, so the record still names codex, and a codex
# relaunch on the same state resumes codex's session.
run_ot - "$HARNESS_SCREEN" codex
assert_eq "switched=$(said 'harness-switched') resume=$(remote | grep -c 'lane-relaunch.sh codex')" "switched=0 resume=1" \
  "a codex relaunch after a failed claude relaunch over a codex record resumes codex"
# The same failure on a host still preparing: the background job's preparing
# and stopped records both still name codex.
prepared_fail codex claude
assert_eq "rc=$RC held=$HELD settled=$SETTLED" "rc=0 held=preparing codex settled=stopped codex" \
  "a claude relaunch handed to the background job whose host wait fails leaves the record naming codex"
# The same switch the other way reaches codex's start brief, never its
# promptless resume or the note that resume owes a pasted line.
run_ot claude "$HARNESS_SCREEN" codex
assert_eq "switched=$(said '^open-terminal: harness-switched item=KEN-1 harness=codex recorded=claude') resume=$(remote | grep -c 'resume --last') lineless=$(said 'resume-lineless')" \
  "switched=1 resume=0 lineless=0" \
  "a record naming claude under a codex relaunch renders codex's start brief"

for harness in codex pi; do
  run_ot claude - "$harness"
  metadata="$("$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" get oversee '[.lanes[]? | select(.item == "KEN-1") | [.harness,.model,.account,.session_id] | join(" ")] | first')"
  assert_eq "rc=$RC launched=$(launched) missing=$(said '^open-terminal: harness-screen-missing item=KEN-1 seconds=2') closed=$(closed) record=$(recorded) metadata=$metadata" \
    'rc=1 launched=0 missing=1 closed=1 record=stopped claude metadata=claude last-model last-account last-session' \
    "switched $harness at a shell fails and keeps the last successful launch metadata"
done
# A missing or unreadable selection is not proof of a fresh start.
for row in 'pending|read' 'resume|cat'; do
  RUN_ENV=(LANE_HOST_STUB_SELECTION="${row%%|*}")
  [[ "${row#*|}" != cat ]] || RUN_ENV+=(LANE_HOST_STUB_CAT_STATUS=1 LANE_HOST_STUB_CAT_PATH=/srv/lane/tmp/lane-mail/KEN-1/relaunch-selection)
  run_ot codex "$HARNESS_SCREEN" codex
  RUN_ENV=()
  assert_eq "rc=$RC launched=$(launched) failed=$(said "^open-terminal: relaunch-selection-failed item=KEN-1 operation=${row#*|}") closed=$(closed) status=$(status)" \
    'rc=1 launched=0 failed=1 closed=1 status=stopped' \
    "Codex selection ${row#*|} failure refuses a success notice"
done
RUN_ENV=(LANE_HOST_STUB_PUT_STATUS=1)
run_ot codex "$HARNESS_SCREEN" codex
RUN_ENV=()
assert_eq "rc=$RC launched=$(launched) failed=$(said '^open-terminal: relaunch-selection-failed item=KEN-1 operation=put')" \
  'rc=1 launched=0 failed=1' 'a selection reset that fails starts no Codex harness'

echo "=== controls ==="
# One mutant per rule. Each keeps the text it edits and removes the behaviour.
SHIPPED="$OPEN_TERMINAL"
control() { # NAME OLD NEW [FILE]
  local file="${4:-open-terminal}" scripts
  scripts="$(mutant_scripts "ctl-$1/orch" "$file")" || exit 1
  OPEN_TERMINAL="$scripts/open-terminal"
  orch_fixture_shared_libs "$TMP_ROOT/ctl-$1/orch"
  mutate_file "$scripts/$file" "$2" "$3"
}
control switch '"$LANE_RECORD_VALUE" != "$HARNESS" ]]' '"$LANE_RECORD_VALUE" == "$HARNESS-never" ]]'
run_ot codex "$HARNESS_SCREEN" claude
assert_eq "continue=$(remote | grep -c -- '--continue') launched=$(launched)" "continue=1 launched=1" \
  "control: without the switch check a codex record's claude relaunch renders --continue"
control fallback "|| [ \$? -ne 1 ] || exec %s\\n' \"\$flags\" \"\$line\" \"\$fresh\"" "\\n' \"\$flags\" \"\$line\""
run_ot claude "$HARNESS_SCREEN" claude
assert_eq "$(replay 1)" "continue" "control: without the fallback a --continue that finds no session runs nothing after it"
control status '|| [ $? -ne 1 ] || exec' '|| exec'
run_ot claude "$HARNESS_SCREEN" claude
assert_eq "$(replay 143)" "continue,fresh" "control: without the status gate a lane stopped by a signal starts afresh"
control screen 'tmux_wait_harness "$pane" "$harness_secs" || harness_rc=$?' 'true || harness_rc=$?'
for row in claude:claude codex:codex pi:pi claude:codex claude:pi; do
  run_ot "${row%%:*}" - "${row#*:}"
  assert_eq "rc=$RC launched=$(launched)" "rc=0 launched=1" \
    "control: without the shared screen check $row at a shell reports launched=1"
done
control selection-fresh 'printf fresh > %q' 'printf resume > %q'
SELECT_KIND=none run_ot codex "$HARNESS_SCREEN" codex
assert_eq "$(cat "$RUN/inline/replay.out") lineless=$(said '^open-terminal: resume-lineless item=KEN-1 harness=codex$')" \
  'rc=0 runs=1 resume=0 fresh=1 target=0 lineless=1' \
  'control: a fresh selection labelled resume wrongly requests a continuation paste'
control selection-resume 'resume) ot_message resume-lineless' 'resume) : ;; unused) ot_message resume-lineless'
SELECT_KIND=matching run_ot codex "$HARNESS_SCREEN" codex
assert_eq "$(cat "$RUN/inline/replay.out") lineless=$(said '^open-terminal: resume-lineless item=KEN-1 harness=codex$')" \
  'rc=0 runs=1 resume=1 fresh=0 target=1 lineless=0' \
  'control: a suppressed resume result loses the continuation handoff'
control selection-read 'UNTAKEN_PANE="$LAUNCH_PANE"; return 1 ;;' 'UNTAKEN_PANE="$LAUNCH_PANE"; : ;;'
RUN_ENV=(LANE_HOST_STUB_SELECTION=pending)
run_ot codex "$HARNESS_SCREEN" codex
RUN_ENV=()
assert_eq "rc=$RC launched=$(launched)" 'rc=0 launched=1' \
  'control: without the result tag check pending counts as a launched Codex'
control selection-cat '    selected="$(host_transport cat --item "$wt_id" "$remote_path/$HOST_SELECTION_FILE")" || rc=$?
    if [[ "$rc" -ne 0 ]]; then' '    selected="$(host_transport cat --item "$wt_id" "$remote_path/$HOST_SELECTION_FILE")" || rc=$?
    if [[ "$rc" -eq 0 ]]; then'
RUN_ENV=(LANE_HOST_STUB_CAT_STATUS=1 LANE_HOST_STUB_CAT_PATH=/srv/lane/tmp/lane-mail/KEN-1/relaunch-selection)
run_ot codex "$HARNESS_SCREEN" codex
RUN_ENV=()
assert_eq "rc=$RC failed=$(said '^open-terminal: relaunch-selection-failed item=KEN-1 operation=cat')" 'rc=1 failed=0' \
  'control: an inverted read check loses the host cat failure classification'
control selection-put '    printf pending | host_transport put --item "$wt_id" "$remote_path/$HOST_SELECTION_FILE" || rc=$?
    if [[ "$rc" -ne 0 ]]; then' '    printf pending | host_transport put --item "$wt_id" "$remote_path/$HOST_SELECTION_FILE" || rc=$?
    if [[ "$rc" -eq 0 ]]; then'
RUN_ENV=(LANE_HOST_STUB_PUT_STATUS=1)
run_ot codex "$HARNESS_SCREEN" codex
RUN_ENV=()
assert_eq "rc=$RC failed=$(said '^open-terminal: relaunch-selection-failed item=KEN-1 operation=put')" 'rc=1 failed=0' \
  'control: an inverted reset check loses the host put failure classification'
control screen-bound 'case "$HARNESS" in codex | pi) TIMEOUT_IS_READ=true ;; esac' ': '
for harness in codex pi; do
  RUN_ENV=(ORCH_TMUX_VERIFY_SECS=abc)
  run_ot "$harness" "$HARNESS_SCREEN" "$harness"
  RUN_ENV=()
  assert_eq "rc=$RC launched=$(launched) invalid=$(said 'verify-seconds-invalid')" \
    'rc=0 launched=1 invalid=0' "control: without the bound reader $harness relaunch ignores invalid input"
done
for harness in codex pi; do
  if [[ "$harness" == codex ]]; then native="      codex) printf 'codex %sresume --last\\n' \"\$flags\"; return ;;"
  else native="      pi) printf 'pi %s-c%s\\n' \"\$flags\" \"\$line\"; return ;;"; fi
  control "$harness-lookup" '      codex | pi)' "$native"$'\n''      pi | codex)'
  run_ot "$harness" "$HARNESS_SCREEN" "$harness"
  if [[ "$harness" == codex ]]; then expected='rc=0 runs=1 resume=1 fresh=0 target=0'
  else expected='rc=0 runs=1 resume=0 fresh=0 target=0'; fi
  assert_eq "$(ot_replay_relaunch "$(remote)" "${OPEN_TERMINAL%/*}" "$RUN" "$harness" none 0 KEN-1)" \
    "$expected" \
    "control: native $harness continue on an empty host loses the start brief" "$RUN/replay.err"
done
while IFS="|" read -r name old new kind expected; do
  control "$name" "$old" "$new" lib/lane-relaunch.sh
  for harness in codex pi; do
    run_ot "$harness" "$HARNESS_SCREEN" "$harness"
    assert_eq "$(ot_replay_relaunch "$(remote)" "${OPEN_TERMINAL%/*}" "$RUN" "$harness" "$kind" 0 KEN-1)" \
      "$expected" "control: $name changes $harness selection" "$RUN/replay.err"
  done
done <<'ROWS'
lookup-empty|    1) exit 1 ;;|    1) exit 0 ;;|none|rc=0 runs=1 resume=1 fresh=0 target=0
lookup-failure|  exit 2|  exit 1|scan-failed|rc=0 runs=1 resume=0 fresh=1 target=0
worktree|.cwd==\$cwd and .lead|true and .lead|newer-foreign|rc=0 runs=1 resume=1 fresh=0 target=0
wrong-target|0) session_id_of "$1" "$session_file" && exit 0 ;;|0) id="$(session_id_of "$1" "$session_file")" && printf "%s-wrong\n" "$id" && exit 0 ;;|matching|rc=0 runs=1 resume=1 fresh=0 target=0
ROWS
# The matcher reads shipped unattended text, never the mutated launch owner.
control unattended "LAUNCH_UNATTENDED_TEXT='This is" "LAUNCH_UNATTENDED_TEXT='changed unattended text. This is" lib/lane-launch.sh
for harness in codex pi; do
  run_ot "$harness" "$HARNESS_SCREEN" "$harness"
  assert_eq "$(ot_replay_relaunch "$(remote)" "${OPEN_TERMINAL%/*}" "$RUN" "$harness" none 0 KEN-1)" \
    'rc=0 runs=1 resume=0 fresh=0 target=0' "control: changed unattended text fails the $harness fresh-prompt match"
done
for row in 'source|.source=="cli"|.source!="cli"|exec-only' 'parent|.parent_thread_id==null|.parent_thread_id!=null|parent-only'; do
  IFS="|" read -r rule old new kind <<<"$row"
  control "codex-$rule" "$old" "$new" lib/lane-relaunch.sh
  run_ot codex "$HARNESS_SCREEN" codex
  assert_eq "$(ot_replay_relaunch "$(remote)" "${OPEN_TERMINAL%/*}" "$RUN" codex "$kind" 0 KEN-1)" \
    'rc=0 runs=1 resume=1 fresh=0 target=0' "control: without $rule eligibility Codex resumes a non-lead"
done
control brief '"$RELAUNCH_ROUTE" != resume-or-fresh ]]; then' '"$HOST_RELAUNCH" == false ]]; then'
run_ot codex - claude
assert_eq "rc=$RC launched=$(launched) stuck=$(said '^open-terminal: composer-stuck item=KEN-1 ') missing=$(said '^open-terminal: harness-screen-missing item=KEN-1 seconds=2')" \
  "rc=1 launched=0 stuck=0 missing=1" \
  "control: gating the brief on a local relaunch loses its brief failure, but shared readiness still refuses the shell"
control capture 'capture-pane -pJ -t "$pane" 2>/dev/null)" || return 2' 'capture-pane -pJ -t "$pane" 2>/dev/null)" || return 1'
RUN_ENV=("${CAPTURE_FAILS[@]}")
run_ot claude "$HARNESS_SCREEN" claude
RUN_ENV=()
assert_eq "missing=$(said 'harness-screen-missing')" "missing=1" \
  "control: without its own status a failed read reports as a pane with no harness screen"
control stopped 'UNTAKEN_PANE" ]] || launch_stop || true' 'UNTAKEN_PANE" ]] || true'
run_ot claude - claude
assert_eq "closed=$(closed) status=$(status)" "closed=0 status=running" \
  "control: without the stop the window stays open and the record stays running behind the dead pane"
control fields 'if .status == "running" then . else del(' 'if .status != "never" then . else del('
run_ot codex - claude
run_ot - "$HARNESS_SCREEN" codex
switched="$(said 'harness-switched')"
prepared_fail codex claude
assert_eq "switched=$switched held=$HELD settled=$SETTLED" "switched=1 held=preparing claude settled=stopped claude" \
  "control: a relaunch record that rewrites the harness before it takes names claude and turns the next codex relaunch into a harness switch"
control close 'tmux_window_close "$UNTAKEN_PANE" "$title" || return 1' 'tmux_window_close "$UNTAKEN_PANE" "$title" || true'
RUN_ENV=(OT_TMUX_FAIL=kill-window)
run_ot claude - claude
RUN_ENV=()
assert_eq "status=$(status)" "status=stopped" "control: a stop past a failed close writes stopped over a live window"
control untaken '|| -z "$UNTAKEN_PANE" ]]' '|| -z "${UNTAKEN_PANE:=$LAUNCH_PANE}" ]]'
SEED_LANES='[42]'
run_ot claude "$HARNESS_SCREEN" claude
SEED_LANES='[]'
assert_eq "closed=$(closed)" "closed=1" "control: a stop on every failure closes a relaunch that took"
OPEN_TERMINAL="$SHIPPED"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
