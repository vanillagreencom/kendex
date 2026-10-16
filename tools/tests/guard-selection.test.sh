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
if mutant_guard 's/if (text ~ \/\^# Inputs: \/)/if (0)/' ; then
  git -C "$R" reset -q --hard "$BASE"
  printf '# changed\n' >> "$R/skills/input/tests/lib/evaluator.py"
  preview range true "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ ! -s "$SUITE_LOG" ] \
    && ok 'control: omitting input notes loses the indirect reader' || bad 'control: omitting input notes loses the indirect reader' "$OUT"
else
  bad 'input-note control changes the guard'
fi

# Shared skill libraries have consumers in other trees, directly or through
# a test helper. An unrelated library must keep those consumers excluded.
mkdir -p "$R/skills/orch/scripts/lib" "$R/skills/orch/tests" "$R/hooks/tests/lib" "$R/refresh/tests" "$R/skills/walkers/tests"
printf '# Orch\n' > "$R/skills/orch/README.md"
printf '# Hooks\n' > "$R/hooks/README.md"
cat > "$R/skills/walkers/tests/walker.test.sh" <<'SH'
#!/usr/bin/env bash
SKILL_DIR="$PWD/skills/walkers"
find "$SKILL_DIR" -name '*.md' >/dev/null
printf 'walker\n' >> "$SUITE_LOG"
SH
cat > "$R/skills/walkers/tests/catalog.test.sh" <<'SH'
#!/usr/bin/env bash
find "$PWD/skills" -name '*.md' >/dev/null
printf 'catalog\n' >> "$SUITE_LOG"
SH
printf ':\n' > "$R/skills/orch/scripts/lib/shared.sh"
printf ':\n' > "$R/skills/orch/scripts/lib/private.sh"
printf 'source "$PWD/skills/orch/scripts/lib/shared.sh"\n' > "$R/hooks/tests/lib/shared-world.sh"
cat > "$R/skills/orch/tests/libraries.test.sh" <<'SH'
#!/usr/bin/env bash
source "$PWD/skills/orch/scripts/lib/shared.sh"
source "$PWD/skills/orch/scripts/lib/private.sh"
printf 'orch\n' >> "$SUITE_LOG"
SH
cat > "$R/hooks/tests/shared.test.sh" <<'SH'
#!/usr/bin/env bash
source "$PWD/hooks/tests/lib/shared-world.sh"
printf 'hooks\n' >> "$SUITE_LOG"
SH
cat > "$R/refresh/tests/shared.test.sh" <<'SH'
#!/usr/bin/env bash
source "$PWD/skills/orch/scripts/lib/shared.sh"
printf 'refresh\n' >> "$SUITE_LOG"
SH
printf '#!/usr/bin/env bash\nprintf "unrelated-refresh\\n" >> "$SUITE_LOG"\nexit 1\n' > "$R/refresh/tests/unrelated.test.sh"
git -C "$R" add -A
git -C "$R" commit -q -m libraries
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$BASE"
for row in \
  'skills/orch/scripts/lib/shared.sh|hooks orch refresh' \
  'skills/orch/scripts/lib/private.sh|orch' \
  'skills/orch/README.md|catalog' \
  'hooks/README.md|'; do
  IFS='|' read -r input expected <<<"$row"
  for mode in full range; do
    git -C "$R" reset -q --hard "$BASE"
    printf '# changed\n' >> "$R/$input"
    preview "$mode" true
    selected="$(sort "$SUITE_LOG" | tr '\n' ' ' | sed 's/ $//')"
    [ "$RC" -eq 0 ] && [ "$selected" = "$expected" ] \
      && ok "$mode input $input selects its same-tree and external consumers only" \
      || bad "$mode input $input selects its same-tree and external consumers only" "selected=$selected rc=$RC out=$OUT"
  done
done
if [ "$(grep -c '^    for consumer in .*consumer_trees.*; do$' "$GUARD")" -eq 1 ] \
  && mutant_guard '/^    for consumer in .*consumer_trees.*; do$/,/^    done$/d'; then
  git -C "$R" reset -q --hard "$BASE"
  printf '# changed\n' >> "$R/skills/orch/scripts/lib/shared.sh"
  preview range true "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$(cat "$SUITE_LOG")" = orch ] \
    && ok 'control: omitting cross-tree inputs loses both hooks and refresh consumers' \
    || bad 'control: omitting cross-tree inputs loses both hooks and refresh consumers' "rc=$RC out=$OUT"
else
  bad 'cross-tree control changes the guard'
fi
if [ "$(grep -c '^    walk_root=' "$GUARD")" -eq 1 ] \
  && mutant_guard '/^    walk_root=/s/.*/    walk_root="$skill_root|$catalog_root"/'; then
  git -C "$R" reset -q --hard "$BASE"
  printf '# changed\n' >> "$R/skills/orch/scripts/lib/private.sh"
  preview range true "$MUTANT_TOOLS/guard"
  selected="$(sort "$SUITE_LOG" | tr '\n' ' ' | sed 's/ $//')"
  [ "$RC" -eq 0 ] && [ "$selected" = 'catalog orch walker' ] \
    && ok 'control: ignoring external walk roots selects unrelated document walkers' \
    || bad 'control: ignoring external walk roots selects unrelated document walkers' "selected=$selected rc=$RC out=$OUT"
else
  bad 'external walk-root control changes the guard'
fi

# Reader comparisons can fail while the files remain readable. Normal runs
# must run the whole set; scoped runs must refuse the unavailable evidence.
git -C "$R" reset -q --hard "$BASE"
printf '# Tools\n' > "$R/tools/README.md"
git -C "$R" add tools/README.md
git -C "$R" commit -q -m reader
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$BASE"
READER_GREP="$(command -v grep)"
READER_SED="$(command -v sed)"
READER_AWK="$(command -v awk)"
mkdir -p "$TMP/reader-bin"
cat > "$TMP/reader-bin/grep" <<'SH'
#!/usr/bin/env bash
if [ "${2:-}" = -e ] && [[ ${1:-} == -q[FE] ]]; then
  count=0
  [ ! -f "$READER_CALLS" ] || read -r count < "$READER_CALLS"
  count=$((count + 1))
  printf '%s\n' "$count" > "$READER_CALLS"
  [ "$count" != "$READER_FAILURE" ] || exit 2
fi
exec "$READER_GREP" "$@"
SH
cat > "$TMP/reader-bin/awk" <<'SH'
#!/usr/bin/env bash
program=$1
shift
case "$program:$READER_FAILURE" in
  *'function scan_file('*:[1234])
    needle='for (reader_phase = 0; reader_phase < 4; reader_phase++) {'
    [[ $program == *"$needle"* ]] || exit 2
    rest=${program#*"$needle"}
    [[ $rest != *"$needle"* ]] || exit 2
    phase=$((READER_FAILURE - 1))
    replacement="$needle if (reader_phase == $phase) injected_failure = 1;"
    program=${program/"$needle"/"$replacement"}
    program+=$'\nEND { if (injected_failure) exit 2 }'
    ;;
esac
exec "$READER_AWK" "$program" "$@"
SH
cat > "$TMP/reader-bin/sed" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  's/[]['*) [ "$READER_FAILURE" != sed ] || { printf 'sed\n' > "$READER_CALLS"; exit 2; } ;;
esac
exec "$READER_SED" "$@"
SH
chmod +x "$TMP/reader-bin/grep" "$TMP/reader-bin/sed" "$TMP/reader-bin/awk"
reader_failure() { # INPUT SCOPED FAILURE GUARD
  git -C "$R" reset -q --hard "$BASE"
  printf '# changed\n' >> "$R/$1"
  : > "$SUITE_LOG"
  rm -f -- "$TMP/reader-calls"
  RC=0
  OUT="$(cd "$R" && env -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS \
    PATH="$TMP/reader-bin:$PATH" READER_GREP="$READER_GREP" READER_SED="$READER_SED" READER_AWK="$READER_AWK" \
    READER_CALLS="$TMP/reader-calls" READER_FAILURE="$3" DEV_VALIDATE_SCOPED="$2" SUITE_LOG="$SUITE_LOG" \
    "$4" --selection --range "$BASE" 2>&1)" || RC=$?
}

# Two inputs in tools/ share the completed reader scan. The grep wrapper
# counts only the old per-reader comparisons, not extraction or other gates.
reader_grep_row() { # GUARD
  git -C "$R" reset -q --hard "$BASE"
  for input in tools/README.md .github/workflows/skill-tests.yml; do
    printf '# changed\n' >> "$R/$input"
  done
  rm -f -- "$TMP/reader-calls"
  : > "$SUITE_LOG"
  RC=0
  OUT="$(cd "$R" && env -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS \
    PATH="$TMP/reader-bin:$PATH" READER_GREP="$READER_GREP" READER_SED="$READER_SED" READER_AWK="$READER_AWK" \
    READER_CALLS="$TMP/reader-calls" READER_FAILURE=none DEV_VALIDATE_SCOPED=true SUITE_LOG="$SUITE_LOG" \
    "$1" --selection --range "$BASE" 2>&1)" || RC=$?
  reader_grep_calls=0
  [ ! -f "$TMP/reader-calls" ] || read -r reader_grep_calls < "$TMP/reader-calls"
  [ "$RC" -eq 0 ] && [ "$(cat "$SUITE_LOG")" = aggregate ] && [ "$reader_grep_calls" -eq 0 ]
}
reader_grep_row "$GUARD" \
  && ok 'two inputs reuse one tree reader scan without per-reader grep' \
  || bad 'two inputs reuse one tree reader scan without per-reader grep' "calls=$reader_grep_calls rc=$RC out=$OUT"
if mutant_guard '/^    doc_readers "\$rel" || return 2$/a\
    grep -qF -e "/$rel" -- ${SCAN_PATH[@]+"${SCAN_PATH[@]}"} || [ $? -eq 1 ] || return 2'; then
  if reader_grep_row "$MUTANT_TOOLS/guard"; then
    bad 'control: repeated reader grep turns the cached comparison assertion red'
  else
    [ "$reader_grep_calls" -gt 0 ] && [ "$RC" -eq 0 ] && [ "$(cat "$SUITE_LOG")" = aggregate ] \
      && ok 'control: repeated reader grep turns the cached comparison assertion red' \
      || bad 'control: repeated reader grep turns the cached comparison assertion red' "calls=$reader_grep_calls rc=$RC out=$OUT"
  fi
else
  bad 'reader grep control changes the guard'
fi

for failure in 1 2 3 4 sed; do
  for row in 'tools/README.md|false' '.github/workflows/skill-tests.yml|false' '.github/workflows/skill-tests.yml|true'; do
    IFS='|' read -r input scoped <<<"$row"
    reader_failure "$input" "$scoped" "$failure" "$GUARD"
    if [ "$scoped" = true ]; then
      [ "$RC" -ne 0 ] && [ ! -s "$SUITE_LOG" ] && [[ $OUT == *'guard: mapped-suites=2 '* ]] \
        && ok "reader $failure failure refuses scoped input $input" || bad "reader $failure failure refuses scoped input $input" "$OUT"
    else
      [ "$RC" -eq 0 ] && [[ $OUT == *'all reason=unreadable '* ]] && [ ! -s "$SUITE_LOG" ] \
        && ok "reader $failure failure selects all for $input" || bad "reader $failure failure selects all for $input" "$OUT"
    fi
  done
done
# The same injected failures must redden the contract when they are accepted
# as no match. Keep all comparisons so the control still reaches the error.
if mutant_guard '/scan_input.*|| return 2$/s/|| return 2/|| true/; s/^  token=\(.*\) || return 2$/  token=\1 || true/'; then
  for failure in 1 sed; do
    reader_failure .github/workflows/skill-tests.yml true "$failure" "$MUTANT_TOOLS/guard"
    [ -s "$SUITE_LOG" ] && [[ $OUT != *'guard: mapped-suites=2 '* ]] \
      && ok "control: accepting reader $failure failure loses scoped refusal" || bad "control: accepting reader $failure failure loses scoped refusal" "$OUT"
  done
else
  bad 'reader-failure control changes the guard'
fi

# Exercise the shipped aggregate assertion through range selection. This
# isolated checkout keeps the tools consumers used below so the routing
# fixture cannot select itself while proving a workflow defect.
actual="$TMP/aggregate-checkout"
mkdir -p "$actual"
git -C "$REPO" ls-files -z > "$TMP/aggregate-files"
tar -C "$REPO" --null -T "$TMP/aggregate-files" -cf "$TMP/aggregate-tree.tar"
tar -xf "$TMP/aggregate-tree.tar" -C "$actual"
# Keep reader text and the shared runner for selection. Only the aggregate
# assertion executes its real contract in this checkout.
git -C "$REPO" ls-files '*/tests/*.sh' '*/tests/*.mjs' > "$TMP/replay-suites"
while IFS= read -r suite; do
  case "$suite" in
    tools/* | */tests/run-all.sh | */tests/*/*) continue ;;
    *.mjs) printf 'process.exit(0);\n' > "$TMP/replay-suite" ;;
    *) printf 'exit 0\n' > "$TMP/replay-suite" ;;
  esac
  cat "$actual/$suite" >> "$TMP/replay-suite"
  mv "$TMP/replay-suite" "$actual/$suite"
done < "$TMP/replay-suites"
for suite in "$actual"/tools/tests/*.sh; do
  case "${suite##*/}" in ci-aggregate.test.sh | vendored-settings-libs.test.sh | run-all.sh) ;; *) rm -- "$suite" ;; esac
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

# PR #5200's changed orch scripts and libraries must reach the real hooks
# and refresh readers. Preserve suite text for the mapper, but stop bodies
# before execution: this row proves selection, not those suites' contracts.
git -C "$actual" reset -q --hard "$actual_base"
for suite in ci-aggregate.test.sh vendored-settings-libs.test.sh; do
  printf 'exit 0\n' > "$TMP/replay-suite"
  cat "$actual/tools/tests/$suite" >> "$TMP/replay-suite"
  mv "$TMP/replay-suite" "$actual/tools/tests/$suite"
done
git -C "$actual" add tools/tests/ci-aggregate.test.sh tools/tests/vendored-settings-libs.test.sh
git -C "$actual" commit -q -m replay
replay_base="$(git -C "$actual" rev-parse HEAD)"
for input in \
  skills/orch/scripts/lib/adapters/claude.sh \
  skills/orch/scripts/lib/lane-launch.sh \
  skills/orch/scripts/lib/lane-model.sh \
  skills/orch/scripts/lib/lane-relaunch.sh \
  skills/orch/scripts/lib/overseer-launch.sh \
  skills/orch/scripts/oversee \
  skills/orch/scripts/oversee-succeed; do
  printf '\n# KEN-3966 replay\n' >> "$actual/$input"
  printf '\n# KEN-3966 replay\n' >> "$actual/.agents/$input"
done
RC=0
OUT="$(cd "$actual" && env -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS \
  DEV_VALIDATE_SCOPED=true "$GUARD" --selection --range "$replay_base" 2>&1)" || RC=$?
for suite in hooks/tests/lane-mail-check.test.sh hooks/tests/lane-mail-model-switch.test.sh refresh/tests/refresh-consumer.test.sh; do
  [ "$RC" -eq 0 ] && grep -Fxq "=== $suite" <<<"$OUT" \
    && ok "KEN-3966 replay selects $suite" || bad "KEN-3966 replay selects $suite" "rc=$RC out=$OUT"
done

# A noncanonical source and its render reach the shipped glob consumer only
# through its input declaration. Its one-member tools roster makes the mapped
# count identify that consumer. Both baselines retain the consumer's code.
git -C "$actual" reset -q --hard "$replay_base"
rm -- "$actual/tools/tests/ci-aggregate.test.sh"
git -C "$actual" add -u tools/tests
git -C "$actual" commit -q -m 'glob consumer'
glob_base="$(git -C "$actual" rev-parse HEAD)"
consumer=tools/tests/vendored-settings-libs.test.sh
input_note='# Inputs: skills/*/scripts/lib/kendex-env.sh .agents/skills/*/scripts/lib/kendex-env.sh'
if [ "$(grep -Fxc "$input_note" "$actual/$consumer")" -ne 1 ]; then
  bad 'the glob-consumer control finds one input declaration'
  exit 1
fi
sed '/^# Inputs: /d' "$actual/$consumer" > "$TMP/replay-suite"
cmp -s "$actual/$consumer" "$TMP/replay-suite" && { bad 'the glob-consumer control removes its declaration'; exit 1; }
mv "$TMP/replay-suite" "$actual/$consumer"
git -C "$actual" add "$consumer"
git -C "$actual" commit -q -m 'without glob inputs'
without_inputs_base="$(git -C "$actual" rev-parse HEAD)"
for row in \
  'present|skills/github/scripts/lib/kendex-env.sh|1/1' \
  'present|.agents/skills/github/scripts/lib/kendex-env.sh|1/1' \
  'absent|skills/github/scripts/lib/kendex-env.sh|0/1' \
  'absent|.agents/skills/github/scripts/lib/kendex-env.sh|0/1'; do
  IFS='|' read -r declaration input expected <<<"$row"
  if [ "$declaration" = present ]; then input_base=$glob_base; else input_base=$without_inputs_base; fi
  for mode in full range; do
    git -C "$actual" reset -q --hard "$input_base"
    git -C "$actual" update-ref refs/remotes/origin/main "$input_base"
    printf '\n# changed library input\n' >> "$actual/$input"
    replay_args=(--selection)
    if [ "$mode" = full ]; then replay_args+=(--full); else replay_args+=(--range "$input_base"); fi
    RC=0
    OUT="$(cd "$actual" && env -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS \
      DEV_VALIDATE_SCOPED=false "$GUARD" "${replay_args[@]}" 2>&1)" || RC=$?
    [ "$RC" -eq 0 ] && grep -Fxq "guard-note: suites=$expected reason=mapped tree=tools" <<<"$OUT" \
      && ok "$mode input $input with declaration $declaration maps glob consumer $expected" \
      || bad "$mode input $input with declaration $declaration maps glob consumer $expected" "rc=$RC out=$OUT"
  done
done

printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
