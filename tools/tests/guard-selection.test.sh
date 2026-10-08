#!/usr/bin/env bash
# tools/guard --selection previews the existing suite map. Its scoped route
# executes script owners, retaining repository checks and leaving CI the full record.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"

SUITE_LOG="$TMP/suites"
mkdir -p "$R/tools/tests"
printf '#!/usr/bin/env bash\nprintf "demo\\n" >> "$SUITE_LOG"\n' > "$R/skills/demo/tests/demo.test.sh"
printf '#!/usr/bin/env bash\nprintf "unrelated\\n" >> "$SUITE_LOG"\nexit 1\n' > "$R/skills/demo/tests/unrelated.test.sh"
printf '#!/usr/bin/env bash\nprintf "tool\\n" >> "$SUITE_LOG"\n' > "$R/tools/tests/demo-tool.test.sh"
printf '#!/usr/bin/env bash\nprintf "other-tool\\n" >> "$SUITE_LOG"\nexit 1\n' > "$R/tools/tests/other.test.sh"
printf 'unmapped\n' > "$R/tools/unmapped"
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false
git -C "$R" add -A
git -C "$R" commit -q -m fixture
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$BASE"

preview() { # MODE SCOPED [GUARD]
  local args=(--selection)
  if [ "$1" = range ]; then args+=(--range "$BASE"); else args+=(--full); fi
  : > "$SUITE_LOG"
  RC=0
  OUT="$(cd "$R" && env -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS \
    DEV_VALIDATE_SCOPED="$2" SUITE_LOG="$SUITE_LOG" "${3:-$GUARD}" "${args[@]}" 2>&1)" || RC=$?
}

for mode in full range; do
  for selection in all subset; do
    git -C "$R" reset -q --hard "$BASE"
    if [ "$selection" = all ]; then
      printf 'echo changed\n' >> "$R/tools/unmapped"
    else
      printf 'echo changed\n' >> "$R/skills/demo/scripts/demo.sh"
      printf 'echo changed\n' >> "$R/.agents/skills/demo/scripts/demo.sh"
    fi
    preview "$mode" false
    [ "$RC" -eq 0 ] && [ "$(sed -n '/^selection=/p' <<<"$OUT")" = "selection=$selection" ] && [ ! -s "$SUITE_LOG" ] \
      && ok "$mode previews $selection without executing any suite" \
      || bad "$mode previews $selection without executing any suite" "rc=$RC out=$OUT suites=$(cat "$SUITE_LOG")"
  done
done

# A disposable guard that executes during preview must fail the same no-run assertion.
if mutant_guard 's/if \[ "\$selection_only" -eq 1 \] \&\& \[ "\$scoped_only" -eq 0 \]; then continue; fi/if [ "$selection_only" -eq 1 ] \&\& [ "$scoped_only" -eq 0 ] \&\& false; then continue; fi/'; then
  preview range false "$MUTANT_TOOLS/guard"
  [ -s "$SUITE_LOG" ] && ok 'control: executing preview turns its no-suite guarantee red' \
    || bad 'control: executing preview turns its no-suite guarantee red' "$OUT"
else
  bad 'preview control changes the guard'
fi

git -C "$R" reset -q --hard "$BASE"
printf 'echo changed\n' >> "$R/tools/demo-tool.sh"
for mode in full range; do
  preview "$mode" true
  [ "$RC" -eq 0 ] && [ "$(cat "$SUITE_LOG")" = tool ] \
    && [ "$(sed -n '/^validate:/p' <<<"$OUT" | tail -1)" = 'validate: lanes=scoped-suites selection=subset' ] \
    && [ "$(sed -n '/^scoped=/p' <<<"$OUT")" = scoped=true ] \
    && ok "$mode scoped execution runs the changed tool's suite and excludes the unrelated suite" \
    || bad "$mode scoped execution runs the changed tool's suite and excludes the unrelated suite" "rc=$RC out=$OUT suites=$(cat "$SUITE_LOG")"
done
if mutant_guard 's/        case "\$d" in skills\/\* | hooks | tools) run="" ;; esac/        case "$d" in skills\/* | hooks) run="" ;; esac/; s/\[ "\$scoped_only" -eq 0 \] || run=""/[ "$scoped_only" -eq 0 ] || run=all/'; then
  preview range true "$MUTANT_TOOLS/guard"
  [ "$RC" -ne 0 ] && grep -Fxq other-tool "$SUITE_LOG" \
    && ok 'control: expanding scoped tools to every suite turns the exclusion red' \
    || bad 'control: expanding scoped tools to every suite turns the exclusion red' "rc=$RC out=$OUT"
else
  bad 'scoped control changes the guard'
fi

# External inputs use the same mapper in full previews and range execution.
mkdir -p "$R/.github/workflows" "$R/skills/input/tests/lib"
printf 'workflow\n' > "$R/.github/workflows/skill-tests.yml"
printf 'unrelated\n' > "$R/.github/workflows/other.yml"
printf 'helper\n' > "$R/skills/input/tests/lib/evaluator.py"
printf '#!/usr/bin/env bash\nexit 0\n' > "$R/skills/input/tests/ignored.sh"
cat > "$R/tools/tests/ci-aggregate.test.sh" <<'SH'
#!/usr/bin/env bash
# Inputs: skills/input/tests/lib/*
workflow=.github/workflows/skill-tests.yml
printf 'aggregate\n' >> "$SUITE_LOG"
grep -Fxq broken "$workflow" && exit 1
exit 0
SH
git -C "$R" add -A
git -C "$R" commit -q -m inputs
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$BASE"
for row in '.github/workflows/skill-tests.yml|aggregate' '.github/workflows/other.yml|' 'skills/input/tests/lib/evaluator.py|aggregate'; do
  IFS='|' read -r input expected <<<"$row"
  for mode in full range; do
    git -C "$R" reset -q --hard "$BASE"
    printf '# changed\n' >> "$R/$input"
    preview "$mode" false
    [[ $OUT == *'reason=mapped tree=tools'* ]] && [ "$RC" -eq 0 ] && [ ! -s "$SUITE_LOG" ] \
      && ok "$mode previews repository input $input" || bad "$mode previews repository input $input" "$OUT"
    preview "$mode" true
    [ "$RC" -eq 0 ] && [ "$(cat "$SUITE_LOG")" = "$expected" ] \
      && ok "$mode scoped input $input runs its reader" || bad "$mode scoped input $input runs its reader" "$OUT"
  done
done
git -C "$R" reset -q --hard "$BASE"
printf 'broken\n' >> "$R/.github/workflows/skill-tests.yml"
: > "$SUITE_LOG"
RC=0
OUT="$(cd "$R" && SUITE_LOG="$SUITE_LOG" "$GUARD" --range "$BASE" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && [ "$(cat "$SUITE_LOG")" = aggregate ] \
  && ok 'a failing aggregate input rejects actual range selection' || bad 'a failing aggregate input rejects actual range selection' "$OUT"
if mutant_guard 's/      \*) tree=tools; rel="\.\.\/\$f" ;;/      *) continue ;;/'; then
  : > "$SUITE_LOG"
  RC=0
  OUT="$(cd "$R" && SUITE_LOG="$SUITE_LOG" "$MUTANT_TOOLS/guard" --range "$BASE" 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] && [ ! -s "$SUITE_LOG" ] \
    && ok 'control: omitting workflow inputs hides the failing aggregate' || bad 'control: omitting workflow inputs hides the failing aggregate' "$OUT"
else
  bad 'external-input control changes the guard'
fi
if mutant_guard 's/^    inputs=$(sed .*$/    inputs=/' ; then
  git -C "$R" reset -q --hard "$BASE"
  printf '# changed\n' >> "$R/skills/input/tests/lib/evaluator.py"
  preview range true "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ ! -s "$SUITE_LOG" ] \
    && ok 'control: omitting input notes loses the indirect reader' || bad 'control: omitting input notes loses the indirect reader' "$OUT"
else
  bad 'input-note control changes the guard'
fi

# Exercise the shipped aggregate assertion through range selection. This
# isolated checkout keeps one tools suite so the routing fixture cannot
# select itself while proving a workflow defect.
actual="$TMP/aggregate-checkout"
mkdir -p "$actual"
git -C "$REPO" archive HEAD | tar -x -C "$actual"
for suite in "$actual"/tools/tests/*.sh; do
  case "${suite##*/}" in ci-aggregate.test.sh | run-all.sh) ;; *) rm -- "$suite" ;; esac
done
git -C "$actual" init -q
git -C "$actual" config user.email test@example.com
git -C "$actual" config user.name test
git -C "$actual" config core.hooksPath "$TMP/nohooks"
git -C "$actual" config gc.auto 0
git -C "$actual" config maintenance.auto false
git -C "$actual" add -A
git -C "$actual" commit -q -m aggregate
actual_base="$(git -C "$actual" rev-parse HEAD)"
sed 's/run: tools\/ci-job-set --event-parity/run: tools\/ci-job-set/' "$actual/.github/workflows/skill-tests.yml" > "$TMP/broken-workflow"
cmp -s "$actual/.github/workflows/skill-tests.yml" "$TMP/broken-workflow" && { bad 'aggregate control changes the workflow'; exit 1; }
mv "$TMP/broken-workflow" "$actual/.github/workflows/skill-tests.yml"
RC=0
OUT="$(cd "$actual" && "$GUARD" --range "$actual_base" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && [[ $OUT == *suite=ci-aggregate.test* ]] && [[ $OUT == *'fail=1'* ]] \
  && ok 'the shipped aggregate rejects a broken workflow through range selection' \
  || bad 'the shipped aggregate rejects a broken workflow through range selection' "$OUT"

printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
