#!/usr/bin/env bash
# oversee-cycle: a closed lane's record against its class target, the stamps
# it writes to the lane record, the repeat-miss bar, and the per-class rollup.
#
# The real script runs from links to the shipped orch/scripts, laid out by
# mutant_scripts beside a stub github skill, whose pr-timeline answers the
# case's timeline.json, and a stub harness-ci classifier, which answers the
# case's class file; a lane-host fake, which serves a hosted lane's files from
# the case's host directory, stands in for that one link.
# Each stub logs its argv to the case. The checkout is a two-commit
# repository whose HEAD is the merge commit the timeline names; its origin
# holds one more commit the checkout lacks. Each case asserts the printed
# line, and the lane record's `cycle` read back from the fleet state.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "oversee_cycle: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "oversee_cycle: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "oversee_cycle: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# mutant_scripts and mutate_file: the layout and the controls below.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

LAYOUT="$TMP_ROOT/skills"
mutant_scripts skills/orch >/dev/null || exit 1
mkdir -p "$LAYOUT/github/scripts" "$LAYOUT/harness-ci/scripts"
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
reason=stub
[[ ! -f "$CASE/reason" ]] || reason="$(cat "$CASE/reason")"
printf 'class: class=%s measured=%s cause=%s\n' "$(cat "$CASE/class")" "$measured" "$reason" >&2
printf 'change_class=%s\n' "$(cat "$CASE/class")"
SH
# `cat --item ITEM PATH` serves PATH from the case's host directory, exit 2
# where it holds no such file, as a provider answers; `touch` answers.
# The kinds kendex owns, local and claude-cloud, are the real dispatcher's
# answers, its refusal of a provider verb included, and any other host
# declares a provider's files=verb line, but caps-broken, whose line the
# dispatcher refuses as a provider's line missing a key.
rm -- "$LAYOUT/orch/scripts/lane-host"
export OVERSEE_CYCLE_REAL_LANE_HOST="$TEST_DIR/../scripts/lane-host"
cat > "$LAYOUT/orch/scripts/lane-host" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CASE/lane-host.calls"
case "$ORCH_LANE_HOST" in local | claude-cloud) exec "$OVERSEE_CYCLE_REAL_LANE_HOST" "$@" ;; esac
case "$1" in
  capabilities)
    [[ "$ORCH_LANE_HOST" != caps-broken ]] || { echo 'lane-host: capability-invalid key=files value=' >&2; exit 1; }
    printf 'kind=ssh\tfiles=verb\n' ;;
  cat) [[ -f "$CASE/host$4" ]] || exit 2; cat -- "$CASE/host$4" ;;
  touch) exit 0 ;;
  *) exit 9 ;;
esac
SH
# gh answers `repo view` with the case's slug file, owner/repo by default,
# which is the repository this checkout resolves to. Its `api` answers a
# repository activity read with the case's activity.json and a compare of
# BASE with HEAD with the case's compare-BASE...HEAD file, the status
# GitHub gives, failing as GitHub's 404 where the case holds no such file;
# each api call is logged to gh.calls.
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == api ]]; then
  printf '%s\n' "$*" >> "$CASE/gh.calls"
  case "$*" in
    "api --paginate repos/owner/repo/activity?"*) file="$CASE/activity.json" ;;
    "api repos/owner/repo/compare/"*" --jq .status") file="$CASE/compare-${2#*/compare/}" ;;
    *) exit 9 ;;
  esac
  [[ -f "$file" ]] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
  exec cat -- "$file"
fi
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
env GIT_AUTHOR_DATE='1790000060 +0000' GIT_COMMITTER_DATE='1790000900 +0000' \
  git -C "$REPO" -c user.name=t -c user.email=t@t commit -q --allow-empty -m merge
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
# small: first commit 60, opened 120, gate 300, CI 360, armed 420. Its rounds
# are PR_ROUNDS, none by default.
timeline() {
  jq -n --arg merge "$MERGE" --arg fc "$(at 60)" --arg cr "$(at 120)" --arg gate "$(at 300)" \
    --arg ci "$(at 360)" --arg armed "$(at 420)" --arg merged "$(at "$1")" --argjson open "$(($1 - 120))" \
    --arg fg "$(at "${2:-300}")" --arg push "$(at "${3:-110}")" --argjson rounds "${PR_ROUNDS:-[]}" \
    '{pr: 7, repo: "owner/repo", state: "MERGED", head: "h", merge_commit: $merge,
      stamps: {first_commit: $fc, created: $cr, last_push: $push, first_bot_review: null,
               first_gate_met: $fg, gate_met: $gate, ci_green: $ci, armed: $armed,
               queued: null, merged: $merged},
      ci_head_secs: 60, ci_merge_group_secs: null, open_secs: $open, bot_reviews: 0,
      push_times: [$push], bot_review_times: [], rounds: $rounds}' > "$CASE/timeline.json"
}
edit_json() { jq "$2" "$1" > "$1.new" && mv -- "$1.new" "$1"; } # FILE FILTER
# answer AFTER STATUS: GitHub's compare of the recorded commit with AFTER.
answer() { printf %s "$2" > "$CASE/compare-$MERGE...$1"; }

# pushes [SECS:AFTER...]: the base branch's push log GitHub answers, each push
# SECS past T0 leaving the branch at AFTER, newest first as GitHub orders it.
pushes() {
  jq -n --argjson t0 "$T0" --arg entries "$*" '[$entries | split(" ")[] | select(. != "") | split(":")
    | {activity_type: "push", ref: "refs/heads/main", timestamp: ($t0 + (.[0] | tonumber) | todate), after: .[1]}]
    | sort_by(.timestamp) | reverse' > "$CASE/activity.json"
}

RECORD_ARGS=(--pr 7)
# CONTROL_STATE_DIR, where set, is the ORCH_STATE_DIR the overseer's own
# machine runs under.
record() { # ITEM TIER [ARGS...]
  local item="$1" tier="$2" rc=0 tier_args=()
  shift 2
  [[ -z "$tier" ]] || tier_args=(--tier "$tier")
  (cd "$REPO" && PATH="$TMP_ROOT/bin:$PATH" env -u ORCH_STATE_DIR -u GH_REPO -u WORKTREE_DEFAULT_BRANCH ${CONTROL_STATE_DIR:+ORCH_STATE_DIR="$CONTROL_STATE_DIR"} "${RUN_BIN:-$BIN}" --state-dir "$CASE/state" record ${RECORD_ARGS[@]+"${RECORD_ARGS[@]}"} ${tier_args[@]+"${tier_args[@]}"} "$@" "$item") \
    > "$CASE/out" 2> "$CASE/err" || rc=$?
  printf 'rc=%s %s' "$rc" "$(cat "$CASE/out")"
}
field() { grep -o " $1=[^ ]*" <<<"$2" | head -n 1 | sed 's/^ //'; } # NAME LINE

state() { jq -c "$1" "$CASE/state/workflow-state-oversee.json"; }

# Both delivery forms use the same reader and writer. The direct-push case
# has no timeline fixture: calling pr-timeline would fail the record.
echo "=== direct push and the mutually exclusive delivery flags ==="
while IFS='|' read -r name form want_out want_err; do
  new_case "delivery-$name"
  printf small > "$CASE/class"
  edit_json "$CASE/state/workflow-state-oversee.json" '.lanes[0].tier = "micro"'
  case "$form" in
    pr) RECORD_ARGS=(--pr 7); timeline 900 ;;
    commit) RECORD_ARGS=(--commit "$MERGE"); pushes "900:$MERGE" ;;
    both) RECORD_ARGS=(--pr 7 --commit "$MERGE"); timeline 900 ;;
    neither) RECORD_ARGS=() ;;
  esac
  got="$(record KEN-1 '')"
  assert_eq "$(sed -E 's/ phase=.*//' <<<"$got")|$(sed -n '/^oversee-cycle: usage=/p' "$CASE/err")" \
    "${want_out//SHA/$MERGE}|$want_err" "delivery flags: $name"
done <<'ROWS'
PR|pr|rc=0 cycle item=KEN-1 pr=7 class=small tier=micro target=1800 merge_group=- actual=900 open=780 verdict=met|
direct push|commit|rc=0 cycle item=KEN-1 commit=SHA class=small tier=micro target=1800 merge_group=- actual=900 open=- verdict=unmeasured|
both|both|rc=2 |oversee-cycle: usage=--pr,--commit
neither|neither|rc=2 |oversee-cycle: usage=--pr,--commit
ROWS
assert_eq "$(state '[.lanes[] | has("cycle")] | any')" false "neither form writes no cycle"

# The commit's committer date is 900; GitHub records its push at 1200, after
# another lane's push at 300.
new_case direct-stamps
printf small > "$CASE/class"
edit_json "$CASE/state/workflow-state-oversee.json" '.lanes[0].tier = "micro"'
RECORD_ARGS=(--commit "$MERGE")
pushes "300:$BASE" "1200:$MERGE"
got="$(record KEN-1 '')"
assert_eq "$got" \
  "rc=0 cycle item=KEN-1 commit=$MERGE class=small tier=micro target=1800 merge_group=- actual=1200 open=- verdict=unmeasured phase=- phase_secs=- cause=- bot_wait=- thread_fix=- paused=- missing=pr_opened,gate_green,ci_green,armed review=- fix=- bot=- full_validations=- pr_rounds=- escaped=true tier_inputs=- class_reason=stub escape_cause=- refixed=-" \
  "direct push prints the commit, elapsed time to its push, escape and absent PR fields"
assert_eq "$(state '.lanes[0].cycle | [.commit, has("pr"), .class, .tier, .actual, .escaped, .stamps]')" \
  "[\"$MERGE\",false,\"small\",\"micro\",1200,true,{\"launched\":\"$(at 0)\",\"first_commit\":\"$(at 60)\",\"pr_opened\":null,\"gate_green\":null,\"ci_green\":null,\"armed\":null,\"merged\":\"$(at 1200)\"}]" \
  "direct push persists its authored date and its push time, not its committer date, in UTC"
assert_eq "$(grep -c '^api --paginate repos/owner/repo/activity?ref=refs%2Fheads%2Fmain&activity_type=push&per_page=100' "$CASE/gh.calls")|$(grep -c compare/ "$CASE/gh.calls" || true)" \
  "1|0" "the push is read from the base branch's push log, and a push leaving the branch at the commit needs no compare"
assert_eq "$(state '.fleet_log[-1].text')" "\"${got#rc=0 }\"" "direct cycle row is the printed row"
assert_eq "$(grep -o -- '--base [^ ]* --head [^ ]*' "$CASE/class.calls")" "--base $BASE --head $MERGE" \
  "direct push reuses the first-parent classifier"
assert_eq "$(test -f "$CASE/github.calls" && echo called || echo absent)" absent "direct push reads no PR or CI checks"
assert_contains "$(cd "$REPO" && "$BIN" --state-dir "$CASE/state" rollup)" \
  'rollup class=small items=1 median=1200 p90=1200 misses=0' "rollup includes the direct push in its class"

# A push the log cannot place: each row is the base branch's push log, the
# compare answers, and the merged stamp, actual and merged-unread cause the
# record gives. A batch push whose `after` contains the commit places it;
# a push before the launch is never compared, its compare left unanswered.
echo "=== the push time, from GitHub's push log, and a push it cannot place ==="
OTHER=1111111111111111111111111111111111111111 BATCH=2222222222222222222222222222222222222222
OLD=3333333333333333333333333333333333333333
shas() { local v="${1//other/$OTHER}"; v="${v//batch/$BATCH}"; printf '%s' "${v//old/$OLD}"; } # ROW_FIELD
while IFS='|' read -r name log answers want_merged want_actual want_cause; do
  new_case "push-$name"
  printf small > "$CASE/class"
  edit_json "$CASE/state/workflow-state-oversee.json" '.lanes[0].tier = "micro"'
  [[ "$log" == unread ]] || pushes "$(shas "$log")"
  for pair in $(shas "$answers"); do answer "${pair%%=*}" "${pair#*=}"; done
  got="$(record KEN-1 '')"
  assert_eq "$(state '.lanes[0].cycle.stamps.merged') $(field actual "$got") $(cut -d' ' -f1 <<<"$got")|$(sed -n 's/^oversee-cycle: merged-unread commit=[^ ]* //p' "$CASE/err")" \
    "${want_merged/AT/\"$(at 1500)\"} $want_actual rc=0|$want_cause" "push time: $name"
done <<'ROWS'
batch push containing it|-100:old 300:other 1500:batch|other=diverged batch=ahead|AT|actual=1500|
no push leaves the branch at it or past it|300:other|other=diverged|null|actual=-|cause=no-push
log unread|unread||null|actual=-|cause=activity-unread
compare unanswered|1500:batch||null|actual=-|cause=compare-failed
ROWS

# The log is read over GitHub's shortest period that holds the launch.
new_case push-period
printf small > "$CASE/class"
edit_json "$CASE/state/workflow-state-oversee.json" ".lanes[0] += {tier: \"micro\", launched_at: \"$(jq -rn 'now - 7200 | floor | todate')\"}"
pushes "1200:$MERGE"
record KEN-1 '' >/dev/null
assert_eq "$(grep -o 'time_period=[a-z]*' "$CASE/gh.calls")" time_period=day "a launch two hours back reads the past day's pushes"
RECORD_ARGS=(--pr 7)

# --- the target per class, and the miss verdict ------------------------------
# One row per class, open to merge one second over its target, and each class
# at its target exactly, which meets it; each tier with each class that could
# escape. The PR opens at 120 s, so open is merged minus 120.
echo "=== each class is judged against its own target ==="
while IFS='|' read -r class merged tier want_target want_verdict want_escaped; do
  [[ -n "$class" ]] || continue
  new_case "$class-$merged-$tier"
  printf '%s' "$class" > "$CASE/class"
  timeline "$merged"
  got="$(record KEN-1 "$tier")"
  assert_eq "$(sed -E 's/ phase=.*//' <<<"$got") $(field escaped "$got")" \
    "rc=0 cycle item=KEN-1 pr=7 class=$class tier=$tier target=$want_target merge_group=- actual=$merged open=$((merged - 120)) verdict=$want_verdict escaped=$want_escaped" \
    "$class at $merged s, tier $tier: target $want_target, $want_verdict, escaped $want_escaped"
done <<'ROWS'
render|421|standard|300|miss|false
render|420|standard|300|met|false
trivial|421|standard|300|miss|false
trivial|420|standard|300|met|false
micro|1321|standard|1200|miss|false
micro|1320|micro|1200|met|false
small|1921|standard|1800|miss|false
small|1920|micro|1800|met|true
small|1920|small|1800|met|false
standard|5521|standard|5400|miss|false
standard|5520|micro|5400|met|true
standard|5520|small|5400|met|true
ROWS

echo "=== merge-group CI widens the target and comes off only the merged gap ==="
# The fleet example uses a 900 s micro target. Keep the shipped target table
# unchanged and replay that input in a private copy of the real script.
FLEET_BIN="$LAYOUT/orch/scripts/oversee-cycle-fleet"
cp -- "$BIN" "$FLEET_BIN"
mutate_file "$FLEET_BIN" '"micro":1200' '"micro":900'
while IFS='|' read -r name bin merged group want; do
  new_case "merge-group-$name"
  printf micro > "$CASE/class"
  RUN_BIN="$BIN"
  [[ "$bin" != fleet ]] || RUN_BIN="$FLEET_BIN"
  timeline "$merged"
  edit_json "$CASE/timeline.json" ".ci_merge_group_secs = $group | .stamps |= (.gate_met = \"$(at 500)\" | .ci_green = \"$(at 560)\" | .armed = \"$(at 620)\")"
  got="$(record KEN-1 micro)"
  assert_eq "$(field target "$got") $(field merge_group "$got") $(field verdict "$got") $(field phase "$got") $(field phase_secs "$got")|$(state '.lanes[0].cycle | [.target, .merge_group, .actual, .open, .phase, .phase_secs, .gate_waits]')" \
    "$want" "$name: the printed allowance and phase match the record; actual, open and gate waits keep their seconds"
done <<'ROWS'
allowance|fleet|1080|280|target=1180 merge_group=280 verdict=met phase=gate_green phase_secs=380|[1180,280,1080,960,"gate_green",380,{"bot_wait":380,"thread_fix":0,"paused":0}]
null-control|fleet|1080|null|target=900 merge_group=- verdict=miss phase=merged phase_secs=460|[900,null,1080,960,"merged",460,{"bot_wait":380,"thread_fix":0,"paused":0}]
queue-wait|fleet|2000|280|target=1180 merge_group=280 verdict=miss phase=merged phase_secs=1100|[1180,280,2000,1880,"merged",1100,{"bot_wait":380,"thread_fix":0,"paused":0}]
shipped-target|shipped|1500|280|target=1480 merge_group=280 verdict=met phase=merged phase_secs=600|[1480,280,1500,1380,"merged",600,{"bot_wait":380,"thread_fix":0,"paused":0}]
floor|shipped|200|280|target=1480 merge_group=280 verdict=met phase=merged phase_secs=0|[1480,280,200,80,"merged",0,null]
zero|fleet|1080|0|target=900 merge_group=0 verdict=miss phase=merged phase_secs=460|[900,0,1080,960,"merged",460,{"bot_wait":380,"thread_fix":0,"paused":0}]
ROWS
RUN_BIN=""

echo "=== the verdict reads open to merge, not launch to merge ==="
# Launch to PR opened takes 900 s, so launch to merge is over the micro
# target while open to merge is under it.
new_case open-span
printf micro > "$CASE/class"
timeline 2000
edit_json "$CASE/timeline.json" ".stamps.created = \"$(at 900)\" | .open_secs = 1100"
got="$(record KEN-1 micro)"
assert_eq "$(field actual "$got") $(field open "$got") $(field verdict "$got")" "actual=2000 open=1100 verdict=met" \
  "a slow launch to PR opened is no miss while open to merge meets the target"

echo "=== the class is read over the merge commit's first parent to the merge ==="
assert_eq "$(grep -o -- '--base [^ ]* --head [^ ]*' "$CASE/class.calls")" "--base $BASE --head $MERGE" \
  "the classifier is handed merge^1 and the merge commit"

echo "=== a class the classifier did not give is unclassified, never judged ==="
new_case unclassified
timeline 5401
assert_eq "$(record KEN-1 standard)" \
  "rc=0 cycle item=KEN-1 pr=7 class=- tier=standard target=- merge_group=- actual=5401 open=5281 verdict=unclassified phase=merged phase_secs=4981 cause=- bot_wait=180 thread_fix=0 paused=0 missing=- review=- fix=- bot=- full_validations=- pr_rounds=0 escaped=- tier_inputs=- class_reason=- escape_cause=- refixed=false" \
  "the classifier's refusal records no class and no target"
assert_eq "$(grep '^oversee-cycle: class-unread' "$CASE/err")" "oversee-cycle: class-unread cause=classifier-exit-2" "and names the cause on stderr"

new_case unmeasured-class
printf standard > "$CASE/class"; printf false > "$CASE/measured"
timeline 1000
got="$(record KEN-1 micro)"
assert_eq "$(field class "$got") $(field verdict "$got") $(field escaped "$got")|$(grep '^oversee-cycle: class-unread' "$CASE/err")" \
  "class=- verdict=unclassified escaped=-|oversee-cycle: class-unread cause=class-unmeasured" \
  "the classifier's fallback to standard, measured=false, is no class"

new_case absent-merge
printf micro > "$CASE/class"
timeline 1000
edit_json "$CASE/timeline.json" '.merge_commit = "0123456789abcdef0123456789abcdef01234567"'
got="$(record KEN-1 micro)"
assert_eq "$(field class "$got") $(field verdict "$got")|$(grep '^oversee-cycle: class-unread' "$CASE/err")" \
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
PR_ROUNDS='[{"kind":"review","head":"a","start":"s1","end":"e1","secs":600},{"kind":"fix","head":"a","start":"e1","end":"s2","secs":1200},{"kind":"review","head":"b","start":"s2","end":"e2","secs":300}]'
PR_ROUNDS="$PR_ROUNDS" timeline 1500 300 500
# The lane's own state, where workflow-state puts a local lane's in this
# checkout; each round figure has a value no other one shares.
jq -n '{first_panel: {agents: ["a"]}, rereview_cycles: 2, cycles: 5, pr_comment_review: {iterations: 4},
        validate_rounds: [{mode: "full"}, {mode: "range"}, {mode: "full"}]}' > "$REPO/tmp/workflow-state-KEN-2.json"
assert_eq "$(record KEN-2 micro)" \
  "rc=0 cycle item=KEN-2 pr=7 class=micro tier=micro target=1200 merge_group=- actual=1500 open=1380 verdict=miss phase=merged phase_secs=1080 cause=merged bot_wait=180 thread_fix=0 paused=0 missing=- review=3 fix=5 bot=4 full_validations=2 pr_rounds=2 escaped=false tier_inputs=- class_reason=stub escape_cause=- refixed=true" \
  "the printed line: a miss whose longest gap ends at the merge, and a push after the first gate pass"
assert_eq "$(state '.lanes[] | select(.item == "KEN-2") | .cycle | [.class, .tier, .verdict, .stamps]')" \
  "[\"micro\",\"micro\",\"miss\",{\"launched\":\"$(at 0)\",\"first_commit\":\"$(at 60)\",\"pr_opened\":\"$(at 120)\",\"gate_green\":\"$(at 300)\",\"ci_green\":\"$(at 360)\",\"armed\":\"$(at 420)\",\"merged\":\"$(at 1500)\"}]" \
  "the lane record reads back the class and the seven stamps"
assert_eq "$(state '.lanes[] | select(.item == "KEN-2") | .cycle.pr_rounds')" "$PR_ROUNDS" \
  "and the review and fix rounds pr-timeline read"
assert_eq "$(state '[.lanes[] | select(.item != "KEN-2") | has("cycle")] | any')" "false" "no other record is written"
assert_eq "$(state '.fleet_log | map(.kind + ":" + .item) | join(",")')" '"cycle:KEN-2"' "one cycle row joins the fleet log"
assert_eq "$(state '.fleet_log[0].text')" "\"$(sed 's/^rc=0 //' <<<"$(record KEN-2 micro)")\"" \
  "and its text is the printed line"

echo "=== a negative round interval is refused at write ==="
# negative_write NAME: a case for a met micro whose review round reads -40 s,
# as pr-timeline gives a head whose first check suite postdates its review.
negative_write() {
  new_case "$1"
  printf micro > "$CASE/class"
  PR_ROUNDS='[{"kind":"review","head":"a","start":"s1","end":"e1","secs":-40},{"kind":"fix","head":"a","start":"e1","end":"s2","secs":1200}]' timeline 1000
}
negative_write negative-write
got="$(record KEN-1 micro)"
assert_eq "$(field verdict "$got") $(field pr_rounds "$got")" "verdict=met pr_rounds=1" "the record is written and its review round still counts"
assert_eq "$(state '.lanes[] | select(.item == "KEN-1") | .cycle.pr_rounds | map(.secs)')" '[null,1200]' \
  "the negative seconds are written as none, the others kept"
assert_eq "$(grep '^oversee-cycle: negative-interval' "$CASE/err")" \
  "oversee-cycle: negative-interval item=KEN-1 kind=review head=a secs=-40" "and the refused interval is named on stderr"
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

# The lane resolves its state directory on its own host: the overseer's
# ORCH_STATE_DIR names a directory on the overseer's machine, and the lane's
# worktree settings name its own.
assert_eq "$(field fix "$(CONTROL_STATE_DIR=/fleet/state record KEN-4 micro)")" "fix=7" \
  "a hosted lane's state is read in its own state directory, whatever the overseer's ORCH_STATE_DIR"
mkdir -p "$CASE/host/clone/lane-state"
printf '{"cycles": 3}' > "$CASE/host/clone/lane-state/workflow-state-KEN-4.json"
printf '[env]\nORCH_STATE_DIR = "lane-state"\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=3" \
  "a hosted lane whose worktree settings name its state directory is read there"
printf '[env]\nORCH_STATE_DIR = lane-state\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
assert_eq "$(field fix "$(record KEN-4 micro)")|$(grep -c '^oversee-cycle: rounds-unread item=KEN-4$' "$CASE/err" || true)|$(grep -c "settings-unread path=/w/KEN-4/kendex.settings.toml" "$CASE/err" || true)" \
  "fix=-|1|1" "a worktree settings file that does not parse records no rounds and names the file"
printf '[env]\nORCH_STATE_DIR = ""\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=7" "an empty state directory setting is tmp, as workflow-state reads it"
# The lane's private env file outranks its settings, as workflow-state loads
# them; this machine reads only a literal assignment from it, never runs it.
mkdir -p "$CASE/host/clone/private-state" "$CASE/host/w/KEN-4/config"
printf '{"cycles": 4}' > "$CASE/host/clone/private-state/workflow-state-KEN-4.json"
printf '[env]\nORCH_STATE_DIR = "lane-state"\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
printf 'SECRET=x\nexport ORCH_STATE_DIR="private-state"\n' > "$CASE/host/w/KEN-4/.env.local"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=4" \
  "a hosted lane whose private env file names its state directory is read there, over its settings"
printf '[env]\nORCH_STATE_DIR = "lane-state"\nKENDEX_ENV_FILE = "config/priv.env"\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
mv -- "$CASE/host/w/KEN-4/.env.local" "$CASE/host/w/KEN-4/config/priv.env"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=4" \
  "the private env file the settings name as KENDEX_ENV_FILE is the one read"
printf 'ORCH_STATE_DIR=$HOME/state\n' > "$CASE/host/w/KEN-4/config/priv.env"
assert_eq "$(field fix "$(record KEN-4 micro)")|$(grep -c '^oversee-cycle: rounds-unread item=KEN-4$' "$CASE/err" || true)|$(grep -c "private-env-unread path=/w/KEN-4/config/priv.env key=ORCH_STATE_DIR" "$CASE/err" || true)" \
  "fix=-|1|1" "a private env file that sets the state directory other than literally records no rounds and names the file"
rm -rf -- "${CASE:?}/host/w/KEN-4/kendex.settings.toml" "${CASE:?}/host/w/KEN-4/config"

echo "=== a gone sandbox's rounds are read from the archive its close kept ==="
# gone_case NAME [ARCHIVE [AT [STATE_DIR]]] — KEN-4 hosted on a host that
# holds nothing, its close's kept= row in the fleet log, stamped AT seconds
# past the launch (10 by default), naming ARCHIVE, by default the case's
# kept.tgz, which holds the clone's and the worktree's tmp and the item's
# state in the clone's STATE_DIR, tmp by default. Its lane-host-state member
# names that state's member, as close records it, or GONE_MANIFEST where set:
# `none` for an archive close wrote before it recorded one, empty for a lane
# that wrote no state. GONE_STALE puts an older copy of the state, 9 fix
# rounds, in the clone's tmp beside it, and GONE_WT_COPY another, 8, in the
# worktree's tmp.
gone_case() {
  local archive manifest=() dir="${4:-tmp}"
  new_case "$1"; printf micro > "$CASE/class"; timeline 1200
  archive="${2:-$CASE/kept.tgz}"
  mkdir -p "$CASE/archive/clone/$dir" "$CASE/archive/clone/tmp" "$CASE/archive/w/KEN-4/tmp" "${archive%/*}"
  [[ -z "${GONE_STALE:-}" ]] || printf '{"cycles": 9}' > "$CASE/archive/clone/tmp/workflow-state-KEN-4.json"
  [[ -z "${GONE_WT_COPY:-}" ]] || printf '{"cycles": 8}' > "$CASE/archive/w/KEN-4/tmp/workflow-state-KEN-4.json"
  printf '{"cycles": 5}' > "$CASE/archive/clone/$dir/workflow-state-KEN-4.json"
  printf '{}' > "$CASE/archive/w/KEN-4/tmp/dev-return-KEN-4-1.json"
  if [[ "${GONE_MANIFEST-}" != none ]]; then
    printf '%s\n' "${GONE_MANIFEST-clone/$dir/workflow-state-KEN-4.json}" > "$CASE/archive/lane-host-state"
    manifest=(lane-host-state)
  fi
  tar -czf "$archive" -C "$CASE/archive" ${manifest[@]+"${manifest[@]}"} clone w
  edit_json "$CASE/state/workflow-state-oversee.json" \
    "(.lanes[] | select(.item == \"KEN-4\")) |= (.host = \"box\" | .mail_root = \"/w/KEN-4\")
     | .fleet_log += [{at: \"$(at "${3:-10}")\", kind: \"lane\", item: \"KEN-4\", text: \"lane-closed KEN-4 kept=$archive\"}]"
}
gone_case gone
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=5" "a gone sandbox's fix count comes from its kept= archive"
gone_case gone-custom "" 10 lane-state
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=5" \
  "a gone sandbox whose settings named its state directory reads the state its close archived there"
GONE_STALE=1 gone_case gone-moved "" 10 zz-state
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=5" \
  "an archive holding an older copy of the state in tmp reads the member its close recorded"
GONE_STALE=1 GONE_MANIFEST='' gone_case gone-unwritten "" 10 zz-state
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=-" \
  "an archive whose close recorded no state reads none, whatever copies it holds"
GONE_MANIFEST=none gone_case gone-unrecorded
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=5" \
  "an archive written before close recorded the member reads the clone's tmp copy"
GONE_MANIFEST=none GONE_WT_COPY=1 gone_case gone-unrecorded-both
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=5" \
  "an archive written before close recorded the member reads the clone's copy before the worktree's"
gone_case gone-non-ascii "" 10 café-state
assert_eq "$(field fix "$(LC_ALL=C record KEN-4 micro)")" "fix=5" \
  "a recorded member whose name the locale cannot print is read as written"
# stream_read LIB — lane_archived_state from LIB on the case's archive, as
# the fix rounds it read and what it left in its scratch directory, which the
# control host reads archives without writing bulk data to.
stream_read() {
  rm -rf -- "${CASE:?}/scratch" && mkdir -p "$CASE/scratch"
  ( source "$1/lane-gitfile.sh"
    lane_archived_state KEN-4 "$CASE/kept.tgz" "$CASE/scratch" /w/KEN-4 || exit 1
    printf '%s left=%s' "$(jq -r .cycles <<<"$LANE_ITEM_STATE")" "$(cd "$CASE/scratch" && ls -A | tr '\n' ' ')" )
}
gone_case gone-stream
assert_eq "$(stream_read "$TEST_DIR/../scripts/lib")" "5 left=state.err " \
  "the kept= archive is read as a stream, nothing of it written to disk"
# hardlink_case NAME: an archive whose recorded member tar wrote as a hard
# link to the same file archived first under the clone's tmp, as close writes
# it where the clone's path reaches its state through a symlink.
hardlink_case() {
  gone_case "$1" "" 10 zz-state
  rm -f -- "${CASE:?}/archive/clone/zz-state/workflow-state-KEN-4.json"
  printf '{"cycles": 5}' > "$CASE/archive/clone/tmp/state-copy.json"
  ln -- "$CASE/archive/clone/tmp/state-copy.json" "$CASE/archive/clone/zz-state/workflow-state-KEN-4.json"
  tar -czf "$CASE/kept.tgz" -C "$CASE/archive" lane-host-state clone/tmp/state-copy.json clone/zz-state/workflow-state-KEN-4.json
}
hardlink_case gone-hardlink
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=5" \
  "a recorded member tar wrote as a hard link reads the file it names"
GONE_MANIFEST=clone/elsewhere/workflow-state-KEN-4.json gone_case gone-misnamed
assert_eq "$(field fix "$(record KEN-4 micro)")|$(grep -c '^archive-member-missing ' "$CASE/err" || true)" \
  "fix=-|1" "an archive naming a member it does not hold is unread, the member named"
gone_case gone-missing
rm -f -- "${CASE:?}/kept.tgz"
assert_eq "$(field fix "$(record KEN-4 micro)")|$(grep -c '^oversee-cycle: rounds-unread item=KEN-4$' "$CASE/err" || true)" \
  "fix=-|1" "a kept= archive that is not there records no rounds and says so"
gone_case gone-spaced "$TMP_ROOT/case-gone-spaced/my fleet/kept.tgz"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=5" "a kept= archive under a directory with spaces is read whole"
gone_case gone-earlier "" -10
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=-" "a kept= row from before the lane's session is an earlier run's, never read"
# A live read that fails keeps its failure: an archive an earlier close kept
# never answers for a lane whose host still holds its worktree.
gone_case gone-live-fails
mkdir -p "$CASE/host/w/KEN-4"
echo "gitdir: /clone/.git/worktrees/KEN-4" > "$CASE/host/w/KEN-4/.git"
printf '[env]\nORCH_STATE_DIR = lane-state\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
assert_eq "$(field fix "$(record KEN-4 micro)")|$(grep -c '^oversee-cycle: rounds-unread item=KEN-4$' "$CASE/err" || true)" \
  "fix=-|1" "a hosted read that fails with a kept= archive on file stays unread"

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
assert_eq "$(field verdict "$got") $(field phase "$got") $(field phase_secs "$got") $(field bot_wait "$got") $(field missing "$got")" \
  "verdict=met phase=- phase_secs=- bot_wait=- missing=ci_green" "the verdict stands, the phase and its gate waits are unnamed and the absent stamp is listed"

new_case no-launch
printf small > "$CASE/class"
timeline 1100
edit_json "$CASE/state/workflow-state-oversee.json" '(.lanes[] | select(.item == "KEN-1")).launched_at = null'
edit_json "$CASE/timeline.json" '.stamps.first_commit = null'
got="$(record KEN-1 standard)"
assert_eq "$(field verdict "$got") $(field actual "$got") $(field open "$got") $(field phase "$got") $(field missing "$got")" \
  "verdict=met actual=- open=980 phase=merged missing=launched,first_commit" \
  "a lane with no launch or first-commit stamp has no actual, and its open span is still judged and names its phase"

new_case no-open
printf small > "$CASE/class"
timeline 1100
edit_json "$CASE/timeline.json" '.stamps.created = null | .open_secs = null'
got="$(record KEN-1 standard)"
assert_eq "$(field verdict "$got") $(field open "$got") $(field missing "$got")" "verdict=unmeasured open=- missing=pr_opened" \
  "a PR with no open stamp is unmeasured, never met"

echo "=== which phase dominates is read from the PR's open span ==="
new_case phase
printf small > "$CASE/class"
jq -n --arg merge "$MERGE" --arg fc "$(at 900)" --arg cr "$(at 960)" --arg gate "$(at 1000)" --arg ci "$(at 1010)" --arg m "$(at 1100)" \
  '{pr: 7, merge_commit: $merge, stamps: {first_commit: $fc, created: $cr, last_push: $cr, first_gate_met: null,
    gate_met: $gate, ci_green: $ci, armed: null, queued: $gate, merged: $m}, open_secs: 140, push_times: [], bot_review_times: []}' > "$CASE/timeline.json"
assert_eq "$(record KEN-3 micro)" \
  "rc=0 cycle item=KEN-3 pr=7 class=small tier=micro target=1800 merge_group=- actual=1100 open=140 verdict=met phase=merged phase_secs=90 cause=- bot_wait=40 thread_fix=0 paused=0 missing=- review=- fix=- bot=- full_validations=- pr_rounds=- escaped=true tier_inputs=- class_reason=stub escape_cause=- refixed=-" \
  "launch to first commit, the lane's longest gap, is outside the open span and names no phase; queued stands in for armed, a micro tier merged small escaped, and no gate pass leaves refixed unknown, a timeline with no rounds no pr_rounds"

echo "=== armed time starts after both CI and the gate are green ==="
# pr-timeline green($head) uses the last completed head check, including an
# optional check completed after merge. Only green stamps in the measured
# span can place an arm in that span.
while IFS='|' read -r name ci gate armed queued want_phase want_secs; do
  new_case "arm-order-$name"
  printf micro > "$CASE/class"
  timeline 1800
  edit_json "$CASE/timeline.json" ".stamps |= (.ci_green = \"$(at "$ci")\" | .gate_met = \"$(at "$gate")\"
    | .armed = $(if [[ "$armed" == null ]]; then echo null; else printf '\"%s\"' "$(at "$armed")"; fi)
    | .queued = $(if [[ "$queued" == null ]]; then echo null; else printf '\"%s\"' "$(at "$queued")"; fi))"
  got="$(record KEN-1 micro)"
  assert_eq "$(field phase "$got") $(field phase_secs "$got")" "phase=$want_phase phase_secs=$want_secs" "$name"
  assert_eq "$(state '.lanes[0].cycle | [.phase, .phase_secs, .stamps.ci_green, .stamps.gate_green, .stamps.armed]')" \
    "[\"$want_phase\",$want_secs,\"$(at "$ci")\",\"$(at "$gate")\",\"$(at "${armed/null/$queued}")\"]" "$name persists the phase and original stamps"
done <<'ROWS'
arm before both|1700|1600|1500|null|gate_green|1480
arm before CI|1700|300|1500|null|ci_green|1400
arm before gate|300|1700|1500|null|gate_green|1400
arm at last green|1700|300|1700|null|ci_green|1400
arm after both|300|360|1700|null|armed|1340
queue before CI|1700|300|null|1500|ci_green|1400
CI after merge|10000|300|1500|null|armed|1200
gate after merge|300|10000|1500|null|armed|1200
both green after merge|10000|11000|1500|null|armed|1380
CI before open|100|300|1500|null|armed|1200
gate before open|300|100|1500|null|armed|1200
queue with CI after merge|10000|300|null|1500|armed|1200
ROWS

echo "=== the gate_green phase is split into the waits it holds ==="
# gate_timeline PUSHES REVIEWS MERGED: a PR whose gate_green gap, opened at
# 120 to the gate at 3000, is the longest unless MERGED is late; CI 3060,
# armed 3100. PUSHES and REVIEWS are space-separated seconds past T0, `-`
# for none; PUSHES `null` is a timeline whose `push_times` is null.
gate_timeline() {
  local lists
  lists="$(jq -n --argjson t0 "$T0" --arg p "$1" --arg r "$2" \
    'def times($s): [$s | split(" ")[] | select(. != "-" and . != "") | tonumber + $t0 | todate];
     {push_times: (if $p == "null" then null else times($p) end), bot_review_times: times($r)}')"
  jq -n --arg merge "$MERGE" --arg fc "$(at 60)" --arg cr "$(at 120)" --arg gate "$(at 3000)" \
    --arg ci "$(at 3060)" --arg armed "$(at 3100)" --arg merged "$(at "$3")" --argjson open "$(($3 - 120))" --argjson lists "$lists" \
    '{pr: 7, merge_commit: $merge, open_secs: $open,
      stamps: {first_commit: $fc, created: $cr, last_push: $cr, first_gate_met: $gate, gate_met: $gate,
               ci_green: $ci, armed: $armed, queued: null, merged: $merged}} + $lists' > "$CASE/timeline.json"
}
# pauses PAUSES PARKED: the lane record's pauses, `from-to` pairs in seconds
# past T0, and a park standing since PARKED, `-` for none of either.
pauses() { # ITEM PAUSES PARKED
  # The program sits in a variable, never inside a double-quoted command
  # substitution: Bash 3.2 brace-expands the {..,..} object in that position.
  local program filter
  program='
    def iso: tonumber + $t0 | todate;
    "(.lanes[] | select(.item == \($item | tojson))) |= (.pauses = \([$p | split(" ")[] | select(. != "-") | split("-")
       | {from: (.[0] | iso), to: (.[1] | iso), cause: "walled"}] | tojson)"
    + (if $k == "-" then ")" else " | .parked = {at: \($k | iso | tojson)})" end)'
  filter="$(jq -rn --argjson t0 "$T0" --arg item "$1" --arg p "$2" --arg k "$3" "$program")"
  edit_json "$CASE/state/workflow-state-oversee.json" "$filter"
}
# One row per rule: the wait a push opens, the wait a bot review opens, a
# pause taken out of the wait it falls in, pauses overlapping one another and
# a park still standing, the wait the gap opens in read from before it, a
# push a later rebase rewrote, which the push log keeps, a phase other than
# gate_green, and a timeline whose `push_times` is null.
#   label|pushes|reviews|pauses|parked|merged|waits
while IFS='|' read -r label pushes reviews paused parked merged want; do
  [[ -n "$label" ]] || continue
  new_case "split-${label// /-}"
  printf micro > "$CASE/class"
  gate_timeline "$pushes" "$reviews" "$merged"
  pauses KEN-1 "$paused" "$parked"
  got="$(record KEN-1 standard)"
  assert_eq "$(field phase "$got") $(field cause "$got") $(field bot_wait "$got") $(field thread_fix "$got") $(field paused "$got")" "$want" "$label"
done <<'ROWS'
a push waits on a bot, a review on the lane, and a wall comes out of the wait it fell in|100 1400|400 1500 2000|600-1000|-|3200|phase=gate_green cause=thread_fix bot_wait=380 thread_fix=2100 paused=400
a wall over most of the gap is the cause|100 1400|400 1500 2000|400-2900|-|3200|phase=gate_green cause=paused bot_wait=280 thread_fix=100 paused=2500
overlapping pauses count once and a standing park runs to the gate|100 1400|400 1500 2000|2400-2600|2500|3200|phase=gate_green cause=thread_fix bot_wait=380 thread_fix=1900 paused=600
a review before the gap opens it on the lane|1400|110 1500|-|-|3200|phase=gate_green cause=thread_fix bot_wait=100 thread_fix=2780 paused=0
no push and no review is all bot wait|-|-|-|-|3200|phase=gate_green cause=bot_wait bot_wait=2880 thread_fix=0 paused=0
a fix pushed between two reviews and a rebase pushed after them are both bot waits|900 2500|400 2000|-|-|3200|phase=gate_green cause=bot_wait bot_wait=1880 thread_fix=1000 paused=0
another phase is the miss's cause and keeps the split|100 1400|400 1500 2000|-|-|9000|phase=merged cause=merged bot_wait=380 thread_fix=2500 paused=0
null push times split nothing and leave the miss its phase|null|400 1500 2000|-|-|3200|phase=gate_green cause=gate_green bot_wait=- thread_fix=- paused=-
ROWS
new_case split-admin-route
printf micro > "$CASE/class"
gate_timeline "100 1400" "400 1500 2000" 3200
edit_json "$CASE/timeline.json" '.stamps.armed = null'
got="$(record KEN-1 standard)"
assert_eq "$(field phase "$got") $(field cause "$got") $(field bot_wait "$got") $(field thread_fix "$got") $(field missing "$got")" \
  "phase=gate_green cause=thread_fix bot_wait=380 thread_fix=2500 missing=armed" \
  "an admin-route merge, never armed or queued, reads its phase and gate waits from the stamps it has"

new_case split-record
printf micro > "$CASE/class"
gate_timeline "100 1400" "400 1500 2000" 3200
pauses KEN-1 600-1000 -
record KEN-1 standard >/dev/null
assert_eq "$(state '.lanes[] | select(.item == "KEN-1") | .cycle | [.cause, .gate_waits]')" \
  '["thread_fix",{"bot_wait":380,"thread_fix":2100,"paused":400}]' "the lane record carries the cause and the gate waits"

echo "=== the ci_green phase names the larger part of its gap as its cause ==="
# ci_timeline PUSH: a micro miss whose ci_green gap, gate 300 to CI green at
# 4000, is the longest; armed 4100, merged 4200. PUSH is last_push in seconds
# past T0, `null` for none.
ci_timeline() {
  timeline 4200 300 110
  edit_json "$CASE/timeline.json" ".stamps |= (.ci_green = \"$(at 4000)\" | .armed = \"$(at 4100)\"
    | .last_push = $(if [[ "$1" == null ]]; then echo null; else echo "\"$(at "$1")\""; fi))"
}
#   label|last push|cause
while IFS='|' read -r label push want; do
  new_case "ci-${label// /-}"
  printf micro > "$CASE/class"
  ci_timeline "$push"
  got="$(record KEN-1 micro)"
  assert_eq "$(field verdict "$got") $(field phase "$got") $(field cause "$got")" "verdict=miss phase=ci_green cause=$want" "$label"
done <<'ROWS'
rounds pushed after the PR opened are work|3500|work
a final push early in the gap leaves the checks the larger part|400|ci
a final push before the gap opened leaves it all ci|110|ci
work wins a tie|2150|work
a push after ci_green splits nothing and leaves the miss its phase|4050|ci_green
no last push splits nothing|null|ci_green
ROWS

echo "=== a miss always records a cause ==="
# A miss's cause is the wait its phase reads, else its phase, else unread
# where a missing stamp leaves no phase; a met record names none.
#   label|merged|ci_green|armed|line|cause written
miss_cause_case() { # NAME MERGED CI_GREEN [ARMED]
  new_case "$1"
  printf micro > "$CASE/class"
  timeline "$2"
  [[ "$3" != null ]] || edit_json "$CASE/timeline.json" '.stamps.ci_green = null'
  [[ "${4:-}" != null ]] || edit_json "$CASE/timeline.json" '.stamps.armed = null'
}
while IFS='|' read -r label merged ci armed want stored; do
  miss_cause_case "miss-cause-${label// /-}" "$merged" "$ci" "$armed"
  got="$(record KEN-1 micro)"
  assert_eq "$(field verdict "$got") $(field phase "$got") $(field cause "$got")" "$want" "$label"
  assert_eq "$(state '.lanes[] | select(.item == "KEN-1") | .cycle.cause')" "$stored" "$label: the record carries it"
done <<'ROWS'
a miss with a stamp missing reads no phase and records unread|5000|null|420|verdict=miss phase=- cause=unread|"unread"
a miss on the admin route, never armed or queued, reads its phase|5000|360|null|verdict=miss phase=merged cause=merged|"merged"
a miss on merged records its phase|5000|360|420|verdict=miss phase=merged cause=merged|"merged"
a met record names no cause|800|360|420|verdict=met phase=merged cause=-|null
ROWS

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
a tier item-tier never prints|KEN-1 start|oversee-cycle: usage=--tier
ROWS
edit_json "$CASE/timeline.json" '.merge_commit = null'
record KEN-1 standard >/dev/null || true
assert_eq "$(grep '^oversee-cycle: not-merged=' "$CASE/err")" "oversee-cycle: not-merged=7" "a PR with no merge commit writes nothing"
assert_eq "$(state '[.lanes[] | has("cycle")] | any')" "false" "and no refusal wrote a record"

# --- the repeat-miss bar -----------------------------------------------------
# The bar is one predicate with one conjunct per rule: this record is a miss,
# its phase is named, it was not already a miss on that phase, and the
# fleet's records that are misses on that phase are exactly three. Each row
# records a sequence and asserts the bar lines its last record printed; each
# conjunct has a row it alone decides, and a control below that plants its
# removal against that row.
#   m   a miss at 5000 s, its longest gap ending at merged
#   p   a miss whose CI went green at 700 s, before the PR opened at 2460 s,
#       so the longest gap before the PR opens is 1760 s from CI green to
#       the opening; the longest gap after it ends at gate_green
#   a   a miss at 5000 s whose CI went green at 10000 s, after the merge,
#       a gap longer than any in the span; its phase is still merged
#   n   a miss with CI green absent, so no phase is named
#   ok  a met record at 800 s, its phase merged too
#   g   a miss on gate_green whose longest wait is the thread fix
#   w   the same miss with a wall over that wait
#   cw  a miss on ci_green whose final push came late in the gap: work
#   cc  a miss on ci_green whose final push came early in it: ci
echo "=== the repeat-miss bar ==="
repeat_row() { # CASE SEQUENCE — prints the bar lines the last record printed
  local step kind item got=""
  new_case "$1"
  printf micro > "$CASE/class"
  for step in $2; do
    kind="${step%%:*}" item="KEN-${step#*:}"
    case "$kind" in
      m) timeline 5000 ;;
      p) timeline 4360
         edit_json "$CASE/timeline.json" ".stamps |= (.first_commit = \"$(at 600)\" | .ci_green = \"$(at 700)\"
           | .created = \"$(at 2460)\" | .gate_met = \"$(at 3400)\" | .armed = \"$(at 3800)\") | .open_secs = 1900" ;;
      a) timeline 5000; edit_json "$CASE/timeline.json" ".stamps.ci_green = \"$(at 10000)\"" ;;
      n) timeline 5000; edit_json "$CASE/timeline.json" '.stamps.ci_green = null' ;;
      ok) timeline 800 ;;
      g) gate_timeline "100 1400" "400 1500 2000" 3200 ;;
      w) gate_timeline "100 1400" "400 1500 2000" 3200; pauses "$item" 400-2900 - ;;
      cw) ci_timeline 3500 ;;
      cc) ci_timeline 400 ;;
      *) echo "repeat_row: unknown step $step" >&2; exit 2 ;;
    esac
    got="$(record "$item" micro)"
  done
  grep '^repeat-miss' <<<"$got" || true
}
REPEAT_ROWS='third|m:1 m:2 m:3|repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged
met-record|m:1 m:2 m:3 ok:4|
met-not-counted|ok:1 m:2 m:3|
other-phase|m:1 m:2 p:3|
pre-open|p:1 p:2 p:3|repeat-miss phase=gate_green items=KEN-1,KEN-2,KEN-3 causes=bot_wait,bot_wait,bot_wait
post-merge|a:1 a:2 a:3|repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged
unnamed-phase|n:1 n:2 n:3|
recorded-again|m:1 m:2 m:3 m:3|
fourth|m:1 m:2 m:3 m:4|
causes|g:1 w:2 g:3|repeat-miss phase=gate_green items=KEN-1,KEN-2,KEN-3 causes=thread_fix,paused,thread_fix
ci-work|cw:1 cw:2 cw:3|
ci-slow|cw:1 cc:2 cc:3 cc:4|repeat-miss phase=ci_green items=KEN-2,KEN-3,KEN-4 causes=ci,ci,ci
ci-work-after|cc:1 cc:2 cc:3 cw:4|
ci-recounted|cc:1 cc:2 cw:3 cc:3|repeat-miss phase=ci_green items=KEN-1,KEN-2,KEN-3 causes=ci,ci,ci'
while IFS='|' read -r name sequence want; do
  assert_eq "$(repeat_row "repeat-$name" "$sequence")" "$want" "repeat bar, $name: $sequence"
done <<<"$REPEAT_ROWS"
repeat_row repeat-log "m:1 m:2 m:3" >/dev/null
assert_eq "$(state '.fleet_log[-1].text')" '"repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged"' "the fleet log carries the bar line"
new_case repeat-legacy-cause
printf micro > "$CASE/class"
timeline 5000
record KEN-1 micro >/dev/null
record KEN-2 micro >/dev/null
edit_json "$CASE/state/workflow-state-oversee.json" '(.lanes[] | select(.item == "KEN-1")).cycle.cause = null'
assert_eq "$(record KEN-3 micro | grep '^repeat-miss' || true)" "repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged" \
  "a miss written with no cause reads its phase on the bar"

# --- the rollup --------------------------------------------------------------
echo "=== the rollup counts each class, its median and p90 ==="
new_case rollup
cycle() { # CLASS ACTUAL VERDICT ROUNDS ESCAPED REFIXED [PR_ROUNDS]
  printf '{"class":%s,"actual":%s,"verdict":"%s","rounds":%s,"escaped":%s,"refixed":%s,"pr_rounds":%s}' \
    "$1" "$2" "$3" "$4" "$5" "$6" "${7:-null}"
}
R='{"review":1,"fix":2,"bot":1,"full_validations":1}'
pr_round() { printf '{"kind":"%s","secs":%s}' "$1" "$2"; } # KIND SECS
# Micro: 3, 1 and 0 review rounds on three records, one of P1's three with
# no seconds, and a fourth record with no pr_rounds; standard: 2 rounds.
P1="[$(pr_round review 300),$(pr_round fix 900),$(pr_round review 500),$(pr_round review null)]"
P2="[$(pr_round review 700)]"
P3="[]"
PS="[$(pr_round review 1200),$(pr_round fix 60),$(pr_round review 900)]"
# The render record follows the micro ones, so neither lane order nor
# alphabetical order is the target table's.
jq -n --argjson c "[$(cycle '"micro"' 100 met "$R" false false "$P1"),$(cycle '"micro"' 400 met "$R" true true "$P2"),$(cycle '"micro"' 1000 miss null false null "$P3"),$(cycle '"micro"' 200 met "$R" false false),$(cycle '"render"' 30 met "$R" false false),$(cycle '"standard"' 6000 miss "$R" false true "$PS"),$(cycle null 50 unclassified null null false)]" \
  '{lanes: ([$c | to_entries[] | {item: "KEN-\(.key)", status: "done", cycle: .value}] + [{item: "KEN-99", status: "running"}]), fleet_log: []}' \
  > "$CASE/state/workflow-state-oversee.json"
want='rollup class=render items=1 median=30 p90=30 misses=0 review=1 fix=2 bot=1 full_validations=1 rounds_unread=0 escaped=0 estimate_miss=0 path_miss=0 refixed=0 pr_rounds=- pr_rounds_unread=1 round_median=- fix_median=- rounds_untimed=0
rollup class=micro items=4 median=200 p90=1000 misses=1 review=3 fix=6 bot=3 full_validations=3 rounds_unread=1 escaped=1 estimate_miss=0 path_miss=0 refixed=1 pr_rounds=1 pr_rounds_unread=1 round_median=500 fix_median=900 rounds_untimed=1
rollup class=standard items=1 median=6000 p90=6000 misses=1 review=1 fix=2 bot=1 full_validations=1 rounds_unread=0 escaped=0 estimate_miss=0 path_miss=0 refixed=1 pr_rounds=2 pr_rounds_unread=0 round_median=900 fix_median=60 rounds_untimed=0
rollup class=unclassified items=1 median=50 p90=50 misses=0 review=- fix=- bot=- full_validations=- rounds_unread=1 escaped=0 estimate_miss=0 path_miss=0 refixed=0 pr_rounds=- pr_rounds_unread=1 round_median=- fix_median=- rounds_untimed=0'
rollup() { (cd "$REPO" && "${RUN_BIN:-$BIN}" --state-dir "$CASE/state" rollup) 2>"$CASE/err"; }
# report_unchanged: report's rows, then whether the state directory's listing
# and the state file, which holds the fleet log, are byte for byte as before.
report_unchanged() {
  local before out rc=0
  cp -- "$CASE/state/workflow-state-oversee.json" "$CASE/state.before"
  before="$(ls -A "$CASE/state")"
  out="$( (cd "$REPO" && "${RUN_BIN:-$BIN}" --state-dir "$CASE/state" report) 2>"$CASE/err")" || rc=$?
  printf 'rc=%s\n%s\nunchanged=' "$rc" "$out"
  if [[ "$(ls -A "$CASE/state")" == "$before" ]] && cmp -s -- "$CASE/state.before" "$CASE/state/workflow-state-oversee.json"; then
    printf yes
  else
    printf no
  fi
}
assert_eq "$(report_unchanged)" "rc=0
$want
unchanged=yes" "report prints the rollup rows and leaves the fleet state and its log byte-identical"
assert_eq "$(rollup)" "$want" "one row per class with a record, in target order, unclassified last"
assert_eq "$(state '.fleet_log | map(.item) | join(",")')" '"render,micro,standard,unclassified"' "each row joins the fleet log under its class"

new_case rollup-no-state
rm -f -- "${CASE:?}/state/workflow-state-oversee.json"
rc=0; out="$(rollup)" || rc=$?
assert_eq "rc=$rc out=$out files=$(ls -A "$CASE/state" | tr '\n' ' ')" "rc=0 out= files=" "with no fleet state yet the rollup prints nothing, writes nothing and exits 0"
rc=0; out="$( (cd "$REPO" && "$BIN" --state-dir "$CASE/state" report) 2>"$CASE/err")" || rc=$?
assert_eq "rc=$rc out=$out files=$(ls -A "$CASE/state" | tr '\n' ' ')" "rc=0 out= files=" "and so does the report"
assert_eq "$(record KEN-1 micro) $(head -n 1 "$CASE/err")" "rc=1  oversee-cycle: state-missing=$CASE/state/workflow-state-oversee.json" "while a record refuses"

echo "=== a negative interval written before the refusal enters no aggregate ==="
# A record on disk with a negative launch-to-merge and negative round seconds.
NEG_ROUNDS="[$(pr_round review 300),$(pr_round review -40),$(pr_round fix -10),$(pr_round fix 200)]"
negative_rollup() {
  new_case "$1"
  jq -n --argjson c "[$(cycle '"micro"' 100 met null false false "$NEG_ROUNDS"),$(cycle '"micro"' -50 met null false false)]" \
    '{lanes: [$c | to_entries[] | {item: "KEN-\(.key)", status: "done", cycle: .value}], fleet_log: []}' \
    > "$CASE/state/workflow-state-oversee.json"
  local line
  line="$(rollup)"
  printf '%s %s %s %s %s' "$(field median "$line")" "$(field p90 "$line")" "$(field round_median "$line")" \
    "$(field fix_median "$line")" "$(field rounds_untimed "$line")"
}
assert_eq "$(negative_rollup rollup-negative)" "median=100 p90=100 round_median=300 fix_median=200 rounds_untimed=2" \
  "negative seconds enter neither median nor p90, and a negative round counts as untimed"

echo "=== --help prints the targets the verdict and the reader of the rollup use ==="
assert_eq "$("$BIN" --help | tail -n 2)" "Targets, open-to-merge seconds: render 300, trivial 300, micro 1200, small 1800, standard 5400
Review rounds per pull request: micro 1, small 1, standard 2; seconds per round: 600" \
  "the last two help lines are the merge-time and review-stage target tables"

# --- controls ----------------------------------------------------------------
# Planted defects in the record verb's target comparison, the span its verdict
# judges and the stamps its phase reads, the rollup verb, and the
# lane_item_state it reads rounds through, each in a private copy of that one
# file among links to the shipped scripts, beside the same stubs, the
# lane-host fake among them.
control() { # NAME FILE ANCHOR REPLACEMENT — sets RUN_BIN to the mutant's oversee-cycle
  local dir
  dir="$(mutant_scripts "skills/$1" "$2")" || exit 1
  ln -sf -- "$LAYOUT/orch/scripts/lane-host" "$dir/lane-host" || exit 1
  mutate_file "$dir/$2" "$3" "$4"
  RUN_BIN="$dir/oversee-cycle"
}

echo "=== controls ==="
# Each independent refusal is disabled alone. The mutant must get past the
# flag guard, so a different refusal is not credited as this guard working.
while IFS='|' read -r name anchor replacement form; do
  control "m-delivery-$name" oversee-cycle "$anchor" "$replacement"
  new_case "c-delivery-$name"; printf small > "$CASE/class"; timeline 900
  case "$form" in
    both) RECORD_ARGS=(--pr 7 --commit "$MERGE") ;;
    neither) RECORD_ARGS=() ;;
  esac
  got="$(record KEN-1 micro)"
  assert_not_contains "$(cat "$CASE/err")" 'oversee-cycle: usage=--pr,--commit' \
    "control: disabling $name turns its keyed refusal assertion red"
  assert_not_contains "$got" 'rc=2 ' "control: $name reaches beyond the flag guard"
done <<'ROWS'
neither|[[ -z "$PR" && -z "$COMMIT" ]]|{ [[ -z "$PR" && -z "$COMMIT" ]] && false; }|neither
both|[[ -n "$PR" && -n "$COMMIT" ]]; then|{ [[ -n "$PR" && -n "$COMMIT" ]] && false; }; then|both
ROWS
RECORD_ARGS=(--commit "$MERGE")
# Each rule of the push read alone: the push leaving the branch at the
# commit, a later push containing it, the launch bound on the compared pushes,
# no stand-in for an unplaced push, and the period the log is read over.
control m-push-exact oversee-cycle '([.[] | select(.after == $commit)] | first' '([.[] | select(false)] | first'
new_case c-push-exact; printf small > "$CASE/class"; pushes "300:$BASE" "1200:$MERGE"
assert_eq "$(field actual "$(record KEN-1 micro)")" 'actual=-' \
  "control: without the exact match, a push leaving the branch at the commit is compared and goes unplaced"
control m-push-ahead oversee-cycle '[[ "$status" == ahead ]] || continue' '[[ "$status" == never ]] || continue'
new_case c-push-ahead; printf small > "$CASE/class"; pushes "1500:$BATCH"; answer "$BATCH" ahead
assert_eq "$(field actual "$(record KEN-1 micro)")" 'actual=-' \
  "control: without the containment answer, a batch push containing the commit goes unplaced"
control m-push-since oversee-cycle 'select((.at | fromdate) >= ($since | tonumber))' 'select(true)'
new_case c-push-since; printf small > "$CASE/class"; pushes "-100:$OLD" "1500:$BATCH"; answer "$BATCH" ahead
assert_eq "$(field actual "$(record KEN-1 micro)")|$(sed -n 's/^oversee-cycle: merged-unread commit=[^ ]* //p' "$CASE/err")" 'actual=-|cause=compare-failed' \
  "control: without the launch bound, a push before the launch is compared"
control m-push-fallback oversee-cycle 'merged: (if $merged == "" then null' 'merged: (if $merged == "" then ($authored | tonumber | todate)'
new_case c-push-fallback; printf small > "$CASE/class"; pushes "300:$OTHER"; answer "$OTHER" diverged
assert_eq "$(field actual "$(record KEN-1 micro)")" 'actual=60' \
  "control: a stand-in date for an unplaced push turns the null-merged assertion red"
control m-push-period oversee-cycle 'query+="&time_period=${span%%:*}"' 'query+=""'
new_case c-push-period; printf small > "$CASE/class"; pushes "1200:$MERGE"
edit_json "$CASE/state/workflow-state-oversee.json" ".lanes[0].launched_at = \"$(jq -rn 'now - 7200 | floor | todate')\""
record KEN-1 micro >/dev/null
assert_eq "$(grep -c 'time_period=' "$CASE/gh.calls" || true)" 0 \
  "control: without the period, the whole push log is read"
RECORD_ARGS=(--pr 7)

control m-merge-target oversee-cycle '$targets[$class] + ($merge_group // 0)' '$targets[$class] + 0'
new_case c-merge-target; printf micro > "$CASE/class"; timeline 1500
edit_json "$CASE/timeline.json" '.ci_merge_group_secs = 280'
assert_eq "$(field verdict "$(record KEN-1 micro)")" "verdict=miss" \
  "control: without the allowance the shipped-target row turns from met to miss"

control m-merge-gap oversee-cycle '.secs - ($merge_group // 0)' '.secs - 0'
new_case c-merge-gap; printf micro > "$CASE/class"; timeline 1080
edit_json "$CASE/timeline.json" ".ci_merge_group_secs = 280 | .stamps |= (.gate_met = \"$(at 500)\" | .ci_green = \"$(at 560)\" | .armed = \"$(at 620)\")"
assert_eq "$(field phase "$(record KEN-1 micro)")" "phase=merged" \
  "control: without the merged-gap subtraction the allowance row names merged"

control m-record oversee-cycle 'elif $open > $target then "miss"' 'elif false then "miss"'
new_case c-miss; printf standard > "$CASE/class"; timeline 5521
assert_eq "$(field verdict "$(record KEN-1 standard)")" "verdict=met" \
  "control: without the target comparison a close past its target reports no miss"

control m-open oversee-cycle 'elif $open > $target then "miss"' 'elif $actual > $target then "miss"'
new_case c-open; printf micro > "$CASE/class"; timeline 2000
edit_json "$CASE/timeline.json" ".stamps.created = \"$(at 900)\" | .open_secs = 1100"
assert_eq "$(field verdict "$(record KEN-1 micro)")" "verdict=miss" \
  "control: judged on launch to merge, a slow launch to PR opened records a miss"

control m-phase oversee-cycle '| select(.at >= $o and .at <= $m)]' '| select(.at <= $m)]'
assert_eq "$(repeat_row c-phase "p:1 p:2 p:3")" "repeat-miss phase=pr_opened items=KEN-1,KEN-2,KEN-3 causes=pr_opened,pr_opened,pr_opened" \
  "control: without the lower bound, a CI green before the PR opened charges the miss to CI green to PR opened"

control m-phase-end oversee-cycle '| select(.at >= $o and .at <= $m)]' '| select(.at >= $o)]'
assert_eq "$(repeat_row c-phase-end "a:1 a:2 a:3")" "repeat-miss phase=ci_green items=KEN-1,KEN-2,KEN-3 causes=ci,ci,ci" \
  "control: without the upper bound, a CI green after the merge charges the miss to merged to CI green"

control m-arm-order oversee-cycle \
  '| map(select(.name != "armed" or .at > $green))' \
  '| map(select(true))'
new_case c-arm-order; printf micro > "$CASE/class"; timeline 1800
edit_json "$CASE/timeline.json" ".stamps |= (.ci_green = \"$(at 1700)\" | .armed = \"$(at 1500)\")"
got="$(record KEN-1 micro)"
assert_eq "$(field phase "$got") $(field phase_secs "$got")" "phase=armed phase_secs=1200" \
  "control: old ordering charges pre-CI time to armed and fails the ci_green row"

control m-arm-outside oversee-cycle \
  '([.[] | select(.name == "ci_green" or .name == "gate_green") | .at] | max) as $green' \
  '([$stamps.ci_green, $stamps.gate_green] | map(fromdate) | max) as $green'
new_case c-arm-outside; printf micro > "$CASE/class"; timeline 1800
edit_json "$CASE/timeline.json" ".stamps |= (.ci_green = \"$(at 10000)\" | .armed = \"$(at 1500)\")"
got="$(record KEN-1 micro)"
assert_eq "$(field phase "$got") $(field phase_secs "$got")" "phase=merged phase_secs=1500" \
  "control: a post-merge CI threshold hides the arm and turns the armed row red"

control m-ci-bar oversee-cycle '(.phase != "ci_green" or .cause == "ci")' '(true)'
assert_eq "$(repeat_row c-ci-bar "cw:1 cw:2 cw:3")" "repeat-miss phase=ci_green items=KEN-1,KEN-2,KEN-3 causes=work,work,work" \
  "control: counting every ci_green miss, three lanes of post-open work make the bar"

control m-ci-split oversee-cycle '$push - $from >= $to - $push' '$to - $push >= $push - $from'
new_case c-ci-split; printf micro > "$CASE/class"; ci_timeline 3500
assert_eq "$(field cause "$(record KEN-1 micro)")" "cause=ci" \
  "control: with the parts swapped, work late in the gap reads as ci"

control m-rollup oversee-cycle '| if $n == 0 then "-" else $a[(($n * $p) | ceil) - 1] end;' '| if $n == 0 then "-" else $a[(($n * $p) | floor) - 1] end;'
new_case c-rollup
jq -n --argjson c "[$(cycle '"micro"' 100 met null false false),$(cycle '"micro"' 400 met null false false),$(cycle '"micro"' 1000 miss null false false),$(cycle '"micro"' 200 met null false false)]" \
  '{lanes: [$c | to_entries[] | {item: "KEN-\(.key)", status: "done", cycle: .value}], fleet_log: []}' \
  > "$CASE/state/workflow-state-oversee.json"
assert_eq "$(rollup | grep -o 'p90=[0-9]*')" "p90=400" "control: a floor rank reports a p90 below the slowest tenth"

control m-report oversee-cycle '    if [[ "$VERB" == rollup ]]; then' '    if true; then'
new_case c-report
jq -n --argjson c "[$(cycle '"micro"' 100 met null false false)]" \
  '{lanes: [$c | to_entries[] | {item: "KEN-\(.key)", status: "done", cycle: .value}], fleet_log: []}' \
  > "$CASE/state/workflow-state-oversee.json"
assert_eq "$(report_unchanged | tail -n 1)" "unchanged=no" "control: a report that appends its rows changes the fleet state"

control m-rollup-rounds oversee-cycle 'select(.kind == "fix") | .secs | interval // empty] | nr(0.5))' 'select(.kind == "review") | .secs | interval // empty] | nr(0.5))'
new_case c-rollup-rounds
jq -n --argjson c "[$(cycle '"micro"' 100 met null false false "$P1")]" \
  '{lanes: [$c | to_entries[] | {item: "KEN-\(.key)", status: "done", cycle: .value}], fleet_log: []}' \
  > "$CASE/state/workflow-state-oversee.json"
assert_eq "$(rollup | grep -o 'fix_median=[0-9]*')" "fix_median=300" "control: a fix median read over the review rounds reports a review's seconds"

control m-lane-state lib/lane-gitfile.sh 'path="$(cd -- "$6" && "$1" path "$4" 2>"$7/state.err")" || return 2' \
  'path="$("$1" path "$4" 2>"$7/state.err")" || return 2'
new_case c-lane-root; printf micro > "$CASE/class"; timeline 1200
edit_json "$CASE/state/workflow-state-oversee.json" "(.lanes[] | select(.item == \"KEN-5\")).mail_root = \"$ELSE\""
assert_eq "$(field fix "$(record KEN-5 micro)")" "fix=-" \
  "control: read from the caller's checkout, another repository's lane has no rounds"

control m-hosted-dir lib/lane-gitfile.sh 'lane_hosted_state_path "$LANE_HOSTED_CLONE" "$LANE_HOSTED_STATE_DIR" "$2"' \
  'lane_hosted_state_path "$LANE_HOSTED_CLONE" "${ORCH_STATE_DIR:-tmp}" "$2"'
new_case c-hosted-dir; printf micro > "$CASE/class"; timeline 1200
edit_json "$CASE/state/workflow-state-oversee.json" '(.lanes[] | select(.item == "KEN-4")) |= (.host = "box" | .mail_root = "/w/KEN-4")'
mkdir -p "$CASE/host/w/KEN-4" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-4" > "$CASE/host/w/KEN-4/.git"
printf '{"cycles": 7}' > "$CASE/host/clone/tmp/workflow-state-KEN-4.json"
assert_eq "$(field fix "$(CONTROL_STATE_DIR=/fleet/state record KEN-4 micro)")" "fix=-" \
  "control: read at the overseer's ORCH_STATE_DIR, a hosted lane has no rounds"
control m-hosted-settings lib/lane-gitfile.sh 'for file in kendex.settings.toml .kendex/settings.toml; do' 'for file in; do'
mkdir -p "$CASE/host/clone/lane-state"
printf '{"cycles": 3}' > "$CASE/host/clone/lane-state/workflow-state-KEN-4.json"
printf '[env]\nORCH_STATE_DIR = "lane-state"\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=7" \
  "control: without the worktree settings read, the lane's own state directory is missed"
control m-empty-dir lib/lane-gitfile.sh 'LANE_HOSTED_STATE_DIR="${LANE_HOSTED_STATE_DIR:-tmp}"' ':'
new_case c-empty-dir; printf micro > "$CASE/class"; timeline 1200
edit_json "$CASE/state/workflow-state-oversee.json" '(.lanes[] | select(.item == "KEN-4")) |= (.host = "box" | .mail_root = "/w/KEN-4")'
mkdir -p "$CASE/host/w/KEN-4" "$CASE/host/clone/tmp"
echo "gitdir: /clone/.git/worktrees/KEN-4" > "$CASE/host/w/KEN-4/.git"
printf '{"cycles": 7}' > "$CASE/host/clone/tmp/workflow-state-KEN-4.json"
printf '[env]\nORCH_STATE_DIR = ""\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=-" \
  "control: without the empty-setting fallback, the state is sought at the clone's root"
control m-gone-only lib/lane-gitfile.sh '[[ "$rc" -eq 0 && "$LANE_HOSTED_GONE" == 1 && -n "${8:-}" ]] || return "$rc"' \
  '[[ -z "$LANE_ITEM_STATE" && -n "${8:-}" ]] || return "$rc"'
gone_case c-gone-only
mkdir -p "$CASE/host/w/KEN-4"
echo "gitdir: /clone/.git/worktrees/KEN-4" > "$CASE/host/w/KEN-4/.git"
printf '[env]\nORCH_STATE_DIR = lane-state\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=5" \
  "control: falling back on any empty read, a failed live read is answered from the archive"
control m-kept-since oversee-cycle 'select(.item == $item and ((.at // "") >= $since))' 'select(.item == $item)'
gone_case c-kept-since "" -10
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=5" \
  "control: without the session bound, an earlier run's archive is read"
control m-kept-spaced oversee-cycle '(?<p>/.*[^\\s])\\s*$' '(?<p>/\\S+)'
gone_case c-kept-spaced "$TMP_ROOT/case-c-kept-spaced/my fleet/kept.tgz"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=-" \
  "control: a path cut at its first space names no archive"
control m-kept-member lib/lane-gitfile.sh 'if "lane-host-state" in members:' 'if False:'
GONE_STALE=1 gone_case c-kept-member "" 10 zz-state
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=9" \
  "control: matched by name alone, the older tmp copy, first in byte order, is read"
control m-kept-listed lib/lane-gitfile.sh 'raw.decode(tar.encoding, "surrogateescape")' 'raw.decode("ascii", "backslashreplace")'
gone_case c-kept-listed "" 10 café-state
assert_eq "$(field fix "$(LC_ALL=C record KEN-4 micro)")" "fix=-" \
  "control: matched against an escaped spelling, a name the locale cannot print is missed"
control m-kept-stream lib/lane-gitfile.sh '  [[ -f "$2" ]] || { printf '"'"'archive-missing' \
  '  tar -xzf "$2" -C "$3" 2>/dev/null || :; [[ -f "$2" ]] || { printf '"'"'archive-missing'
gone_case c-kept-stream
assert_eq "$(stream_read "${RUN_BIN%/*}/lib")" "5 left=clone lane-host-state state.err w " \
  "control: an archive unpacked to be read leaves its members on disk"
control m-kept-clone lib/lane-gitfile.sh 'key=lambda m: (m.name.startswith(root + "/"), m.name)' \
  'key=lambda m: (not m.name.startswith(root + "/"), m.name)'
GONE_MANIFEST=none GONE_WT_COPY=1 gone_case c-kept-clone
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=8" \
  "control: preferring the worktree's copy reads it over the clone's"
control m-private-env lib/lane-gitfile.sh '  if [[ -n "$private" ]]; then' '  if false; then'
new_case c-private-env; printf micro > "$CASE/class"; timeline 1200
edit_json "$CASE/state/workflow-state-oversee.json" '(.lanes[] | select(.item == "KEN-4")) |= (.host = "box" | .mail_root = "/w/KEN-4")'
mkdir -p "$CASE/host/w/KEN-4" "$CASE/host/clone/tmp" "$CASE/host/clone/private-state"
echo "gitdir: /clone/.git/worktrees/KEN-4" > "$CASE/host/w/KEN-4/.git"
printf '{"cycles": 7}' > "$CASE/host/clone/tmp/workflow-state-KEN-4.json"
printf '{"cycles": 4}' > "$CASE/host/clone/private-state/workflow-state-KEN-4.json"
printf 'ORCH_STATE_DIR=private-state\n' > "$CASE/host/w/KEN-4/.env.local"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=7" \
  "control: without the private env file read, the lane's private state directory is missed"
control m-private-named lib/lane-gitfile.sh '        e=*) private="${line#e=}" ;;' '        e=*) ;;'
mkdir -p "$CASE/host/w/KEN-4/config"
mv -- "$CASE/host/w/KEN-4/.env.local" "$CASE/host/w/KEN-4/config/priv.env"
printf '[env]\nKENDEX_ENV_FILE = "config/priv.env"\n' > "$CASE/host/w/KEN-4/kendex.settings.toml"
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=7" \
  "control: reading .env.local whatever KENDEX_ENV_FILE names misses the named file"
control m-kept-hardlink lib/lane-gitfile.sh 'readable = lambda m: m.isfile() or m.islnk()' 'readable = lambda m: m.isfile()'
hardlink_case c-kept-hardlink
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=-" \
  "control: taking regular files alone, a hard-link entry reads as missing"
control m-kept oversee-cycle '"$LANE_HOST_SPEC" "$LANE_ROOT" "$WORK" ${LANE_KEPT:+"$LANE_KEPT"} || return $?' '"$LANE_HOST_SPEC" "$LANE_ROOT" "$WORK" || return $?'
gone_case c-kept
assert_eq "$(field fix "$(record KEN-4 micro)")" "fix=-" \
  "control: without the kept= archive, a gone sandbox has no rounds"

control m-split oversee-cycle '     else gate_waits($seq[$gate - 1].at; $seq[$gate].at) end) as $waits' '     else null end) as $waits'
new_case c-split; printf micro > "$CASE/class"
gate_timeline "100 1400" "400 1500 2000" 3200
pauses KEN-1 600-1000 -
got="$(record KEN-1 standard)"
assert_eq "$(field phase "$got") $(field cause "$got") $(field paused "$got")" "phase=gate_green cause=gate_green paused=-" \
  "control: without the split the gate_green phase stays undivided and names no wait"

control m-interval oversee-cycle 'def interval: if type == "number" and . < 0 then null else . end;' 'def interval: .;'
negative_write c-interval-write
record KEN-1 micro >/dev/null
assert_eq "$(state '.lanes[] | select(.item == "KEN-1") | .cycle.pr_rounds | map(.secs)')" '[-40,1200]' \
  "control: without the interval rule the record writes the negative seconds"
assert_eq "$(negative_rollup c-interval-rollup)" "median=-50 p90=100 round_median=-40 fix_median=-10 rounds_untimed=0" \
  "control: without the interval rule the negative seconds lead the medians"

control m-miss-cause oversee-cycle 'def miss_cause: .cause // .phase // "unread";' 'def miss_cause: .cause;'
miss_cause_case c-miss-cause 5000 null
assert_eq "$(field cause "$(record KEN-1 micro)")" "cause=-" \
  "control: without the fallback a miss with a stamp missing records no cause"

control m-admin-route oversee-cycle '$missing - ["launched", "first_commit", "armed"]' '$missing - ["launched", "first_commit"]'
new_case c-admin-route; printf micro > "$CASE/class"
gate_timeline "100 1400" "400 1500 2000" 3200
edit_json "$CASE/timeline.json" '.stamps.armed = null'
got="$(record KEN-1 standard)"
assert_eq "$(field phase "$got") $(field bot_wait "$got")" "phase=- bot_wait=-" \
  "control: with armed a stamp the span requires, an admin-route merge reads no phase or gate waits"
RUN_BIN=""

echo
# Launch tier is authoritative, while old records remain visibly unbound.
new_case launch-tier
printf standard > "$CASE/class"; timeline 5520
edit_json "$CASE/state/workflow-state-oversee.json" '.lanes[0] += {tier:"small", tier_inputs:{estimate:12,delta:40,paths:3}}'
printf 'production-past-small production=328' > "$CASE/reason"
got="$(record KEN-1 '')"
assert_eq "$(field tier "$got") $(field class_reason "$got") $(field escape_cause "$got")" \
  'tier=small class_reason=production-past-small escape_cause=estimate-miss' "stored launch tier needs no hand tier"
assert_eq "$(state '.lanes[0].cycle | [.tier_inputs, .class_cause, .class_reason, .escape_cause]')" \
  '[{"estimate":12,"delta":40,"paths":3},null,"production-past-small","estimate-miss"]' "measured reason stays separate from unread-class cause"
assert_contains "$(state '.fleet_log[-1].text')" 'class_reason=production-past-small escape_cause=estimate-miss' "fleet log retains escape evidence"
assert_eq "$(record KEN-1 standard)|$(cat "$CASE/err")" \
  'rc=1 |oversee-cycle: tier-mismatch item=KEN-1 launch=small given=standard' "a hand tier cannot erase a launch escape"
assert_eq "$(wc -l < "$CASE/class.calls" | tr -d ' ')" '1' "tier mismatch refuses before classification"
control m-tier-check oversee-cycle '[[ -n "$TIER" && "$TIER" != "$launch_tier" ]]; then' '[[ -n "$TIER" && "$TIER" != "$launch_tier" ]] && false; then'
assert_contains "$(record KEN-1 standard)" 'rc=0 cycle' "control: disabling the comparison accepts the mismatched tier"
RUN_BIN=""

# Existing classifier evidence explains misses without another classifier.
while IFS='|' read -r reason want; do
  new_case "escape-$want-${reason%% *}"; printf standard > "$CASE/class"; timeline 5520
  edit_json "$CASE/state/workflow-state-oversee.json" '.lanes[0] += {tier:"small", tier_inputs:{estimate:12,delta:40,paths:3}}'
  printf '%s' "$reason" > "$CASE/reason"
  got="$(record KEN-1 small)"
  assert_eq "$(field escape_cause "$got")" "escape_cause=$want" "escape reason: $reason"
  assert_contains "$(rollup)" "${want/-/_}=1" "rollup counts the missed input"
done <<'ROWS'
production-past-small production=328|estimate-miss
excluded-path path=.github/workflows/build.yml glob=.github/workflows/*|path-miss
instruction-file path=AGENTS.md measured-class=micro|path-miss
several-subsystems production=40|path-miss
ROWS
control m-class-reason oversee-cycle 'class_reason="${class_evidence%% *}"' 'class_reason="" # ${class_evidence%% *}'
got="$(record KEN-1 small)"
assert_eq "$(field class_reason "$got") $(field escape_cause "$got")" 'class_reason=- escape_cause=-' \
  "control: discarding the classifier reason turns the escape assertion red"
RUN_BIN=""
new_case legacy-tier; printf micro > "$CASE/class"; timeline 1000
got="$(record KEN-1 micro)"
assert_contains "$(cat "$CASE/err")" 'oversee-cycle: launch-tier-missing item=KEN-1' "legacy launch warns instead of inventing inputs"
assert_eq "$(state '.lanes[0].cycle.tier_inputs')" 'null' "legacy inputs remain unknown"

echo "=== a claude-cloud record: the tier it states, no rounds read ==="
# The launch records the tier the brief's item-tier line states, or null
# where none does. Its host kind declares files=none, so no workflow state is
# read: the dispatcher refuses every provider verb under that kind.
# cloud_case NAME TIER [HOST] — KEN-1 as open-terminal records a cloud lane,
# TIER being its JSON tier, on HOST, claude-cloud by default.
cloud_case() {
  new_case "$1"; printf standard > "$CASE/class"; timeline 1000
  edit_json "$CASE/state/workflow-state-oversee.json" \
    "(.lanes[] | select(.item == \"KEN-1\")) += {host: \"${3:-claude-cloud}\", kind: \"claude-cloud\", mail_root: \"$TMP_ROOT/cloud-wt\", tier: $2, tier_inputs: null}"
}
# cloud_seen TIER [HOST] — a record of KEN-1 with no --tier: its tier, escape
# and rounds, and the stderr lines the read printed.
cloud_seen() {
  local got
  cloud_case "cloud-$1-${2:-}" "$1" "${2:-}"
  got="$(record KEN-1 '')"
  printf '%s %s %s %s unread=%s lane-host=%s' "$(cut -d' ' -f1 <<<"$got")" "$(field tier "$got")" "$(field escaped "$got")" \
    "$(field review "$got")" "$(grep -c rounds-unread "$CASE/err" || true)" "$(grep -c '^lane-host: ' "$CASE/err" || true)"
}
assert_eq "$(cloud_seen '"small"')" 'rc=0 tier=small escaped=true review=- unread=0 lane-host=0' \
  "a cloud record's stated tier stands with no --tier, and a files=none kind reads no rounds and prints nothing"
assert_eq "$(cloud_seen null)" 'rc=0 tier=- escaped=- review=- unread=0 lane-host=0' \
  "a cloud record that states no tier records none, with no escape judged"
# A host whose capability line cannot be read is a read that failed, never a
# lane with no state.
assert_eq "$(cloud_seen '"small"' caps-broken)" 'rc=0 tier=small escaped=true review=- unread=1 lane-host=1' \
  "a host whose capability line is refused records no rounds and prints rounds-unread with the refusal"
control m-files-none lib/lane-gitfile.sh '[[ "$files" != none ]] || return 0' '{ [[ "$files" != none ]] || true; } || return 0'
assert_eq "$(cloud_seen '"small"')" 'rc=0 tier=small escaped=true review=- unread=1 lane-host=2' \
  "control: a cloud record read for its rounds prints rounds-unread and the dispatcher's refusals"
control m-caps-unread lib/lane-gitfile.sh 'lane_capabilities_read "$2" "$5" 2>"$7/state.err" || return 2' \
  'lane_capabilities_read "$2" "$5" 2>"$7/state.err" || return 0'
assert_eq "$(cloud_seen '"small"' caps-broken | cut -d' ' -f5)" 'unread=0' \
  "control: a refused capability read taken as no state prints no rounds-unread"
control m-tier-none oversee-cycle '  none) ;;' '  none) usage_error --tier ;;'
assert_eq "$(cloud_seen null | cut -d' ' -f1)" 'rc=2' \
  "control: a stated null tier taken as missing refuses the record"
RUN_BIN=""

echo '=== running lanes read script-written rounds across a resume ==='
new_case live-stages
printf micro > "$CASE/class"; timeline 1500
WS="$LAYOUT/orch/scripts/workflow-state"
SF="$REPO/tmp/workflow-state-KEN-1.json"
"$WS" --state-dir "$REPO/tmp" init KEN-1 --worktree "$REPO" >/dev/null
edit_json "$CASE/state/workflow-state-oversee.json" ".lanes[0] += {status: \"running\", tier: \"micro\", mail_root: \"$REPO\", pending_pr: {pr: 7}}"
stage_command() {
  (cd "$REPO" && env -u ORCH_STATE_DIR "${RUN_BIN:-$BIN}" --state-dir "$CASE/state" stages "$1")
}
dev_stage() {
  local kind="$1" rid args=()
  rid="$("$WS" --state-dir "$REPO/tmp" new-round-id KEN-1 dev_round_id)"
  jq -n --arg kind "$kind" --arg rid "$rid" --arg commit "$MERGE" '
    {schema_version:1,issue:"KEN-1",branch:"main",round_id:$rid,kind:$kind,commit:$commit,
     validate:"pass",validate_mode:"full",validate_time:{started_at:"2026-01-01T00:00:00Z",ended_at:"2026-01-01T00:55:00Z",seconds:3300},items:[]}
    | if $kind == "implement" then .baseline_lines=1 else .items=[{n:1,decision:"Applied",reasoning:"fixed"}] end' \
    > "$REPO/tmp/dev-return-KEN-1-$rid.json"
  if [[ "$kind" == fix ]]; then
    jq -n --arg rid "$rid" --arg base "$MERGE" '{schema_version:2,issue:"KEN-1",round_id:$rid,base_sha:$base,adds:[],items:[{n:1,text:"fix"}]}' \
      > "$REPO/tmp/dev-round-KEN-1-$rid.json"
    args=(--expect-items-from-round)
  fi
  env -u DEV_VALIDATE_RANGE_CMD ORCH_STATE_DIR="$REPO/tmp" "$LAYOUT/orch/scripts/dev-artifact-check" \
    --worktree "$REPO" --issue KEN-1 --round-id "$rid" ${args[@]+"${args[@]}"} > "$CASE/check.out"
  assert_eq "$(jq -r '.ok' "$CASE/check.out")" true "$kind artifact accepted"
}
review_stage() {
  local rid
  rid="$("$WS" --state-dir "$REPO/tmp" new-round-id KEN-1 review_round_id)"
  jq -n --arg head "$MERGE" '{verdict:"pass",head:$head,dirty_paths:[]}' > "$REPO/tmp/review-r-live.json"
  "$LAYOUT/orch/scripts/review-artifact-check" "$REPO" r 0 --issue KEN-1 --state-dir "$REPO/tmp" > "$CASE/check.out"
  assert_eq "$(jq -r '.ok' "$CASE/check.out")" true 'review artifact accepted'
}
dev_stage implement
review_stage
dev_stage fix
dev_stage fix
"$WS" --state-dir "$REPO/tmp" update KEN-1 '.handoff={remaining:["fix"],resumed_at:null}'
"$WS" --state-dir "$REPO/tmp" handoff-resume KEN-1 >/dev/null
dev_stage fix
review_stage
open_round="$("$WS" --state-dir "$REPO/tmp" new-round-id KEN-1 dev_round_id)"
rows="$(stage_command KEN-1)"
assert_eq "$(jq -c '[.stages[] | .kind] | sort' "$SF")" \
  '["dev","fix","fix","fix","implement","review","review","validate","validate","validate","validate"]' 'all resumed rounds and each validate run exist'
assert_eq "$(jq -r '[.stages[] | select(.round_id != $round) | .end != null] | all' --arg round "$open_round" "$SF")" true 'completed rounds have ends'
assert_eq "$(grep -c '^stage item=KEN-1 ' <<<"$rows")" "$(jq '.stages | length' "$SF")" 'running command prints each discovered stage'
assert_contains "$rows" "kind=dev round_id=$open_round" 'running command includes open round'
assert_contains "$rows" "end=-" 'open round has unknown end'
assert_eq "$(sed -E 's/.* start=([0-9]+) .*/\1/' <<<"$rows" | sort -n)" \
  "$(sed -E 's/.* start=([0-9]+) .*/\1/' <<<"$rows")" 'running rows sort by start'
assert_eq "$(state '.lanes[0] | has("cycle")')" false 'running read creates no cycle'
record KEN-1 micro >/dev/null
assert_eq "$(state '.lanes[0].cycle.stages')" "$(jq -c '.stages' "$SF")" 'record copies the same stages'
control m-stages oversee-cycle 'stages: $stages,' 'stages: null,'
record KEN-1 micro >/dev/null
assert_eq "$(state '.lanes[0].cycle.stages')" null 'control: dropping cycle stages fails same-stage copy'
RUN_BIN=""
control m-stage-reader oversee-cycle "'sort_by(.start)[]" "'sort_by(.start)[] | select(false)"
assert_eq "$(stage_command KEN-1)" '' 'control: hiding discovered rows fails running-stage count'
RUN_BIN=""
cp "$SF" "$CASE/stage-state.saved"
mv -- "$SF" "$REPO/tmp/workflow-state-pr-7.json"
assert_eq "$(stage_command KEN-1)" "$rows" 'lane PR key resolves when item key is absent'
record KEN-1 micro >/dev/null
assert_eq "$(state '.lanes[0].cycle.stages')" "$(jq -c '.stages' "$REPO/tmp/workflow-state-pr-7.json")" 'record shares PR fallback'
rm -- "$REPO/tmp/workflow-state-pr-7.json"
for item in KEN-unknown KEN-1; do
  rc=0
  stage_command "$item" > "$CASE/out" 2> "$CASE/err" || rc=$?
  assert_eq "$rc" 1 "$item without readable state refuses"
  case "$item" in KEN-unknown) expected='record-missing=KEN-unknown' ;; *) expected='stages-unread item=KEN-1 cause=no-state' ;; esac
  assert_eq "$(cat "$CASE/err")" "oversee-cycle: $expected" "$item refusal identifies missing evidence"
done
cp "$CASE/state/workflow-state-oversee.json" "$CASE/stage-fleet.saved"
# Interrupted external state edits can leave broken JSON. workflow-state
# update can also write a stages value that the row formatter cannot read.
# The overseer's refusal reader consumes the first stderr line.
for broken in lane-json fleet-json stages-object stages-false stages-string stages-number; do
  cp "$CASE/stage-state.saved" "$SF"
  cp "$CASE/stage-fleet.saved" "$CASE/state/workflow-state-oversee.json"
  case "$broken" in
    lane-json) printf 'not json' > "$SF" ;;
    fleet-json) printf 'not json' > "$CASE/state/workflow-state-oversee.json" ;;
    stages-object) "$WS" --state-dir "$REPO/tmp" update KEN-1 '.stages={wrong:true}' ;;
    stages-false) "$WS" --state-dir "$REPO/tmp" update KEN-1 '.stages=false' ;;
    stages-string) "$WS" --state-dir "$REPO/tmp" update KEN-1 '.stages="wrong"' ;;
    stages-number) "$WS" --state-dir "$REPO/tmp" update KEN-1 '.stages=7' ;;
  esac
  rc=0; stage_command KEN-1 > "$CASE/out" 2> "$CASE/err" || rc=$?
  assert_eq "$rc" 1 "$broken refuses running read"
  assert_eq "$(sed -n '1p' "$CASE/err")" 'oversee-cycle: stages-unread=KEN-1' "$broken puts the keyed refusal first"
  [[ -n "$(sed -n '2,$p' "$CASE/err")" ]] && pass "$broken keeps the read diagnostic" || fail "$broken keeps the read diagnostic"
done
control m-stage-error-order oversee-cycle \
  '(jq -c '\''.stages | if . == null then [] else . end'\'' <<<"$LANE_ITEM_STATE" | print_stages "$ITEM") 2>"$WORK/state.err"' \
  '(jq -c '\''.stages | if . == null then [] else . end'\'' <<<"$LANE_ITEM_STATE" | print_stages "$ITEM")'
rc=0; stage_command KEN-1 > "$CASE/out" 2> "$CASE/err" || rc=$?
[[ "$(sed -n '1p' "$CASE/err")" != 'oversee-cycle: stages-unread=KEN-1' ]] \
  && pass 'control: uncaptured formatter stderr fails first-line assertion' || fail 'control: uncaptured formatter stderr fails first-line assertion'
RUN_BIN=""
"$WS" --state-dir "$REPO/tmp" update KEN-1 '.stages=false'
control m-stage-false oversee-cycle \
  "'.stages | if . == null then [] else . end'" "'.stages // []'"
rc=0; stage_command KEN-1 > "$CASE/out" 2> "$CASE/err" || rc=$?
assert_eq "$rc|$(cat "$CASE/err")" '0|' 'control: defaulting false to an empty array fails unread-data refusal'
RUN_BIN=""
printf 'not json' > "$SF"
control m-stage-unread oversee-cycle 'read_lane_state || refuse stages-unread "$ITEM" "$WORK/state.err"' 'read_lane_state || true'
rc=0; stage_command KEN-1 > "$CASE/out" 2> "$CASE/err" || rc=$?
assert_eq "$(cat "$CASE/err")" 'oversee-cycle: stages-unread item=KEN-1 cause=no-state' 'control: swallowing read failure fails unread-cause assertion'
RUN_BIN=""
rm -- "$SF"
cloud_case stages-cloud null
rc=0; stage_command KEN-1 > "$CASE/out" 2> "$CASE/err" || rc=$?
assert_eq "$rc|$(cat "$CASE/err")" '1|oversee-cycle: stages-unread item=KEN-1 cause=no-state' 'files=none has no readable stages'
control m-stage-no-state oversee-cycle 'if [[ -z "$LANE_ITEM_STATE" ]]; then' 'if false; then'
rc=0; stage_command KEN-1 > "$CASE/out" 2> "$CASE/err" || rc=$?
assert_eq "$rc" 0 'control: absent-state refusal disabled accepts an empty read'
RUN_BIN=""
control m-stage-no-record oversee-cycle '[[ -n "$lane" ]] || refuse record-missing "$ITEM"
  read_lane_state' '[[ -n "$lane" ]] || lane="{}"
  read_lane_state'
rc=0; stage_command KEN-unknown > "$CASE/out" 2> "$CASE/err" || rc=$?
assert_eq "$(cat "$CASE/err")" 'oversee-cycle: stages-unread item=KEN-unknown cause=no-state' 'control: absent-lane refusal disabled fails record-missing assertion'
RUN_BIN=""

echo "pass: $PASS  fail: $FAIL"
[[ "$FAIL" -eq 0 ]]
