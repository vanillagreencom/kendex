#!/usr/bin/env bash
# Tests for dev-validate-run --attached, the foreground start a host needs when
# its agent warden kills detached jobs.
#
# The attached run is the detached run's child started inside the caller's own
# process tree: the same bound, class, run directory, sentinel and record,
# which dev-return-write takes as a round's validate evidence and
# dev-artifact-check accepts. The rows below pin that the run stays in the
# caller's tree, that it keeps the bound and the class, that what the command
# leaves in its group ends with it, that --stop ends it, and that its record
# carries a pass through both readers.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/process-table.sh"
# mutant_scripts and mutate_file, the two halves of the controls below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
# orch_fixture_shared_libs: an attached start forks through the github skill's
# group-leader prefix, which a mutant's copy of the scripts reaches beside it.
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/../scripts" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "dev_validate_run_attached: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "dev_validate_run_attached: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "dev_validate_run_attached: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

RUN="$SCRIPTS_DIR/dev-validate-run"
WRITE="$SCRIPTS_DIR/dev-return-write"
CHECK="$SCRIPTS_DIR/dev-artifact-check"

echo "=== dev-validate-run --attached ==="

# The detached control needs a runner to launch it under: setsid where no user
# manager answers.
SKIP_REASON=""
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  SKIP_REASON="neither timeout nor gtimeout is installed"
elif ! command -v setsid >/dev/null 2>&1; then
  SKIP_REASON="setsid is not installed"
fi
if [[ -n "$SKIP_REASON" ]]; then
  echo "  skip  $SKIP_REASON; the attached rows did not run"
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  exit 0
fi

# A committed project whose settings carry one validation command and one
# bound, on a branch of its own so dev-return-write measures a real baseline.
make_proj() { # NAME CMD TIMEOUT_SECS
  local dir="$TMP_ROOT/$1"
  git init -q -b main "$dir"
  git -C "$dir" config gc.auto 0
  git -C "$dir" config maintenance.auto false
  git -C "$dir" config user.email test@example.com
  git -C "$dir" config user.name Test
  git -C "$dir" config commit.gpgsign false
  printf 'tmp/\n' > "$dir/.gitignore"
  {
    printf '[env]\n'
    printf 'DEV_VALIDATE_CMD = "%s"\n' "$2"
    printf 'DEV_VALIDATE_TIMEOUT_SECS = "%s"\n' "$3"
  } > "$dir/kendex.settings.toml"
  git -C "$dir" add -A
  git -C "$dir" commit -q -m base
  git -C "$dir" switch -q -c work
  printf '%s\n' "$dir"
}

# One run with the settings, the class and the base-branch hint the caller's
# shell carries cleared, so a developer's own values, or this suite running
# under dev-validate-run itself, never reach the row.
OUT=""
ERR=""
RC=0
run_script() { # SCRIPT ARG...
  local script="$1"
  shift
  ERR="$(mktemp "$TMP_ROOT/err.XXXXXX")" || { echo "dev_validate_run_attached: scratch=mktemp-failed" >&2; exit 1; }
  set +e
  OUT="$(env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_BASE \
    -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS -u WORKTREE_DEFAULT_BRANCH \
    "$script" "$@" 2>"$ERR")"
  RC=$?
  set -e
}

run_dir_of() { sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$1"; }
# The verdict fields a caller acts on, from the last line.
verdict_of() {
  sed -n '$s/^\(state=[a-z]*\) \(guard-exit=[0-9]*\) at=[^ ]* \(validate=[A-Za-z-]*\).*$/\1 \2 \3/p;$s/^\(state=lost\) .*\(validate=[A-Za-z]*\).*$/\1 \2/p' <<<"$1"
}
# A command that records its own chain of ancestors, one pid per line, and the
# change class it was handed. The runs below read whether this suite's process
# is among them: a job a warden reaps as escaped is one outside it.
write_chain() { # PROJ
  cat > "$1/chain.sh" <<'SH'
p=$$
while [ "$p" -gt 1 ]; do
  echo "$p"
  p="$(ps -o ppid= -p "$p" | tr -d ' ')" || break
done > chain
echo "class=$DEV_VALIDATE_CLASS"
SH
}
in_tree() { # PROJ
  if [[ ! -s "$1/chain" ]]; then echo unrecorded; elif grep -qFx -- "$$" "$1/chain"; then echo yes; else echo no; fi
}

MUTANT=""
mutant() { # NAME FILE OLD NEW
  MUTANT="$(mutant_scripts "$1" "$2")" || exit 1
  orch_fixture_shared_libs "$TMP_ROOT/$1" || { echo "dev_validate_run_attached: shared-libs=copy-failed mutant=$1" >&2; exit 1; }
  mutate_file "$MUTANT/$2" "$3" "$4"
  MUTANT="$MUTANT/dev-validate-run"
}

# --- --attached belongs to the start alone -----------------------------------
# A resumed poll that repeats the start's flag is refused, never run as if the
# flag meant something there.
mkdir -p "$TMP_ROOT/no-run"
run_script "$RUN" --wait --run-dir "$TMP_ROOT/no-run" --attached
assert_eq "rc=$RC $(sed -n 1p "$ERR")" "rc=2 dev-validate-run: option-unused option=--attached mode=wait" \
  "--attached beside --wait is refused as a flag that mode would drop" "$ERR"
mutant mutant-attached-dropped dev-validate-run \
  '[[ "$attached" == false || -z "$mode" || "$mode" == start ]]' '[[ true ]]'
run_script "$MUTANT" --wait --run-dir "$TMP_ROOT/no-run" --attached
assert_eq "rc=$RC $(sed -n 1p "$ERR")" "rc=2 dev-validate-run: no-run path=$TMP_ROOT/no-run/start" \
  "control: without that refusal the flag is dropped and the poll runs on" "$ERR"

# --- An attached start needs the github skill beside orch -------------------
# The start forks through that skill's group-leader prefix; a copy of the
# scripts with no github skill beside it refuses under the key job-unit.sh
# names, and starts nothing.
lone_start() { # SCRIPTS_DIR PROJ
  run_script "$1/dev-validate-run" --worktree "$2" --poll 1 --attached
  printf 'rc=%s %s' "$RC" "$(grep -F 'dev-validate-run: ' "$ERR" | sed -n 1p)"
}
LONE="$(mutant_scripts lone/orch)" || exit 1
proj="$(make_proj proj-lone "exit 0" 20)"
assert_eq "$(lone_start "$LONE" "$proj")" \
  "rc=2 dev-validate-run: group-leader-missing path=$LONE/lib/../../../github/scripts/lib/group-leader.sh" \
  "an attached start with no github skill beside orch is refused as group-leader-missing" "$ERR"
LONE="$(mutant_scripts lone-setsid/orch dev-validate-run)" || exit 1
mutate_file "$LONE/dev-validate-run" '2) die "$JOB_UNIT_ERROR_KEY" "$JOB_UNIT_ERROR" ;;' '2) die missing-command commands=setsid ;;'
assert_eq "$(lone_start "$LONE" "$proj")" "rc=2 dev-validate-run: missing-command commands=setsid" \
  "control: a start that reads every exit 2 as the detached runner's names setsid instead"

# --- The run stays in the caller's tree, under its own bound and class --------
proj="$(make_proj proj-pass "bash chain.sh" 20)"
write_chain "$proj"
run_script "$RUN" --worktree "$proj" --poll 1 --attached
PASS_DIR="$(run_dir_of "$OUT")"
assert_eq "$(verdict_of "$OUT") rc=$RC" "state=done guard-exit=0 validate=pass rc=0" \
  "an attached run that passes prints the started line, then a passing verdict" "$ERR"
assert_eq "$(sed -n 1p "$PASS_DIR/log" 2>/dev/null)|$(sed -n 2p "$PASS_DIR/log" 2>/dev/null)" "runner=attached|class=standard" \
  "its log opens with the attached runner line, and the command reads the change class" "$ERR"
assert_eq "$(in_tree "$proj")" "yes" \
  "the command runs inside the caller's own process tree, where a warden sees it as the caller's work" "$ERR"

# The tree's control: the same start launched detached leaves the caller's
# process tree, under a unit or setsid alike.
mutant mutant-detached dev-validate-run 'job_unit_attach "$run_dir/runner" --' \
  'job_unit_launch "validate-${worktree##*/}" "$run_dir/runner" --cap "$cap_secs" --'
proj_detached="$(make_proj proj-detached "bash chain.sh" 20)"
write_chain "$proj_detached"
run_script "$MUTANT" --worktree "$proj_detached" --poll 1 --attached
assert_eq "$(verdict_of "$OUT") in-tree=$(in_tree "$proj_detached")" \
  "state=done guard-exit=0 validate=pass in-tree=no" \
  "control: a detached launch runs the command outside the caller's process tree" "$ERR"

proj="$(make_proj proj-bound "sleep 30" 2)"
run_script "$RUN" --worktree "$proj" --poll 1 --attached
assert_eq "$(verdict_of "$OUT") rc=$RC" "state=done guard-exit=124 validate=no-verdict rc=1" \
  "an attached command that outlives the bound is cut off at it: no verdict" "$ERR"

# --- What the command leaves in the run's group ends with the run -------------
# The grandchild is killed after the read, so a row that leaves it running
# leaves nothing behind the suite.
grandchild_state() { # PROJ
  local pid
  pid="$(cat "$1/grand.pid" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo unrecorded; return 0; }
  proc_state_after "$pid"
  kill -KILL "$pid" 2>/dev/null || true
}
GRAND_CMD='sleep 300 & echo $! > grand.pid; exit 0'
proj="$(make_proj proj-grand "$GRAND_CMD" 20)"
run_script "$RUN" --worktree "$proj" --poll 1 --attached
assert_eq "$(verdict_of "$OUT") $(grandchild_state "$proj")" "state=done guard-exit=0 validate=pass gone" \
  "an attached run leaves no process the command started in its group" "$ERR"

# The teardown's control: a runner that ends nothing for an attached job leaves
# the grandchild running.
mutant mutant-no-end lib/job-unit.sh 'setsid|attached) job_unit_teardown "$2" member ;;' \
  'setsid) job_unit_teardown "$2" member ;; attached) ;;'
proj="$(make_proj proj-grand-kept "$GRAND_CMD" 20)"
run_script "$MUTANT" --worktree "$proj" --poll 1 --attached
assert_eq "$(verdict_of "$OUT") $(grandchild_state "$proj")" "state=done guard-exit=0 validate=pass alive" \
  "control: with no teardown for an attached job the grandchild outlives the run" "$ERR"

# --- --stop ends an attached run by its group --------------------------------
# The run is started in the background and stopped once its child has recorded
# its pid; the started run then reads as lost, since nothing recorded a verdict.
attached_in_background() { # SCRIPT PROJ
  env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_TIMEOUT_SECS -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_BASE \
    -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS -u WORKTREE_DEFAULT_BRANCH \
    "$1" --worktree "$2" --poll 1 --attached > "$2.out" 2>&1 &
  BG_PID=$!
  local n=0
  until compgen -G "$2/tmp/dev-validate-*/pid" >/dev/null; do
    (( n < 100 )) || { fail "the attached run in $2 recorded no pid"; return 0; }
    sleep 0.1
    n=$((n + 1))
  done
}
stop_state() { # SCRIPT PROJ
  local bg
  attached_in_background "$1" "$2"
  bg="$BG_PID"
  run_script "$1" --stop --worktree "$2"
  printf '%s' "$OUT"
  # The control's run is still going; the shipped --stop ends it, so the row
  # leaves nothing behind the suite.
  [[ "$OUT" == *"groups=1"* ]] || run_script "$RUN" --stop --worktree "$2"
  wait "$bg" || :
}
proj="$(make_proj proj-stop "sleep 30" 60)"
assert_eq "$(stop_state "$RUN" "$proj") $(verdict_of "$(cat "$proj.out")")" "state=stopped units=0 groups=1 state=lost validate=FAILING" \
  "--stop ends a running attached run by its process group, and that run reads as lost" "$proj.out"

# The stop's control: a runner that leaves an attached job alone stops nothing.
mutant mutant-no-stop lib/job-unit.sh 'setsid|attached) job_unit_kill_group "$2" "$3" ;;' \
  'setsid) job_unit_kill_group "$2" "$3" ;; attached) return 1 ;;'
proj="$(make_proj proj-stop-kept "sleep 30" 60)"
assert_eq "$(stop_state "$MUTANT" "$proj")" "state=stopped units=0 groups=0" \
  "control: a runner that leaves an attached job alone stops nothing"

# --- The attached run is a round's validate evidence --------------------------
# dev-return-write records the pass from the run record, and dev-artifact-check
# accepts the artifact it writes.
proj="$TMP_ROOT/proj-pass"
printf 'change\n' > "$proj/change.txt"
git -C "$proj" add change.txt
git -C "$proj" commit -q -m change
head_sha="$(git -C "$proj" rev-parse HEAD)"
receipt() { # RUN_DIR
  local err
  err="$(mktemp "$TMP_ROOT/err.XXXXXX")" || { echo "dev_validate_run_attached: scratch=mktemp-failed" >&2; exit 1; }
  ERR="$err"
  set +e
  OUT="$("$WRITE" --worktree "$proj" --kind implement --issue issue-att --round-id 1-1 --branch work \
    --commit "$head_sha" --validate pass --validate-run-dir "$1" --no-summary 2>"$err")"
  RC=$?
  set -e
}
receipt "$PASS_DIR"
assert_eq "rc=$RC $(jq -r '[.validate, .validate_mode] | join(" ")' "$OUT" 2>/dev/null || echo UNPARSEABLE)" "rc=0 pass full" \
  "dev-return-write records an attached run's pass as the round's validate evidence" "$ERR"
assert_eq "$("$CHECK" --file "$OUT" 2>/dev/null | jq -r '[.verdict, .reason] | join(" ")' 2>/dev/null || echo UNPARSEABLE)" "accept valid" \
  "dev-artifact-check accepts that artifact as a pass"

# The receipt's control: an attached run that records no verdict leaves the
# round no run record, and dev-return-write refuses its pass.
mutant mutant-no-sentinel dev-validate-run 'mv "$run_dir/exit.part" "$run_dir/exit"' 'rm "$run_dir/exit.part"'
proj_lost="$(make_proj proj-lost "exit 0" 20)"
run_script "$MUTANT" --worktree "$proj_lost" --poll 1 --attached
lost_dir="$(run_dir_of "$OUT")"
assert_eq "$(verdict_of "$OUT")" "state=lost validate=FAILING" \
  "control: an attached run with no sentinel reads as lost" "$ERR"
receipt "$lost_dir"
assert_eq "rc=$RC $(grep -c -F "dev-return-write: validate-disagrees validate=pass run=unfinished" "$ERR" || true)" "rc=2 1" \
  "control: dev-return-write refuses a pass for a round whose run recorded no verdict" "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
