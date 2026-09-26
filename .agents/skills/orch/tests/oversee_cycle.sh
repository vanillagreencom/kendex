#!/usr/bin/env bash
# oversee-cycle: a closed lane's record against its class target, the stamps
# it writes to the lane record, the repeat-miss bar, and the per-class rollup.
#
# The real script runs from a copy of orch/scripts laid out beside a stub
# github skill, whose pr-timeline answers the case's timeline.json, a stub
# harness-ci classifier, which answers the case's class file, and a lane-host
# fake, which serves a hosted lane's files from the case's host directory.
# Each stub logs its argv to the case. The checkout is a two-commit
# repository whose HEAD is the merge commit the timeline names; its origin
# holds one more commit the checkout lacks. Each case asserts the printed
# line, and the lane record's `cycle` read back from the fleet state.
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
cp -R "$TEST_DIR/../../github/scripts/lib" "$LAYOUT/github/scripts/lib"
BIN="$LAYOUT/orch/scripts/oversee-cycle"
cat > "$LAYOUT/github/scripts/github.sh" <<'SH'
#!/usr/bin/env bash
[[ "$1" == pr-timeline ]] || { echo "github-stub: $1" >&2; exit 9; }
printf '%s\n' "$*" >> "$CASE/github.calls"
cat "$CASE/timeline.json"
SH
# The classifier's own stderr `class:` line carries the measured marker the
# case's measured file names, true by default.
cat > "$LAYOUT/harness-ci/scripts/change-class" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE/class.calls"
[[ -f "$CASE/class" ]] || { echo "change-class: cause=stub" >&2; exit 2; }
measured=true
[[ ! -f "$CASE/measured" ]] || measured="$(cat "$CASE/measured")"
printf 'class: class=%s measured=%s cause=stub\n' "$(cat "$CASE/class")" "$measured" >&2
printf 'change_class=%s\n' "$(cat "$CASE/class")"
SH
# `cat --item ITEM PATH` serves PATH from the case's host directory, exit 2
# where it holds no such file, as a provider answers; `touch` answers.
cat > "$LAYOUT/orch/scripts/lane-host" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE/lane-host.calls"
case "$1" in
  cat) [[ -f "$CASE/host$4" ]] || exit 2; cat -- "$CASE/host$4" ;;
  touch) exit 0 ;;
  *) exit 9 ;;
esac
SH
# gh answers `repo view` with the case's slug file, owner/repo by default,
# which is the repository this checkout resolves to.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
[[ "$1 $2" == "repo view" ]] || exit 1
if [[ -f "$CASE/slug" ]]; then cat "$CASE/slug"; else echo owner/repo; fi
SH
chmod +x "$LAYOUT/github/scripts/github.sh" "$LAYOUT/harness-ci/scripts/change-class" "$LAYOUT/orch/scripts/lane-host" "$TMP_ROOT/bin/gh"

commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2"; }
ORIGIN="$TMP_ROOT/origin.git"
git init -q --bare "$ORIGIN"
REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
commit "$REPO" base
commit "$REPO" merge
MERGE="$(git -C "$REPO" rev-parse HEAD)"
BASE="$(git -C "$REPO" rev-parse HEAD^)"
git -C "$REPO" remote add origin "$ORIGIN"
git -C "$REPO" push -q origin HEAD:refs/heads/main
# A merge commit only origin holds, as a queue merge is before the checkout
# syncs: a second clone commits it and pushes it to a branch of its own.
OTHER="$TMP_ROOT/other"
git clone -q -b main "$ORIGIN" "$OTHER"
git -C "$OTHER" config gc.auto 0
git -C "$OTHER" config maintenance.auto false
commit "$OTHER" far
FAR="$(git -C "$OTHER" rev-parse HEAD)"
git -C "$OTHER" push -q origin HEAD:refs/heads/far
mkdir -p "$REPO/tmp"

T0=1790000000 # the lane's launched_at
at() { jq -rn --argjson t "$((T0 + $1))" '$t | todate'; }

# new_case NAME: a fleet state holding lane records KEN-1..KEN-6, all
# launched at T0.
new_case() {
  CASE="$TMP_ROOT/case-$1"
  export CASE
  mkdir -p "$CASE/state"
  jq -n --arg at "$(at 0)" '{lanes: [range(1; 7) | {item: "KEN-\(.)", repo: null, launched_at: $at, status: "done"}], fleet_log: []}' \
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
edit_json() { jq "$2" "$1" > "$1.new" && mv -- "$1.new" "$1"; } # FILE FILTER

record() { # ITEM TIER [ARGS...]
  local item="$1" tier="$2" rc=0
  shift 2
  (cd "$REPO" && PATH="$TMP_ROOT/bin:$PATH" env -u ORCH_STATE_DIR -u GH_REPO "${RUN_BIN:-$BIN}" --state-dir "$CASE/state" record --pr 7 --tier "$tier" "$@" "$item") \
    > "$CASE/out" 2> "$CASE/err" || rc=$?
  printf 'rc=%s %s' "$rc" "$(cat "$CASE/out")"
}
field() { grep -o " $1=[^ ]*" <<<"$2" | head -n 1 | sed 's/^ //'; } # NAME LINE

state() { jq -c "$1" "$CASE/state/workflow-state-oversee.json"; }

# --- the target per class, and the miss verdict ------------------------------
# One row per class, one second over its target, and each class at its
# target exactly, which meets it; each tier with each class that could escape.
echo "=== each class is judged against its own target ==="
while IFS='|' read -r class merged tier want_target want_verdict want_escaped; do
  [[ -n "$class" ]] || continue
  new_case "$class-$merged-$tier"
  printf '%s' "$class" > "$CASE/class"
  timeline "$merged"
  got="$(record KEN-1 "$tier")"
  assert_eq "$(sed -E 's/ phase=.*//' <<<"$got") $(field escaped "$got")" \
    "rc=0 cycle item=KEN-1 pr=7 class=$class tier=$tier target=$want_target actual=$merged verdict=$want_verdict escaped=$want_escaped" \
    "$class at $merged s, tier $tier: target $want_target, $want_verdict, escaped $want_escaped"
done <<'ROWS'
render|301|standard|300|miss|false
render|300|standard|300|met|false
trivial|301|standard|300|miss|false
trivial|300|standard|300|met|false
micro|901|standard|900|miss|false
micro|900|micro|900|met|false
small|1501|standard|1500|miss|false
small|1500|micro|1500|met|true
standard|5401|standard|5400|miss|false
standard|5400|micro|5400|met|true
ROWS

echo "=== the class is read over the merge commit's first parent to the merge ==="
assert_eq "$(grep -o -- '--base [^ ]* --head [^ ]*' "$CASE/class.calls")" "--base $BASE --head $MERGE" \
  "the classifier is handed merge^1 and the merge commit"

echo "=== a class the classifier did not give is unclassified, never judged ==="
new_case unclassified
timeline 5401
assert_eq "$(record KEN-1 standard)" \
  "rc=0 cycle item=KEN-1 pr=7 class=- tier=standard target=- actual=5401 verdict=unclassified phase=merged phase_secs=4981 missing=- review=- fix=- bot=- full_validations=- escaped=- refixed=false" \
  "the classifier's refusal records no class and no target"
assert_eq "$(head -n 1 "$CASE/err")" "oversee-cycle: class-unread cause=classifier-exit-2" "and names the cause on stderr"

new_case unmeasured-class
printf standard > "$CASE/class"; printf false > "$CASE/measured"
timeline 1000
got="$(record KEN-1 micro)"
assert_eq "$(field class "$got") $(field verdict "$got") $(field escaped "$got")|$(head -n 1 "$CASE/err")" \
  "class=- verdict=unclassified escaped=-|oversee-cycle: class-unread cause=class-unmeasured" \
  "the classifier's fallback to standard, measured=false, is no class"

new_case absent-merge
printf micro > "$CASE/class"
timeline 1000
edit_json "$CASE/timeline.json" '.merge_commit = "0123456789abcdef0123456789abcdef01234567"'
got="$(record KEN-1 micro)"
assert_eq "$(field class "$got") $(field verdict "$got")|$(head -n 1 "$CASE/err")" \
  "class=- verdict=unclassified|oversee-cycle: class-unread cause=merge-commit-absent" \
  "a merge commit neither the checkout nor origin holds is no class"

new_case fetched-merge
printf micro > "$CASE/class"
timeline 1000
edit_json "$CASE/timeline.json" ".merge_commit = \"$FAR\""
got="$(record KEN-1 micro)"
assert_eq "$(field class "$got")|$(grep -o -- '--head [^ ]*' "$CASE/class.calls")" "class=micro|--head $FAR" \
  "a merge commit only origin holds is fetched and classified"

# --- the stamps are written to the record and read back ----------------------
echo "=== the record carries its seven stamps, its class and its rounds ==="
new_case stamps
printf micro > "$CASE/class"
timeline 1200 300 500
# The lane's own state, where workflow-state puts a local lane's in this
# checkout; each round figure has a value no other one shares.
jq -n '{first_panel: {agents: ["a"]}, rereview_cycles: 2, cycles: 5, pr_comment_review: {iterations: 4},
        validate_rounds: [{mode: "full"}, {mode: "range"}, {mode: "full"}]}' > "$REPO/tmp/workflow-state-KEN-2.json"
assert_eq "$(record KEN-2 micro)" \
  "rc=0 cycle item=KEN-2 pr=7 class=micro tier=micro target=900 actual=1200 verdict=miss phase=merged phase_secs=780 missing=- review=3 fix=5 bot=4 full_validations=2 escaped=false refixed=true" \
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

echo "=== a hosted lane's rounds are read from its clone ==="
new_case hosted
printf micro > "$CASE/class"
timeline 1200
edit_json "$CASE/state/workflow-state-oversee.json" '(.lanes[] | select(.item == "KEN-4")) |= (.host = "box" | .mail_root = "/w/KEN-4")'
mkdir -p "$CASE/host/w/KEN-4" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-4" > "$CASE/host/w/KEN-4/.git"
printf '{"cycles": 7}' > "$CASE/host/clone/tmp/workflow-state-KEN-4.json"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=7" "the fix count comes from the hosted clone's state"

echo "=== the repository the timeline is read from ==="
new_case repo
printf micro > "$CASE/class"
timeline 1200
edit_json "$CASE/state/workflow-state-oversee.json" '(.lanes[] | select(.item == "KEN-1")).repo = "owner/other"'
record KEN-1 micro >/dev/null
record KEN-2 micro --repo owner/cli >/dev/null
record KEN-1 micro --repo owner/cli >/dev/null
assert_eq "$(tr '\n' ';' < "$CASE/github.calls")" "pr-timeline 7 --repo owner/other;pr-timeline 7 --repo owner/cli;pr-timeline 7 --repo owner/cli;" \
  "--repo, else the lane record's repo, names the repository; --repo wins over the record"

echo "=== the class is read only from a checkout of the lane's repository ==="
# ELSE is another repository, with an origin of its own; a worktree of this
# checkout shares its origin.
ELSE="$TMP_ROOT/else"
git init -q "$ELSE"
git -C "$ELSE" config gc.auto 0
git -C "$ELSE" config maintenance.auto false
git -C "$ELSE" remote add origin "$TMP_ROOT/else-origin.git"
mkdir -p "$ELSE/tmp"
printf '{"cycles": 9}' > "$ELSE/tmp/workflow-state-KEN-5.json"
git -C "$REPO" worktree add -q "$TMP_ROOT/same" HEAD
new_case other-repo
printf micro > "$CASE/class"
timeline 1200
edit_json "$CASE/state/workflow-state-oversee.json" "(.lanes[] | select(.item == \"KEN-5\")).mail_root = \"$ELSE\" | (.lanes[] | select(.item == \"KEN-6\")).mail_root = \"$TMP_ROOT/same\""
while IFS='|' read -r label item args want; do
  [[ -n "$label" ]] || continue
  : > "$CASE/class.calls"
  # shellcheck disable=SC2086
  got="$(record "$item" micro $args)"
  assert_eq "$(field class "$got") $(field fix "$got")|$(grep -m 1 class-unread "$CASE/err" || true)|$(wc -l < "$CASE/class.calls" | tr -d ' ')" "$want" "$label"
done <<'ROWS'
a local lane whose worktree names another origin|KEN-5||class=- fix=9|oversee-cycle: class-unread cause=checkout-other-repo|0
a lane named in another repository|KEN-1|--repo owner/other|class=- fix=-|oversee-cycle: class-unread cause=checkout-other-repo|0
a lane named in this repository, in any case|KEN-1|--repo Owner/Repo|class=micro fix=-||1
a local lane in a worktree of this checkout|KEN-6||class=micro fix=-||1
ROWS
git -C "$REPO" worktree remove --force "$TMP_ROOT/same"

echo "=== a missing stamp names no phase ==="
# CI green at 1000 and armed at 1010: with CI gone the gate-to-armed gap
# would read as the longest and name armed.
new_case missing
printf small > "$CASE/class"
timeline 1100
jq --arg armed "$(at 1010)" '.stamps.ci_green = null | .stamps.armed = $armed' "$CASE/timeline.json" > "$CASE/t" && mv -- "$CASE/t" "$CASE/timeline.json"
got="$(record KEN-1 standard)"
assert_eq "$(field verdict "$got") $(field phase "$got") $(field phase_secs "$got") $(field missing "$got")" \
  "verdict=met phase=- phase_secs=- missing=ci_green" "the verdict stands, the phase is unnamed and the absent stamp is listed"

new_case no-launch
printf small > "$CASE/class"
timeline 1100
edit_json "$CASE/state/workflow-state-oversee.json" '(.lanes[] | select(.item == "KEN-1")).launched_at = null'
got="$(record KEN-1 standard)"
assert_eq "$(field verdict "$got") $(field actual "$got") $(field missing "$got")" "verdict=unmeasured actual=- missing=launched" \
  "a lane with no launch stamp is unmeasured, never met"

echo "=== which phase dominates is read from the stamps ==="
new_case phase
printf small > "$CASE/class"
jq -n --arg merge "$MERGE" --arg fc "$(at 900)" --arg cr "$(at 960)" --arg gate "$(at 1000)" --arg ci "$(at 1010)" --arg m "$(at 1100)" \
  '{pr: 7, merge_commit: $merge, stamps: {first_commit: $fc, created: $cr, last_push: $cr, first_gate_met: null,
    gate_met: $gate, ci_green: $ci, armed: null, queued: $gate, merged: $m}}' > "$CASE/timeline.json"
assert_eq "$(record KEN-3 micro)" \
  "rc=0 cycle item=KEN-3 pr=7 class=small tier=micro target=1500 actual=1100 verdict=met phase=first_commit phase_secs=900 missing=- review=- fix=- bot=- full_validations=- escaped=true refixed=-" \
  "launch to first commit dominates, queued stands in for armed, a micro tier merged small escaped, and no gate pass leaves refixed unknown"

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
edit_json "$CASE/timeline.json" '.merge_commit = null'
record KEN-1 standard >/dev/null || true
assert_eq "$(head -n 1 "$CASE/err")" "oversee-cycle: not-merged=7" "a PR with no merge commit writes nothing"
assert_eq "$(state '[.lanes[] | has("cycle")] | any')" "false" "and no refusal wrote a record"

# --- the repeat-miss bar -----------------------------------------------------
# The bar is one predicate with one conjunct per rule: this record is a miss,
# its phase is named, it was not already a miss on that phase, and the
# fleet's records that are misses on that phase are exactly three. Each row
# records a sequence and asserts the bar lines its last record printed; each
# conjunct has a row it alone decides, and a control below that plants its
# removal against that row.
#   m   a miss at 5000 s, its longest gap ending at merged
#   f   a miss whose first commit at 4000 s makes that gap the phase
#   n   a miss with CI green absent, so no phase is named
#   ok  a met record at 800 s, its phase merged too
echo "=== the repeat-miss bar ==="
repeat_row() { # CASE SEQUENCE — prints the bar lines the last record printed
  local step kind item got="" armed
  new_case "$1"
  printf micro > "$CASE/class"
  for step in $2; do
    kind="${step%%:*}" item="KEN-${step#*:}"
    case "$kind" in
      m) timeline 5000 ;;
      f) timeline 5000; edit_json "$CASE/timeline.json" ".stamps.first_commit = \"$(at 4000)\"" ;;
      n) timeline 5000; edit_json "$CASE/timeline.json" '.stamps.ci_green = null' ;;
      ok) timeline 800 ;;
      *) echo "repeat_row: unknown step $step" >&2; exit 2 ;;
    esac
    got="$(record "$item" micro)"
  done
  grep '^repeat-miss' <<<"$got" || true
}
REPEAT_ROWS='third|m:1 m:2 m:3|repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3
met-record|m:1 m:2 m:3 ok:4|
met-not-counted|ok:1 m:2 m:3|
other-phase|m:1 m:2 f:3|
unnamed-phase|n:1 n:2 n:3|
recorded-again|m:1 m:2 m:3 m:3|
fourth|m:1 m:2 m:3 m:4|'
while IFS='|' read -r name sequence want; do
  assert_eq "$(repeat_row "repeat-$name" "$sequence")" "$want" "repeat bar, $name: $sequence"
done <<<"$REPEAT_ROWS"
repeat_row repeat-log "m:1 m:2 m:3" >/dev/null
assert_eq "$(state '.fleet_log[-1].text')" '"repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3"' "the fleet log carries the bar line"

# --- the rollup --------------------------------------------------------------
echo "=== the rollup counts each class, its median and p90 ==="
new_case rollup
cycle() { # CLASS ACTUAL VERDICT ROUNDS ESCAPED REFIXED
  printf '{"class":%s,"actual":%s,"verdict":"%s","rounds":%s,"escaped":%s,"refixed":%s}' "$@"
}
R='{"review":1,"fix":2,"bot":1,"full_validations":1}'
# The render record follows the micro ones, so neither lane order nor
# alphabetical order is the target table's.
jq -n --argjson c "[$(cycle '"micro"' 100 met "$R" false false),$(cycle '"micro"' 400 met "$R" true true),$(cycle '"micro"' 1000 miss null false null),$(cycle '"micro"' 200 met "$R" false false),$(cycle '"render"' 30 met "$R" false false),$(cycle '"standard"' 6000 miss "$R" false true),$(cycle null 50 unclassified null null false)]" \
  '{lanes: ([$c | to_entries[] | {item: "KEN-\(.key)", status: "done", cycle: .value}] + [{item: "KEN-99", status: "running"}]), fleet_log: []}' \
  > "$CASE/state/workflow-state-oversee.json"
want='rollup class=render items=1 median=30 p90=30 misses=0 review=1 fix=2 bot=1 full_validations=1 rounds_unread=0 escaped=0 refixed=0
rollup class=micro items=4 median=200 p90=1000 misses=1 review=3 fix=6 bot=3 full_validations=3 rounds_unread=1 escaped=1 refixed=1
rollup class=standard items=1 median=6000 p90=6000 misses=1 review=1 fix=2 bot=1 full_validations=1 rounds_unread=0 escaped=0 refixed=1
rollup class=unclassified items=1 median=50 p90=50 misses=0 review=- fix=- bot=- full_validations=- rounds_unread=1 escaped=0 refixed=0'
rollup() { (cd "$REPO" && "${RUN_BIN:-$BIN}" --state-dir "$CASE/state" rollup) 2>"$CASE/err"; }
assert_eq "$(rollup)" "$want" "one row per class with a record, in target order, unclassified last"
assert_eq "$(state '.fleet_log | map(.item) | join(",")')" '"render,micro,standard,unclassified"' "each row joins the fleet log under its class"

new_case rollup-no-state
rm -f -- "${CASE:?}/state/workflow-state-oversee.json"
rc=0; out="$(rollup)" || rc=$?
assert_eq "rc=$rc out=$out files=$(ls -A "$CASE/state" | tr '\n' ' ')" "rc=0 out= files=" "with no fleet state yet the rollup prints nothing, writes nothing and exits 0"
assert_eq "$(record KEN-1 micro) $(head -n 1 "$CASE/err")" "rc=1  oversee-cycle: state-missing=$CASE/state/workflow-state-oversee.json" "while a record refuses"

echo "=== --help prints the targets the verdict reads ==="
assert_eq "$("$BIN" --help | tail -n 1)" "Targets, seconds: render 300, trivial 300, micro 900, small 1500, standard 5400" \
  "the last help line is the target table"

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
assert_eq "$(field verdict "$(record KEN-1 standard)")" "verdict=met" \
  "control: without the target comparison a close past its target reports no miss"

mutant no-write '(.lanes[] | select(.item == $item)).cycle = $cycle' '.'
new_case c-write; printf micro > "$CASE/class"; timeline 1200
record KEN-2 micro >/dev/null
assert_eq "$(state '.lanes[] | select(.item == "KEN-2") | .cycle.stamps')" "null" \
  "control: without the record write the lane carries no stamps"

mutant no-fix-rounds 'fix: (.cycles // 0),' 'fix: 0,'
new_case c-rounds; printf micro > "$CASE/class"; timeline 1200
printf '{"cycles": 3}' > "$REPO/tmp/workflow-state-KEN-2.json"
assert_eq "$(field fix "$(record KEN-2 micro)")" "fix=0" \
  "control: a fix count not read from the lane's state reads as none"
rm -f -- "${REPO:?}/tmp/workflow-state-KEN-2.json"

mutant first-phase 'sort_by(- .secs)' 'sort_by(.secs)'
new_case c-phase; printf micro > "$CASE/class"; timeline 1200
assert_eq "$(field phase "$(record KEN-1 micro)")" "phase=first_commit" \
  "control: sorting gaps shortest first names a phase that did not dominate"

mutant phase-over-missing 'if ($missing | length) > 0 then' 'if false then'
new_case c-missing; printf small > "$CASE/class"; timeline 1100
jq --arg armed "$(at 1010)" '.stamps.ci_green = null | .stamps.armed = $armed' "$CASE/timeline.json" > "$CASE/t" && mv -- "$CASE/t" "$CASE/timeline.json"
assert_eq "$(field phase "$(record KEN-1 standard)")" "phase=armed" \
  "control: naming a phase across a missing stamp blames armed for CI's time"

mutant unmeasured-class '[[ "$CHANGE_CLASS_MEASURED" != true ]]' 'false'
new_case c-measured; printf standard > "$CASE/class"; printf false > "$CASE/measured"; timeline 1000
assert_eq "$(field class "$(record KEN-1 micro)")" "class=standard" \
  "control: without the marker check the classifier's fallback reads as a class"

other_repo_row() { # prints class and fix for the lane whose worktree names another origin
  new_case "$1"; printf micro > "$CASE/class"; timeline 1200
  edit_json "$CASE/state/workflow-state-oversee.json" "(.lanes[] | select(.item == \"KEN-5\")).mail_root = \"$ELSE\""
  got="$(record KEN-5 micro)"
  printf '%s %s' "$(field class "$got")" "$(field fix "$got")"
}
mutant other-repo 'elif other_repo "$checkout"; then' 'elif false; then'
assert_eq "$(other_repo_row c-other-repo)" "class=micro fix=9" \
  "control: without the repository check another repository's lane is classified from this checkout"
RUN_BIN=""
LIB="$LAYOUT/orch/scripts/lib/lane-gitfile.sh"
cp -- "$LIB" "$TMP_ROOT/lane-gitfile.sh.kept"
anchor='path="$(cd -- "$6" && "$1" path "$4" 2>"$7/state.err")" || return 2'
assert_eq "$(grep -Fc -- "$anchor" "$LIB")" "1" "the lane-root control finds its anchor"
A="$anchor" awk '{ i = index($0, ENVIRON["A"]); if (i) $0 = substr($0, 1, i - 1) "path=\"$(\"$1\" path \"$4\" 2>\"$7/state.err\")\" || return 2" substr($0, i + length(ENVIRON["A"])); print }' \
  "$TMP_ROOT/lane-gitfile.sh.kept" > "$LIB"
assert_eq "$(other_repo_row c-lane-root)" "class=- fix=-" \
  "control: read from the caller's checkout, another repository's lane has no rounds"
cp -- "$TMP_ROOT/lane-gitfile.sh.kept" "$LIB"

# One planted removal per conjunct of the repeat bar, each run against the
# row that conjunct alone decides, which then prints a bar.
while IFS='@' read -r name anchor replacement row; do
  mutant "repeat-$name" "$anchor" "$replacement"
  sequence="$(awk -F'|' -v row="$row" '$1 == row { print $2 }' <<<"$REPEAT_ROWS")"
  assert_eq "$(repeat_row "c-repeat-$name" "$sequence" | grep -c '^repeat-miss' || true)" "1" \
    "control: without the $name conjunct the $row row fires the bar"
done <<'ROWS'
this-miss@if $cycle.verdict != "miss"@if false@met-record
counted-miss@[.lanes[]? | select(.cycle.verdict == "miss")@[.lanes[]? | select(true)@met-not-counted
same-phase@| select(.cycle.phase == $cycle.phase) | .item]@| .item]@other-phase
named-phase@or $cycle.phase == null@or false@unnamed-phase
newly-made@or ($prior.verdict == "miss" and $prior.phase == $cycle.phase)@or false@recorded-again
exactly-third@select(length == 3)@select(length >= 3)@fourth
ROWS

mutant no-state-rollup '[[ "$VERB" != rollup ]] || exit 0' ':'
new_case c-no-state
rm -f -- "${CASE:?}/state/workflow-state-oversee.json"
rc=0; rollup >/dev/null || rc=$?
assert_eq "rc=$rc $(head -n 1 "$CASE/err")" "rc=1 oversee-cycle: state-missing=$CASE/state/workflow-state-oversee.json" \
  "control: without the no-state exit a Stop before any launch refuses its rollup"

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
