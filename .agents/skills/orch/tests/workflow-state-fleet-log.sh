#!/usr/bin/env bash
# `workflow-state fleet-log takeover|audit`: the fleet log's two readers. The
# takeover read is exactly the last ORCH_TAKEOVER_ROWS rows, the audit read
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

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

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
  [[ "$got" == "$want" ]] && ok "takeover at ORCH_TAKEOVER_ROWS=$rows prints exactly the last rows" \
    || bad "takeover at ORCH_TAKEOVER_ROWS=$rows prints exactly the last rows" "got=$got"
done <<'ROWS'
10|KEN-4,KEN-5,KEN-6,KEN-7,KEN-8,KEN-9,KEN-10,KEN-11,KEN-12,KEN-13
3|KEN-11,KEN-12,KEN-13
20|KEN-0,KEN-1,KEN-2,KEN-3,KEN-4,KEN-5,KEN-6,KEN-7,KEN-8,KEN-9,KEN-10,KEN-11,KEN-12,KEN-13
0|
ROWS

got="$(env -u ORCH_TAKEOVER_ROWS "$WS" --state-dir "$sd" fleet-log takeover | jq -s 'length')"
[[ "$got" == "10" ]] && ok "takeover reads 10 rows by default" || bad "takeover reads 10 rows by default" "got=$got"

got="$("$WS" --state-dir "$sd" fleet-log audit | jq -rs 'map(.kind) | unique | join(",")')"
count="$("$WS" --state-dir "$sd" fleet-log audit | jq -s 'length')"
[[ "$got" == "proposal,ruling" && "$count" == "8" ]] \
  && ok "audit prints every proposal and ruling row and no other kind" \
  || bad "audit prints every proposal and ruling row and no other kind" "kinds=$got count=$count"

rc=0
"$WS" --state-dir "$sd" fleet-log tail >/dev/null 2>"$TMP_ROOT/reader.err" || rc=$?
key="$(head -n 1 "$TMP_ROOT/reader.err")"
[[ "$rc" -eq 2 && "$key" == "workflow-state: fleet-log-reader reader=tail" ]] \
  && ok "another reader is refused as fleet-log-reader" \
  || bad "another reader is refused as fleet-log-reader" "rc=$rc key=$key"

# A first fleet session has no fleet state yet: its takeover is empty, not a
# refusal whose advice would write an issue-shaped state as the fleet's.
rc=0
out="$("$WS" --state-dir "$TMP_ROOT/no-fleet" fleet-log takeover 2>&1)" || rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] && ok "takeover with no fleet state prints nothing and exits 0" \
  || bad "takeover with no fleet state prints nothing and exits 0" "rc=$rc out=$out"

# Planted: the takeover slice dropped. The read then prints the whole log.
MUTANT_DIR="$TMP_ROOT/mutant"
mkdir -p "$MUTANT_DIR"
cp -R "$REPO_ROOT/skills/orch/scripts/lib" "$MUTANT_DIR/lib"
cp "$REPO_ROOT/skills/orch/scripts/orch-env" "$REPO_ROOT/skills/orch/scripts/git-context" "$MUTANT_DIR/"
anchor="if \$n == 0 then empty else .[-\$n:][] end"
[[ "$(grep -Fc -- "$anchor" "$WS")" == "1" ]] && ok "the slice control finds the takeover slice" \
  || bad "the slice control finds the takeover slice"
sed 's/else \.\[-\$n:\]\[\] end/else .[] end/' "$WS" > "$MUTANT_DIR/workflow-state"
got="$(bash "$MUTANT_DIR/workflow-state" --state-dir "$sd" fleet-log takeover | jq -s 'length')"
[[ "$got" == "14" ]] && ok "control: without the slice the takeover read prints every row" \
  || bad "control: without the slice the takeover read prints every row" "got=$got"

# Planted: the absent-state arm made the existence check every other reader
# takes. The first session's takeover then refuses as state-missing.
anchor='[[ -f "$state_file" ]] || return 0'
[[ "$(grep -Fc -- "$anchor" "$WS")" == "1" ]] && ok "the absent-state control finds its arm" \
  || bad "the absent-state control finds its arm"
awk -v a="$anchor" 'index($0, a) { sub(/[^ ].*/, ""); print $0 "ensure_state_exists \"$state_file\""; next } { print }' \
  "$WS" > "$MUTANT_DIR/absent-refused"
rc=0
bash "$MUTANT_DIR/absent-refused" --state-dir "$TMP_ROOT/no-fleet" fleet-log takeover >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && ok "control: without the absent-state arm the first takeover refuses" \
  || bad "control: without the absent-state arm the first takeover refuses" "rc=$rc"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
