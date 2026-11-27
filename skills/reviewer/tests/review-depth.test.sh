#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: scripts/review-depth. Inputs: change-scope/scripts/lib/change-scope.sh,
# orch/tests/lib/assertions.sh. The classifier fixture supplies its public
# stdout/stderr protocol; the real reader and depth command consume it.
# Inputs: skills/change-scope/scripts/, skills/change-scope/references/
set -euo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SKILL_DIR="$(cd -- "$TEST_DIR/.." && pwd -P)"
source "$SKILL_DIR/../orch/tests/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'review-depth.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'review-depth.test: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'review-depth.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

INSTALL="$TMP_ROOT/skills"
mkdir -p "$INSTALL/reviewer/scripts" "$INSTALL/change-scope/scripts/lib"
cp "$SKILL_DIR/scripts/review-depth" "$INSTALL/reviewer/scripts/"
cp "$SKILL_DIR/../change-scope/scripts/lib/change-scope.sh" "$INSTALL/change-scope/scripts/lib/"
CLASSIFIER="$INSTALL/change-scope/scripts/change-scope"
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
expected_args="$(printf '%s\n' --event pull_request --base base-ref --head head-ref --repo "$TMP_ROOT/judged tree")"
assert_eq "$(cat "$DEPTH_FIXTURE_ARGS")" "$expected_args" 'the real reader forwards the range and path as arguments'

# A floor is the class a route promised: the class above the one a run escaped
# from. It raises the depth and never lowers it; the record keeps the measured
# class. The micro/small row is a micro escape on Copilot no-files, whose small
# run measures the same micro diff. floor_line says whether stderr carries the
# floor's key line, which it does only when the floor changed the depth.
while read -r class measured floor depth expected_status floor_line; do
  status=0
  output="$(DEPTH_FIXTURE_CLASS="$class" DEPTH_FIXTURE_MEASURED="$measured" \
    "$DEPTH" --base base-ref --floor "$floor" 2>"$TMP_ROOT/stderr")" || status=$?
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
assert_contains "$(cat "$TMP_ROOT/stderr")" 'review-depth: cause=classifier-absent ' 'missing classifier names its cause'
mv "$CLASSIFIER.disabled" "$CLASSIFIER"

# Without change-scope's library beside the package there is no reader to run
# the classifier through: the keyed line first, exit 2, no depth.
READER="$INSTALL/change-scope/scripts/lib/change-scope.sh"
mv "$READER" "$READER.disabled"
status=0
output="$("$DEPTH" --base base-ref 2>"$TMP_ROOT/stderr")" || status=$?
assert_eq "$status $output $(sed -n '1p' "$TMP_ROOT/stderr")" \
  "2  review-depth: cause=dependency-absent skill=change-scope path=$INSTALL/reviewer/scripts/../../change-scope/scripts/lib/change-scope.sh" \
  'missing change-scope library refuses at startup by key and publishes no depth'
mv "$READER.disabled" "$READER"

for option in --class --event; do
  status=0
  output="$("$DEPTH" "$option" small 2>"$TMP_ROOT/stderr")" || status=$?
  assert_eq "$status" 2 "$option cannot supply a class or another event"
  assert_eq "$output" '' "$option publishes no depth"
done

# The control changes one real depth decision in a disposable source copy:
# the small class reviewed at full depth instead of bot.
cp "$DEPTH" "$INSTALL/reviewer/scripts/small-full"
python3 - "$INSTALL/reviewer/scripts/small-full" 'small) DEPTH=bot ;;' 'small) DEPTH=full ;;' <<'PY'
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
status=0
(depth_table "$INSTALL/reviewer/scripts/small-full") >"$TMP_ROOT/control.log" 2>&1 || status=$?
assert_eq "$status" 1 'must-fail control rejects the changed small depth'

# The real classifier, installed whole beside a second copy of this package:
# a range confined to a kendex manifest, a JSON settings file or Markdown
# gets the cheapest class's depth at any size, and a script reads by its
# size.
REAL="$TMP_ROOT/real"
mkdir -p "$REAL/reviewer/scripts"
cp "$SKILL_DIR/scripts/review-depth" "$REAL/reviewer/scripts/"
cp -R "$SKILL_DIR/../change-scope" "$REAL/change-scope"
QUICK="$TMP_ROOT/quick"
git init -q -b main "$QUICK"
git -C "$QUICK" config user.email review-depth@example.invalid
git -C "$QUICK" config user.name review-depth
git -C "$QUICK" config gc.auto 0
git -C "$QUICK" config maintenance.auto false
printf '%s\n' '[".kendex-generated.json"]' >"$QUICK/.kendex-generated.json"
printf 'schema = 8\n[install]\nmethod = "copy"\n' >"$QUICK/kendex.toml"
mkdir -p "$QUICK/.vscode" "$QUICK/skills/x"
printf '{}\n' >"$QUICK/.vscode/settings.json"
printf '# X\n' >"$QUICK/skills/x/SKILL.md"
printf 'MODE=old\n' >"$QUICK/run.sh"
git -C "$QUICK" add -A
git -C "$QUICK" commit -qm base
QUICK_BASE="$(git -C "$QUICK" rev-parse HEAD)"
while IFS='|' read -r name path content lines expected; do
  git -C "$QUICK" checkout -q -B "$name" "$QUICK_BASE"
  if [ "$lines" = - ]; then
    printf '%b\n' "$content" >"$QUICK/$path"
  else
    awk -v n="$lines" 'BEGIN { for (i = 1; i <= n; i++) print "# Line " i "." }' >>"$QUICK/$path"
  fi
  git -C "$QUICK" add -A
  git -C "$QUICK" commit -qm "$name"
  status=0
  output="$(env -u HARNESS_CI_TRIVIAL_PATHS -u ORCH_SIZE_TEST_PATHS -u ORCH_SIZE_RENDER_ROOTS \
    "$REAL/reviewer/scripts/review-depth" --base "$QUICK_BASE" --head HEAD --repo "$QUICK" 2>"$TMP_ROOT/stderr")" || status=$?
  assert_eq "$status $output" "0 $expected" "$name: the real classifier's depth" "$TMP_ROOT/stderr"
done <<'ROWS'
manifest-past-small|kendex.toml||200|change_class=trivial review_depth=none native_approval=unchanged
json-settings-past-small|.vscode/settings.json||200|change_class=trivial review_depth=none native_approval=unchanged
skill-markdown-past-small|skills/x/SKILL.md||200|change_class=trivial review_depth=none native_approval=unchanged
script-past-micro|run.sh||40|change_class=small review_depth=bot native_approval=unchanged
ROWS

printf '\nreview-depth: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
