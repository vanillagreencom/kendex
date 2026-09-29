#!/usr/bin/env bash
# open-terminal's relaunch route on a hosted lane: relaunch_route decides
# between the native resume and the start brief, start_cmd renders that verdict,
# and open_tmux counts the lane as launched only once its pane shows a harness.
#
# A hosted claude relaunch renders `--continue` with the start brief behind it,
# which runs where claude exits 1, its answer where the host holds no session. A
# relaunch whose harness differs from the one the fleet record names renders the
# start brief alone. A pane that shows no harness screen is no launched lane,
# and its fleet record reads stopped.
#
# tmux, worktree and gh are the shared open-terminal stubs, and the host is the
# lane-host fixture. The rendered remote command is also run for real, against
# a stub claude, which is what shows the start brief runs in the same call.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export ORCH_LANE_HOST=local ORCH_OVERSEER_LANES=1000
unset ORCH_LANE_DIRS ORCH_LANE_ALIASES ORCH_LANE_EXCLUDE ORCH_LANE_RETIRE ORCH_LANE_COPILOT_POOL ORCH_LANES_USAGE_TTL CODEX_HOME
unset ORCH_LANES_CLAUDE_CLIENT_ID ORCH_LANES_TOKEN_CMD ORCH_LANES_CLAUDE_TOKEN_URL
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
# run_ot RECORDED SCREEN HARNESS — one hosted relaunch of CC-1 on HARNESS into
# a fleet whose record for CC-1 names RECORDED and reads running. SCREEN is the
# harness screen file, `-` for a pane that never draws one. Sets OUT, RC and
# RUN.
run_ot() {
  local recorded="$1" screen="$2" harness="$3" flags='--model opus --effort high'
  [[ "$harness" != codex ]] || flags='-m gpt-6-astra -c model_reasoning_effort=high'
  [[ "$screen" != - ]] || screen=""
  RUN="$TMP_ROOT/runs/$((++RUN_SEQ))"
  mkdir -p "$RUN/state" "$RUN/remote/srv/lane"
  printf 'gitdir: /srv/clone/.git/worktrees/lane\n' > "$RUN/remote/srv/lane/.git"
  if ! "$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" init oversee >/dev/null \
    || ! "$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" update oversee --arg h "$recorded" \
      '.lanes = [{item: "CC-1", harness: $h, status: "running"}]' >/dev/null; then
    echo "open-terminal-relaunch-route: seed-failed run=$RUN" >&2
    exit 1
  fi
  OUT="$(env LANES_HOME="$H" ORCH_LANES_FETCH_CMD="$FETCHER" ORCH_LANE_MAX_PCT=95 ORCH_LANE_ALIASES=eclaude=work \
    GH_ISSUE_PATTERN='[A-Z]+-[0-9]+' LANE_HOST_STUB_DIR="$RUN/remote" LANE_HOST_STUB_LOG="$RUN/host.log" \
    ORCH_TMUX_VERIFY_SECS=1 ORCH_LANE_SSH_PROMPT_SECS=1 OT_HARNESS_SCREEN="$screen" \
    TMUX=stub,1,0 ORCH_TMUX_SESSION=stub OT_TMUX_LOG="$RUN/tmux.log" OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$RUN/panes" \
    OT_WT_LOG="$RUN/worktree.log" OVERSEE_WATCH_STATE_DIR="$RUN/state" PATH="$OT_STUB_BIN:$PATH" WORKTREE_CLI="$OT_STUB_BIN/worktree" \
    "$OPEN_TERMINAL" --state-dir "$RUN/state" --host "$HOST_STUB" --repo o/r --relaunch \
    --harness "$harness" --lane work --launch-flags "$flags" CC-1 2>&1)"
  RC=$?
}
# The remote command the run typed into its ssh session.
remote() { grep -m1 '^exec bash -lc ' "$RUN/tmux.log" || echo none; }
said() { grep -c -- "$1" <<<"$OUT" || true; }
launched() { sed -n 's/.*summary launched=\([0-9]*\).*/\1/p' <<<"$OUT"; }
status() { "$SCRIPTS_DIR/workflow-state" --state-dir "$RUN/state" get oversee '[.lanes[]? | select(.item == "CC-1") | .status] | first // "none"'; }
# replay RC — runs the typed remote command against the stub claude, its
# `--continue` exiting RC, in a sandbox of its own, and prints each claude run
# it made as `continue` or `fresh`, joined by `,`.
replay() {
  local sandbox="$RUN/sandbox" line
  mkdir -p "$sandbox"
  : > "$RUN/claude.log"
  line="$(remote | sed -e 's/^exec bash -lc /bash -c /' -e "s#cd /srv/lane #cd $sandbox #")"
  env -i PATH="$HARNESS_BIN:$PATH" HOME="$RUN" CLAUDE_LOG="$RUN/claude.log" CLAUDE_CONTINUE_RC="$1" bash -c "$line" 2>/dev/null
  awk '/ --continue / { r = r s "continue"; s = "," ; next } /^-n CC-1 .*\/orch start CC-1$/ { r = r s "fresh"; s = "," ; next } { r = r s "other"; s = "," } END { print (r == "" ? "none" : r) }' "$RUN/claude.log"
}

echo "=== a hosted claude relaunch continues, and runs the start brief where claude finds no session ==="
run_ot claude "$HARNESS_SCREEN" claude
assert_eq "rc=$RC launched=$(launched) continue=$(remote | grep -c -- "--continue '" ) fallback=$(remote | grep -cF "|| [ \$? -ne 1 ] || exec claude -n CC-1 ")" \
  "rc=0 launched=1 continue=1 fallback=1" \
  "a hosted claude relaunch renders --continue with the start brief behind it, and counts once its pane shows a harness"
# One row per status claude can end --continue with: 1 is its no-session exit,
# 0 a lane quit by hand, 143 a lane stopped by a signal.
for row in '1|continue,fresh' '0|continue' '143|continue'; do
  assert_eq "$(replay "${row%%|*}")" "${row#*|}" \
    "a --continue that exits ${row%%|*} runs: ${row#*|}"
done

echo "=== a pane that shows no harness is no launched lane ==="
run_ot claude - claude
assert_eq "rc=$RC launched=$(launched) missing=$(said '^open-terminal: harness-screen-missing item=CC-1 seconds=1') status=$(status)" \
  "rc=1 launched=0 missing=1 status=stopped" \
  "a hosted relaunch whose pane shows no harness is harness-screen-missing, not launched, and its record reads stopped"

echo "=== a relaunch across a harness switch renders the start brief alone ==="
run_ot codex "$HARNESS_SCREEN" claude
assert_eq "rc=$RC switched=$(said '^open-terminal: harness-switched item=CC-1 harness=claude recorded=codex') continue=$(remote | grep -c -- '--continue') fresh=$(remote | grep -c "exec claude -n CC-1 .*/orch start CC-1")" \
  "rc=0 switched=1 continue=0 fresh=1" \
  "a record naming codex under a claude relaunch renders the start brief and no --continue"
# The same switch the other way reaches codex's start brief, never its
# promptless resume or the note that resume owes a pasted line.
run_ot claude "$HARNESS_SCREEN" codex
assert_eq "switched=$(said '^open-terminal: harness-switched item=CC-1 harness=codex recorded=claude') resume=$(remote | grep -c 'resume --last') lineless=$(said 'resume-lineless')" \
  "switched=1 resume=0 lineless=0" \
  "a record naming claude under a codex relaunch renders codex's start brief"

echo "=== controls ==="
# One mutant per rule. Each keeps the text it edits and removes the behaviour.
SHIPPED="$OPEN_TERMINAL"
control() { # NAME OLD NEW
  OPEN_TERMINAL="$(mutant_scripts "ctl-$1/orch" open-terminal)/open-terminal" || exit 1
  orch_fixture_shared_libs "$TMP_ROOT/ctl-$1/orch"
  mutate_file "$OPEN_TERMINAL" "$2" "$3"
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
control screen '[[ "$RELAUNCH_ROUTE" == resume-or-fresh ]] && ! tmux_wait_harness' '[[ "$RELAUNCH_ROUTE" == never ]] && ! tmux_wait_harness'
run_ot claude - claude
assert_eq "rc=$RC launched=$(launched)" "rc=0 launched=1" \
  "control: without the harness-screen check a pane at a shell reports launched=1"
control stopped '| .status) = "stopped"' '| .status) = "running"'
run_ot claude - claude
assert_eq "status=$(status)" "status=running" "control: without the stopped write the record stays running behind the dead pane"
OPEN_TERMINAL="$SHIPPED"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
