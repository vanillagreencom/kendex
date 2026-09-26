#!/usr/bin/env bash
# oversee-cycle: a closed lane's record against its class target, the stamps
# it writes to the lane record, the repeat-miss bar, and the per-class rollup.
#
# The real script runs from a copy of orch/scripts laid out beside a stub
# github skill, whose pr-timeline answers the case's timeline.json, and a stub
# harness-ci classifier, which answers the case's class file. The checkout is
# a two-commit repository whose HEAD is the merge commit the timeline names.
# Each case asserts the printed line whole, and the lane record's `cycle`
# read back from the fleet state.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(cd -- "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
assert_eq() { # GOT WANT LABEL
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$3" "$2" "$1"
  fi
}

LAYOUT="$TMP_ROOT/skills"
mkdir -p "$LAYOUT/orch" "$LAYOUT/github/scripts" "$LAYOUT/harness-ci/scripts"
cp -R "$TEST_DIR/../scripts" "$LAYOUT/orch/scripts"
BIN="$LAYOUT/orch/scripts/oversee-cycle"
cat > "$LAYOUT/github/scripts/github.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == pr-timeline ]] || { echo "github-stub: $1" >&2; exit 9; }
printf '%s\n' "$*" >> "$CASE/github.calls"
cat "$CASE/timeline.json"
SH
cat > "$LAYOUT/harness-ci/scripts/change-class" <<'SH'
#!/usr/bin/env bash
[[ -f "$CASE/class" ]] || { echo "change-class: cause=stub" >&2; exit 2; }
printf 'change_class=%s\n' "$(cat "$CASE/class")"
SH
chmod +x "$LAYOUT/github/scripts/github.sh" "$LAYOUT/harness-ci/scripts/change-class"

REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m base
git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m merge
MERGE="$(git -C "$REPO" rev-parse HEAD)"

T0=1790000000 # the lane's launched_at
at() { jq -rn --argjson t "$((T0 + $1))" '$t | todate'; }

# new_case NAME: a fleet state holding lane records KEN-1..KEN-4, all
# launched at T0.
new_case() {
  CASE="$TMP_ROOT/case-$1"
  export CASE
  mkdir -p "$CASE/state"
  jq -n --arg at "$(at 0)" '{lanes: [range(1; 5) | {item: "KEN-\(.)", repo: null, launched_at: $at, status: "done"}], fleet_log: []}' \
    > "$CASE/state/workflow-state-oversee.json"
}

# timeline MERGED [FIRST_GATE PUSH]: the PR's stamps as seconds past T0. The
# gaps are fixed so the longest is the one ending at merged unless MERGED is
# small: first commit 60, opened 120, gate 300, CI 360, armed 420.
timeline() {
  jq -n --arg merge "$MERGE" --arg fc "$(at 60)" --arg cr "$(at 120)" --arg gate "$(at 300)" \
    --arg ci "$(at 360)" --arg armed "$(at 420)" --arg merged "$(at "$1")" \
    --arg fg "$(at "${2:-300}")" --arg push "$(at "${3:-110}")" \
    '{pr: 7, repo: "owner/repo", state: "MERGED", head: "h", merge_commit: $merge,
      stamps: {first_commit: $fc, created: $cr, last_push: $push, first_bot_review: null,
               first_gate_met: $fg, gate_met: $gate, ci_green: $ci, armed: $armed,
               queued: null, merged: $merged},
      ci_head_secs: 60, ci_merge_group_secs: null, open_secs: null, bot_reviews: 0}' > "$CASE/timeline.json"
}

record() { # ITEM TIER [ARGS...]
  local item="$1" tier="$2" rc=0
  shift 2
  (cd "$REPO" && env -u ORCH_STATE_DIR "${RUN_BIN:-$BIN}" --state-dir "$CASE/state" record --pr 7 --tier "$tier" "$@" "$item") \
    > "$CASE/out" 2> "$CASE/err" || rc=$?
  printf 'rc=%s %s' "$rc" "$(cat "$CASE/out")"
}

state() { jq -c "$1" "$CASE/state/workflow-state-oversee.json"; }

# --- the target per class, and the miss verdict ------------------------------
# One row per class, one second over its target, and each class at its
# target exactly, which meets it.
echo "=== each class is judged against its own target ==="
while IFS='|' read -r class merged want_target want_verdict; do
  [[ -n "$class" ]] || continue
  new_case "$class-$merged"
  printf '%s' "$class" > "$CASE/class"
  timeline "$merged"
  got="$(record KEN-1 standard)"
  assert_eq "$(sed -E 's/ phase=.*//' <<<"$got")" \
    "rc=0 cycle item=KEN-1 pr=7 class=$class tier=standard target=$want_target actual=$merged verdict=$want_verdict" \
    "$class merged at $merged s: target $want_target, $want_verdict"
done <<'ROWS'
render|301|300|miss
render|300|300|met
trivial|301|300|miss
trivial|300|300|met
micro|901|900|miss
micro|900|900|met
small|1501|1500|miss
small|1500|1500|met
standard|5401|5400|miss
standard|5400|5400|met
ROWS

echo "=== a class the classifier did not give is unclassified, never judged ==="
new_case unclassified
timeline 5401
assert_eq "$(record KEN-1 standard)" \
  "rc=0 cycle item=KEN-1 pr=7 class=- tier=standard target=- actual=5401 verdict=unclassified phase=merged phase_secs=4981 review=- fix=- bot=- full_validations=- escaped=- refixed=false" \
  "the classifier's refusal records no class and no target"
assert_eq "$(head -n 1 "$CASE/err")" "oversee-cycle: class-unread cause=classifier-exit-2" "and names the cause on stderr"

# --- the stamps are written to the record and read back ----------------------
echo "=== the record carries its seven stamps, its class and its rounds ==="
new_case stamps
printf micro > "$CASE/class"
timeline 1200 300 500
# The lane's own state, where workflow-state puts a local lane's in this
# checkout.
mkdir -p "$REPO/tmp"
jq -n '{first_panel: {agents: ["a"]}, rereview_cycles: 2, cycles: 3, pr_comment_review: {iterations: 4},
        validate_rounds: [{mode: "full"}, {mode: "range"}, {mode: "full"}]}' > "$REPO/tmp/workflow-state-KEN-2.json"
assert_eq "$(record KEN-2 micro)" \
  "rc=0 cycle item=KEN-2 pr=7 class=micro tier=micro target=900 actual=1200 verdict=miss phase=merged phase_secs=780 review=3 fix=3 bot=4 full_validations=2 escaped=false refixed=true" \
  "the printed line: a miss whose longest gap ends at the merge, and a push after the first gate pass"
assert_eq "$(state '.lanes[] | select(.item == "KEN-2") | .cycle | [.class, .tier, .verdict, .stamps]')" \
  "[\"micro\",\"micro\",\"miss\",{\"launched\":\"$(at 0)\",\"first_commit\":\"$(at 60)\",\"pr_opened\":\"$(at 120)\",\"gate_green\":\"$(at 300)\",\"ci_green\":\"$(at 360)\",\"armed\":\"$(at 420)\",\"merged\":\"$(at 1200)\"}]" \
  "the lane record reads back the class and the seven stamps"
assert_eq "$(state '[.lanes[] | select(.item != "KEN-2") | has("cycle")] | any')" "false" "no other record is written"
assert_eq "$(state '.fleet_log | map(.kind + ":" + .item) | join(",")')" '"cycle:KEN-2"' "one cycle row joins the fleet log"
assert_eq "$(state '.fleet_log[0].text')" "\"$(sed 's/^rc=0 //' <<<"$(record KEN-2 micro)")\"" \
  "and its text is the printed line"
assert_eq "$(head -n 1 "$CASE/github.calls")" "pr-timeline 7" "pr-timeline is asked for the PR alone when the record names no repo"

printf 'not json' > "$REPO/tmp/workflow-state-KEN-2.json"
assert_eq "$(record KEN-2 micro | grep -o 'review=[^ ]* fix=[^ ]* bot=[^ ]* full_validations=[^ ]*')|$(grep -m 1 rounds-unread "$CASE/err")" \
  "review=- fix=- bot=- full_validations=-|oversee-cycle: rounds-unread item=KEN-2" \
  "a lane state that does not read records no rounds and says so"
rm -f -- "${REPO:?}/tmp/workflow-state-KEN-2.json"

echo "=== which phase dominates is read from the stamps ==="
new_case phase
printf small > "$CASE/class"
jq -n --arg merge "$MERGE" --arg fc "$(at 900)" --arg cr "$(at 960)" --arg gate "$(at 1000)" --arg m "$(at 1100)" \
  '{pr: 7, merge_commit: $merge, stamps: {first_commit: $fc, created: $cr, last_push: $cr, first_gate_met: null,
    gate_met: $gate, ci_green: null, armed: null, queued: $gate, merged: $m}}' > "$CASE/timeline.json"
assert_eq "$(record KEN-3 micro)" \
  "rc=0 cycle item=KEN-3 pr=7 class=small tier=micro target=1500 actual=1100 verdict=met phase=first_commit phase_secs=900 review=- fix=- bot=- full_validations=- escaped=true refixed=false" \
  "launch to first commit dominates, queued stands in for armed, and a micro tier merged small escaped"

echo "=== refusals ==="
new_case refusals
timeline 100
while IFS='|' read -r label args want; do
  [[ -n "$label" ]] || continue
  # shellcheck disable=SC2086
  record $args >/dev/null || true
  assert_eq "$(head -n 1 "$CASE/err")" "$want" "$label"
done <<'ROWS'
an item the fleet never launched|KEN-9 standard|oversee-cycle: record-missing=KEN-9
a tier oversee.md never gives|KEN-1 small|oversee-cycle: usage=--tier
ROWS
jq '.merge_commit = null' "$CASE/timeline.json" > "$CASE/t" && mv "$CASE/t" "$CASE/timeline.json"
record KEN-1 standard >/dev/null || true
assert_eq "$(head -n 1 "$CASE/err")" "oversee-cycle: not-merged=7" "a PR with no merge commit writes nothing"
assert_eq "$(state '[.lanes[] | has("cycle")] | any')" "false" "and no refusal wrote a record"

# --- the repeat-miss bar -----------------------------------------------------
echo "=== the third miss on one phase names the three lanes ==="
new_case repeat
printf micro > "$CASE/class"
timeline 5000
record KEN-1 micro >/dev/null
assert_eq "$(record KEN-2 micro | grep -c '^repeat-miss' || true)" "0" "two misses on one phase are under the bar"
got="$(record KEN-3 micro)"
assert_eq "$(tail -n 1 <<<"$got")" "repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3" "the third names its phase and lanes"
assert_eq "$(state '.fleet_log[-1].text')" '"repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3"' "and the fleet log carries it"

# --- the rollup --------------------------------------------------------------
echo "=== the rollup counts each class, its median and p90 ==="
new_case rollup
cycle() { # CLASS ACTUAL VERDICT ROUNDS ESCAPED REFIXED
  printf '{"class":%s,"actual":%s,"verdict":"%s","rounds":%s,"escaped":%s,"refixed":%s}' "$@"
}
R='{"review":1,"fix":2,"bot":1,"full_validations":1}'
jq -n --argjson c "[$(cycle '"micro"' 100 met "$R" false false),$(cycle '"micro"' 400 met "$R" true true),$(cycle '"micro"' 1000 miss null false false),$(cycle '"micro"' 200 met "$R" false false),$(cycle '"standard"' 6000 miss "$R" false true),$(cycle null 50 unclassified null null false)]" \
  '{lanes: ([$c | to_entries[] | {item: "KEN-\(.key)", status: "done", cycle: .value}] + [{item: "KEN-99", status: "running"}]), fleet_log: []}' \
  > "$CASE/state/workflow-state-oversee.json"
want='rollup class=micro items=4 median=200 p90=1000 misses=1 review=3 fix=6 bot=3 full_validations=3 rounds_unread=1 escaped=1 refixed=1
rollup class=standard items=1 median=6000 p90=6000 misses=1 review=1 fix=2 bot=1 full_validations=1 rounds_unread=0 escaped=0 refixed=1
rollup class=unclassified items=1 median=50 p90=50 misses=0 review=- fix=- bot=- full_validations=- rounds_unread=1 escaped=0 refixed=0'
rollup() { (cd "$REPO" && "${RUN_BIN:-$BIN}" --state-dir "$CASE/state" rollup) 2>"$CASE/err"; }
assert_eq "$(rollup)" "$want" "one row per class with a record, in target order, unclassified last"
assert_eq "$(state '.fleet_log | map(.item) | join(",")')" '"micro,standard,unclassified"' "each row joins the fleet log under its class"

# --- controls ----------------------------------------------------------------
# One planted defect per surface, each in a copy beside the script so it
# resolves the same stubs; each must turn its case red.
mutant() { # NAME ANCHOR REPLACEMENT
  assert_eq "$(grep -Fc -- "$2" "$BIN")" "1" "the $1 control finds its anchor"
  A="$2" R="$3" awk '{ i = index($0, ENVIRON["A"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["R"] substr($0, i + length(ENVIRON["A"])); print }' \
    "$BIN" > "$BIN.$1"
  chmod +x "$BIN.$1"
  RUN_BIN="$BIN.$1"
}

echo "=== controls ==="
mutant no-miss 'elif $actual > $target then "miss"' 'elif false then "miss"'
new_case c-miss; printf standard > "$CASE/class"; timeline 5401
assert_eq "$(record KEN-1 standard | grep -o 'verdict=[a-z]*')" "verdict=met" \
  "control: without the target comparison a close past its target reports no miss"

mutant no-write '(.lanes[] | select(.item == $item)).cycle = $cycle' '.'
new_case c-write; printf micro > "$CASE/class"; timeline 1200
record KEN-2 micro >/dev/null
assert_eq "$(state '.lanes[] | select(.item == "KEN-2") | .cycle.stamps')" "null" \
  "control: without the record write the lane carries no stamps"

mutant no-fix-rounds 'fix: (.cycles // 0),' 'fix: 0,'
new_case c-rounds; printf micro > "$CASE/class"; timeline 1200
printf '{"cycles": 3}' > "$REPO/tmp/workflow-state-KEN-2.json"
assert_eq "$(record KEN-2 micro | grep -o ' fix=[0-9-]*')" " fix=0" \
  "control: a fix count not read from the lane's state reads as none"
rm -f -- "${REPO:?}/tmp/workflow-state-KEN-2.json"

mutant first-phase 'sort_by(- .secs)' 'sort_by(.secs)'
new_case c-phase; printf micro > "$CASE/class"; timeline 1200
assert_eq "$(record KEN-1 micro | grep -o 'phase=[a-z_]*')" "phase=first_commit" \
  "control: sorting gaps shortest first names a phase that did not dominate"

mutant repeat-bar 'select(length == 3)' 'select(length == 4)'
new_case c-repeat; printf micro > "$CASE/class"; timeline 5000
record KEN-1 micro >/dev/null; record KEN-2 micro >/dev/null
assert_eq "$(record KEN-3 micro | grep -c '^repeat-miss' || true)" "0" \
  "control: a bar at four misses is silent on the third"

mutant p90-floor '| if $n == 0 then "-" else $a[(($n * $p) | ceil) - 1] end;' '| if $n == 0 then "-" else $a[(($n * $p) | floor) - 1] end;'
new_case c-rollup
jq -n --argjson c "[$(cycle '"micro"' 100 met null false false),$(cycle '"micro"' 400 met null false false),$(cycle '"micro"' 1000 miss null false false),$(cycle '"micro"' 200 met null false false)]" \
  '{lanes: [$c | to_entries[] | {item: "KEN-\(.key)", status: "done", cycle: .value}], fleet_log: []}' \
  > "$CASE/state/workflow-state-oversee.json"
assert_eq "$(rollup | grep -o 'p90=[0-9]*')" "p90=400" "control: a floor rank reports a p90 below the slowest tenth"
RUN_BIN=""

echo
echo "pass: $PASS  fail: $FAIL"
[[ "$FAIL" -eq 0 ]]
