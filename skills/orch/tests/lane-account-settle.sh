#!/usr/bin/env bash
# Tests for the settle pause of lib/lane-launch.sh's lane_account_check: two
# reads ORCH_LANE_SETTLE_MS apart decide an observed account, the caller's bound
# stays in seconds whatever the pause, and a value outside 1 to 1000 is named
# rather than replaced by the default.
#
# The pane is a tmux stub naming a live process that carries no lane variable,
# so every row in range reads until its bound runs out. A sleep stub records
# each pause and returns at once, so the rows cost no wall time and the pauses
# they assert are the arguments the check slept on. The readings come from
# /proc, so on a host without it the in-range rows are skipped; the refusals
# come before any reading and run everywhere.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# mutant_scripts and mutate_file, the two halves of the controls below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

TMP_ROOT="$(mktemp -d)" || { echo "lane-account-settle: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-account-settle: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-account-settle: scratch=resolve-failed" >&2; exit 1; }
sleep 300 &
QUIET_PID=$!
trap 'kill "$QUIET_PID" 2>/dev/null || true; rm -rf -- "${TMP_ROOT:?}"' EXIT

BIN="$TMP_ROOT/bin"
SLEEP_LOG="$TMP_ROOT/sleeps"
mkdir -p "$BIN"
cat > "$BIN/tmux" <<STUB
#!/bin/sh
printf '%s\n' "$QUIET_PID"
STUB
cat > "$BIN/sleep" <<STUB
#!/bin/sh
printf '%s\n' "\$1" >> "$SLEEP_LOG"
STUB
chmod +x "$BIN/tmux" "$BIN/sleep"

# settle_row LIB SETTING BOUND — `result=<LANE_ACCOUNT_RESULT> pauses=<each
# pause, comma-joined, or none>` for one check through the library at LIB, with
# ORCH_LANE_SETTLE_MS at SETTING (`unset` exports none).
settle_row() {
  local lib="$1" setting="$2" bound="$3"
  : > "$SLEEP_LOG"
  (
    # shellcheck source=/dev/null
    source "$lib"
    if [[ "$setting" == unset ]]; then unset ORCH_LANE_SETTLE_MS; else export ORCH_LANE_SETTLE_MS="$setting"; fi
    PATH="$BIN:$PATH"
    lane_account_check %1 CLAUDE_CONFIG_DIR "$TMP_ROOT/.claude" prefix "$bound" || true
    pauses="$(paste -sd, - < "$SLEEP_LOG")"
    printf 'result=%s pauses=%s' "$LANE_ACCOUNT_RESULT" "${pauses:-none}"
  )
}

# repeat COUNT PAUSE — PAUSE COUNT times, comma-joined.
repeat() { local i out=""; for ((i = 0; i < $1; i++)); do out+="${out:+,}$2"; done; printf '%s' "$out"; }

LIB="$SCRIPTS_DIR/lib/lane-launch.sh"
# shellcheck source=../scripts/lib/lane-launch.sh
source "$LIB"
UNREAD='result=unobserved:no-lane-variable'
INVALID='result=unobserved:settle-invalid pauses=none'

echo "=== the pause between the two reads ==="
# label|setting|bound|expect
for row in \
  "unset, the reads are a second apart|unset|1|$UNREAD pauses=1" \
  "empty reads as unset||1|$UNREAD pauses=1" \
  "a whole second sleeps as the integer, once per second of the bound|1000|2|$UNREAD pauses=1,1" \
  "a shorter pause reads ten times inside a one-second bound|100|1|$UNREAD pauses=$(repeat 10 0.100)" \
  "a pause that misses the bound by a millisecond reads once more|999|1|$UNREAD pauses=0.999,0.999"; do
  IFS='|' read -r label setting bound expect <<<"$row"
  if ! lane_process_env_readable; then
    printf '  skip  %s (no per-process environment on this host)\n' "$label"
    continue
  fi
  assert_eq "$(settle_row "$LIB" "$setting" "$bound")" "$expect" "$label"
done

echo "=== a value outside 1 to 1000 ==="
for row in \
  "zero is refused, never a pause that never advances|0|1" \
  "a second and a millisecond is refused, past what a one-second bound fits|1001|1" \
  "a leading zero is refused, never read as octal|0100|1" \
  "a negative value is refused|-5|1" \
  "a word is refused|abc|1"; do
  IFS='|' read -r label setting bound <<<"$row"
  assert_eq "$(settle_row "$LIB" "$setting" "$bound")" "$INVALID" "$label"
done

echo "=== controls ==="
# One planted defect per rule, each in a private copy of the library, each
# observed through the row its rule decides. Past the refusal a host without
# /proc names no-process-environment, so the shape and ceiling controls expect
# the reading this host offers; the two pause controls need that reading.
control() { # NAME OLD NEW SETTING BOUND EXPECT LABEL
  local dir
  dir="$(mutant_scripts "$1" lib/lane-launch.sh)" || exit 1
  mutate_file "$dir/lib/lane-launch.sh" "$2" "$3"
  assert_eq "$(settle_row "$dir/lib/lane-launch.sh" "$4" "$5")" "$6" "$7"
}
TAKEN_0100='result=unobserved:no-process-environment pauses=none'
TAKEN_1001="$TAKEN_0100"
if lane_process_env_readable; then
  # 0100 is octal to the shell's arithmetic: a 64 ms pause, sixteen of them.
  TAKEN_0100="$UNREAD pauses=$(repeat 16 0.064)"
  TAKEN_1001="$UNREAD pauses=0.1001"
fi
control shape '[[ ! "$settle_ms" =~ ^[1-9][0-9]{0,3}$ ]] || ' '' 0100 1 "$TAKEN_0100" \
  "control: without the shape rule a leading-zero value is read as a pause"
control ceiling ' || (( settle_ms > 1000 ))' '' 1001 1 "$TAKEN_1001" \
  "control: without the ceiling a pause past a second is taken"
if lane_process_env_readable; then
  control pause 'sleep "$pause"' 'sleep 1' 100 1 "$UNREAD pauses=$(repeat 10 1)" \
    "control: a check that sleeps a second whatever the setting fails the shorter pause"
  control bound '(( waited >= bound * 1000 ))' '(( waited >= bound ))' 100 1 "$UNREAD pauses=0.100" \
    "control: a bound counted in pauses rather than seconds ends the reading early"
fi

echo "=== Codex ignores helpers and other account carriers retain their readings ==="
if lane_process_env_readable; then
  # The executables retain their command names while waiting. The child sends
  # readiness through a pipe after exec, so the check reads the whole tree.
  for command in codex node_repl codex-code-mode MainThread pi opencode; do
    cp "$BASH" "$BIN/$command"
  done
  ACCOUNT_STUB='child_env=()
[[ "$CHILD_HOME" == unset ]] || child_env+=("$ACCOUNT_NAME=$CHILD_HOME")
env -i PATH="$PATH" "${child_env[@]}" "$BIN/$CHILD_COMMAND" -c '\''printf "ready\n" >&8; read -r -t 30 hold <&9 || true'\'' &
child=$!
trap '\''kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true'\'' EXIT
wait "$child"'
  account_row() { # LIB NAME PARENT_COMMAND CHILD_COMMAND CHILD_HOME
    (
      source "$1"
      mkfifo "$TMP_ROOT/ready" "$TMP_ROOT/hold"
      exec 8<> "$TMP_ROOT/ready" 9<> "$TMP_ROOT/hold"
      env -i PATH="$PATH" "$2=$TMP_ROOT/picked" ACCOUNT_NAME="$2" BIN="$BIN" CHILD_COMMAND="$4" CHILD_HOME="$5" \
        "$BASH" -c '"$1" -c "$2" & child=$!; trap '\''kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true'\'' EXIT; wait "$child"' \
        pane "$BIN/$3" "$ACCOUNT_STUB" &
      pane_pid=$!
      trap 'kill "$pane_pid" 2>/dev/null || true; wait "$pane_pid" 2>/dev/null || true; rm -- "$TMP_ROOT/ready" "$TMP_ROOT/hold"' EXIT
      read -r -t 5 ready <&8
      [[ "$ready" == ready ]]
      tmux() { printf '%s\n' "$pane_pid"; }
      PATH="$BIN:$PATH"
      lane_account_check %1 "$2" "$TMP_ROOT/picked" prefix 1 || true
      printf '%s' "$LANE_ACCOUNT_RESULT"
    )
  }
  # name|parent command|child command|child home|result|label
  # Copilot's native binary uses MainThread. lane_env_prefix emits
  # CLAUDE_CONFIG_DIR for Pi-on-Claude and Opencode as well as Claude.
  for row in \
    "CODEX_HOME|codex|node_repl|$TMP_ROOT/default|verified|a codex process on the picked home ignores a node_repl child on another home" \
    "CODEX_HOME|codex|codex-code-mode|$TMP_ROOT/default|verified|a codex process on the picked home ignores a codex-code-mode child on another home" \
    "CODEX_HOME|codex|codex|$TMP_ROOT/default|mismatch|a codex wrapper on the picked home cannot hide a deeper codex process on another home" \
    'CODEX_HOME|codex|codex|unset|unobserved:no-lane-variable|a deeper codex process without CODEX_HOME cannot inherit the observed wrapper account' \
    "COPILOT_HOME|MainThread|MainThread|$TMP_ROOT/picked|verified|Copilot MainThread on the picked home verifies" \
    "COPILOT_HOME|MainThread|MainThread|$TMP_ROOT/default|mismatch|Copilot MainThread on another home mismatches" \
    'COPILOT_HOME|MainThread|MainThread|unset|verified|an unset non-Codex child retains the deepest nonempty account' \
    "CLAUDE_CONFIG_DIR|pi|pi|$TMP_ROOT/picked|verified|Pi-on-Claude on the picked home verifies" \
    "CLAUDE_CONFIG_DIR|pi|pi|$TMP_ROOT/default|mismatch|Pi-on-Claude on another home mismatches" \
    "CLAUDE_CONFIG_DIR|opencode|opencode|$TMP_ROOT/picked|verified|Opencode on the picked home verifies" \
    "CLAUDE_CONFIG_DIR|opencode|opencode|$TMP_ROOT/default|mismatch|Opencode on another home mismatches"; do
    IFS='|' read -r name parent_command child_command child_home expect label <<<"$row"
    assert_eq "$(account_row "$LIB" "$name" "$parent_command" "$child_command" "$child_home")" "$expect" "$label"
  done
  ACCOUNT_CONTROL="$(mutant_scripts helper-account lib/lane-launch.sh)" || exit 1
  mutate_file "$ACCOUNT_CONTROL/lib/lane-launch.sh" '[[ "$command" == codex ]] || continue' ':'
  assert_eq "$(account_row "$ACCOUNT_CONTROL/lib/lane-launch.sh" CODEX_HOME codex node_repl "$TMP_ROOT/default")" mismatch \
    "control: reading every descendant lets node_repl replace the picked harness account"
  ACCOUNT_CONTROL="$(mutant_scripts non-codex-account lib/lane-launch.sh)" || exit 1
  mutate_file "$ACCOUNT_CONTROL/lib/lane-launch.sh" 'if [[ "$name" == CODEX_HOME ]]; then' 'if :; then'
  assert_eq "$(account_row "$ACCOUNT_CONTROL/lib/lane-launch.sh" COPILOT_HOME MainThread MainThread "$TMP_ROOT/default")" unobserved:no-lane-variable \
    "control: filtering non-Codex process names hides a replaced Copilot account"
  ACCOUNT_CONTROL="$(mutant_scripts unset-codex-account lib/lane-launch.sh)" || exit 1
  mutate_file "$ACCOUNT_CONTROL/lib/lane-launch.sh" '[[ "$name" == CODEX_HOME || -n "$value" ]]' '[[ -n "$value" ]]'
  assert_eq "$(account_row "$ACCOUNT_CONTROL/lib/lane-launch.sh" CODEX_HOME codex codex unset)" verified \
    "control: discarding an empty Codex reading falsely verifies the wrapper account"
  ACCOUNT_CONTROL="$(mutant_scripts unset-non-codex-account lib/lane-launch.sh)" || exit 1
  mutate_file "$ACCOUNT_CONTROL/lib/lane-launch.sh" 'if [[ "$name" == CODEX_HOME || -n "$value" ]]; then' 'if :; then'
  assert_eq "$(account_row "$ACCOUNT_CONTROL/lib/lane-launch.sh" COPILOT_HOME MainThread MainThread unset)" unobserved:no-lane-variable \
    "control: retaining an empty non-Codex reading hides the account still carried by its parent"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
