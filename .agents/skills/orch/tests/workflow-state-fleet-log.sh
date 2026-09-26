#!/usr/bin/env bash
# `workflow-state fleet-log takeover|audit`: the fleet log's two readers. The
# takeover read is exactly the last ORCH_TAKEOVER_ROWS rows but cycle rows, the audit read
# every proposal and ruling row and no other kind, and any other reader is
# refused.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

WS="$REPO_ROOT/skills/orch/scripts/workflow-state"
# Outside any checkout, so no project settings file answers for a setting.
cd "$TMP_ROOT"

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

echo
echo "--- workflow-state fleet-log ---"

sd="$TMP_ROOT/state"
"$WS" --state-dir "$sd" init oversee >/dev/null
"$WS" --state-dir "$sd" update oversee '.fleet_log = [range(0; 14) as $i
  | {at: "2020-01-01T00:00:00Z", kind: (["proposal", "ruling", "close", "peer"][$i % 4]),
     item: "KEN-\($i)", text: "row \($i)"}]'

# Rows: ORCH_TAKEOVER_ROWS, then the items the read must print in order.
while IFS='|' read -r rows want; do
  got="$(ORCH_TAKEOVER_ROWS="$rows" "$WS" --state-dir "$sd" fleet-log takeover | jq -rs 'map(.item) | join(",")')"
  [[ "$got" == "$want" ]] && pass "takeover at ORCH_TAKEOVER_ROWS=$rows prints exactly the last rows" \
    || fail "takeover at ORCH_TAKEOVER_ROWS=$rows prints exactly the last rows" "got=$got"
done <<'ROWS'
10|KEN-4,KEN-5,KEN-6,KEN-7,KEN-8,KEN-9,KEN-10,KEN-11,KEN-12,KEN-13
3|KEN-11,KEN-12,KEN-13
20|KEN-0,KEN-1,KEN-2,KEN-3,KEN-4,KEN-5,KEN-6,KEN-7,KEN-8,KEN-9,KEN-10,KEN-11,KEN-12,KEN-13
0|
ROWS

got="$(env -u ORCH_TAKEOVER_ROWS "$WS" --state-dir "$sd" fleet-log takeover | jq -s 'length')"
[[ "$got" == "10" ]] && pass "takeover reads 10 rows by default" || fail "takeover reads 10 rows by default" "got=$got"

# The cycle rows oversee-cycle logs, one per merge and one per class at
# Stop, never fill the takeover window the rulings are handed over in.
csd="$TMP_ROOT/cycle-state"
"$WS" --state-dir "$csd" init oversee >/dev/null
"$WS" --state-dir "$csd" update oversee '.fleet_log = [range(0; 6) as $i
  | {at: "2020-01-01T00:00:00Z", kind: (if $i < 2 then "ruling" else "cycle" end), item: "KEN-\($i)", text: "row \($i)"}]'
got="$(ORCH_TAKEOVER_ROWS=2 "$WS" --state-dir "$csd" fleet-log takeover | jq -rs 'map(.item) | join(",")')"
[[ "$got" == "KEN-0,KEN-1" ]] && pass "takeover reads the last rows but the cycle rows" \
  || fail "takeover reads the last rows but the cycle rows" "got=$got"

got="$("$WS" --state-dir "$sd" fleet-log audit | jq -rs 'map(.kind) | unique | join(",")')"
count="$("$WS" --state-dir "$sd" fleet-log audit | jq -s 'length')"
[[ "$got" == "proposal,ruling" && "$count" == "8" ]] \
  && pass "audit prints every proposal and ruling row and no other kind" \
  || fail "audit prints every proposal and ruling row and no other kind" "kinds=$got count=$count"

rc=0
"$WS" --state-dir "$sd" fleet-log tail >/dev/null 2>"$TMP_ROOT/reader.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/reader.err")"
[[ "$rc" -eq 2 && "$key" == "workflow-state: fleet-log-reader reader=tail" ]] \
  && pass "another reader is refused as fleet-log-reader" \
  || fail "another reader is refused as fleet-log-reader" "rc=$rc key=$key"

# A first fleet session has no fleet state yet: its takeover is empty, not a
# refusal whose advice would write an issue-shaped state as the fleet's.
rc=0
out="$("$WS" --state-dir "$TMP_ROOT/no-fleet" fleet-log takeover 2>&1)" || rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] && pass "takeover with no fleet state prints nothing and exits 0" \
  || fail "takeover with no fleet state prints nothing and exits 0" "rc=$rc out=$out"

# The suite's one must-fail control: the takeover slice dropped. The read then
# prints the whole log.
NO_SLICE="$(mutant_scripts no-slice workflow-state)/workflow-state" || exit 1
mutate_file "$NO_SLICE" 'else .[-$n:][] end' 'else .[] end'
got="$("$NO_SLICE" --state-dir "$sd" fleet-log takeover | jq -s 'length')"
[[ "$got" == "14" ]] && pass "control: without the slice the takeover read prints every row" \
  || fail "control: without the slice the takeover read prints every row" "got=$got"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
