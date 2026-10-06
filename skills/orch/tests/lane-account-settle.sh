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

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
