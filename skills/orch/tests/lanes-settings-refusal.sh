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

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

echo "=== lanes refuses a rejected settings load ==="

# An empty lane home and an inert fetcher: with the startup check in place
# neither is ever consulted — the refusal happens first.
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/badcfg"
printf '[env]\nORCH_LANE_ALIASES = "a"\nORCH_LANE_ALIASES = "b"\n' > "$TMP_ROOT/badcfg/kendex.settings.toml"
rc=0
out="$( (cd "$TMP_ROOT/badcfg" && LANES_HOME="$TMP_ROOT/home" ORCH_LANES_FETCH_CMD=true "$LANES" pick --harness claude) 2>"$TMP_ROOT/err")" || rc=$?
assert_eq "$rc" "1" "a refused settings load terminates lanes before any lane work"
assert_eq "$out" "" "no lane result is produced from a partial settings read"
if grep -Fxq "lanes: settings-rejected path=$TMP_ROOT/badcfg" "$TMP_ROOT/err"; then
  pass "the refusal names the settings load, not the lane inventory"
else
  fail "the refusal names the settings load, not the lane inventory" "stderr: $(cat "$TMP_ROOT/err")"
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
  assert_eq "${out%%$'\n'*}" "lanes: missing-value arg1=$flag" \
    "lanes list $flag with no value names the flag"
done

# The `=` spelling splits to an empty string, which the space form already
# refuses; both spellings answer the same way.
for flag in --harness --max-pct; do
  rc=0
  out="$(run_bounded 10 "$LANES" list "$flag=")" || rc=$?
  assert_eq "$rc" "1" "lanes list $flag= with an empty value exits 1"
  assert_eq "${out%%$'\n'*}" "lanes: missing-value arg1=$flag" \
    "lanes list $flag= with an empty value names the flag"
done

echo "=== lanes refuses a lane setting it cannot read ==="
# A retirement date that does not parse, or names no calendar day, would keep
# a lane pickable past its day; an exclusion or retirement key written as a
# path names no lane, so the account it meant to cover would be read; and a
# TTL that does not parse has no reuse window to apply. A usage threshold that
# does not parse has no bound to judge against, and falling back to a number of
# the script's own is the silent disagreement reading the setting exists to end.
# Each is
# refused before any lane is enumerated; the inverse row is a well-formed pair
# that lists. Rows: `setting|value|first line`, an empty first line meaning
# the run succeeds.
while IFS='|' read -r setting value want; do
  [[ -n "$setting" ]] || continue
  rc=0; sub=list; [[ "$setting" != ORCH_HANDOFF_HEADROOM_PCT ]] || sub=context
  out="$(cd "$TMP_ROOT/home" && env -u ORCH_LANE_DIRS -u CODEX_HOME -u ORCH_LANE_EXCLUDE -u ORCH_LANE_RETIRE -u ORCH_LANES_USAGE_TTL -u ORCH_HANDOFF_HEADROOM_PCT -u ORCH_LANE_MAX_PCT \
    LANES_HOME="$TMP_ROOT/home" ORCH_LANES_FETCH_CMD=false OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/state" \
    "$setting=$value" "$LANES" "$sub" --json 2>&1 >/dev/null)" || rc=$?
  if [[ -z "$want" ]]; then
    assert_eq "$rc" "0" "$setting=$value is accepted"
  else
    assert_eq "$rc" "1" "$setting=$value exits 1"
    assert_eq "${out%%$'\n'*}" "$want" "$setting=$value names the entry"
  fi
done <<'ROWS'
ORCH_LANE_RETIRE|nclaude=2026-1012|lanes: invalid-retire entry=nclaude=2026-1012
ORCH_LANE_RETIRE|nclaude|lanes: invalid-retire entry=nclaude
ORCH_LANE_RETIRE|=2026-10-12|lanes: invalid-retire entry==2026-10-12
ORCH_LANE_RETIRE|eclaude=2026-10-12, nclaude = 2026-10-12|
ORCH_LANES_USAGE_TTL|soon|lanes: invalid-usage-ttl value=soon
ORCH_LANES_USAGE_TTL|0|
ORCH_HANDOFF_HEADROOM_PCT|101|lanes: invalid-handoff-headroom value=101
ORCH_LANE_MAX_PCT|101|lanes: invalid-lane-max-pct value=101
ORCH_LANE_MAX_PCT|soon|lanes: invalid-lane-max-pct value=soon
ORCH_LANE_MAX_PCT|95|
ORCH_LANE_RETIRE|nclaude=2026-13-01|lanes: invalid-retire entry=nclaude=2026-13-01
ORCH_LANE_RETIRE|nclaude=2027-02-29|lanes: invalid-retire entry=nclaude=2027-02-29
ORCH_LANE_RETIRE|nclaude=2028-02-29|
ORCH_LANE_RETIRE|~/.nclaude=2026-10-12|lanes: invalid-retire entry=~/.nclaude=2026-10-12
ORCH_LANE_EXCLUDE|/home/someone/.xclaude|lanes: invalid-exclude entry=/home/someone/.xclaude
ORCH_LANE_EXCLUDE|~/.xclaude|lanes: invalid-exclude entry=~/.xclaude
ORCH_LANE_EXCLUDE|xclaude/|lanes: invalid-exclude entry=xclaude/
ORCH_LANE_EXCLUDE|xclaude, work|
ROWS

echo "=== lanes refuses a clock it cannot read ==="
# An empty or malformed date would read as "no retirement has come" and hand a
# retired lane back out, so the run stops before any lane is read. The home
# holds one measurable lane and the fetch stub logs every call, so a run that
# got past the clock would leave the log behind. Rows: `label|date stub body`.
mkdir -p "$TMP_ROOT/clock-home/.claude" "$TMP_ROOT/clock-bin"
printf '{"claudeAiOauth":{"accessToken":"t","expiresAt":0}}\n' > "$TMP_ROOT/clock-home/.claude/.credentials.json"
cat > "$TMP_ROOT/clock-fetch" <<'STUB'
#!/usr/bin/env bash
basename "$2" >> "$CLOCK_FETCH_LOG"
exit 1
STUB
chmod +x "$TMP_ROOT/clock-fetch"
while IFS='|' read -r label body; do
  [[ -n "$label" ]] || continue
  printf '#!/usr/bin/env bash\n%s\n' "$body" > "$TMP_ROOT/clock-bin/date"
  chmod +x "$TMP_ROOT/clock-bin/date"
  rm -f -- "$TMP_ROOT/clock-fetch.log"
  rc=0
  out="$(cd "$TMP_ROOT/clock-home" && env -u ORCH_LANE_DIRS -u CODEX_HOME -u ORCH_LANE_EXCLUDE -u ORCH_LANE_RETIRE -u ORCH_LANES_USAGE_TTL \
    PATH="$TMP_ROOT/clock-bin:$PATH" LANES_HOME="$TMP_ROOT/clock-home" ORCH_LANES_FETCH_CMD="$TMP_ROOT/clock-fetch" \
    CLOCK_FETCH_LOG="$TMP_ROOT/clock-fetch.log" OVERSEE_WATCH_STATE_DIR="$TMP_ROOT/clock-state" \
    "$LANES" list --json 2>&1 >/dev/null)" || rc=$?
  assert_eq "$rc" "1" "$label: exits 1"
  assert_eq "${out%%$'\n'*}" "lanes: time-failed clock=UTC" "$label: names the clock"
  assert_eq "$([[ -e "$TMP_ROOT/clock-fetch.log" ]] && echo fetched || echo none)" "none" "$label: fetches nothing"
done <<'ROWS'
a date command that fails|exit 1
a date command that prints no date|echo soon
ROWS

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
