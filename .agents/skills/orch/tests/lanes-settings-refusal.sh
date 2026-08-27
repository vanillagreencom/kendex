#!/usr/bin/env bash
# lanes runs without errexit, so the settings loader's refusal must be
# checked explicitly at startup: continuing past it would pick a lane from
# whatever exported before the bad line — a successful-looking answer from
# partial configuration.
set -euo pipefail

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

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
