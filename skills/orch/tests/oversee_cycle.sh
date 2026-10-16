#!/usr/bin/env bash
# oversee-cycle: a closed lane's record against its class target, the stamps
# it writes to the lane record, the repeat-miss bar, and the per-class rollup.
#
# The shipped recorder and evidence helper read a real first-parent range.
# GitHub fixtures supply measured Actions logs. The executable classifier stub
# records forbidden proof calls. A lane-host fake serves hosted lane state.
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
case "$ORCH_LANE_HOST" in local | claude-cloud | /*) exec "$OVERSEE_CYCLE_REAL_LANE_HOST" "$@" ;; esac
case "$1" in
  capabilities)
    [[ "$ORCH_LANE_HOST" != caps-broken ]] || { echo 'lane-host: capability-invalid key=files value=' >&2; exit 1; }
    printf 'kind=ssh\tfiles=verb\n' ;;
  cat) [[ -f "$CASE/host$4" ]] || exit 2; cat -- "$CASE/host$4" ;;
  touch) exit 0 ;;
  *) exit 9 ;;
esac
SH
# gh answers `repo view` with the case's slug file, vanillagreencom/kendex by default,
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
    "api repos/vanillagreencom/kendex/commits/"*"/check-runs?"*)
      head=${2#*/commits/}; head=${head%%/*}
      base=$(git rev-parse "$head^1")
      printf '%s\n' "--base $base --head $head" >> "$CASE/evidence.calls"
      printf '%s' "$head" > "$CASE/request-head"
      # The production job skips pushes. Only PR timeline cases have a
      # merge-group producer; a direct push has no classifier check.
      [[ -f $CASE/timeline.json && -f $CASE/class ]] || { printf '[{"total_count":0,"check_runs":[]}]\n'; exit 0; }
      jq -cn --arg head "$head" '[{total_count:1,check_runs:[{id:72,name:"Classify the diff",app:{slug:"github-actions"},head_sha:$head,status:"completed",conclusion:"success"}]}]'; exit 0 ;;
    "api repos/vanillagreencom/kendex/actions/jobs/72")
      jq -cn --arg head "$(cat "$CASE/request-head")" '{id:72,run_id:20,check_run_url:"https://api.github.com/repos/vanillagreencom/kendex/check-runs/72",name:"Classify the diff",head_sha:$head,status:"completed",conclusion:"success"}'; exit 0 ;;
    "api repos/vanillagreencom/kendex/actions/runs/20")
      jq -cn --arg head "$(cat "$CASE/request-head")" --arg repo "$(cat "$CASE/run-repo" 2>/dev/null || printf vanillagreencom/kendex)" '{id:20,path:".github/workflows/skill-tests.yml",event:"merge_group",head_sha:$head,repository:{full_name:$repo},head_repository:{full_name:$repo},status:"completed",conclusion:"success"}'; exit 0 ;;
    "api repos/vanillagreencom/kendex/actions/jobs/72/logs --allow-escape-sequences")
      [[ ! -e $CASE/log-failed ]] || exit 1
      head=$(cat "$CASE/request-head"); base=$(git rev-parse "$head^1")
      [[ ! -e $CASE/log-head ]] || head=$(cat "$CASE/log-head")
      [[ ! -e $CASE/log-base ]] || base=$(cat "$CASE/log-base")
      measured=true; [[ ! -e $CASE/measured ]] || measured=$(cat "$CASE/measured")
      reason=stub; [[ ! -e $CASE/reason ]] || reason=$(cat "$CASE/reason")
      printf 'base-rev: %s\nhead-rev: %s\nclass: class=%s measured=%s cause=%s\n' "$base" "$head" "$(cat "$CASE/class")" "$measured" "$reason"; exit 0 ;;
    "api --paginate repos/vanillagreencom/kendex/activity?"*) file="$CASE/activity.json" ;;
    "api repos/vanillagreencom/kendex/compare/"*" --jq .status") file="$CASE/compare-${2#*/compare/}" ;;
    *) exit 9 ;;
  esac
  [[ -f "$file" ]] || { echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
  exec cat -- "$file"
fi
[[ "$1 $2" == "repo view" ]] || exit 1
if [[ -f "$CASE/slug" ]]; then cat "$CASE/slug"; else echo vanillagreencom/kendex; fi
SH
chmod +x "$LAYOUT/github/scripts/github.sh" "$LAYOUT/harness-ci/scripts/change-class" "$LAYOUT/orch/scripts/lane-host" "$TMP_ROOT/bin/gh"

commit() { git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m "$2"; }
ORIGIN="$TMP_ROOT/origin.git"
git init -q --bare "$ORIGIN"
REPO="$TMP_ROOT/repo"
git init -q "$REPO"
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
mkdir -p "$REPO/.github/workflows" "$REPO/.github/actions/change-class"
cp "$TEST_DIR/../../../.github/workflows/skill-tests.yml" "$REPO/.github/workflows/"
cp "$TEST_DIR/../../../.github/actions/change-class/"{action.yml,classify,proof} "$REPO/.github/actions/change-class/"
git -C "$REPO" add .github
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
  jq -n --arg at "$(at 0)" --arg owner "$REPO" '{overseer:{cwd:$owner},lanes: [range(1; 7) | {item: "KEN-\(.)", repo: null, launched_at: $at, status: "done"}], fleet_log: []}' \
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
    '{pr: 7, repo: "vanillagreencom/kendex", state: "MERGED", head: "h", merge_commit: $merge,
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
PR|pr|rc=0 cycle item=KEN-1 pr=7 class=small tier=micro target=1800 merge_group=- ci_head=60 ci_clean=- lane=900 actual=900 open=780 verdict=met|
direct push|commit|rc=0 cycle item=KEN-1 commit=SHA class=- tier=micro target=- merge_group=- ci_head=- ci_clean=- lane=900 actual=900 open=- verdict=unclassified|
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
  "rc=0 cycle item=KEN-1 commit=$MERGE class=- tier=micro target=- merge_group=- ci_head=- ci_clean=- lane=1200 actual=1200 open=- verdict=unclassified phase=- phase_secs=- cause=- bot_wait=- draft=- thread_fix=- paused=- missing=pr_opened,gate_green,ci_green,armed review=- fix=- bot=- full_validations=- pr_rounds=- escaped=- tier_inputs=- class_reason=- escape_cause=- refixed=-" \
  "direct push prints its timing, unclassified verdict and absent PR fields"
assert_eq "$(state '.lanes[0].cycle | [.commit, has("pr"), .class, .tier, .actual, .escaped, .stamps]')" \
  "[\"$MERGE\",false,null,\"micro\",1200,null,{\"launched\":\"$(at 0)\",\"first_commit\":\"$(at 60)\",\"pr_opened\":null,\"gate_green\":null,\"ci_green\":null,\"armed\":null,\"merged\":\"$(at 1200)\",\"ready\":null}]" \
  "direct push persists its authored date and its push time, not its committer date, in UTC"
assert_eq "$(grep -c '^api --paginate repos/vanillagreencom/kendex/activity?ref=refs%2Fheads%2Fmain&activity_type=push&per_page=100' "$CASE/gh.calls")|$(grep -c compare/ "$CASE/gh.calls" || true)" \
  "1|0" "the push is read from the base branch's push log, and a push leaving the branch at the commit needs no compare"
assert_eq "$(state '.fleet_log[-1].text')" "\"${got#rc=0 }\"" "direct cycle row is the printed row"
assert_eq "$(grep -o -- '--base [^ ]* --head [^ ]*' "$CASE/evidence.calls")" "--base $BASE --head $MERGE" \
  "direct push reads first-parent evidence"
assert_eq "$(test -f "$CASE/github.calls" && echo called || echo absent)" absent "direct push reads no PR timeline"
assert_contains "$(cd "$REPO" && "$BIN" --state-dir "$CASE/state" rollup)" \
  'rollup class=unclassified items=1 median=1200 p90=1200 lane_median=1200 open_median=- miss_share=- misses=0' "rollup retains direct-push timing without a measured miss"

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
# One row per class, lane time one second over its target, and each class
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
    "rc=0 cycle item=KEN-1 pr=7 class=$class tier=$tier target=$want_target merge_group=- ci_head=60 ci_clean=- lane=$merged actual=$merged open=$((merged - 120)) verdict=$want_verdict escaped=$want_escaped" \
    "$class at $merged s, tier $tier: target $want_target, $want_verdict, escaped $want_escaped"
done <<'ROWS'
render|301|standard|300|miss|false
render|300|standard|300|met|false
trivial|301|standard|300|miss|false
trivial|300|standard|300|met|false
micro|1201|standard|1200|miss|false
micro|1200|micro|1200|met|false
small|1801|standard|1800|miss|false
small|1800|micro|1800|met|true
small|1800|small|1800|met|false
standard|5401|standard|5400|miss|false
standard|5400|micro|5400|met|true
standard|5400|small|5400|met|true
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
allowance|fleet|1080|280|target=1180 merge_group=280 verdict=met phase=gate_green phase_secs=380|[1180,280,1080,960,"gate_green",380,{"bot_wait":380,"draft":0,"thread_fix":0,"paused":0}]
null-control|fleet|1080|null|target=900 merge_group=- verdict=miss phase=merged phase_secs=460|[900,null,1080,960,"merged",460,{"bot_wait":380,"draft":0,"thread_fix":0,"paused":0}]
queue-wait|fleet|2000|280|target=1180 merge_group=280 verdict=miss phase=merged phase_secs=1100|[1180,280,2000,1880,"merged",1100,{"bot_wait":380,"draft":0,"thread_fix":0,"paused":0}]
shipped-target|shipped|1480|280|target=1480 merge_group=280 verdict=met phase=merged phase_secs=580|[1480,280,1480,1360,"merged",580,{"bot_wait":380,"draft":0,"thread_fix":0,"paused":0}]
floor|shipped|200|280|target=1480 merge_group=280 verdict=met phase=first_commit phase_secs=60|[1480,280,200,80,"first_commit",60,null]
zero|fleet|1080|0|target=900 merge_group=0 verdict=miss phase=merged phase_secs=460|[900,0,1080,960,"merged",460,{"bot_wait":380,"draft":0,"thread_fix":0,"paused":0}]
ROWS
RUN_BIN=""

echo "=== the verdict reads lane-controlled launch-to-merge time ==="
# Launch to PR opened takes 900 s, so launch to merge is over the micro
# target while open to merge is under it.
new_case open-span
printf micro > "$CASE/class"
timeline 2000
edit_json "$CASE/timeline.json" ".stamps.created = \"$(at 900)\" | .open_secs = 1100"
got="$(record KEN-1 micro)"
assert_eq "$(field actual "$got") $(field open "$got") $(field verdict "$got")" "actual=2000 open=1100 verdict=miss" \
  "the lane verdict includes work before PR opened, while open time stays visible"

echo "=== evidence binds the merge commit and its first parent ==="
assert_eq "$(grep -o -- '--base [^ ]* --head [^ ]*' "$CASE/evidence.calls")" "--base $BASE --head $MERGE" \
  "evidence is requested for merge^1 and the merge commit"

echo "=== a class the evidence did not give is unclassified, never judged ==="
new_case unclassified
timeline 5401
assert_eq "$(record KEN-1 standard)" \
  "rc=0 cycle item=KEN-1 pr=7 class=- tier=standard target=- merge_group=- ci_head=60 ci_clean=- lane=5401 actual=5401 open=5281 verdict=unclassified phase=merged phase_secs=4981 cause=- bot_wait=180 draft=0 thread_fix=0 paused=0 missing=- review=- fix=- bot=- full_validations=- pr_rounds=0 escaped=- tier_inputs=- class_reason=- escape_cause=- refixed=false" \
  "absent evidence records no class and no target"
assert_eq "$(grep '^oversee-cycle: class-unread' "$CASE/err")" "oversee-cycle: class-unread cause=ci-proof-missing" "and names the cause on stderr"

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
assert_eq "$(field class "$got")|$(grep -o -- '--head [^ ]*' "$CASE/evidence.calls")" "class=micro|--head $FAR" \
  "a merge commit only origin holds is fetched for its evidence"

# Exact evidence reaches the production recorder without executable proof.
while IFS='|' read -r row cause; do
  new_case "evidence-$row"
  printf micro > "$CASE/class"
  timeline 1000
  case "$row" in
    accepted) ;;
    unreadable) touch "$CASE/log-failed" ;;
    repository) printf other/repo > "$CASE/run-repo" ;;
    base) printf '%s' "$MERGE" > "$CASE/log-base" ;;
    head) printf '%s' "$BASE" > "$CASE/log-head" ;;
    origin) printf owner/other > "$CASE/slug" ;;
  esac
  got="$(record KEN-1 micro)"
  if [[ $cause == pass ]]; then
    assert_eq "$(state '.lanes[0].cycle | [.class,.target,.class_reason]')" '["micro",1200,"stub"]' "$row exact evidence"
  else
    assert_eq "$(state '.lanes[0].cycle | [.class,.verdict,.class_cause]')" "[null,\"unclassified\",\"$cause\"]" "$row refuses evidence"
  fi
  assert_eq "$(test -e "$CASE/class.calls" && echo called || echo absent)" absent "$row runs no classifier"
done <<'ROWS'
accepted|pass
unreadable|ci-proof-missing
repository|ci-proof-missing
base|ci-proof-missing
head|ci-proof-missing
origin|origin-untrusted
ROWS
CYCLE_CONTROL="$LAYOUT/orch/scripts/cycle-executable-control"
cp "$BIN" "$CYCLE_CONTROL"
mutate_file "$CYCLE_CONTROL" 'change_class_merged "$base" "$merge" "$checkout" "$evidence_repo" "$WORK/class.err"' 'change_class_read "$base" "$merge" "$checkout" "$WORK/class.err"'
new_case evidence-control
printf micro > "$CASE/class"
timeline 1000
RUN_BIN="$CYCLE_CONTROL" record KEN-1 micro >/dev/null
assert_eq "$(test -s "$CASE/class.calls" && echo called || echo absent)" called 'cycle control makes the no-execution assertion red'

# --- the stamps are written to the record and read back ----------------------
echo "=== the record carries its phase stamps, ready, class and rounds ==="
new_case stamps
printf micro > "$CASE/class"
PR_ROUNDS='[{"kind":"review","head":"a","start":"s1","end":"e1","secs":600},{"kind":"fix","head":"a","start":"e1","end":"s2","secs":1200},{"kind":"review","head":"b","start":"s2","end":"e2","secs":300}]'
PR_ROUNDS="$PR_ROUNDS" timeline 1500 300 500
# The lane's own state, where workflow-state puts a local lane's in this
# checkout; each round figure has a value no other one shares.
jq -n '{first_panel: {agents: ["a"]}, rereview_cycles: 2, cycles: 5, pr_comment_review: {iterations: 4},
        validate_rounds: [{mode: "full"}, {mode: "range"}, {mode: "full"}]}' > "$REPO/tmp/workflow-state-KEN-2.json"
assert_eq "$(record KEN-2 micro)" \
  "rc=0 cycle item=KEN-2 pr=7 class=micro tier=micro target=1200 merge_group=- ci_head=60 ci_clean=- lane=1500 actual=1500 open=1380 verdict=miss phase=merged phase_secs=1080 cause=merged bot_wait=180 draft=0 thread_fix=0 paused=0 missing=- review=3 fix=5 bot=4 full_validations=2 pr_rounds=2 escaped=false tier_inputs=- class_reason=stub escape_cause=- refixed=true" \
  "the printed line: a miss whose longest gap ends at the merge, and a push after the first gate pass"
assert_eq "$(state '.lanes[] | select(.item == "KEN-2") | .cycle | [.class, .tier, .verdict, .stamps]')" \
  "[\"micro\",\"micro\",\"miss\",{\"launched\":\"$(at 0)\",\"first_commit\":\"$(at 60)\",\"pr_opened\":\"$(at 120)\",\"gate_green\":\"$(at 300)\",\"ci_green\":\"$(at 360)\",\"armed\":\"$(at 420)\",\"merged\":\"$(at 1500)\",\"ready\":null}]" \
  "the lane record reads back the class, phase stamps and ready"
assert_eq "$(state '.lanes[] | select(.item == "KEN-2") | .cycle.pr_rounds')" "$PR_ROUNDS" \
  "and the review and fix rounds pr-timeline read"
assert_eq "$(state '[.lanes[] | select(.item != "KEN-2") | has("cycle")] | any')" "false" "no other record is written"
assert_eq "$(state '.fleet_log | map(.kind + ":" + .item) | join(",")')" '"cycle:KEN-2"' "one cycle row joins the fleet log"
assert_eq "$(state '.fleet_log[0].text')" "\"$(sed 's/^rc=0 //' <<<"$(record KEN-2 micro)")\"" \
  "and its text is the printed line"

control() { # NAME FILE ANCHOR REPLACEMENT — sets RUN_BIN to the mutant's oversee-cycle
  local dir
  dir="$(mutant_scripts "skills/$1" "$2")" || exit 1
  ln -sf -- "$LAYOUT/orch/scripts/lane-host" "$dir/lane-host" || exit 1
  mutate_file "$dir/$2" "$3" "$4"
  RUN_BIN="$dir/oversee-cycle"
}

echo "=== first ready is recorded without changing phase accounting ==="
control ready-control oversee-cycle 'stamps: ($stamps + {ready: ([$t.ready_times[]? | select(. != null)] | min)})' 'stamps: $stamps'
READY_CONTROL="$RUN_BIN"
unset RUN_BIN
while IFS='|' read -r name ready_times want_ready want_draft; do
  new_case "ready-$name"
  printf micro > "$CASE/class"
  timeline 600
  edit_json "$CASE/timeline.json" ".ready_times = $ready_times"
  got="$(record KEN-1 micro)"
  assert_contains "$got" 'rc=0 cycle ' "$name records a cycle"
  assert_eq "$(state '.lanes[0].cycle | [.stamps | has("ready"), .ready]')" \
    "[true,$want_ready]" "$name records the earliest ready event or null"
  assert_eq "$(state '.lanes[0].cycle | [.stamps.pr_opened, .phase, .phase_secs, .gate_waits, .missing]')" \
    "[\"$(at 120)\",\"gate_green\",180,{\"bot_wait\":$((180 - want_draft)),\"draft\":$want_draft,\"thread_fix\":0,\"paused\":0},[]]" \
    "$name retains creation time and phase accounting, including the last-ready draft share"
  assert_eq "$(wc -l < "$CASE/github.calls" | tr -d ' ')" 1 "$name reuses the existing timeline read"
  accounting="$(state '.lanes[0].cycle | [.phase, .phase_secs, .gate_waits, .missing]')"
  RUN_BIN="$READY_CONTROL" record KEN-1 micro >/dev/null
  assert_eq "$(state '.lanes[0].cycle.stamps | has("ready")')" false "$name control lacks the required ready field"
  assert_eq "$(state '.lanes[0].cycle | [.phase, .phase_secs, .gate_waits, .missing]')" "$accounting" "$name phase accounting matches the control"
done <<'ROWS'
draft-then-ready|["2026-09-21T14:17:20Z"]|"2026-09-21T14:17:20Z"|120
repeated-ready-with-nulls|[null,"2026-09-21T14:17:20Z","2026-09-21T14:16:20Z",null]|"2026-09-21T14:16:20Z"|120
no-ready|[]|null|0
only-null|[null]|null|0
ROWS

# The final-head timeline is pr-timeline's producer. Reruns have different
# all-attempt and clean spans. The cycle log is the fleet audit's protocol.
clean_ci_rows() {
  while IFS='|' read -r name head clean group merged form launch want; do
    new_case "clean-ci-$1-$name"
    printf micro > "$CASE/class"
    edit_json "$CASE/state/workflow-state-oversee.json" '.lanes[0].tier = "micro"'
    if [[ "$form" == commit ]]; then
      RECORD_ARGS=(--commit "$MERGE"); pushes "$merged:$MERGE"
    else
      RECORD_ARGS=(--pr 7); timeline "$merged"
      edit_json "$CASE/timeline.json" ".ci_head_secs = $head | .ci_head_clean_secs = $clean | .ci_merge_group_secs = $group"
    fi
    [[ "$launch" != missing ]] || edit_json "$CASE/state/workflow-state-oversee.json" '.lanes[0].launched_at = null'
    got="$(record KEN-1 '')"
    assert_eq "$(field target "$got") $(field ci_head "$got") $(field ci_clean "$got") $(field lane "$got") $(field verdict "$got")|$(state '.lanes[0].cycle | [.target, .ci_head, .ci_clean, .lane_secs, .open]')" \
      "$want" "$name: the record and fleet log separate clean CI from lane and open time"
  done <<'ROWS'
clean|1394|1394|963|3557|pr|present|target=3557 ci_head=1394 ci_clean=1394 lane=1200 verdict=met|[3557,1394,1394,1200,3437]
rerun|6736|1400|963|8899|pr|present|target=3563 ci_head=6736 ci_clean=1400 lane=6536 verdict=miss|[3563,6736,1400,6536,8779]
no-green|1394|null|963|3557|pr|present|target=2163 ci_head=1394 ci_clean=- lane=2594 verdict=miss|[2163,1394,null,2594,3437]
no-group|1394|1394|null|2594|pr|present|target=2594 ci_head=1394 ci_clean=1394 lane=1200 verdict=met|[2594,1394,1394,1200,2474]
no-ci|null|null|null|1200|pr|present|target=1200 ci_head=- ci_clean=- lane=1200 verdict=met|[1200,null,null,1200,1080]
missing-launch|1394|1394|963|3557|pr|missing|target=3557 ci_head=1394 ci_clean=1394 lane=- verdict=unmeasured|[3557,1394,1394,null,3437]
direct|null|null|null|1200|commit|present|target=- ci_head=- ci_clean=- lane=1200 verdict=unclassified|[null,null,null,1200,null]
ROWS
  RECORD_ARGS=(--pr 7)
}
clean_ci_rows shipped
RUN_BIN=""

# Direct pushes retain elapsed time without a class target or miss verdict.
direct_verdicts() {
  while IFS='|' read -r name secs; do
    new_case "direct-verdict-$1-$name"
    printf small > "$CASE/class"
    RECORD_ARGS=(--commit "$MERGE"); pushes "$secs:$MERGE"
    got="$(record KEN-1 micro)"
    assert_eq "$(state '.lanes[0].cycle | [.class,.class_cause,.verdict,.actual,.lane_secs,.target]')" \
      "[null,\"ci-proof-missing\",\"unclassified\",$secs,$secs,null]" "direct $name: absent production evidence preserves timing without classification"
    assert_eq "$(field verdict "$got") $(field target "$got") $(field ci_head "$got") $(field ci_clean "$got")|$(cd "$REPO" && "${RUN_BIN:-$BIN}" --state-dir "$CASE/state" report | sed -E 's/ draft=.*//')" \
      "verdict=unclassified target=- ci_head=- ci_clean=-|rollup class=unclassified items=1 median=$secs p90=$secs lane_median=$secs open_median=- miss_share=- misses=0" "direct $name: unclassified rollup retains elapsed time"
    assert_not_contains "$(cat "$CASE/gh.calls")" '/actions/jobs/' "direct $name: discovery supplies no invented job or log"
  done <<'ROWS'
earlier|1800
later|1801
ROWS
  RECORD_ARGS=(--pr 7)
}
direct_verdicts shipped
RUN_BIN=""

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

echo '=== missing state reports the item and every attempted path ==='
new_case absent-state
printf micro > "$CASE/class"
timeline 1200
record KEN-6 micro >/dev/null
assert_file_contains "$CASE/err" 'oversee-cycle: rounds-unread item=KEN-6' 'an absent state produces the recorder diagnostic'
assert_file_contains "$CASE/err" "lane-gitfile: state-tried item=KEN-6 path=$REPO/tmp/workflow-state-KEN-6.json" 'the live path is named'
assert_file_contains "$CASE/err" "lane-gitfile: state-tried item=KEN-6 path=$REPO/tmp/cycle-state/workflow-state-KEN-6.json" 'the saved path is named'
cp -p "$BIN" "$LAYOUT/orch/scripts/no-rounds-diagnostic"
mutate_file "$LAYOUT/orch/scripts/no-rounds-diagnostic" \
  'elif [[ "$LANE_ITEM_STATE_REASON" != files-none ]]; then' \
  'elif false && [[ "$LANE_ITEM_STATE_REASON" != files-none ]]; then'
RUN_BIN="$LAYOUT/orch/scripts/no-rounds-diagnostic" record KEN-6 micro >/dev/null
assert_eq "$(state '.lanes[] | select(.item == "KEN-6") | .cycle.rounds')" null 'control: disabling the diagnostic still records unknown rounds'
assert_file_not_contains "$CASE/err" 'oversee-cycle: rounds-unread item=KEN-6' 'control: disabling the missing-state branch removes its diagnostic'

echo '=== merged lanes retain rounds through live-state and worktree removal ==='
connected_checkout="$TMP_ROOT/connected-cycle"
git clone -q -b main "$ORIGIN" "$connected_checkout"
for form in local hosted; do
  new_case "saved-$form"
  printf micro > "$CASE/class"
  timeline 1200
  mkdir -p "$REPO/tmp/cycle-state" "$REPO/tmp/oversee-watch"
  saved="$REPO/tmp/cycle-state/workflow-state-KEN-6.json"
  live="$REPO/tmp/workflow-state-KEN-6.json"
  printf '{"first_panel":true,"rereview_cycles":2,"cycles":5,"pr_comment_review":{"iterations":4},"validate_rounds":[{"mode":"full"},{"mode":"range"},{"mode":"full"}],"stages":[{"kind":"review","round_id":"saved","start":1,"end":2}]}' > "$live"
  cp -- "$live" "$saved"
  (cd "$REPO" && FLEET_DIR="$CASE/fleet" "$LAYOUT/orch/scripts/workflow-state" --state-dir "$REPO/tmp" remove KEN-6) >"$CASE/remove.out"
  assert_eq "$([[ ! -e "$live" && -f "$saved" ]] && printf retained)" retained "$form close-out removes live state and retains the cycle copy" "$CASE/remove.out"
  if [[ "$form" == hosted ]]; then
    mkdir -p "$CASE/host/clone/tmp/cycle-state"
    cp -- "$saved" "$CASE/host/clone/tmp/cycle-state/workflow-state-KEN-6.json"
    rm -- "$saved"
    # A connected repository's row still lives under the primary watch's prefix.
    printf 'clone-root\tKEN-6\t/clone\n' > "$REPO/tmp/oversee-watch/saved__none.mail"
    edit_json "$CASE/state/workflow-state-oversee.json" '(.lanes[] | select(.item == "KEN-6")) += {host:"box",mail_root:"/w/KEN-6",repo:"vanillagreencom/kendex"}'
    got="$(REPO="$connected_checkout" record KEN-6 micro)"
    assert_eq "$(field fix "$got")" 'fix=5' 'a connected checkout records from the primary fleet watch rows' "$CASE/err"
    # Older fleet state can identify its owner through its directory alone.
    mkdir -p "$REPO/tmp/primary-fleet" "$connected_checkout/tmp/explicit-watch"
    jq 'del(.overseer)' "$CASE/state/workflow-state-oversee.json" > "$REPO/tmp/primary-fleet/workflow-state-oversee.json"
    got="$(cd "$connected_checkout" && env -u ORCH_STATE_DIR "$BIN" --state-dir "$REPO/tmp/primary-fleet" stages KEN-6)"
    assert_eq "$got" 'stage item=KEN-6 kind=review round_id=saved start=1 end=2' 'a connected checkout resolves primary watch rows from the fleet state directory'
    mv -- "$REPO/tmp/oversee-watch/saved__none.mail" "$connected_checkout/tmp/explicit-watch/saved.mail"
    got="$(cd "$connected_checkout" && env -u ORCH_STATE_DIR OVERSEE_WATCH_STATE_DIR="$connected_checkout/tmp/explicit-watch" "$BIN" --state-dir "$CASE/state" stages KEN-6)"
    assert_eq "$got" 'stage item=KEN-6 kind=review round_id=saved start=1 end=2' 'an explicit watch directory overrides the fleet owner'
    mv -- "$connected_checkout/tmp/explicit-watch/saved.mail" "$REPO/tmp/oversee-watch/saved__none.mail"
  else
    cp -- "$saved" "$CASE/saved-source.json"
    got="$(record KEN-6 micro)"
    assert_eq "$(field fix "$got")" 'fix=5' 'a standing clone records saved state after live state removal' "$CASE/err"
    cp -- "$CASE/saved-source.json" "$saved"
    git -C "$REPO" worktree add -q --detach "$CASE/lane" HEAD
    git -C "$REPO" worktree remove "$CASE/lane"
    edit_json "$CASE/state/workflow-state-oversee.json" "(.lanes[] | select(.item == \"KEN-6\")) += {mail_root:\"$CASE/lane\"}"
  fi
  got="$(record KEN-6 micro)"
  assert_eq "$(field review "$got") $(field fix "$got") $(field bot "$got") $(field full_validations "$got")" \
    'review=3 fix=5 bot=4 full_validations=2' "$form removed lane records numeric rounds from saved state" "$CASE/err"
  if [[ "$form" == local ]]; then
    assert_eq "$([[ ! -e "$saved" ]] && printf removed)" removed 'a successful local record removes its saved copy'
  else
    assert_eq "$([[ -f "$CASE/host/clone/tmp/cycle-state/workflow-state-KEN-6.json" ]] && printf retained)" retained 'the hosted saved copy remains for host close'
    cp -p "$TEST_DIR/../scripts/lib/lane-gitfile.sh" "$TMP_ROOT/no-saved-read.sh"
    mutate_file "$TMP_ROOT/no-saved-read.sh" \
      'lane_item_saved_state() { # LANE_HOST_CLI ITEM CLONE SCRATCH STATE_KEY' \
      $'lane_item_saved_state() { # LANE_HOST_CLI ITEM CLONE SCRATCH STATE_KEY\n  return 0'
    rm -- "$LAYOUT/orch/scripts/lib/lane-gitfile.sh"
    cp -p "$TMP_ROOT/no-saved-read.sh" "$LAYOUT/orch/scripts/lib/lane-gitfile.sh"
    record KEN-6 micro >/dev/null
    assert_eq "$(state '.lanes[] | select(.item == "KEN-6") | .cycle.rounds')" null 'control: skipping saved reads restores null rounds on the merged lane'
    assert_file_contains "$CASE/err" 'oversee-cycle: rounds-unread item=KEN-6' 'control: unread saved state is reported'
    rm -- "$LAYOUT/orch/scripts/lib/lane-gitfile.sh"
    ln -s "$TEST_DIR/../scripts/lib/lane-gitfile.sh" "$LAYOUT/orch/scripts/lib/lane-gitfile.sh"
    rm -- "$REPO/tmp/oversee-watch/saved__none.mail"
    rm -- "$CASE/host/clone/tmp/cycle-state/workflow-state-KEN-6.json"
    record KEN-6 micro >/dev/null
    assert_file_contains "$CASE/err" 'lane-gitfile: state-unread item=KEN-6 cause=no-state' 'a gone hosted lane refuses missing state by item'
    assert_file_contains "$CASE/err" 'lane-gitfile: state-tried item=KEN-6 path=/w/KEN-6/.git' 'the gone hosted worktree path is named'
  fi
done

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
  : > "$CASE/evidence.calls"
  # shellcheck disable=SC2086
  got="$(record "$item" micro $args)"
  assert_eq "$(field class "$got") $(field fix "$got")|$(grep -m 1 class-unread "$CASE/err" || true)|$(wc -l < "$CASE/evidence.calls" | tr -d ' ')" "$want" "$label"
done <<'ROWS'
a local lane whose worktree names another origin|KEN-5||class=- fix=9|oversee-cycle: class-unread cause=checkout-other-repo|0
a lane named in another repository|KEN-1|--repo owner/other|class=- fix=-|oversee-cycle: class-unread cause=checkout-other-repo|0
a lane named in this repository, in any case|KEN-1|--repo Vanillagreencom/Kendex|class=micro fix=-||1
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
  "verdict=unmeasured actual=- open=980 phase=- missing=launched,first_commit" \
  "a lane with no launch stamp has no lane measure, and its lane phase is unknown"

new_case no-open
printf small > "$CASE/class"
timeline 1100
edit_json "$CASE/timeline.json" '.stamps.created = null | .open_secs = null'
got="$(record KEN-1 standard)"
assert_eq "$(field verdict "$got") $(field open "$got") $(field missing "$got")" "verdict=met open=- missing=pr_opened" \
  "no-open: a measured lane verdict does not require the PR open stamp"

echo "=== which phase dominates is read from the lane launch span ==="
new_case phase
printf small > "$CASE/class"
jq -n --arg merge "$MERGE" --arg fc "$(at 900)" --arg cr "$(at 960)" --arg gate "$(at 1000)" --arg ci "$(at 1010)" --arg m "$(at 1100)" \
  '{pr: 7, merge_commit: $merge, stamps: {first_commit: $fc, created: $cr, last_push: $cr, first_gate_met: null,
    gate_met: $gate, ci_green: $ci, armed: null, queued: $gate, merged: $m}, open_secs: 140, push_times: [], bot_review_times: []}' > "$CASE/timeline.json"
assert_eq "$(record KEN-3 micro)" \
  "rc=0 cycle item=KEN-3 pr=7 class=small tier=micro target=1800 merge_group=- ci_head=- ci_clean=- lane=1100 actual=1100 open=140 verdict=met phase=first_commit phase_secs=900 cause=- bot_wait=40 draft=0 thread_fix=0 paused=0 missing=- review=- fix=- bot=- full_validations=- pr_rounds=- escaped=true tier_inputs=- class_reason=stub escape_cause=- refixed=-" \
  "phase: launch to first commit names the longest gap; queued stands in for armed, a micro tier merged small escaped, and no gate pass leaves refixed unknown, a timeline with no rounds no pr_rounds"

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
# draft_rows: #1305's 3197 s draft period and 166 s bot review, relative to T0.
# The timeline read and cycle record also feed the per-class rollup.
draft_rows() {
  while IFS='|' read -r name ready pushes reviews draft bot fix; do
    new_case "draft-$1-$name"; printf micro > "$CASE/class"
    gate_timeline "$pushes" "$reviews" 3683
    edit_json "$CASE/timeline.json" ".ready_times = $ready | .stamps.gate_met = \"$(at 3483)\" | .stamps.ci_green = \"$(at 3543)\" | .stamps.armed = \"$(at 3583)\""
    got="$(record KEN-1 micro)"
    assert_eq "$(field draft "$got") $(field bot_wait "$got") $(field thread_fix "$got")" \
      "draft=$draft bot_wait=$bot thread_fix=$fix" "draft attribution: $name"
    assert_eq "$(state '.lanes[0].cycle.gate_waits.draft')" "$draft" "draft record: $name"
    assert_eq "$(wc -l < "$CASE/github.calls" | tr -d ' ')" 1 "draft uses the existing timeline: $name"
  done <<ROWS
fleet-1305|["$(at 3317)"]|100|3483|3197|166|0
never-draft|[]|100|3483|0|3363|0
last-ready-before-gate|["$(at 200)", "$(at 3317)", "$(at 4000)"]|100|3483|3197|166|0
push-after-ready|["$(at 3317)"]|100 3400|3317 3483|3197|83|83
ROWS
}
draft_rows shipped
assert_eq "$(state '.lanes[0].cycle.cause')" '"draft"' "draft work can cause the cycle miss"
assert_contains "$( (cd "$REPO" && "$BIN" --state-dir "$CASE/state" rollup))" "draft=3197" "rollup counts draft seconds"
control m-draft oversee-cycle 'fromdate | select(. <= $to)] | max) as $ready' 'fromdate | select(. <= $to and false)] | max) as $ready'
if (FAIL=0; draft_rows control; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/draft-control.out"; then
  fail "draft attribution: removing the ready cutoff did not redden the fleet row"
else
  assert_eq "$(grep -c '^  FAIL  draft attribution: fleet-1305$' "$TMP_ROOT/draft-control.out")" 1 "control: the original clock misattributes the fleet draft period"
  assert_contains "$(cat "$TMP_ROOT/draft-control.out")" 'bot_wait=3363' "control: the base clock reports bot wait above 2603 seconds"
fi
RUN_BIN=""

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

# The merge gap is 12000 s. Its pause union and CI span come from the
# existing lane and timeline producers; the printed cycle is the fleet
# audit protocol, and the stored cause must agree with it at every tier.
merged_cause_rows() {
  local name tier group held parked route want gate_paused got
  while IFS='|' read -r name tier group held parked route want gate_paused; do
    new_case "merged-cause-$1-$name"
    printf standard > "$CASE/class"
    timeline 12420
    pauses KEN-1 "$held" "$parked"
    edit_json "$CASE/timeline.json" ".ci_merge_group_secs = $group | .merge_decision = $route"
    got="$(record KEN-1 "$tier")"
    assert_eq "$(field verdict "$got") $(field phase "$got") $(field phase_secs "$got") $(field cause "$got") $(field paused "$got")|$(state '.lanes[0].cycle.cause')" \
      "verdict=miss phase=merged phase_secs=$((12000 - group)) cause=$want paused=${gate_paused:-0}|\"$want\"" "merged cause: $name"
  done <<'ROWS'
standard CI|standard|7000|-|-|{"route":"admin","cause":"queue-bypass-safe"}|merge_group
small CI|small|7000|-|-|null|merge_group
micro CI|micro|7000|-|-|null|merge_group
standard hold|standard|0|500-7600|-|{"route":"queue","cause":"queue-required"}|paused
small hold|small|0|500-7600|-|null|paused
micro hold|micro|0|500-7600|-|null|paused
overlapping clipped holds|standard|0|0-300 400-2000 1500-7600|-|null|paused|180
standing park|standard|0|-|500|null|paused
CI ties remaining wait|standard|6000|-|-|null|merge_group
pause ties CI|standard|6000|420-6420|-|null|paused
queue decision|standard|0|-|-|{"route":"queue","cause":"queue-required"}|queue
admin decision|standard|0|-|-|{"route":"admin","cause":"queue-bypass-safe"}|admin
missing decision|standard|0|-|-|null|merged
ROWS
}
merged_cause_rows shipped
RUN_BIN=""

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
  assert_eq "$(field phase "$got") $(field cause "$got") $(field bot_wait "$got") $(field draft "$got") $(field thread_fix "$got") $(field paused "$got")" "$want" "$label"
done <<'ROWS'
a push waits on a bot, a review on the lane, and a wall comes out of the wait it fell in|100 1400|400 1500 2000|600-1000|-|3200|phase=gate_green cause=thread_fix bot_wait=380 draft=0 thread_fix=2100 paused=400
a wall over most of the gap is the cause|100 1400|400 1500 2000|400-2900|-|3200|phase=gate_green cause=paused bot_wait=280 draft=0 thread_fix=100 paused=2500
overlapping pauses count once and a standing park runs to the gate|100 1400|400 1500 2000|2400-2600|2500|3200|phase=gate_green cause=thread_fix bot_wait=380 draft=0 thread_fix=1900 paused=600
a review before the gap opens it on the lane|1400|110 1500|-|-|3200|phase=gate_green cause=thread_fix bot_wait=100 draft=0 thread_fix=2780 paused=0
no push and no review is all bot wait|-|-|-|-|3200|phase=gate_green cause=bot_wait bot_wait=2880 draft=0 thread_fix=0 paused=0
a fix pushed between two reviews and a rebase pushed after them are both bot waits|900 2500|400 2000|-|-|3200|phase=gate_green cause=bot_wait bot_wait=1880 draft=0 thread_fix=1000 paused=0
another phase is the miss's cause and keeps the split|100 1400|400 1500 2000|-|-|9000|phase=merged cause=merged bot_wait=380 draft=0 thread_fix=2500 paused=0
null push times split nothing and leave the miss its phase|null|400 1500 2000|-|-|3200|phase=gate_green cause=gate_green bot_wait=- draft=- thread_fix=- paused=-
ROWS
new_case split-admin-route
printf micro > "$CASE/class"
gate_timeline "100 1400" "400 1500 2000" 3200
edit_json "$CASE/timeline.json" '.stamps.armed = null'
got="$(record KEN-1 standard)"
assert_eq "$(field phase "$got") $(field cause "$got") $(field bot_wait "$got") $(field draft "$got") $(field thread_fix "$got") $(field missing "$got")" \
  "phase=gate_green cause=thread_fix bot_wait=380 draft=0 thread_fix=2500 missing=armed" \
  "an admin-route merge, never armed or queued, reads its phase and gate waits from the stamps it has"

new_case split-record
printf micro > "$CASE/class"
gate_timeline "100 1400" "400 1500 2000" 3200
pauses KEN-1 600-1000 -
record KEN-1 standard >/dev/null
assert_eq "$(state '.lanes[] | select(.item == "KEN-1") | .cycle | [.cause, .gate_waits]')" \
  '["thread_fix",{"bot_wait":380,"draft":0,"thread_fix":2100,"paused":400}]' "the lane record carries the cause and the gate waits"

echo "=== the ci_green phase names the larger part of its gap as its cause ==="
# ci_timeline PUSH [SPANS [CLEAN]]: a micro miss whose ci_green gap, gate 300
# to CI green at 4000, is the longest; armed 4100, merged 4200. PUSH is
# last_push in seconds past T0, `null` for none. SPANS are the final head's
# check runs as START-END pairs past T0, `null` for none read; one run from
# the push to CI green by default. CLEAN is ci_head_clean_secs, null by
# default.
ci_timeline() {
  timeline 4200 300 110
  edit_json "$CASE/timeline.json" ".ci_head_clean_secs = ${3:-null} | .stamps |= (.ci_green = \"$(at 4000)\" | .armed = \"$(at 4100)\"
    | .last_push = $(if [[ "$1" == null ]]; then echo null; else echo "\"$(at "$1")\""; fi))"
  jq --argjson t0 "$T0" --arg spans "${2:-$1-4000}" '.ci_head_spans = (if $spans == "null" then null
    else [$spans | split(" ")[] | split("-") | map($t0 + tonumber | todate) | {start: .[0], end: .[1]}] end)' \
    "$CASE/timeline.json" > "$CASE/t" && mv -- "$CASE/t" "$CASE/timeline.json"
}
#   label|last push|check spans|clean CI|cause
ci_cause_rows() {
  local label push spans clean want got
  while IFS='|' read -r label push spans clean want; do
    new_case "ci-$1-${label// /-}"
    printf micro > "$CASE/class"
    ci_timeline "$push" "$spans" "$clean"
    got="$(record KEN-1 micro)"
    assert_eq "$(field verdict "$got") $(field phase "$got") $(field cause "$got")" "verdict=miss phase=ci_green cause=$want" "ci cause: $label"
  done <<'ROWS'
rounds pushed after the PR opened are work|3500|3500-4000|null|work
one check run filling the gap after an early final push is ci|400|400-4000|null|ci
a final push before the gap opened leaves the gap to the checks|110|110-4000|null|ci
work wins a tie|2150|2150-4000|null|work
two short runs with a long idle gap between them are wait|400|400-546 3864-4000|136|wait
ci and wait tie to wait|300|300-2150|null|wait
a push after ci_green splits nothing and leaves the miss its phase|4050|4050-4100|null|ci_green
no last push splits nothing|null|300-4000|null|ci_green
no check spans read splits nothing|400|null|null|ci_green
ROWS
}
ci_cause_rows shipped

# Forgiven final-head CI cannot set the phase or its larger cause.
clean_phase_rows() {
  new_case "clean-phase-$1"
  printf micro > "$CASE/class"
  timeline 3500
  edit_json "$CASE/timeline.json" ".ci_head_clean_secs = 1800 | .stamps |= (.ci_green = \"$(at 2100)\" | .armed = \"$(at 2200)\")"
  got="$(record KEN-1 micro)"
  assert_eq "$(field lane "$got") $(field verdict "$got") $(field phase "$got") $(field phase_secs "$got") $(field cause "$got")" \
    'lane=1700 verdict=miss phase=merged phase_secs=1300 cause=merged' 'forgiven-CI phase: merge wait owns the remaining miss'
  new_case "clean-cause-$1"
  printf micro > "$CASE/class"; ci_timeline 1400
  edit_json "$CASE/timeline.json" '.ci_head_clean_secs = 1800'
  got="$(record KEN-1 micro)"
  assert_eq "$(field lane "$got") $(field phase "$got") $(field phase_secs "$got") $(field cause "$got")" \
    'lane=2400 phase=ci_green phase_secs=1900 cause=work' 'forgiven-CI cause: work exceeds the unforgiven final-head checks'
}
clean_phase_rows shipped
RUN_BIN=""

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
# conjunct has a row it alone decides.
#   m   a miss at 5000 s, its longest gap ending at merged
#   p   a miss whose CI went green at 700 s, before the PR opened at 2460 s,
#       so the longest gap before the PR opens is 1760 s from CI green to
#       the opening; pr_opened names the lane phase and repeated miss
#   a   a miss at 5000 s whose CI went green at 10000 s, after the merge,
#       a gap longer than any in the span; its phase is still merged
#   n   a miss with CI green absent, so no phase is named
#   ok  a met record at 800 s, its phase merged too
#   g   a miss on gate_green whose longest wait is the thread fix
#   w   the same miss with a wall over that wait
#   cw  a miss on ci_green whose final push came late in the gap: work
#   cc  a miss on ci_green whose final push came early in it: ci
#   cv  a miss on ci_green whose final push came early in it, with two short
#       check runs and a long idle gap between them: wait
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
      cf) timeline 3500
          edit_json "$CASE/timeline.json" ".ci_head_clean_secs = 1800 | .stamps |= (.ci_green = \"$(at 2100)\" | .armed = \"$(at 2200)\")" ;;
      a) timeline 5000; edit_json "$CASE/timeline.json" ".stamps.ci_green = \"$(at 10000)\" | .ci_head_spans = [{start: \"$(at 110)\", end: \"$(at 10000)\"}]" ;;
      n) timeline 5000; edit_json "$CASE/timeline.json" '.stamps.ci_green = null' ;;
      ok) timeline 800 ;;
      g) gate_timeline "100 1400" "400 1500 2000" 3200 ;;
      w) gate_timeline "100 1400" "400 1500 2000" 3200; pauses "$item" 400-2900 - ;;
      cw) ci_timeline 3500 ;;
      cc) ci_timeline 400 ;;
      cv) ci_timeline 400 "400-546 3864-4000" 136 ;;
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
pre-open|p:1 p:2 p:3|repeat-miss phase=pr_opened items=KEN-1,KEN-2,KEN-3 causes=pr_opened,pr_opened,pr_opened
forgiven-ci|cf:1 cf:2 cf:3|repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged
post-merge|a:1 a:2 a:3|repeat-miss phase=merged items=KEN-1,KEN-2,KEN-3 causes=merged,merged,merged
unnamed-phase|n:1 n:2 n:3|
recorded-again|m:1 m:2 m:3 m:3|
fourth|m:1 m:2 m:3 m:4|
causes|g:1 w:2 g:3|repeat-miss phase=gate_green items=KEN-1,KEN-2,KEN-3 causes=thread_fix,paused,thread_fix
ci-work|cw:1 cw:2 cw:3|
ci-slow|cw:1 cc:2 cc:3 cc:4|repeat-miss phase=ci_green items=KEN-2,KEN-3,KEN-4 causes=ci,ci,ci
ci-work-after|cc:1 cc:2 cc:3 cw:4|
ci-wait|cv:1 cv:2 cv:3|
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
want='rollup class=render items=1 median=30 p90=30 lane_median=- open_median=- miss_share=- misses=0 draft=- review=1 fix=2 bot=1 full_validations=1 rounds_unread=0 escaped=0 estimate_miss=0 path_miss=0 refixed=0 pr_rounds=- pr_rounds_unread=1 round_median=- fix_median=- rounds_untimed=0
rollup class=micro items=4 median=200 p90=1000 lane_median=- open_median=- miss_share=- misses=1 draft=- review=3 fix=6 bot=3 full_validations=3 rounds_unread=1 escaped=1 estimate_miss=0 path_miss=0 refixed=1 pr_rounds=1 pr_rounds_unread=1 round_median=500 fix_median=900 rounds_untimed=1
rollup class=standard items=1 median=6000 p90=6000 lane_median=- open_median=- miss_share=- misses=1 draft=- review=1 fix=2 bot=1 full_validations=1 rounds_unread=0 escaped=0 estimate_miss=0 path_miss=0 refixed=1 pr_rounds=2 pr_rounds_unread=0 round_median=900 fix_median=60 rounds_untimed=0
rollup class=unclassified items=1 median=50 p90=50 lane_median=- open_median=- miss_share=- misses=0 draft=- review=- fix=- bot=- full_validations=- rounds_unread=1 escaped=0 estimate_miss=0 path_miss=0 refixed=0 pr_rounds=- pr_rounds_unread=1 round_median=- fix_median=- rounds_untimed=0'
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

# Three records with different lane and open medians. Stale verdicts must
# not set the lane miss share; the rollup is the fleet audit's protocol.
cycle_medians() {
  new_case "medians-$1"
  jq -n '{lanes: [
    {item: "KEN-1", cycle: {class: "micro", actual: 3557, lane_secs: 1200, open: 3437, verdict: "miss"}},
    {item: "KEN-2", cycle: {class: "micro", actual: 8899, lane_secs: 6536, open: 8779, verdict: "met"}},
    {item: "KEN-3", cycle: {class: "micro", actual: 2500, lane_secs: 900, open: 2380, verdict: "miss"}}
  ], fleet_log: []}' > "$CASE/state/workflow-state-oversee.json"
  got="$(rollup)"
  assert_eq "$(field lane_median "$got") $(field open_median "$got") $(field miss_share "$got")" \
    'lane_median=1200 open_median=3437 miss_share=1/3' 'both medians and the lane miss fraction come from the cycle records'
}
cycle_medians shipped
RUN_BIN=""

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

# Counting the whole gap as checks must redden the ordinary CI-cause table.
control m-ci-running oversee-cycle \
  'covered_seconds([$t.ci_head_spans[] | {from: (.start | fromdate), to: (.end | fromdate)}]; $final; $to)' '($to - $final)'
if (FAIL=0; ci_cause_rows control; [[ "$FAIL" -eq 0 ]]) > "$TMP_ROOT/ci-running-control.out"; then
  fail 'ci cause: counting the whole gap after the push as checks did not redden the suite'
else
  assert_eq "$(grep -c '^  FAIL  ci cause: two short runs with a long idle gap between them are wait$' "$TMP_ROOT/ci-running-control.out")" "1" \
    "control: today's split reddens the idle-gap row"
fi
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
assert_eq "$(wc -l < "$CASE/evidence.calls" | tr -d ' ')" '1' "tier mismatch refuses before evidence read"
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
cp "$SF" "$CASE/stage-state.saved"
mv -- "$SF" "$REPO/tmp/workflow-state-pr-7.json"
assert_eq "$(stage_command KEN-1)" "$rows" 'lane PR key resolves when item key is absent'
record KEN-1 micro >/dev/null
assert_eq "$(state '.lanes[0].cycle.stages')" "$(jq -c '.stages' "$REPO/tmp/workflow-state-pr-7.json")" 'record shares PR fallback'

# The shipped SSH provider selects its target by the launched item. Only
# transport is local here; the dispatcher, provider and state reader are real.
stage_case_root="$CASE"
new_case hosted-pr-stages
printf micro > "$CASE/class"; timeline 1500
hosted_root="$CASE/remote/lane"
hosted_clone="$CASE/remote/clone"
hosted_provider="$TEST_DIR/../scripts/lane-host-ssh"
mkdir -p "$hosted_root/tmp" "$hosted_clone/lane-state" "$CASE/ssh-bin" "$CASE/home"
printf 'gitdir: %s/.git/worktrees/KEN-1\n' "$hosted_clone" > "$hosted_root/.git"
cp "$stage_case_root/stage-state.saved" "$hosted_root/tmp/workflow-state-pr-7.json"
# A previous item snapshot must not win before a live PR-key state.
mkdir -p "$hosted_clone/tmp/cycle-state"
printf '{"stages":[{"kind":"fix","round_id":"old","start":1,"end":2}]}' > "$hosted_clone/tmp/cycle-state/workflow-state-KEN-1.json"
jq -n --arg clone "$hosted_clone" --arg account "$CASE/account" \
  '[{repo:"vanillagreencom/kendex",item:"KEN-1",target:"lane.example",clone:$clone,account:$account}]' > "$CASE/hosts.json"
cat > "$CASE/ssh-bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$CASE/ssh.calls"
exec "$BASH" -c "${!#}"
SH
chmod +x "$CASE/ssh-bin/ssh"
edit_json "$CASE/state/workflow-state-oversee.json" \
  "(.lanes[] | select(.item == \"KEN-1\")) += {status: \"running\", tier: \"micro\", host: \"$hosted_provider\", mail_root: \"$hosted_root\", pending_pr: {pr: 7}}"
# Old watch sessions can disagree after a lane moves between clones. A live
# root or an explicit kept archive still binds the PR-key state without them.
mkdir -p "$REPO/tmp/oversee-watch"
printf 'clone-root\tKEN-1\t/old-clone\n' > "$REPO/tmp/oversee-watch/old-one.mail"
printf 'clone-root\tKEN-1\t/other-clone\n' > "$REPO/tmp/oversee-watch/old-two.mail"
for location in worktree clone-setting archive saved-archive; do
  case "$location" in
    clone-setting)
      mv -- "$hosted_root/tmp/workflow-state-pr-7.json" "$hosted_clone/lane-state/"
      printf '[env]\nORCH_STATE_DIR = "lane-state"\n' > "$hosted_root/kendex.settings.toml"
      ;;
    archive)
      # An older close archive has no recorded member. The requested file
      # key selects its PR state, while the host still probes KEN-1.
      tar -czf "$CASE/kept.tgz" -C "$hosted_clone" lane-state/workflow-state-pr-7.json
      edit_json "$CASE/state/workflow-state-oversee.json" \
        ".fleet_log += [{at: \"$(at 20)\", item: \"KEN-1\", text: \"kept=$CASE/kept.tgz\"}]"
      rm -rf -- "${hosted_root:?}"
      ;;
    saved-archive)
      # Execute the shipped producer's remote shell after real state removal.
      # Its empty live-state marker must still recover the saved PR key.
      git init -q "$hosted_clone"
      rm -- "$hosted_clone/tmp/cycle-state/workflow-state-KEN-1.json"
      printf '{"cycles":99}' > "$hosted_clone/tmp/cycle-state/workflow-state-KEN-other.json"
      mkdir -p "$hosted_clone/.agents/skills/orch"
      ln -s "$LAYOUT/orch/scripts" "$hosted_clone/.agents/skills/orch/scripts"
      cp -- "$hosted_clone/lane-state/workflow-state-pr-7.json" "$hosted_clone/tmp/cycle-state/workflow-state-pr-7.json"
      (cd "$hosted_clone" && "$LAYOUT/orch/scripts/workflow-state" --state-dir "$hosted_clone/lane-state" remove pr-7) >"$CASE/remove.out"
      env ORCH_STATE_DIR=lane-state python3 -I - "$hosted_provider" "$hosted_clone" "$hosted_root" >"$CASE/kept.tgz" <<'PY'
import ast, subprocess, sys
tree = ast.parse(open(sys.argv[1]).read())
function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "archive_tmp")
call = next(n for n in ast.walk(function) if isinstance(n, ast.Call)
            and isinstance(n.func, ast.Name) and n.func.id == "remote")
script = ast.literal_eval(call.args[1])
subprocess.run(["bash", "-c", script, "archive", sys.argv[2], sys.argv[3], "pr-7"],
               stdout=sys.stdout.buffer, check=True)
PY
      assert_eq "$(tar -xzOf "$CASE/kept.tgz" lane-host-state | wc -c | tr -d ' ')" 1 'the real archive producer leaves an empty live-state marker after removal'
      # Only the requested key is eligible when the manifest is empty.
      rm -- "$hosted_clone/tmp/cycle-state/workflow-state-pr-7.json"
      ;;
  esac
  got="$(HOME="$CASE/home" PATH="$CASE/ssh-bin:$PATH" LANE_HOST_SSH_INVENTORY="$CASE/hosts.json" stage_command KEN-1)"
  assert_eq "$got" "$rows" "hosted PR-key stages from $location keep the launched item identity"
  HOME="$CASE/home" PATH="$CASE/ssh-bin:$PATH" LANE_HOST_SSH_INVENTORY="$CASE/hosts.json" record KEN-1 micro >/dev/null
  assert_eq "$(state '.lanes[0].cycle.stages')" "$(jq -c '.stages' "$stage_case_root/stage-state.saved")" \
    "hosted PR-key cycle from $location records the same stages"
  if [[ "$location" == saved-archive ]]; then
    assert_eq "$(state '.lanes[0].cycle.rounds | [.review,.fix,.bot,.full_validations] | all(type == "number")')" true 'saved archive recovery records numeric cycle counts'
    mkdir -p "$CASE/clone-root-scratch"
    got="$(source "$TEST_DIR/../scripts/lib/lane-gitfile.sh"
      lane_archived_state pr-7 "$CASE/kept.tgz" "$CASE/clone-root-scratch" "$hosted_clone"
      jq -c '.stages' <<<"$LANE_ITEM_STATE")"
    assert_eq "$got" "$(jq -c '.stages' "$stage_case_root/stage-state.saved")" 'a clone root keeps its saved archive member eligible'
    cp -p "$TEST_DIR/../scripts/lib/lane-gitfile.sh" "$TMP_ROOT/no-archive-saved-read.sh"
    mutate_file "$TMP_ROOT/no-archive-saved-read.sh" \
      '            if not raw:' \
      $'            if not raw:\n                sys.exit(0)'
    rm -- "$LAYOUT/orch/scripts/lib/lane-gitfile.sh"
    cp -p "$TMP_ROOT/no-archive-saved-read.sh" "$LAYOUT/orch/scripts/lib/lane-gitfile.sh"
    HOME="$CASE/home" PATH="$CASE/ssh-bin:$PATH" LANE_HOST_SSH_INVENTORY="$CASE/hosts.json" record KEN-1 micro >/dev/null
    assert_eq "$(state '.lanes[0].cycle.rounds')" null 'control: skipping saved archive recovery restores null rounds'
    assert_file_contains "$CASE/err" 'oversee-cycle: rounds-unread item=KEN-1' 'control: empty archive recovery reports unread rounds'
    rm -- "$LAYOUT/orch/scripts/lib/lane-gitfile.sh"
    ln -s "$TEST_DIR/../scripts/lib/lane-gitfile.sh" "$LAYOUT/orch/scripts/lib/lane-gitfile.sh"
  fi
done
rm -- "$REPO/tmp/oversee-watch/old-one.mail" "$REPO/tmp/oversee-watch/old-two.mail"
CASE="$stage_case_root"
export CASE
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
rm -- "$SF"
cloud_case stages-cloud null
rc=0; stage_command KEN-1 > "$CASE/out" 2> "$CASE/err" || rc=$?
assert_eq "$rc|$(cat "$CASE/err")" '1|oversee-cycle: stages-unread item=KEN-1 cause=no-state' 'files=none has no readable stages'
echo "pass: $PASS  fail: $FAIL"
[[ "$FAIL" -eq 0 ]]
