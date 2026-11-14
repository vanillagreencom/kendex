#!/usr/bin/env bash
# Tests for CI event selection and platform parity.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

# An event the workflow does not classify on is refused, with the parity
# call or without: a manual dispatch runs the nightly jobs whole with no
# selection, and a selection asked for one would stand lanes down on no
# diff. The main push and the schedule take the proof routes below.
# ARGUMENT|EVENT|EXPECTED
refused_rows=0
while IFS='|' read -r arg event expected; do
  refused_rows=$((refused_rows + 1))
  check "the ${event:-unset} event is refused, called with ${arg:-no argument}" "$expected" \
    "$(SELECT_ARG="$arg" SELECT_EVENT="$event" selection micro false skills/orch/SKILL.md)"
done <<ROWS
|workflow_dispatch|exit=2 unsupported-event event=workflow_dispatch
--event-parity|workflow_dispatch|exit=2 unsupported-event event=workflow_dispatch
||exit=2 unsupported-event event=
ROWS
[ "$refused_rows" -eq 3 ] || { echo "the refused-event table read $refused_rows rows" >&2; exit 1; }
# The macOS legs run wherever a shard and a platform lane run, on the pull
# request as in the merge group.
# EVENT|PATHS|LEGS
leg_rows=0
while IFS='|' read -r event paths expected; do
  leg_rows=$((leg_rows + 1))
  check "the $event legs over '$paths'" "$expected" \
    "$(SELECT_EVENT="$event" selection micro false "$(printf '%s\n' $paths)" | sed 's/.* shell_os=\(\[[^]]*\]\).*/\1/')"
done <<ROWS
pull_request|skills/orch/scripts/lanes|$BOTH
merge_group|skills/orch/scripts/lanes|$BOTH
pull_request|skills/orch/SKILL.md|$LINUX
merge_group|skills/orch/SKILL.md|$LINUX
pull_request|.github/AGENTS.md skills/orch/scripts/lanes|$BOTH
merge_group|.github/AGENTS.md skills/orch/scripts/lanes|$BOTH
pull_request|crates/core/src/lib.rs|$BOTH
merge_group|crates/core/src/lib.rs|$BOTH
ROWS
[ "$leg_rows" -eq 8 ] || { echo "the legs table read $leg_rows rows" >&2; exit 1; }
# Event parity: a copy that plants the macOS legs on the merge group alone is
# refused by the --event-parity call on either event. A call without the flag
# derives its one event alone, so the same copy answers it.
# ARGUMENT|EVENT|EXPECTED; an argument other than --event-parity is refused.
mkdir -p "$TMP/parity/tools"
cp -R "$ROOT/tools/lib" "$TMP/parity/tools/lib"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/parity/tools/"
cp "$ROOT/tools/rust-reads" "$TMP/parity/tools/rust-reads"
sed 's/^      macos_shard "\$shards" || macos=false$/&; [ "$event" = merge_group ] || macos=false/' \
  "$JOB_SET" >"$TMP/parity/tools/ci-job-set"
chmod +x "$TMP/parity/tools/ci-job-set"
[ "$(grep -c 'macos=false; \[ "\$event" = merge_group \] || macos=false$' "$TMP/parity/tools/ci-job-set")" -eq 1 ] ||
  { echo "the event gate was not planted in the ci-job-set copy" >&2; exit 1; }
parity_rows=0
while IFS='|' read -r arg event expected; do
  parity_rows=$((parity_rows + 1))
  check "a macOS leg the merge group alone selects, called with ${arg:-no argument} on $event" "$expected" \
    "$(SELECT_WITH="$TMP/parity/tools/ci-job-set" SELECT_ARG="$arg" SELECT_EVENT="$event" selection micro false skills/orch/scripts/lanes | sed 's/.* shell_os=\(\[[^]]*\]\).*/\1/')"
done <<ROWS
--event-parity|pull_request|exit=2 event-parity event=merge_group
--event-parity|merge_group|exit=2 event-parity event=pull_request
|pull_request|$LINUX
|merge_group|$BOTH
--parity|pull_request|exit=2 unknown-argument value=--parity
ROWS
[ "$parity_rows" -eq 5 ] || { echo "the parity table read $parity_rows rows" >&2; exit 1; }
check "this tree's selection passes the --event-parity call unchanged" \
  "$(selection micro false skills/orch/scripts/lanes)" \
  "$(SELECT_ARG=--event-parity selection micro false skills/orch/scripts/lanes)"

# An Ubuntu lane that differs by event is refused too.
sed 's/^  row="\$class"$/  row="$class"; linux_integration=true; [ "$event" != merge_group ] || linux_integration=false/; s/cargo_linux=true/cargo_linux=$linux_integration/g' "$JOB_SET" >"$TMP/parity/tools/ci-job-set"
! cmp -s "$JOB_SET" "$TMP/parity/tools/ci-job-set" || exit 1
for event in pull_request merge_group; do
  other=merge_group
  [ "$event" != merge_group ] || other=pull_request
  check "Ubuntu event parity on $event" "exit=2 event-parity event=$other" \
    "$(SELECT_WITH="$TMP/parity/tools/ci-job-set" SELECT_ARG=--event-parity SELECT_EVENT="$event" selection micro false skills/orch/scripts/lanes)"
done

# THE PUBLISHED SELECTION: where CI_SELECTION names a file, a class
# selection writes there the skips and targets it emits, the one record the
# push at the group's head reads.
written="$(CI_SELECTION="$TMP/written.json" selection micro false skills/orch/scripts/lanes)"
check "a class selection writes its skips and targets to CI_SELECTION" \
  "$(jq -cn --argjson s "$(sed -n 's/.* skipped_suites=\([^ ]*\).*/\1/p' <<<"$written")" \
    --argjson r "$(sed -n 's/.* rust_targets=\([^ ]*\).*/\1/p' <<<"$written")" '{skipped_suites: $s, rust_targets: $r}')" \
  "$(jq -c . "$TMP/written.json" 2>/dev/null || echo unwritten)"

# THE PUSH ROUTE: a main push owes, on each runner, the suites and Rust
# targets its same-head merge group did not prove. A stub on PATH answers
# `gh api` from a world directory built out of the recorded responses in
# data/: merge-group run 41306604685 and its latest jobs, on the head main
# pushed next, with the selection that run published planted as its
# artifact. Each world varies them as one GitHub state would.
DATA="$TEST_DIR/data"
PUSH_SHA="$(jq -er '.workflow_runs[0].head_sha' "$DATA/main-proof-runs.json")"
PUSH_RUN="$(jq -er '.workflow_runs[0].id' "$DATA/main-proof-runs.json")"
mkdir -p "$TMP/gh-stub"
cat >"$TMP/gh-stub/gh" <<'STUB'
#!/usr/bin/env bash
# `gh api --paginate URL` for a listing and `gh api URL` for an artifact's
# zip, served from GH_WORLD; a `fail` file there is an API outage, and a URL
# the world has no response for is GitHub's 404.
set -eu
case "$#:${1-}:${2-}" in
  3:api:--paginate) url=$3 ;;
  2:api:*) url=$2 ;;
  *) echo "gh-stub: args=$*" >&2; exit 64 ;;
esac
[ ! -e "$GH_WORLD/fail" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
case "$#:$url" in
  3:repos/*/actions/workflows/skill-tests.yml/runs\?event=push\&*) file=push-runs.json ;;
  3:repos/*/actions/workflows/skill-tests.yml/runs\?*) file=runs.json ;;
  3:repos/*/actions/runs/*/jobs\?*) id="${url#repos/*/actions/runs/}"; file="jobs-${id%%/*}.json" ;;
  3:repos/*/actions/runs/*/artifacts\?*) id="${url#repos/*/actions/runs/}"; file="artifacts-${id%%/*}.json" ;;
  2:repos/*/actions/artifacts/*/zip) id="${url#repos/*/actions/artifacts/}"; file="zip-${id%%/*}" ;;
  *) echo "gh-stub: url=$url" >&2; exit 64 ;;
esac
[ -f "$GH_WORLD/$file" ] || { echo 'gh: HTTP 404' >&2; exit 1; }
cat "$GH_WORLD/$file"
STUB
chmod +x "$TMP/gh-stub/gh"
# The recording gives the job shape and the non-shard jobs. The shard legs
# are one recorded leg cloned per roster shard and runner, so a roster or
# eligibility change edits no recorded data.
jq -e --argjson linux "$ROSTER" --argjson macos "$QUEUE_ALL" '
  ([.jobs[] | select(.name | startswith("Skill suites shard ("))][0] // error("no recorded shard leg")) as $leg
  | .jobs = [.jobs[] | select(.name | startswith("Skill suites shard (") | not)]
    + [($linux[] | [., "ubuntu-latest"]), ($macos[] | [., "macos-latest"])
       | $leg + {name: "Skill suites shard (\(.[0]), \(.[1]))"}]' \
  "$DATA/main-proof-jobs.json" >"$TMP/push-jobs.json" ||
  { echo "the recorded jobs gave no shard leg to clone" >&2; exit 1; }
EVERY_TARGET='["agent-runtime/*","orch/*"]'
# The selection a run published, as tools/ci-job-set writes CI_SELECTION,
# zipped as GitHub serves an artifact, and the run's listing of it.
plant_selection() { # DIR RUN SKIPPED RUST [EXPIRED]
  local artifact=$(($2 + 1000))
  jq -cn --argjson run "$2" --argjson id "$artifact" --argjson expired "${5:-false}" '
    {total_count: 1, artifacts: [{id: $id, name: "ci-selection", expired: $expired,
      created_at: "2026-11-13T09:00:00Z", workflow_run: {id: $run}}]}' >"$1/artifacts-$2.json"
  python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("ci-selection.json", sys.argv[2])' "$1/zip-$artifact" "{\"skipped_suites\":$3,\"rust_targets\":$4}"
}
# One world per GitHub state: runs.json, and per run jobs-<run>.json,
# artifacts-<run>.json and the artifact's zip.
push_world() { # NAME
  local dir="$TMP/push/$1" runs="$DATA/main-proof-runs.json" jobs="$TMP/push-jobs.json"
  local second=$((PUSH_RUN + 1))
  mkdir -p "$dir"
  cp "$runs" "$dir/runs.json"
  cp "$jobs" "$dir/jobs-$PUSH_RUN.json"
  plant_selection "$dir" "$PUSH_RUN" '[]' "$EVERY_TARGET"
  edit_jobs() { jq "$1" "$jobs" >"$dir/jobs-$PUSH_RUN.json"; }
  fail_leg() { edit_jobs ".jobs |= map(if .name == \"Skill suites shard ($1)\" then .conclusion = \"failure\" else . end)"; }
  case "$1" in
    all-proved) ;;
    # A leg whose list left a suite out proves the suites it kept.
    kept-subset) plant_selection "$dir" "$PUSH_RUN" "[\"$P_TOOLS\"]" "$EVERY_TARGET" ;;
    red-leg) fail_leg 'guards-tools, ubuntu-latest' ;;
    linux-only) edit_jobs '.jobs |= map(select(.name | endswith(", macos-latest)") | not))' ;;
    no-shard-selected) edit_jobs '.jobs |= map(select(.name | test("^Skill suites shard \\([a-z]") | not))' ;;
    in-progress)
      edit_jobs '.jobs |= map(if .name == "Skill suites shard (guards-scans, ubuntu-latest)" then .status = "in_progress" | .conclusion = null else . end)' ;;
    failed-second-run)
      jq --argjson id "$second" '.workflow_runs += [.workflow_runs[0] | .id = $id | .run_attempt = 1]' "$runs" >"$dir/runs.json"
      jq --argjson id "$second" '.jobs |= map(.run_id = $id | if .name == "Skill suites shard (worktree, ubuntu-latest)" then .conclusion = "failure" else . end)' \
        "$jobs" >"$dir/jobs-$second.json"
      plant_selection "$dir" "$second" '[]' "$EVERY_TARGET" ;;
    foreign-head-job)
      edit_jobs '.jobs |= map(if .name == "Skill suites shard (mailbox, macos-latest)" then .head_sha = "0000000000000000000000000000000000000000" else . end)' ;;
    foreign-run-job)
      edit_jobs '.jobs |= map(if .name == "Skill suites shard (slack, ubuntu-latest)" then .run_id = 1 else . end)' ;;
    # A shard proved with only some of its Rust targets owes the rest.
    one-target) plant_selection "$dir" "$PUSH_RUN" '[]' '["orch/lib"]' ;;
    red-orch-rest) fail_leg 'orch-rest, ubuntu-latest' ;;
    no-selection) rm "$dir/artifacts-$PUSH_RUN.json" ;;
    expired-selection) plant_selection "$dir" "$PUSH_RUN" '[]' "$EVERY_TARGET" true ;;
    bad-selection) plant_selection "$dir" "$PUSH_RUN" '[]' '"orch/*"' ;;
    no-run) printf '{"total_count":0,"workflow_runs":[]}\n' >"$dir/runs.json" ;;
    outage) : >"$dir/fail" ;;
    unparseable) printf 'upstream connect error\n' >"$dir/runs.json" ;;
    jobs-missing) rm "$dir/jobs-$PUSH_RUN.json" ;;
    foreign-head-run) jq '.workflow_runs[0].head_sha = "0000000000000000000000000000000000000000"' "$runs" >"$dir/runs.json" ;;
    push-event-run) jq '.workflow_runs[0].event = "push"' "$runs" >"$dir/runs.json" ;;
    other-workflow-run) jq '.workflow_runs[0].path = ".github/workflows/lock-record.yml"' "$runs" >"$dir/runs.json" ;;
    *) echo "no push world named $1" >&2; exit 1 ;;
  esac
}
# `shards=… queue_macos_shards=… rust_targets=… skips=<linux>/<macos>
# main-proof=… warned=yes|no`, with the step's empty class inputs, or
# `exit=N`; the output stays in push-out for in_list.
push_select() { # WORLD [SELECTOR]
  local out="$TMP/push-out" status=0
  : >"$out"
  (cd "$ROOT" && PATH="$TMP/gh-stub:$PATH" GH_WORLD="$TMP/push/$1" GITHUB_REPOSITORY=vanillagreencom/kendex \
    GITHUB_SHA="$PUSH_SHA" EVENT=push CHANGE_CLASS='' DOCS_ONLY='' CHANGED_PATHS='' GITHUB_OUTPUT="$out" \
    "${2:-$JOB_SET}" --event-parity >"$TMP/push-stdout" 2>"$TMP/push-err") || status=$?
  [ "$status" -eq 0 ] || { printf 'exit=%s' "$status"; return 0; }
  printf 'shards=%s queue_macos_shards=%s rust_targets=%s skips=%s/%s %s warned=%s' \
    "$(field shards <"$out")" "$(field queue_macos_shards <"$out")" "$(field rust_targets <"$out")" \
    "$(field skipped_suites <"$out" | jq length)" "$(field skipped_suites_macos <"$out" | jq length)" \
    "$(sed -n 's/^ci-job-set: \(main-proof=[a-z]*\) .*/\1/p' "$TMP/push-err")" \
    "$(grep -q '^::warning ' "$TMP/push-stdout" && echo yes || echo no)"
}
field() { # NAME — the value of the NAME= line on stdin
  sed -n "s/^$1=//p"
}
in_list() { # NAME MEMBER — whether the last push output's NAME list holds MEMBER
  field "$1" <"$TMP/push-out" | jq --arg m "$2" 'index($m) != null'
}
# The probes and the counts each row's expectation is made of.
P_TOOLS=tools/tests/ci-skill-prose.test.sh
P_JARVIS=skills/jarvis/tests/task.test.sh
UNIVERSE="$(cd "$ROOT" && git ls-files -- ':(glob)skills/*/tests/*.sh' ':(glob)skills/*/tests/*.test.mjs' \
  ':(glob)tools/tests/*.sh' ':(glob)hooks/tests/*.sh' ':(glob)refresh/tests/*.sh' | grep -v '/run-all\.sh$')"
count() { # PREFIX — the universe suites under PREFIX
  grep -c "^$1" <<<"$UNIVERSE" || true
}
U="$(count '')"
N_TOOLS="$(count tools/tests/)"
N_JARVIS="$(count skills/jarvis/tests/)"
N_WORKTREE="$(count skills/worktree/tests/)"
N_MAILBOX="$(count skills/mailbox/tests/)"
N_SLACK="$(count skills/slack/tests/)"
N_ORCH_REST="$(cd "$ROOT" && grep '^skills/orch/tests/' <<<"$UNIVERSE" | RUNNER_OS=Linux bash skills/orch/tests/run-all.sh --shard-of 2>/dev/null | grep -c '^orch-rest ')"
WHOLE="shards=$ROSTER queue_macos_shards=$QUEUE_ALL rust_targets=$EVERY_TARGET skips=0/0"
UNREAD="main-proof=unread warned=yes"
NO_RUN="main-proof=none warned=yes"
# The all-proved world first: its macOS count is every macOS-placed suite,
# which each later row's expectation subtracts from.
push_world all-proved
got="$(push_select all-proved)"
M="$(sed -n 's/.* skips=[0-9]*\/\([0-9]*\) .*/\1/p' <<<"$got")"
check "push route: all-proved" "shards=[] queue_macos_shards=[] rust_targets=[] skips=$U/$M main-proof=read warned=no" "$got"
check "push route: all-proved places suites on macOS" true "$([ "${M:-0}" -gt 0 ] && echo true || echo false)"
# WORLD|EXPECTED. A suite counts only where no selection left it out and
# every same-head leg that runs it on its runner succeeded; a target only
# where every selection listed it and the orch-rest Linux leg succeeded; any
# read that fails runs the whole roster.
push_rows=0
while IFS='|' read -r world expected; do
  push_rows=$((push_rows + 1))
  push_world "$world"
  check "push route: $world" "$expected" "$(push_select "$world")"
done <<ROWS
kept-subset|shards=["guards-tools","guards-tools-tail"] queue_macos_shards=["guards-tools"] rust_targets=[] skips=$((U - 1))/$((M - 1)) main-proof=read warned=no
red-leg|shards=["guards-hooks","guards-tools","guards-tools-tail","rest","jarvis"] queue_macos_shards=[] rust_targets=[] skips=$((U - N_TOOLS - N_JARVIS))/$M main-proof=read warned=no
linux-only|shards=[] queue_macos_shards=$QUEUE_ALL rust_targets=[] skips=$U/0 main-proof=read warned=no
no-shard-selected|$WHOLE main-proof=read warned=no
in-progress|shards=["guards-scans"] queue_macos_shards=[] rust_targets=[] skips=$U/$M main-proof=read warned=no
failed-second-run|shards=["worktree","worktree-restack"] queue_macos_shards=[] rust_targets=[] skips=$((U - N_WORKTREE))/$M main-proof=read warned=no
foreign-head-job|shards=[] queue_macos_shards=["mailbox"] rust_targets=[] skips=$U/$((M - N_MAILBOX)) main-proof=read warned=no
foreign-run-job|shards=["slack"] queue_macos_shards=[] rust_targets=[] skips=$((U - N_SLACK))/$M main-proof=read warned=no
red-orch-rest|shards=["orch-rest"] queue_macos_shards=[] rust_targets=$EVERY_TARGET skips=$((U - N_ORCH_REST))/$M main-proof=read warned=no
no-selection|$WHOLE $UNREAD
expired-selection|$WHOLE $UNREAD
bad-selection|$WHOLE $UNREAD
no-run|$WHOLE $NO_RUN
foreign-head-run|$WHOLE $NO_RUN
push-event-run|$WHOLE $NO_RUN
other-workflow-run|$WHOLE $NO_RUN
outage|$WHOLE $UNREAD
unparseable|$WHOLE $UNREAD
jobs-missing|$WHOLE $UNREAD
ROWS
[ "$push_rows" -eq 19 ] || { echo "the push table read $push_rows rows" >&2; exit 1; }
# The probes: a red Linux leg owes its suites on Linux alone, and a group
# that left a suite out proves its every other suite.
push_select red-leg >/dev/null
check "push route: a red Linux leg owes its suite on Linux" false "$(in_list skipped_suites "$P_TOOLS")"
check "push route: and its macOS leg still proves it" true "$(in_list skipped_suites_macos "$P_TOOLS")"
check "push route: the red leg's other package owes its suites" false "$(in_list skipped_suites "$P_JARVIS")"
push_select kept-subset >/dev/null
check "push route: the suite the group left out is owed" false "$(in_list skipped_suites "$P_TOOLS")"
check "push route: the group's kept suites are proved" true "$(in_list skipped_suites tools/tests/ci-aggregate.test.sh)"
# The one-target world: the group ran orch/lib alone, so every other target
# of both runtimes runs on the push's orch-rest leg.
push_world one-target
check "push route: one-target" "shards=[\"orch-rest\"] queue_macos_shards=[] main-proof=read warned=no" \
  "$(push_select one-target | sed 's/ rust_targets=[^ ]* skips=[^ ]*//')"
check "push route: one-target leaves out the proved target" false "$(in_list rust_targets orch/lib)"
check "push route: one-target owes another orch target" true "$(in_list rust_targets orch/watch_reads)"
check "push route: one-target owes the other runtime whole" true "$(in_list rust_targets 'agent-runtime/*')"

# THE NIGHT ROUTE: the schedule runs again no leg a run at its head ran
# green. Each night world is a push world, the merge group run and its
# selection, beside push run PUSH_RUN + 2 at the same head, whose jobs are
# the same recorded set: every shard leg it owed and the cargo compile legs.
PUSH_PUSH=$((PUSH_RUN + 2))
night_world() { # NAME BASE-WORLD
  local dir="$TMP/push/$1" jobs="$TMP/push-jobs.json"
  rm -rf -- "$dir"
  push_world "$2"
  mv "$TMP/push/$2" "$dir"
  jq --argjson id "$PUSH_PUSH" '.workflow_runs[0] | {total_count: 1, workflow_runs: [.id = $id | .event = "push"]}' \
    "$DATA/main-proof-runs.json" >"$dir/push-runs.json"
  jq --argjson id "$PUSH_PUSH" '.jobs |= map(.run_id = $id)' "$jobs" >"$dir/jobs-$PUSH_PUSH.json"
  edit_push() { jq "$1" "$dir/jobs-$PUSH_PUSH.json" >"$dir/edited.json" && mv "$dir/edited.json" "$dir/jobs-$PUSH_PUSH.json"; }
  case "$1" in
    night-all-proved) ;;
    # The group left a suite out; the push's macOS leg ran it green.
    night-push-proves) ;;
    night-push-red) edit_push '.jobs |= map(if .name == "Skill suites shard (guards-tools, macos-latest)" then .conclusion = "failure" else . end)' ;;
    # A prose group ran no cargo test; the push compiled every lane.
    night-group-no-cargo)
      jq '.jobs |= map(select(.name | test("^(macOS cargo |Windows cargo \\(workspace|Cargo )") | not))' \
        "$jobs" >"$dir/jobs-$PUSH_RUN.json" ;;
    night-direct-push) printf '{"total_count":0,"workflow_runs":[]}\n' >"$dir/runs.json" ;;
    night-no-run)
      printf '{"total_count":0,"workflow_runs":[]}\n' >"$dir/runs.json"
      printf '{"total_count":0,"workflow_runs":[]}\n' >"$dir/push-runs.json" ;;
    night-outage) rm "$dir/push-runs.json" ;;
    *) echo "no night world named $1" >&2; exit 1 ;;
  esac
}
# `shards=… queue_macos_shards=… skips=<macos> cargo_linux=… cargo_macos=…
# cargo_windows=… cargo_windows_check=… night-proof=… warned=yes|no`.
night_select() { # WORLD
  local out="$TMP/push-out" status=0
  : >"$out"
  (cd "$ROOT" && PATH="$TMP/gh-stub:$PATH" GH_WORLD="$TMP/push/$1" GITHUB_REPOSITORY=vanillagreencom/kendex \
    GITHUB_SHA="$PUSH_SHA" EVENT=schedule CHANGE_CLASS='' DOCS_ONLY='' CHANGED_PATHS='' GITHUB_OUTPUT="$out" \
    "$JOB_SET" --event-parity >"$TMP/push-stdout" 2>"$TMP/push-err") || status=$?
  [ "$status" -eq 0 ] || { printf 'exit=%s' "$status"; return 0; }
  printf 'shards=%s queue_macos_shards=%s skips=%s' "$(field shards <"$out")" "$(field queue_macos_shards <"$out")" \
    "$(field skipped_suites_macos <"$out" | jq length)"
  for lane in cargo_linux cargo_macos cargo_windows cargo_windows_check; do
    printf ' %s=%s' "$lane" "$(field "$lane" <"$out")"
  done
  printf ' %s warned=%s' "$(sed -n 's/^ci-job-set: \(night-proof=[a-z]*\) .*/\1/p' "$TMP/push-err")" \
    "$(grep -q '^::warning ' "$TMP/push-stdout" && echo yes || echo no)"
}
NIGHT_PROVED="cargo_linux=false cargo_macos=false cargo_windows=false cargo_windows_check=false"
NIGHT_WHOLE="shards=[] queue_macos_shards=$QUEUE_ALL skips=0 cargo_linux=true cargo_macos=true cargo_windows=true cargo_windows_check=true"
# WORLD|BASE WORLD|EXPECTED
night_rows=0
while IFS='|' read -r world base expected; do
  night_rows=$((night_rows + 1))
  night_world "$world" "$base"
  check "night route: $world" "$expected" "$(night_select "$world")"
done <<ROWS
night-all-proved|all-proved|shards=[] queue_macos_shards=[] skips=$M $NIGHT_PROVED night-proof=read warned=no
night-push-proves|kept-subset|shards=[] queue_macos_shards=[] skips=$M $NIGHT_PROVED night-proof=read warned=no
night-push-red|kept-subset|shards=[] queue_macos_shards=["guards-tools"] skips=$((M - 1)) $NIGHT_PROVED night-proof=read warned=no
night-group-no-cargo|all-proved|shards=[] queue_macos_shards=[] skips=$M cargo_linux=false cargo_macos=true cargo_windows=true cargo_windows_check=false night-proof=read warned=no
night-direct-push|all-proved|shards=[] queue_macos_shards=[] skips=$M cargo_linux=false cargo_macos=true cargo_windows=true cargo_windows_check=false night-proof=read warned=no
night-no-run|all-proved|$NIGHT_WHOLE night-proof=none warned=yes
night-outage|all-proved|$NIGHT_WHOLE night-proof=unread warned=yes
ROWS
[ "$night_rows" -eq 7 ] || { echo "the night table read $night_rows rows" >&2; exit 1; }

# Control: a selector that trusts each job's head without checking it counts
# a foreign head's success as proof, so the foreign-head-job row fails.
mkdir -p "$TMP/trusting/tools"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/trusting/tools/"
awk '{ n += gsub(/select\(\.head_sha == \$sha and \.run_id == \$id\)/, "select(.run_id == $id)") } { print } END { exit n != 1 }' \
  "$JOB_SET" >"$TMP/trusting/tools/ci-job-set" ||
  { echo "the job head check is no longer one select in $JOB_SET" >&2; exit 1; }
chmod +x "$TMP/trusting/tools/ci-job-set"
case "$(push_select foreign-head-job "$TMP/trusting/tools/ci-job-set")" in
  *"queue_macos_shards=[] "*) ok "control: a selector skipping the job head check proves the foreign head's mailbox leg" ;;
  *) bad "control: the head-check mutant did not prove the foreign head's leg" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
