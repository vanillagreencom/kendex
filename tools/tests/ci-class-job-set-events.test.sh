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
# call or without: the nightly run (its schedule and its manual dispatch)
# runs its fixed jobs with no selection, and a selection asked for one would
# stand lanes down on no diff. The main push takes the push route below.
# ARGUMENT|EVENT|EXPECTED
refused_rows=0
while IFS='|' read -r arg event expected; do
  refused_rows=$((refused_rows + 1))
  check "the ${event:-unset} event is refused, called with ${arg:-no argument}" "$expected" \
    "$(SELECT_ARG="$arg" SELECT_EVENT="$event" selection micro false skills/orch/SKILL.md)"
done <<ROWS
|schedule|exit=2 unsupported-event event=schedule
|workflow_dispatch|exit=2 unsupported-event event=workflow_dispatch
--event-parity|schedule|exit=2 unsupported-event event=schedule
||exit=2 unsupported-event event=
ROWS
[ "$refused_rows" -eq 4 ] || { echo "the refused-event table read $refused_rows rows" >&2; exit 1; }
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

# THE PUSH ROUTE: a main push owes the shards its same-head merge group did
# not prove. A stub on PATH answers `gh api` from a world directory built out
# of the recorded responses in data/: merge-group run 41306604685 and its
# latest jobs, on the head main pushed next. Each world varies them as one
# GitHub state would.
DATA="$TEST_DIR/data"
PUSH_SHA="$(jq -er '.workflow_runs[0].head_sha' "$DATA/main-proof-runs.json")"
PUSH_RUN="$(jq -er '.workflow_runs[0].id' "$DATA/main-proof-runs.json")"
mkdir -p "$TMP/gh-stub"
cat >"$TMP/gh-stub/gh" <<'STUB'
#!/usr/bin/env bash
# `gh api --paginate URL`, served from GH_WORLD; a `fail` file there is an
# API outage, and a URL the world has no response for is GitHub's 404.
set -eu
[ "$#" -eq 3 ] && [ "$1 $2" = "api --paginate" ] || { echo "gh-stub: args=$*" >&2; exit 64; }
[ ! -e "$GH_WORLD/fail" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
case "$3" in
  repos/*/actions/workflows/skill-tests.yml/runs\?*) file=runs.json ;;
  repos/*/actions/runs/*/jobs\?*) id="${3#repos/*/actions/runs/}"; file="jobs-${id%%/*}.json" ;;
  *) echo "gh-stub: url=$3" >&2; exit 64 ;;
esac
[ -f "$GH_WORLD/$file" ] || { echo 'gh: HTTP 404' >&2; exit 1; }
cat "$GH_WORLD/$file"
STUB
chmod +x "$TMP/gh-stub/gh"
# One world per GitHub state: runs.json, and jobs-<run>.json per run.
push_world() { # NAME
  local dir="$TMP/push/$1" runs="$DATA/main-proof-runs.json" jobs="$DATA/main-proof-jobs.json"
  local second=$((PUSH_RUN + 1))
  mkdir -p "$dir"
  cp "$runs" "$dir/runs.json"
  cp "$jobs" "$dir/jobs-$PUSH_RUN.json"
  edit_jobs() { jq "$1" "$jobs" >"$dir/jobs-$PUSH_RUN.json"; }
  case "$1" in
    all-proved) ;;
    subset)
      edit_jobs '.jobs |= map(select(.name | test("^Skill suites shard \\((linear|rest), |^Skill suites shard \\(node, ubuntu") | not))' ;;
    macos-only) edit_jobs '.jobs |= map(select(.name | endswith(", ubuntu-latest)") | not))' ;;
    no-shard-selected) edit_jobs '.jobs |= map(select(.name | test("^Skill suites shard \\([a-z]") | not))' ;;
    no-run) printf '{"total_count":0,"workflow_runs":[]}\n' >"$dir/runs.json" ;;
    outage) : >"$dir/fail" ;;
    unparseable) printf 'upstream connect error\n' >"$dir/runs.json" ;;
    jobs-missing) rm "$dir/jobs-$PUSH_RUN.json" ;;
    in-progress)
      edit_jobs '.jobs |= map(if .name == "Skill suites shard (guards-scans, ubuntu-latest)" then .status = "in_progress" | .conclusion = null else . end)' ;;
    failed-second-run)
      jq --argjson id "$second" '.workflow_runs += [.workflow_runs[0] | .id = $id | .run_attempt = 1]' "$runs" >"$dir/runs.json"
      jq --argjson id "$second" '.jobs |= map(.run_id = $id | if .name == "Skill suites shard (worktree, ubuntu-latest)" then .conclusion = "failure" else . end)' \
        "$jobs" >"$dir/jobs-$second.json" ;;
    foreign-head-job)
      edit_jobs '.jobs |= map(if .name == "Skill suites shard (mailbox, macos-latest)" then .head_sha = "0000000000000000000000000000000000000000" else . end)' ;;
    foreign-run-job)
      edit_jobs '.jobs |= map(if .name == "Skill suites shard (slack, ubuntu-latest)" then .run_id = 1 else . end)' ;;
    foreign-head-run) jq '.workflow_runs[0].head_sha = "0000000000000000000000000000000000000000"' "$runs" >"$dir/runs.json" ;;
    push-event-run) jq '.workflow_runs[0].event = "push"' "$runs" >"$dir/runs.json" ;;
    other-workflow-run) jq '.workflow_runs[0].path = ".github/workflows/lock-record.yml"' "$runs" >"$dir/runs.json" ;;
    *) echo "no push world named $1" >&2; exit 1 ;;
  esac
}
# `shards=… queue_macos_shards=… main-proof=… proved-linux=… proved-macos=…
# warned=yes|no`, with the step's empty class inputs, or `exit=N`.
push_select() { # WORLD [SELECTOR]
  local out="$TMP/push-out" status=0
  : >"$out"
  (cd "$ROOT" && PATH="$TMP/gh-stub:$PATH" GH_WORLD="$TMP/push/$1" GITHUB_REPOSITORY=vanillagreencom/kendex \
    GITHUB_SHA="$PUSH_SHA" EVENT=push CHANGE_CLASS='' DOCS_ONLY='' CHANGED_PATHS='' GITHUB_OUTPUT="$out" \
    "${2:-$JOB_SET}" --event-parity >"$TMP/push-stdout" 2>"$TMP/push-err") || status=$?
  [ "$status" -eq 0 ] || { printf 'exit=%s' "$status"; return 0; }
  printf '%s %s warned=%s' "$(tr '\n' ' ' <"$out" | sed 's/ $//')" \
    "$(sed -n 's/^ci-job-set: \(main-proof=[a-z]*\) runs=[^ ]* \(proved-linux=[0-9]* proved-macos=[0-9]*\).*/\1 \2/p' "$TMP/push-err")" \
    "$(grep -q '^::warning ' "$TMP/push-stdout" && echo yes || echo no)"
}
NO_SHARDS="shell_shards=false shell_os=[] shards=[] queue_macos_shards=[]"
ALL_SHARDS='shell_shards=true shell_os=["ubuntu-latest","macos-latest"] '"shards=$ROSTER queue_macos_shards=$QUEUE_ALL"
QUEUE_N="$(jq length <<<"$QUEUE_ALL")"
ROSTER_N="$(jq length <<<"$ROSTER")"
UNREAD="main-proof=unread proved-linux=0 proved-macos=0 warned=yes"
NO_RUN="main-proof=none proved-linux=0 proved-macos=0 warned=yes"
# WORLD|EXPECTED. A shard counts only where every same-head merge-group leg
# on its runner succeeded; any read that fails runs the whole roster.
push_rows=0
while IFS='|' read -r world expected; do
  push_rows=$((push_rows + 1))
  push_world "$world"
  check "push route: $world" "$expected" "$(push_select "$world")"
done <<ROWS
all-proved|$NO_SHARDS main-proof=read proved-linux=$ROSTER_N proved-macos=$QUEUE_N warned=no
subset|shell_shards=true shell_os=["ubuntu-latest","macos-latest"] shards=["linear","rest","node"] queue_macos_shards=["linear","rest"] main-proof=read proved-linux=$((ROSTER_N - 3)) proved-macos=$((QUEUE_N - 2)) warned=no
macos-only|shell_shards=true shell_os=["ubuntu-latest"] shards=$ROSTER queue_macos_shards=[] main-proof=read proved-linux=0 proved-macos=$QUEUE_N warned=no
no-shard-selected|$ALL_SHARDS main-proof=read proved-linux=0 proved-macos=0 warned=no
in-progress|shell_shards=true shell_os=["ubuntu-latest"] shards=["guards-scans"] queue_macos_shards=[] main-proof=read proved-linux=$((ROSTER_N - 1)) proved-macos=$QUEUE_N warned=no
failed-second-run|shell_shards=true shell_os=["ubuntu-latest"] shards=["worktree"] queue_macos_shards=[] main-proof=read proved-linux=$((ROSTER_N - 1)) proved-macos=$QUEUE_N warned=no
foreign-head-job|shell_shards=true shell_os=["macos-latest"] shards=[] queue_macos_shards=["mailbox"] main-proof=read proved-linux=$ROSTER_N proved-macos=$((QUEUE_N - 1)) warned=no
foreign-run-job|shell_shards=true shell_os=["ubuntu-latest"] shards=["slack"] queue_macos_shards=[] main-proof=read proved-linux=$((ROSTER_N - 1)) proved-macos=$QUEUE_N warned=no
no-run|$ALL_SHARDS $NO_RUN
foreign-head-run|$ALL_SHARDS $NO_RUN
push-event-run|$ALL_SHARDS $NO_RUN
other-workflow-run|$ALL_SHARDS $NO_RUN
outage|$ALL_SHARDS $UNREAD
unparseable|$ALL_SHARDS $UNREAD
jobs-missing|$ALL_SHARDS $UNREAD
ROWS
[ "$push_rows" -eq 15 ] || { echo "the push table read $push_rows rows" >&2; exit 1; }

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
