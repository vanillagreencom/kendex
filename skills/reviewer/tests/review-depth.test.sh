#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: scripts/review-depth. Inputs: orch/scripts/lib/change-class.sh,
# orch/tests/lib/assertions.sh. The classifier fixture supplies its public
# stdout/stderr protocol; the real reader and depth command consume it.
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"
source "$SKILL_DIR/../orch/tests/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'review-depth.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'review-depth.test: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'review-depth.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

INSTALL="$TMP_ROOT/skills"
mkdir -p "$INSTALL/reviewer/scripts" "$INSTALL/orch/scripts/lib" "$INSTALL/harness-ci/scripts"
cp "$SKILL_DIR/scripts/review-depth" "$INSTALL/reviewer/scripts/"
cp "$SKILL_DIR/../orch/scripts/lib/change-class.sh" "$INSTALL/orch/scripts/lib/"
CLASSIFIER="$INSTALL/harness-ci/scripts/change-class"
cat > "$CLASSIFIER" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${DEPTH_FIXTURE_ARGS:?}"
printf 'change_class=%s\n' "${DEPTH_FIXTURE_CLASS:?}"
if [ -n "${DEPTH_FIXTURE_MEASURED:-}" ]; then
  printf 'class: class=%s measured=%s cause=fixture\n' "$DEPTH_FIXTURE_CLASS" "$DEPTH_FIXTURE_MEASURED" >&2
fi
exit "${DEPTH_FIXTURE_EXIT:-0}"
STUB
chmod +x "$CLASSIFIER"
export DEPTH_FIXTURE_ARGS="$TMP_ROOT/args"
DEPTH="$INSTALL/reviewer/scripts/review-depth"

# orch's review-pr workflow consumes the record. Each class retains the
# approval field even when package review stands down.
depth_table() {
  local command="$1" class measured depth expected_status status output before
  before="$FAIL"
  while read -r class measured depth expected_status; do
    status=0
    output="$(DEPTH_FIXTURE_CLASS="$class" DEPTH_FIXTURE_MEASURED="$measured" \
      "$command" --base base-ref --head head-ref --repo "$TMP_ROOT/judged tree" 2>"$TMP_ROOT/stderr")" || status=$?
    assert_eq "$status" "$expected_status" "$class/$measured status" "$TMP_ROOT/stderr"
    if [ "$expected_status" = 0 ]; then
      assert_eq "$output" "change_class=$class review_depth=$depth native_approval=unchanged" "$class/$measured depth and native approval"
    else
      assert_eq "$output" '' "$class/$measured publishes no depth"
    fi
  done <<'ROWS'
render true none 0
trivial true none 0
micro true none 0
small true bot 0
standard true full 0
standard false absent 3
ROWS
  [ "$FAIL" -eq "$before" ]
}
depth_table "$DEPTH" || :
expected_args="$(printf '%s\n' --event pull_request --base base-ref --head head-ref --repo "$TMP_ROOT/judged tree" --output /dev/null)"
assert_eq "$(cat "$DEPTH_FIXTURE_ARGS")" "$expected_args" 'the real reader forwards the range and path as arguments'

# A floor is the class a route promised: the class above the one a run escaped
# from. It raises the depth and never lowers it; the record keeps the measured
# class. The micro/small row is a micro escape on Copilot no-files, whose small
# run measures the same micro diff. floor_line says whether stderr carries the
# floor's key line, which it does only when the floor changed the depth.
floor_table() {
  local command="$1" class measured floor depth expected_status floor_line status output before
  before="$FAIL"
  while read -r class measured floor depth expected_status floor_line; do
    status=0
    output="$(DEPTH_FIXTURE_CLASS="$class" DEPTH_FIXTURE_MEASURED="$measured" \
      "$command" --base base-ref --floor "$floor" 2>"$TMP_ROOT/stderr")" || status=$?
    assert_eq "$status" "$expected_status" "$class/floor=$floor status" "$TMP_ROOT/stderr"
    if [ "$expected_status" = 0 ]; then
      assert_eq "$output" "change_class=$class review_depth=$depth native_approval=unchanged" "$class/floor=$floor depth"
    else
      assert_eq "$output" '' "$class/floor=$floor publishes no depth"
    fi
    assert_eq "$(grep -c '^review-depth: floor=' "$TMP_ROOT/stderr" || :)" "$floor_line" "$class/floor=$floor floor line"
  done <<'ROWS'
micro true small bot 0 1
standard true small full 0 0
small true micro bot 0 0
trivial true micro none 0 0
standard false small absent 3 0
micro true trivial absent 2 0
ROWS
  [ "$FAIL" -eq "$before" ]
}
floor_table "$DEPTH" || :

while read -r name marker classifier_exit expected_cause; do
  [ "$marker" != absent ] || marker=''
  status=0
  output="$(DEPTH_FIXTURE_CLASS=standard DEPTH_FIXTURE_MEASURED="$marker" DEPTH_FIXTURE_EXIT="$classifier_exit" \
    "$DEPTH" --base base-ref 2>"$TMP_ROOT/stderr")" || status=$?
  assert_eq "$status" 2 "$name status"
  assert_eq "$output" '' "$name publishes no depth"
  diagnostic="$(cat "$TMP_ROOT/stderr")"
  assert_contains "$diagnostic" "review-depth: cause=$expected_cause " "$name cause"
done <<'ROWS'
failed-classifier true 2 classifier-exit-2
missing-marker absent 0 classifier-unreadable
ROWS

mv "$CLASSIFIER" "$CLASSIFIER.disabled"
status=0
output="$(PATH=/usr/bin:/bin "$DEPTH" --base base-ref 2>"$TMP_ROOT/stderr")" || status=$?
assert_eq "$status" 2 'missing classifier refuses'
assert_eq "$output" '' 'missing classifier publishes no depth'
mv "$CLASSIFIER.disabled" "$CLASSIFIER"

for option in --class --event; do
  status=0
  output="$("$DEPTH" "$option" small 2>"$TMP_ROOT/stderr")" || status=$?
  assert_eq "$status" 2 "$option cannot supply a class or another event"
  assert_eq "$output" '' "$option publishes no depth"
done

# Each control changes one real depth decision in a disposable source copy.
mutant() { # NAME OLD NEW
  cp "$DEPTH" "$INSTALL/reviewer/scripts/$1"
  python3 - "$INSTALL/reviewer/scripts/$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys
p, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
assert not p.is_symlink()
before = p.read_text()
assert before.count(old) == 1
after = before.replace(old, new)
assert after != before
p.write_text(after)
PY
}
mutant small-full 'small) DEPTH=bot ;;' 'small) DEPTH=full ;;'
status=0
(depth_table "$INSTALL/reviewer/scripts/small-full") >"$TMP_ROOT/control.log" 2>&1 || status=$?
assert_eq "$status" 1 'must-fail control rejects the changed small depth'

# The suite's own FAIL lines name the row each control must redden.
mutant floor-ignored 'if [ -n "$FLOOR" ]; then' 'if false; then'
(floor_table "$INSTALL/reviewer/scripts/floor-ignored") >"$TMP_ROOT/control.log" 2>&1 || :
assert_contains "$(cat "$TMP_ROOT/control.log")" 'FAIL  micro/floor=small depth' \
  'must-fail control: an ignored floor fails the micro escape row'

mutant floor-as-class 'if [ "$CHANGE_CLASS_RANK" -gt "$MEASURED_RANK" ]; then' 'if true; then'
(floor_table "$INSTALL/reviewer/scripts/floor-as-class") >"$TMP_ROOT/control.log" 2>&1 || :
assert_contains "$(cat "$TMP_ROOT/control.log")" 'FAIL  standard/floor=small depth' \
  'must-fail control: a floor taken as the class fails the standard row'

mutant floor-line-always '[ "$DEPTH" = "$MEASURED_DEPTH" ] ||' 'false ||'
(floor_table "$INSTALL/reviewer/scripts/floor-line-always") >"$TMP_ROOT/control.log" 2>&1 || :
assert_contains "$(cat "$TMP_ROOT/control.log")" 'FAIL  trivial/floor=micro floor line' \
  'must-fail control: a floor line that left the depth unchanged fails the trivial row'

printf '\nreview-depth: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
