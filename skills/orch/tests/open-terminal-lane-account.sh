#!/usr/bin/env bash
# A fresh --cmd launch through a real tmux pane. Inputs: open-terminal,
# lane-launch, lane-cap, workflow-state and the shared launcher fixtures.
# The claude wrapper either preserves the picked account or overwrites it as
# dotfiles account wrappers do. The launched child records its environment
# before drawing the harness marker. Each child has a parent-process deadline.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/open-terminal-stubs.sh"
source "$TEST_DIR/lib/question-off.sh"
source "$TEST_DIR/lib/growth-state.sh"
source "$TEST_DIR/lib/shared-skill-libs.sh"
REAL_TMUX="$(command -v tmux)" || { echo 'lane-account: tmux-missing' >&2; exit 1; }

if [[ "${1:-}" == --case ]]; then
  ROOT="$2" OT="$3" MODE="$4"
  mkdir -p "$ROOT/bin" "$ROOT/home/.nclaude" "$ROOT/home/.claude" "$ROOT/real-bin"
  ot_stub_bin "$ROOT/bin"
  printf '#!%s\ncase "${1:-}" in check) exit 0 ;; list) echo "[]" ;; esac\n' "$BASH" > "$ROOT/bin/lanes"
  chmod +x "$ROOT/bin/lanes"
  printf '#!%s\nexec %q -S %q "$@"\n' "$BASH" "$REAL_TMUX" "$ROOT/s" > "$ROOT/real-bin/tmux"
  chmod +x "$ROOT/real-bin/tmux"
  tm() { env -i PATH="$ROOT/real-bin:$ROOT/bin:$PATH" HOME="$ROOT/home" SHELL="$BASH" "$REAL_TMUX" -S "$ROOT/s" "$@"; }
  trap 'tm kill-server 2>/dev/null || true' EXIT
  trap 'exit 143' TERM
  tm -f /dev/null new-session -d -s fixture -x 200 -y 50
  tm set-option -g default-shell "$BASH"
  tm set-option -g default-command "$BASH --noprofile --norc -i"
  printf '#!%s\nprintf "%%s" "${CLAUDE_CONFIG_DIR:-}" > %q\nprintf "? for shortcuts\\n"\nexec sleep 30\n' \
    "$BASH" "$ROOT/account" > "$ROOT/bin/claude-real"
  chmod +x "$ROOT/bin/claude-real"
  {
    printf '#!%s\n' "$BASH"
    [[ "$MODE" != wrong ]] || printf 'export CLAUDE_CONFIG_DIR=%q\n' "$ROOT/home/.claude"
    printf 'exec %q "$@"\n' "$ROOT/bin/claude-real"
  } > "$ROOT/bin/claude"
  chmod +x "$ROOT/bin/claude"
  ot_fleet_state "$SCRIPTS_DIR/workflow-state" "$ROOT/state" "$PWD"
  RC=0
  env -i PATH="$ROOT/real-bin:$ROOT/bin:$PATH" HOME="$ROOT/home" SHELL="$BASH" ORCH_TMUX_SESSION=fixture \
    LINEAR_TEAM= ORCH_LANE_HOST=local WORKTREE_CLI="$ROOT/bin/worktree" LANES_CLI="$ROOT/bin/lanes" \
    OT_WT_LOG="$ROOT/worktree.log" ORCH_TMUX_VERIFY_SECS=1 ORCH_LANE_SETTLE_MS=1 \
    OVERSEE_WATCH_STATE_DIR="$ROOT/claims" \
    "$OT" --tmux --state-dir "$ROOT/state" --harness claude --lane "$ROOT/home/.nclaude" \
    --cmd "claude --model opus --effort high $QUESTION_OFF_ALL $COMPACTION_OFF_ALL" KEN-1 > "$ROOT/launch.log" 2>&1 || RC=$?
  # Baseline controls return before the child starts. Its account file is the
  # acknowledgement that this row reached the real exec path.
  for i in {1..100}; do [[ ! -f "$ROOT/account" ]] || break; sleep 0.02; done
  [[ -f "$ROOT/account" ]] || exit 71
  account="$(cat "$ROOT/account")"
  panes="$(tm list-panes -a -F '#{window_name}')"
  present=false
  ! grep -qxF KEN-1 <<<"$panes" || present=true
  record="$("$SCRIPTS_DIR/workflow-state" --state-dir "$ROOT/state" get oversee '[.lanes[]? | select(.item == "KEN-1") | .status] | first // "none"')"
  jq -cn --argjson rc "$RC" --arg account "${account##*/}" --argjson pane "$present" --arg record "$record" \
    '{rc:$rc,account:$account,pane:$pane,record:$record}' > "$ROOT/result"
  exit
fi

TMP_ROOT="$(mktemp -d)" || { echo 'lane-account: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || exit 1
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
CONTROL="$(mutant_scripts custom-unchecked lib/lane-launch.sh)"
orch_fixture_shared_libs "${CONTROL%/scripts}"
mutate_file "$CONTROL/lib/lane-launch.sh" "printf 'custom\n'; return;" "printf 'unchecked\n'; return;"

run_case() { # NAME SCRIPT MODE EXPECT
  local name="$1" script="$2" mode="$3" want="$4" rc=0 actual=missing
  RUN="$TMP_ROOT/$name"
  mkdir -p "$RUN"
  env -i PATH="$PATH" HOME="$TMP_ROOT" timeout 20 "$BASH" "$TEST_DIR/open-terminal-lane-account.sh" \
    --case "$RUN" "$script" "$mode" > "$RUN/log" 2>&1 || rc=$?
  [[ ! -f "$RUN/launch.log" ]] || cat "$RUN/launch.log" >> "$RUN/log"
  [[ ! -f "$RUN/result" ]] || actual="$(cat "$RUN/result")"
  assert_eq "child=$rc $actual" "child=0 $want" "$name: a real fresh launch reports its actual account and fleet record" "$RUN/log"
}

run_case preserved "$SCRIPTS_DIR/open-terminal" preserved '{"rc":0,"account":".nclaude","pane":true,"record":"running"}'
if ( source "$SCRIPTS_DIR/lib/lane-launch.sh" && lane_process_env_readable ); then
  while IFS='|' read -r name script want; do
    run_case "$name" "$script" wrong "$want"
  done <<ROWS
wrong-account|$SCRIPTS_DIR/open-terminal|{"rc":1,"account":".claude","pane":false,"record":"none"}
control-unchecked|$CONTROL/open-terminal|{"rc":0,"account":".claude","pane":true,"record":"running"}
ROWS
else
  printf '  skip wrong-account observations: no readable process environment\n'
fi
printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
