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
      printf 'echo changed\n' >> "$R/tools/demo-tool.sh"
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
if mutant_guard 's/\[ "\$scoped_only" -eq 0 \] || run=""/[ "$scoped_only" -eq 0 ] || run=all/'; then
  preview range true "$MUTANT_TOOLS/guard"
  [ "$RC" -ne 0 ] && grep -Fxq other-tool "$SUITE_LOG" \
    && ok 'control: expanding scoped tools to every suite turns the exclusion red' \
    || bad 'control: expanding scoped tools to every suite turns the exclusion red' "rc=$RC out=$OUT"
else
  bad 'scoped control changes the guard'
fi

printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
