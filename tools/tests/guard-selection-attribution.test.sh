#!/usr/bin/env bash
# tools/guard's scoped selection attributes a changed path to the suites that
# read it, and runs its tree's whole set only where it finds no reader:
# mapped_suites' header and path_role's table state the rule.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"

# skills/attr: a settings example, source and render, that a suite reads by
# path, and a data file under tests/ that nothing reads. skills/bare: an
# example nothing reads, as most packages keep theirs.
mkdir -p "$R/skills/attr/tests/data" "$R/.agents/skills/attr" "$R/skills/bare/tests" "$R/.agents/skills/bare"
for tree in attr bare; do
  printf '[env]\n# ATTR_KEY = "a"\n' > "$R/skills/$tree/kendex.settings.toml.example"
  cp "$R/skills/$tree/kendex.settings.toml.example" "$R/.agents/skills/$tree/kendex.settings.toml.example"
done
printf 'grep -q ATTR "$PWD/skills/attr/kendex.settings.toml.example"\nprintf "linted\\n" >> "$SUITE_LOG"\necho "pass: 1   fail: 0"\n' > "$R/skills/attr/tests/linted.sh"
for name in one two; do
  printf 'printf "attr-%s\\n" >> "$SUITE_LOG"\necho "pass: 1   fail: 0"\n' "$name" > "$R/skills/attr/tests/$name.sh"
  printf 'printf "bare-%s\\n" >> "$SUITE_LOG"\necho "pass: 1   fail: 0"\n' "$name" > "$R/skills/bare/tests/$name.sh"
done
printf 'row\n' > "$R/skills/attr/tests/data/rows.txt"
# skills/pyimp: Python modules under tests/fixtures/, as skills/jarvis keeps
# its harness, which test programs import by dotted path in each import form;
# each wrapper runs one test program by path. Nothing imports unused.py.
mkdir -p "$R/skills/pyimp/tests/fixtures"
for name in harness other unused; do printf 'VALUE = 1\n' > "$R/skills/pyimp/tests/fixtures/$name.py"; done
printf 'from fixtures.harness import VALUE\n' > "$R/skills/pyimp/tests/from_test.py"
printf 'import json, fixtures.other\n' > "$R/skills/pyimp/tests/import_test.py"
printf 'VALUE = 2\n' > "$R/skills/pyimp/tests/plain_test.py"
for name in from import plain; do
  printf 'python3 -B "$PWD/skills/pyimp/tests/%s_test.py"\nprintf "%s\\n" >> "$SUITE_LOG"\necho "pass: 1   fail: 0"\n' "$name" "$name" \
    > "$R/skills/pyimp/tests/$name-wrapper.sh"
done
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm attribution
BASE="$(git -C "$R" rev-parse HEAD)"
SUITE_LOG="$TMP/suites"
ATTR_ALL='skills/attr/tests/linted.sh skills/attr/tests/one.sh skills/attr/tests/two.sh '
BARE_ALL='skills/bare/tests/one.sh skills/bare/tests/two.sh '
PY_ALL='skills/pyimp/tests/from-wrapper.sh skills/pyimp/tests/import-wrapper.sh skills/pyimp/tests/plain-wrapper.sh '

attr_change() { # CHANGE: one edit of the world, then a clean SUITE_LOG
  case "$1" in
    attr-example-comment | bare-example-comment)
      tree=${1%%-*}
      for example in "skills/$tree" ".agents/skills/$tree"; do
        printf '# The poll interval.\n' >> "$R/$example/kendex.settings.toml.example"
      done
      ;;
    unread-data) printf 'row two\n' >> "$R/skills/attr/tests/data/rows.txt" ;;
    harness-module | other-module | unused-module)
      printf 'VALUE = 3\n' >> "$R/skills/pyimp/tests/fixtures/${1%-module}.py"
      ;;
  esac
  [ -n "$(git -C "$R" status --porcelain)" ] || bad "fixture change $1 changed nothing"
  : > "$SUITE_LOG"
}
# The scoped selection: PLAN, its selected-suite lines.
attr_selection() { # GUARD
  RC=0
  OUT="$(cd "$R" && DEV_VALIDATE_SCOPED=true SUITE_LOG="$SUITE_LOG" "$1" --selection --range "$BASE" 2>&1)" || RC=$?
  PLAN="$(sed -n 's/^guard-note: selected-suite=//p' <<<"$OUT" | sort | tr '\n' ' ')"
}

# name | change | selected suites | the whole-set note, or - for none
for row in \
  "a prose-comment example change selects the suite reading it by path|attr-example-comment|skills/attr/tests/linted.sh |-" \
  "a prose-comment example change nothing reads selects no suite|bare-example-comment||-" \
  "a path no file reads still selects its tree's whole set|unread-data|$ATTR_ALL|skills/attr/tests/data/rows.txt" \
  "a test module a from line imports by dotted path selects its importer's wrapper|harness-module|skills/pyimp/tests/from-wrapper.sh |-" \
  "a test module an import line lists by dotted path selects its importer's wrapper|other-module|skills/pyimp/tests/import-wrapper.sh |-" \
  "a test module nothing imports still selects its tree's whole set|unused-module|$PY_ALL|skills/pyimp/tests/fixtures/unused.py"; do
  IFS='|' read -r name change expected whole <<<"$row"
  attr_change "$change"
  attr_selection "$GUARD"
  if [ "$whole" = - ]; then
    ! grep -q '^guard-note: suites=all ' <<<"$OUT" || expected="no whole-set note"
  else
    grep -qx "guard-note: suites=all reason=unidentified path=$whole" <<<"$OUT" || expected="the unidentified note"
  fi
  [ "$RC" -eq 0 ] && [ "$PLAN" = "$expected" ] \
    && ok "scoped attribution: $name" \
    || bad "scoped attribution: $name" "rc=$RC plan=$PLAN expected=$expected out=$OUT"
  git -C "$R" checkout -q -- .
done

# Control: with the example role held to a change that names a key, a
# prose-comment change is a path of no role that no note names, so its tree's
# whole set runs.
read -r -d '' KEY_ONLY <<'SED' || true
/^    skills\/\*:kendex\.settings\.toml\.example)$/,/^      ;;$/s/^      \[ "\$scoped_only" -eq 1 \] || return 1$/      [[ ${example_areas-} == *" $1"$'\\n'* ]] || return 1/
SED
if mutant_guard "$KEY_ONLY"; then
  attr_change bare-example-comment
  attr_selection "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$PLAN" = "$BARE_ALL" ] \
    && grep -qx 'guard-note: suites=all reason=unidentified path=.agents/skills/bare/kendex.settings.toml.example' <<<"$OUT" \
    && ok 'control: the key-only example role selects the whole set and breaks the comment row' \
    || bad 'control: the key-only example role selects the whole set and breaks the comment row' "rc=$RC plan=$PLAN out=$OUT"
  git -C "$R" checkout -q -- .
else
  bad 'control restores the key-only example role'
fi
# Control: without the test-import role a module under tests/fixtures/ is a
# path of no role that no note names, so its tree's whole set runs.
if mutant_guard '/^    \*:tests\/\*\/\*\.py)$/,/^      ;;$/d'; then
  attr_change harness-module
  attr_selection "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$PLAN" = "$PY_ALL" ] \
    && grep -qx 'guard-note: suites=all reason=unidentified path=skills/pyimp/tests/fixtures/harness.py' <<<"$OUT" \
    && ok 'control: without the test-import role a fixtures module selects the whole set and breaks the from-line row' \
    || bad 'control: without the test-import role a fixtures module selects the whole set and breaks the from-line row' "rc=$RC plan=$PLAN out=$OUT"
  git -C "$R" checkout -q -- .
else
  bad 'control removes the test-import role'
fi

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
