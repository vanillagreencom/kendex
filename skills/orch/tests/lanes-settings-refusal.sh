#!/usr/bin/env bash
# lanes runs without errexit, so the settings loader's refusal must be
# checked explicitly at startup: continuing past it would pick a lane from
# whatever exported before the bad line — a successful-looking answer from
# partial configuration.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LANES="$(cd "$TEST_DIR/.." && pwd)/scripts/lanes"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

echo "=== lanes refuses a rejected settings load ==="

# An empty lane home and an inert fetcher: with the startup check in place
# neither is ever consulted — the refusal happens first.
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/badcfg"
printf '[env]\nORCH_LANE_ALIASES = "a"\nORCH_LANE_ALIASES = "b"\n' > "$TMP_ROOT/badcfg/kendex.settings.toml"
rc=0
out="$( (cd "$TMP_ROOT/badcfg" && LANES_HOME="$TMP_ROOT/home" ORCH_LANES_FETCH_CMD=true "$LANES" pick --harness claude) 2>"$TMP_ROOT/err")" || rc=$?
assert_eq "$rc" "1" "a refused settings load terminates lanes before any lane work"
assert_eq "$out" "" "no lane result is produced from a partial settings read"
if grep -q "refusing to run on a rejected settings load" "$TMP_ROOT/err"; then
  PASS=$((PASS + 1)); printf '  ok    the refusal names the settings load, not the lane inventory\n'
else
  FAIL=$((FAIL + 1)); printf '  FAIL  the refusal names the settings load, not the lane inventory\n        stderr: %s\n' "$(cat "$TMP_ROOT/err")"
fi

# A bounded run without `timeout`: stock macOS ships none, this skill supports
# the Bash 3.2 that ships there, and GNU coreutils is not a declared dependency.
# The child runs in the background, a killer sleeps the deadline and signals it,
# and whichever lands first decides. A run that had to be killed reports its
# signal status, which is neither the exit nor the message asserted below, so a
# hang still reds the case rather than passing or running forever.
run_bounded() { # SECS CMD... — combined output on stdout, command status returned
  local secs="$1"
  shift
  local out_file="$TMP_ROOT/bounded-out" child killer status=0
  "$@" >"$out_file" 2>&1 &
  child=$!
  # The killer gets its own stdout: spawned as-is it inherits the write end of
  # the command substitution the caller reads through, and killing the subshell
  # does not kill the `sleep` it is waiting on, so the orphan holds that pipe
  # open and every call blocks for the full deadline whatever the child did.
  {
    sleep "$secs"
    kill -TERM "$child" 2>/dev/null
  } >/dev/null 2>&1 &
  killer=$!
  wait "$child" || status=$?
  kill -TERM "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  cat "$out_file"
  return "$status"
}

# A valued option with its value omitted must name the flag and stop. The space
# forms shift two positionals, and a shift that cannot take two returns non-zero
# WITHOUT shifting under this script's errexit-free posture, so the loop re-reads
# the same argument forever.
for flag in --harness --max-pct; do
  rc=0
  out="$(run_bounded 10 "$LANES" list "$flag")" || rc=$?
  assert_eq "$rc" "1" "lanes list $flag with no value exits 1 rather than looping"
  assert_eq "$out" "lanes: $flag requires a value" \
    "lanes list $flag with no value names the flag"
done

# The `=` spelling splits to an empty string, which the space form already
# refuses; both spellings answer the same way.
for flag in --harness --max-pct; do
  rc=0
  out="$(run_bounded 10 "$LANES" list "$flag=")" || rc=$?
  assert_eq "$rc" "1" "lanes list $flag= with an empty value exits 1"
  assert_eq "$out" "lanes: $flag requires a value" \
    "lanes list $flag= with an empty value names the flag"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
