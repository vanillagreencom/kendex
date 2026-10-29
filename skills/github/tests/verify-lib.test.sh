#!/usr/bin/env bash
# verify-lib's run_stack under live errexit: a failing build or test command
# is recorded with its summary and raises its issue whatever its output is
# (larger than a pipe buffer, one line past MAX_ARG_STRLEN, or matching no
# summary pattern), and a passing one is recorded as such.
#
# Both failure branches once built their summary as
# `echo "$output" | grep -E ... | head -5 | tr`: head closed the pipe on its
# fifth line, SIGPIPEd grep, and pipefail made 141 the status of an unguarded
# assignment, so under errexit the branch died before recording anything.
# Each row runs run_stack with errexit LIVE and reads RESULTS_JSON out of an
# EXIT trap, which is what the summary must survive.
#
# A row is `label|command|stage|build|test|issues`:
#   command  a fixture (see command_of): `large` two thousand matching error
#            lines, `long-line` one matching line past MAX_ARG_STRLEN,
#            `quiet` a failure matching no pattern, `pass` success
#   stage    where the stack spec runs it: `build`, `test`, or `both`
#   build    `.builds.rust`: `-` when never recorded, `ok`, or
#            `fail:<summary length>:<its first 72 characters>`; a success
#            that is neither true nor false renders as its JSON, since
#            verify_prs reads it as truthiness
#   test     `.tests.rust`, the same
#   issues   every issue type in order, joined by `,`; `-` for none
# verify_prs also exercises real Git fetch/merge and owned-resource teardown.
# Inputs: skills/github/scripts/lib/verify-lib.sh skills/github/tests/lib/mutant-copy.sh
# The control runs only individually-clean-joint-conflict against a detached-HEAD mutant.
# bash-runtime: 3.2
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which take precedence over `git -C`;
# sourcing verify-lib.sh runs git rev-parse.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$TEST_DIR/../scripts/lib/verify-lib.sh"
CASE="${1:-all}"
[[ -z "${2:-}" ]] || LIB="$2"
TMP_ROOT="$(mktemp -d)" || { echo 'verify-lib.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "verify-lib.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'verify-lib.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
CONTROL_RESULT="${3:-$TMP_ROOT/conflict-observed}"
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$label"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
  fi
}

# --- the commands ---------------------------------------------------------------
if [[ "$CASE" == all || "$CASE" == run-stack ]]; then
cat >"$TMP_ROOT/large.sh" <<'CMD'
#!/usr/bin/env bash
for i in $(seq 1 2000); do
  printf 'error[E0001]: mismatched types at src/lib.rs:%d — expected u32, found i64\n' "$i"
done
exit 1
CMD
cat >"$TMP_ROOT/long-line.sh" <<'CMD'
#!/usr/bin/env bash
pad=""
for _ in $(seq 1 200); do
  pad="$pad$(printf 'x%.0s' {1..1000})"
done
printf 'error[E0001]: %s\n' "$pad"
exit 1
CMD
cat >"$TMP_ROOT/quiet.sh" <<'CMD'
#!/usr/bin/env bash
echo "build stopped: nothing here matches"
exit 1
CMD
chmod +x "$TMP_ROOT"/*.sh
command_of() {
  case "$1" in
    large|long-line|quiet) printf 'bash %s/%s.sh' "$TMP_ROOT" "$1" ;;
    pass) printf 'true' ;;
    *) echo "UNKNOWN-COMMAND: $1" >&2; exit 2 ;;
  esac
}

# The fixtures' preconditions: the matching text clears two pipe buffers, and
# the single line clears MAX_ARG_STRLEN (131072) on its own. BSD wc pads its
# count, so the blanks come off.
size_of() { bash "$TMP_ROOT/$1.sh" | wc -c | tr -d ' ' || true; }
for f in large long-line; do
  if [[ "$(size_of "$f")" -ge 131072 ]]; then
    PASS=$((PASS + 1)); printf '  ok    precondition: %s writes at least 131072 bytes\n' "$f"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  precondition: %s writes at least 131072 bytes (got %s)\n' "$f" "$(size_of "$f")"
  fi
done

# run_stack under live errexit, RESULTS_JSON recovered from an EXIT trap: an
# aborted run_stack leaves the entry it never wrote missing rather than taking
# the results down with it.
cat >"$TMP_ROOT/drive.sh" <<'DRIVE'
#!/usr/bin/env bash
set -euo pipefail
lib="$1" spec="$2" work="$3" out="$4"
# shellcheck disable=SC1090
source "$lib"
init_results
trap 'printf "%s" "${RESULTS_JSON:-}" >"$out"' EXIT
run_stack "$spec" "$work"
DRIVE

slot() { # results path
  jq -r --arg p "$1" '
    getpath($p | split(".")) as $s
    | if $s == null then "-"
      elif $s.success == true then "ok"
      elif $s.success == false then "fail:\($s.error | length):\($s.error[0:72])"
      else "success=\($s.success | tojson)"
      end' <"$TMP_ROOT/results.json"
}

run() { # command stage
  local cmd spec
  cmd="$(command_of "$1")"
  case "$2" in
    build) spec="rust|$cmd||." ;;
    test) spec="rust||$cmd|." ;;
    both) spec="rust|$cmd|$cmd|." ;;
    *) echo "UNKNOWN-STAGE: $2" >&2; exit 2 ;;
  esac
  : >"$TMP_ROOT/results.json"
  bash "$TMP_ROOT/drive.sh" "$LIB" "$spec" "$TMP_ROOT" "$TMP_ROOT/results.json" >/dev/null 2>&1 || true
  printf 'build=%s test=%s issues=%s' "$(slot builds.rust)" "$(slot tests.rust)" \
    "$(jq -r '[.issues[] | .type] | if length == 0 then "-" else join(",") end' <"$TMP_ROOT/results.json")"
}

run_table() {
  local title="$1" rows="$2" label command stage build test issues got row field before=$((PASS + FAIL))
  echo "=== $title ==="
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r label command stage build test issues <<<"$row"
    for field in "$label" "$command" "$stage" "$build" "$test" "$issues"; do
      [[ "$field" != "" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
    done
    got="$(run "$command" "$stage")"
    # A rendering aid for writing rows; the run is refused after the loop.
    if [[ "${GITHUB_TABLE_PROBE:-}" == 1 ]]; then
      printf '%s => %s\n' "$label" "$got"
      continue
    fi
    assert_eq "$got" "build=$build test=$test issues=$issues" "$label"
  done <<<"$rows"
  # At least one row asserted, and every listed row: an empty table and a
  # probe run are both refused.
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }
  [[ "$((PASS + FAIL - before))" -eq "$(printf '%s\n' "$rows" | grep -c '|')" ]] || { echo "not every listed row was asserted" >&2; exit 2; }
}

LINE1='error[E0001]: mismatched types at src/lib.rs:1 — expected u32, found i64'

run_table "the failure summaries under live errexit" "\
a large build failure is recorded with its first error line, raises its issue and stops the stack|large|both|fail:365:$LINE1|-|rust_build_failed
a large test failure too|large|test|-|fail:365:$LINE1|rust_tests_failed
one error line past MAX_ARG_STRLEN is clipped to what reaches argv, its head kept|long-line|build|fail:2000:error[E0001]: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx|-|rust_build_failed
one error line past MAX_ARG_STRLEN is clipped in the test branch too|long-line|test|-|fail:2000:error[E0001]: xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx|rust_tests_failed
a build failure matching no pattern has an empty summary, not a missing entry|quiet|build|fail:0:|-|rust_build_failed
a test failure matching no pattern too|quiet|test|-|fail:0:|rust_tests_failed
a passing build and test are recorded with no issue|pass|both|ok|ok|-
"
fi

REAL_GIT="$(command -v git)"
REAL_MKTEMP="$(command -v mktemp)"
export REAL_GIT REAL_MKTEMP
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

git_configure() {
  "$REAL_GIT" -C "$1" config gc.auto 0
  "$REAL_GIT" -C "$1" config maintenance.auto false
  "$REAL_GIT" -C "$1" config user.name fixture
  "$REAL_GIT" -C "$1" config user.email fixture@example.invalid
  "$REAL_GIT" -C "$1" config commit.gpgsign false
  "$REAL_GIT" -C "$1" config core.hooksPath /dev/null
}

make_world() {
  FIXTURE="$TMP_ROOT/$1"
  export FIXTURE
  mkdir -p "$FIXTURE/bin" "$FIXTURE/scratch" "$FIXTURE/gh-verify-old"
  printf 'unrelated\n' >"$FIXTURE/gh-verify-old/sentinel"
  touch -t 200001010000 "$FIXTURE/gh-verify-old"
  "$REAL_GIT" init --bare --initial-branch=main "$FIXTURE/origin" >/dev/null
  git_configure "$FIXTURE/origin"
  "$REAL_GIT" clone --quiet "$FIXTURE/origin" "$FIXTURE/repo" 2>"$FIXTURE/clone.log"
  git_configure "$FIXTURE/repo"
  printf 'base\n' >"$FIXTURE/repo/common"
  printf 'base\n' >"$FIXTURE/repo/left"
  printf 'base\n' >"$FIXTURE/repo/right"
  "$REAL_GIT" -C "$FIXTURE/repo" add .
  "$REAL_GIT" -C "$FIXTURE/repo" commit --quiet -m base
  "$REAL_GIT" -C "$FIXTURE/repo" push --quiet origin main
  BASE_TIP="$("$REAL_GIT" -C "$FIXTURE/repo" rev-parse HEAD)"
  for num in 1 2; do
    "$REAL_GIT" -C "$FIXTURE/repo" checkout --quiet -b "pr$num" "$BASE_TIP"
    if [[ "$2" == conflict ]]; then
      printf 'pr%s\n' "$num" >"$FIXTURE/repo/common"
    elif [[ "$num" == 1 ]]; then
      printf 'one\n' >"$FIXTURE/repo/left"
    else
      printf 'two\n' >"$FIXTURE/repo/right"
    fi
    "$REAL_GIT" -C "$FIXTURE/repo" commit --quiet -am "pr$num"
    "$REAL_GIT" -C "$FIXTURE/repo" push --quiet origin "HEAD:refs/pull/$num/head"
  done
  FIRST_TIP="$("$REAL_GIT" -C "$FIXTURE/repo" rev-parse pr1)"
  SECOND_TIP="$("$REAL_GIT" -C "$FIXTURE/repo" rev-parse pr2)"
  export FIRST_TIP SECOND_TIP
  "$REAL_GIT" -C "$FIXTURE/repo" checkout --quiet main
  "$REAL_GIT" -C "$FIXTURE/repo" worktree add --quiet -b unrelated "$FIXTURE/unrelated" main
  printf 'keep\n' >"$FIXTURE/unrelated/sentinel"

  # Only the named boundary is injected. Fetches, merges, refs and worktrees
  # otherwise use this shell's resolved Git executable.
  cat >"$FIXTURE/bin/git" <<'GIT'
#!/bin/bash
set -euo pipefail
args=("$@")
[[ "${1:-}" != -C ]] || shift 2
if [[ "${1:-}" == branch && "${2:-}" == verify/* ]]; then
  printf '%s\n' "$2" >"$FIXTURE/branch"
  if [[ "$MODE" == collision ]]; then
    "$REAL_GIT" -C "$FIXTURE/repo" branch "$2" "$FIRST_TIP"
  fi
fi
if [[ "${1:-}" == worktree ]]; then
  case "${2:-}:$MODE" in
    add:add-before) exit 71 ;;
    add:add-after) "$REAL_GIT" "${args[@]}"; exit 72 ;;
    list:inventory-failure) exit 73 ;;
    remove:remove-failure) exit 74 ;;
  esac
fi
if [[ "${1:-}" == branch && "${2:-}" == -D && "$MODE" == branch-delete-failure ]]; then
  exit 75
fi
exec "$REAL_GIT" "${args[@]}"
GIT
  cat >"$FIXTURE/bin/mktemp" <<'MKTEMP'
#!/bin/bash
set -euo pipefail
case "$MODE" in
  scratch-fail) exit 76 ;;
  scratch-print-fail) printf '%s\n' "$FIXTURE/unrelated"; exit 76 ;;
esac
root="$("$REAL_MKTEMP" "$@")"
printf '%s\n' "$root" >"$FIXTURE/root"
printf '%s\n' "$root"
MKTEMP
  cat >"$FIXTURE/verify.sh" <<'VERIFY'
#!/bin/bash
set -euo pipefail
printf 'ran\n' >"$FIXTURE/verifier-ran"
"$REAL_GIT" merge-base --is-ancestor "$FIRST_TIP" HEAD
"$REAL_GIT" merge-base --is-ancestor "$SECOND_TIP" HEAD
"$REAL_GIT" symbolic-ref HEAD >"$FIXTURE/attached"
"$REAL_GIT" rev-parse HEAD >"$FIXTURE/verified-head"
[[ "$(cat left)" == one && "$(cat right)" == two ]]
VERIFY
  chmod +x "$FIXTURE/bin/git" "$FIXTURE/bin/mktemp"
}

verify_world() {
  local second="${2:-2}"
  VERIFY_STATUS=0
  (
    cd -- "$FIXTURE/repo"
    export MODE="$1" TMPDIR="$FIXTURE/scratch" PATH="$FIXTURE/bin:$PATH"
    # The child keeps the caller's environment; only test boundaries above
    # replace Git and scratch acquisition.
    export GH_VERIFY_CMD='"$BASH" "$FIXTURE/verify.sh"'
    "$BASH" "$LIB" verify_prs 1 "$second"
  ) >"$FIXTURE/result.json" 2>"$FIXTURE/stderr" || VERIFY_STATUS=$?
}

assert_json() {
  local status=0
  jq -e "$1" "$FIXTURE/result.json" >/dev/null || status=$?
  assert_eq "$status" 0 "$2"
}

assert_preserved() {
  local inventory
  inventory="$("$REAL_GIT" -C "$FIXTURE/repo" worktree list --porcelain)"
  assert_eq "$("$REAL_GIT" -C "$FIXTURE/repo" rev-parse HEAD)" "$BASE_TIP" 'original checkout tip preserved'
  assert_eq "$("$REAL_GIT" -C "$FIXTURE/repo" symbolic-ref --short HEAD)" main 'original checkout remains attached'
  assert_eq "$("$REAL_GIT" -C "$FIXTURE/repo" rev-parse unrelated)" "$BASE_TIP" 'unrelated branch tip preserved'
  assert_eq "$(cat "$FIXTURE/unrelated/sentinel")" keep 'unrelated checkout content preserved'
  assert_eq "$(cat "$FIXTURE/gh-verify-old/sentinel")" unrelated 'old unrelated directory preserved'
  local registered=false
  [[ "$inventory" != *"worktree $FIXTURE/unrelated"* ]] || registered=true
  assert_eq "$registered" true 'unrelated checkout stays registered'
}

assert_released() {
  local root branch present=false
  root="$(cat "$FIXTURE/root")"
  branch="$(cat "$FIXTURE/branch")"
  [[ ! -e "$root" ]] || present=true
  assert_eq "$present" false 'acquired scratch released'
  present=false
  if "$REAL_GIT" -C "$FIXTURE/repo" show-ref --verify --quiet "refs/heads/$branch"; then present=true; fi
  assert_eq "$present" false 'acquired branch released'
  present=false
  local inventory
  inventory="$("$REAL_GIT" -C "$FIXTURE/repo" worktree list --porcelain)"
  [[ "$inventory" != *"worktree $root/worktree"* ]] || present=true
  assert_eq "$present" false 'acquired checkout registration released'
}

joint_conflict() {
  make_world individually-clean-joint-conflict conflict
  # Each head really merges with the same base in a disposable checkout.
  for num in 1 2; do
    "$REAL_GIT" -C "$FIXTURE/repo" worktree add --quiet --detach "$FIXTURE/alone$num" "$BASE_TIP"
    "$REAL_GIT" -C "$FIXTURE/alone$num" merge --quiet --no-edit "pr$num"
    assert_eq "$(cat "$FIXTURE/alone$num/common")" "pr$num" "PR$num merges alone"
    "$REAL_GIT" -C "$FIXTURE/repo" worktree remove "$FIXTURE/alone$num"
  done
  verify_world normal
  assert_eq "$VERIFY_STATUS" 0 'conflict uses existing JSON exit convention'
  # This independent typed result is also the named must-fail instrument.
  local conflict=false
  if jq -e '.merge.success == false and .can_batch_merge == false and [.prs[].number] == [1] and [.issues[].type] == ["merge_conflict"]' "$FIXTURE/result.json" >/dev/null; then conflict=true; fi
  assert_eq "$conflict" true 'individually-clean-joint-conflict'
  jq --argjson status "$VERIFY_STATUS" --argjson conflict "$conflict" \
    '. + {process_status: $status, conflict_observed: $conflict}' \
    "$FIXTURE/result.json" >"$CONTROL_RESULT"
  local ran=false
  [[ ! -e "$FIXTURE/verifier-ran" ]] || ran=true
  assert_eq "$ran" false 'conflict skips verification'
  assert_released
  assert_preserved
}

if [[ "$CASE" == all || "$CASE" == individually-clean-joint-conflict ]]; then
  joint_conflict
fi

if [[ "$CASE" == all ]]; then
  make_world accumulated-success success
  verify_world normal
  assert_eq "$VERIFY_STATUS" 0 'accumulated success exits zero'
  assert_json '.merge.success and .can_batch_merge and .builds.custom.success and [.prs[].number] == [1,2]' 'both heads verified together'
  assert_eq "$(cat "$FIXTURE/attached")" "refs/heads/$(cat "$FIXTURE/branch")" 'verifier sees the acquired attached branch'
  assert_released
  assert_preserved

  make_world pr-fetch-failure success
  verify_world normal 99
  assert_eq "$VERIFY_STATUS" 0 'fetch failure preserves JSON exit convention'
  assert_json '.merge.success == false and .can_batch_merge == false and [.prs[].number] == [1] and [.issues[].type] == ["pr_fetch_failed"] and .builds == {}' 'missing head stops before stale FETCH_HEAD merge'
  assert_released
  assert_preserved

  for mode in scratch-fail scratch-print-fail collision add-before add-after inventory-failure remove-failure branch-delete-failure; do
    make_world "$mode" success
    verify_world "$mode"
    assert_eq "$VERIFY_STATUS" 1 "$mode exits nonzero"
    case "$mode" in
      scratch-*)
        assert_json '.can_batch_merge == false and [.issues[].type] == ["worktree_failed"]' "$mode reports acquisition failure"
        assert_eq "$("$REAL_GIT" -C "$FIXTURE/repo" for-each-ref --format='%(refname)' refs/heads/verify/)" '' "$mode creates no branch"
        ;;
      collision)
        assert_json '.can_batch_merge == false and [.issues[].type] == ["worktree_failed"]' 'collision reports acquisition failure'
        assert_eq "$("$REAL_GIT" -C "$FIXTURE/repo" rev-parse "$(cat "$FIXTURE/branch")")" "$FIRST_TIP" 'colliding branch retains its original tip'
        assert_eq "$(find "$FIXTURE/scratch" -mindepth 1 -print)" '' 'collision releases only acquired scratch'
        ;;
      add-*)
        assert_json '.can_batch_merge == false and [.issues[].type] == ["worktree_failed"]' "$mode reports add failure"
        assert_released
        ;;
      inventory-failure|remove-failure)
        root="$(cat "$FIXTURE/root")"
        assert_eq "$("$REAL_GIT" -C "$root/worktree" symbolic-ref --short HEAD)" "$(cat "$FIXTURE/branch")" "$mode retains owned checkout and branch"
        assert_eq "$(cat "$root/worktree/left")" one "$mode retains checkout contents"
        "$REAL_GIT" -C "$FIXTURE/repo" worktree remove --force "$root/worktree"
        "$REAL_GIT" -C "$FIXTURE/repo" branch -D "$(cat "$FIXTURE/branch")" >/dev/null
        ;;
      branch-delete-failure)
        assert_eq "$("$REAL_GIT" -C "$FIXTURE/repo" rev-parse "$(cat "$FIXTURE/branch")")" "$(cat "$FIXTURE/verified-head")" 'failed branch deletion retains acquired ref'
        assert_eq "$(find "$FIXTURE/scratch" -mindepth 1 -print)" '' 'branch deletion failure releases safe scratch'
        ;;
    esac
    assert_preserved
  done

  # The control copy shares this suite's exclusively acquired outside-worktree
  # scratch. Retain the fetch, then plant the original detachment defect.
  source "$TEST_DIR/lib/mutant-copy.sh"
  mutant="$(mutant_copy_edit "$TMP_ROOT/detach-control" \
    '        if ! git fetch --quiet origin "refs/pull/$pr_num/head" 2>/dev/null; then' \
    '        if ! { git fetch --quiet origin "refs/pull/$pr_num/head" && git checkout --detach FETCH_HEAD; } 2>/dev/null; then' \
    lib/verify-lib.sh)"
  control_status=0
  "$BASH" "$0" individually-clean-joint-conflict "$mutant" "$TMP_ROOT/control-result" >"$TMP_ROOT/control.log" 2>&1 || control_status=$?
  assert_eq "$control_status" 1 'detach-regression control fails the named row'
  # Require the exact assertion's failure, not any nonzero harness outcome.
  observed=false
  if jq -e '.process_status == 0 and .conflict_observed == false and .merge.success == true and [.prs[].number] == [1,2] and [.issues[].type] == ["custom_verify_failed"]' "$TMP_ROOT/control-result" >/dev/null; then observed=true; fi
  assert_eq "$observed" true 'detach-regression control loses the joint conflict after both heads merge'
  rm -rf -- "$TMP_ROOT/detach-control"
fi

case "$CASE" in
  all|run-stack|individually-clean-joint-conflict) ;;
  *) echo "verify-lib.test: case=unknown value=[$CASE]" >&2; exit 2 ;;
esac

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
