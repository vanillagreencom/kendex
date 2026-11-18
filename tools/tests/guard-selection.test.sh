#!/usr/bin/env bash
# tools/guard --selection previews the existing suite map. Its scoped route
# executes script owners, retaining repository checks and leaving CI the full record.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"
TIMING_PATH="$PATH"
source "$REPO/skills/agent-runtime/scripts/lib/key.sh"
TIMING_RUNTIME_CACHE="$(agent_runtime_cache)"

current_files() {
  git -C "$REPO" ls-files -z --cached --others --exclude-standard |
    while IFS= read -r -d '' file; do
      if [ -e "$REPO/$file" ] || [ -L "$REPO/$file" ]; then
        printf '%s\0' "$file"
      fi
    done
}

if [ "${1:-all}" != timing ]; then
nested_reach() { # GUARD INPUT
  RC=0
  OUT="$(cd "$REPO" && "$1" --suite-reach <<<"$2" 2>&1)" || RC=$?
}
for input in skills/agent-runtime/runtime/src/launch.rs skills/orch/tests/job/one-job.sh; do
  nested_reach "$GUARD" "$input"
  [ "$RC" -eq 0 ] && grep -Fxq skills/orch/tests/one_job.sh <<<"$OUT" \
    && ! grep -Fxq skills/orch/tests/job/one-job.sh <<<"$OUT" \
    && ok "nested input $input selects the one-job entry without executing its helper as a suite" \
    || bad "nested input $input selects the one-job entry without executing its helper as a suite" "$OUT"
done
if mutant_guard 's@\*:tests/\*/\*.sh | \*:tests/\*/\*.bash) echo helper@*:tests/lib/*.sh | *:tests/lib/*.bash) echo helper@'; then
  nested_reach "$MUTANT_TOOLS/guard" skills/agent-runtime/runtime/src/launch.rs
  [ "$RC" -eq 0 ] && ! grep -Fxq skills/orch/tests/one_job.sh <<<"$OUT" \
    && ok 'control: omitting the nested implementation loses one-job for an agent-runtime launch change' \
    || bad 'control: omitting the nested implementation loses one-job for an agent-runtime launch change' "$OUT"
else
  bad 'nested implementation control changes the guard'
fi
if [ "${1:-all}" = nested ]; then
  printf 'pass: %d fail: %d\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
  exit
fi
SUITE_LOG="$TMP/suites"
mkdir -p "$R/tools/tests"
printf '#!/usr/bin/env bash\nprintf "demo\\n" >> "$SUITE_LOG"\necho "pass: 1   fail: 0"\n' > "$R/skills/demo/tests/demo.test.sh"
printf '#!/usr/bin/env bash\nprintf "unrelated\\n" >> "$SUITE_LOG"\nexit 1\n' > "$R/skills/demo/tests/unrelated.test.sh"
printf '#!/usr/bin/env bash\nprintf "tool\\n" >> "$SUITE_LOG"\necho "pass: 1   fail: 0"\n' > "$R/tools/tests/demo-tool.test.sh"
printf '#!/usr/bin/env bash\nprintf "other-tool\\n" >> "$SUITE_LOG"\nexit 1\n' > "$R/tools/tests/other.test.sh"
printf 'unmapped\n' > "$R/tools/unmapped"
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false
git -C "$R" add -A
entry_points_executable
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
if mutant_guard 's/if \[ "\$selection_only" -eq 1 \] \&\& \[ "\$scoped_only" -eq 0 \] \&\& \[ -z "\$release_version" \]; then continue; fi/if [ "$selection_only" -eq 1 ] \&\& [ "$scoped_only" -eq 0 ] \&\& [ -z "$release_version" ] \&\& false; then continue; fi/'; then
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
# Each suite a run starts opens with the step line orch's validation reads to
# name a slow or stalled step.
step_line='validate-step: name=tools/tests/demo-tool.test.sh command=run-all.sh --local --suite tools/tests/demo-tool.test.sh'
grep -Fxq "$step_line" <<<"$OUT" \
  && ok 'a scoped run names each suite it starts as its step' \
  || bad 'a scoped run names each suite it starts as its step' "$OUT"
if mutant_guard '/RUN_ALL_PENDING_SUITES=\$pool_pending /s/ --local / /'; then
  preview range true "$MUTANT_TOOLS/guard"
  ! grep -Fxq "$step_line" <<<"$OUT" && [ "$(cat "$SUITE_LOG")" = tool ] \
    && ok 'control: a suite started with no step line turns the step row red' \
    || bad 'control: a suite started with no step line turns the step row red' "$OUT"
else
  bad 'step control changes the guard'
fi
# External inputs use the same mapper in full previews and range execution.
mkdir -p "$R/.github/workflows" "$R/skills/input/tests/lib"
printf 'workflow\n' > "$R/.github/workflows/skill-tests.yml"
printf 'unrelated\n' > "$R/.github/workflows/other.yml"
printf 'helper\n' > "$R/skills/input/tests/lib/evaluator.py"
printf '#!/usr/bin/env bash\necho "pass: 1   fail: 0"\n' > "$R/skills/input/tests/ignored.sh"
cat > "$R/tools/tests/ci-aggregate.test.sh" <<'SH'
#!/usr/bin/env bash
# Inputs: skills/input/tests/lib/*
workflow=.github/workflows/skill-tests.yml
printf 'aggregate\n' >> "$SUITE_LOG"
grep -Fxq broken "$workflow" && exit 1
echo "pass: 1   fail: 0"
SH
git -C "$R" add -A
entry_points_executable
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
echo "pass: 1   fail: 0"
SH
cat > "$R/skills/walkers/tests/catalog.test.sh" <<'SH'
#!/usr/bin/env bash
find "$PWD/skills" -name '*.md' >/dev/null
printf 'catalog\n' >> "$SUITE_LOG"
echo "pass: 1   fail: 0"
SH
printf ':\n' > "$R/skills/orch/scripts/lib/shared.sh"
printf ':\n' > "$R/skills/orch/scripts/lib/private.sh"
printf 'source "$PWD/skills/orch/scripts/lib/shared.sh"\n' > "$R/hooks/tests/lib/shared-world.sh"
cat > "$R/skills/orch/tests/libraries.test.sh" <<'SH'
#!/usr/bin/env bash
source "$PWD/skills/orch/scripts/lib/shared.sh"
source "$PWD/skills/orch/scripts/lib/private.sh"
printf 'orch\n' >> "$SUITE_LOG"
echo "pass: 1   fail: 0"
SH
cat > "$R/hooks/tests/shared.test.sh" <<'SH'
#!/usr/bin/env bash
source "$PWD/hooks/tests/lib/shared-world.sh"
printf 'hooks\n' >> "$SUITE_LOG"
echo "pass: 1   fail: 0"
SH
cat > "$R/refresh/tests/shared.test.sh" <<'SH'
#!/usr/bin/env bash
source "$PWD/skills/orch/scripts/lib/shared.sh"
printf 'refresh\n' >> "$SUITE_LOG"
echo "pass: 1   fail: 0"
SH
printf '#!/usr/bin/env bash\nprintf "unrelated-refresh\\n" >> "$SUITE_LOG"\nexit 1\n' > "$R/refresh/tests/unrelated.test.sh"
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -q -m libraries
BASE="$(git -C "$R" rev-parse HEAD)"
git -C "$R" update-ref refs/remotes/origin/main "$BASE"
for row in \
  'skills/orch/scripts/lib/shared.sh|hooks orch refresh' \
  'skills/orch/scripts/lib/private.sh|orch' \
  'skills/orch/README.md|' \
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

# Exercise the shipped aggregate assertion through range selection. This
# isolated checkout keeps the tools consumers used below so the routing
# fixture cannot select itself while proving a workflow defect.
actual="$TMP/aggregate-checkout"
mkdir -p "$actual"
current_files > "$TMP/aggregate-files"
tar -C "$REPO" --null -T "$TMP/aggregate-files" -cf "$TMP/aggregate-tree.tar"
tar -xf "$TMP/aggregate-tree.tar" -C "$actual"
# Metadata supplies the real build graph for this selection fixture. Every
# other Cargo call stays at the fixture boundary, including runtime tests.
REPLAY_REAL_CARGO="$(command -v cargo)" || exit 2
REPLAY_CARGO_LOG="$TMP/replay-cargo"
mkdir -p "$TMP/replay-bin"
cat >"$TMP/replay-bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$REPLAY_CARGO_LOG"
if [ "${1:-}" = metadata ]; then exec "$REPLAY_REAL_CARGO" "$@"; fi
SH
chmod +x "$TMP/replay-bin/cargo"
export REPLAY_REAL_CARGO REPLAY_CARGO_LOG
export PATH="$TMP/replay-bin:$PATH"
# Keep reader text and the shared runner for selection. Only the aggregate
# assertion executes its real contract in this checkout.
stub_replay_suite() { # REPOSITORY-RELATIVE-SUITE
  local suite="$1" stop header
  case "$suite" in
    *.mjs) stop="console.log('pass: 1   fail: 0'); process.exit(0);"; header='^[[:space:]]*(//|#!|$)' ;;
    *) stop="echo 'pass: 1   fail: 0'; exit 0"; header='^[[:space:]]*(#|$)' ;;
  esac
  # Header metadata must stay before the first command for the runtime lint.
  # The stop prints one passing row, since run-all.sh reds a suite that exits
  # 0 with no row counted.
  # Keep the body text so dependency selection still reads the real inputs.
  awk -v stop="$stop" -v header="$header" '
    !stopped && $0 !~ header { print stop; stopped = 1 }
    { print }
    END { if (!stopped) print stop }
  ' "$actual/$suite" > "$TMP/replay-suite"
  mv "$TMP/replay-suite" "$actual/$suite"
}
current_files | while IFS= read -r -d '' file; do
  case "$file" in */tests/*.sh | */tests/*.mjs) printf '%s\n' "$file" ;; esac
done > "$TMP/replay-suites"
while IFS= read -r suite; do
  case "$suite" in
    tools/* | */tests/run-all.sh | */tests/*/*) continue ;;
  esac
  stub_replay_suite "$suite"
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
entry_points_executable "$actual"
git -C "$actual" commit -q -m aggregate
actual_base="$(git -C "$actual" rev-parse HEAD)"
# The fixture row above proves that a selected failing aggregate rejects the
# range; this one proves the shipped aggregate suite is what a workflow edit
# selects. The tools roster here is that suite and vendored-settings-libs,
# which reads no workflow, so the mapped count names the aggregate.
printf '\n# changed workflow\n' >> "$actual/.github/workflows/skill-tests.yml"
RC=0
OUT="$(cd "$actual" && env -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS \
  DEV_VALIDATE_SCOPED=false "$GUARD" --selection --range "$actual_base" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && grep -Fxq 'guard-note: suites=1/2 reason=mapped tree=tools' <<<"$OUT" \
  && ok 'a workflow edit selects the shipped aggregate suite' \
  || bad 'a workflow edit selects the shipped aggregate suite' "rc=$RC out=$OUT"

# The replay base: the two tools suites keep their text for the mapper and
# stop before execution, so the row below proves selection alone.
git -C "$actual" reset -q --hard "$actual_base"
for suite in ci-aggregate.test.sh vendored-settings-libs.test.sh; do
  stub_replay_suite "tools/tests/$suite"
done
guard_fixture_suite_environment "$actual"
git -C "$actual" add tools/ci-job-set tools/tests/ci-aggregate.test.sh tools/tests/vendored-settings-libs.test.sh
git -C "$actual" commit -q -m replay
replay_base="$(git -C "$actual" rev-parse HEAD)"
# A noncanonical source and its render reach the shipped glob consumer
# through its input declaration. Its one-member tools roster makes the mapped
# count identify that consumer.
git -C "$actual" reset -q --hard "$replay_base"
rm -- "$actual/tools/tests/ci-aggregate.test.sh"
git -C "$actual" add -u tools/tests
git -C "$actual" commit -q -m 'glob consumer'
glob_base="$(git -C "$actual" rev-parse HEAD)"
for input in skills/github/scripts/lib/kendex-env.sh .agents/skills/github/scripts/lib/kendex-env.sh; do
  for mode in full range; do
    git -C "$actual" reset -q --hard "$glob_base"
    git -C "$actual" update-ref refs/remotes/origin/main "$glob_base"
    printf '\n# changed library input\n' >> "$actual/$input"
    replay_args=(--selection)
    if [ "$mode" = full ]; then replay_args+=(--full); else replay_args+=(--range "$glob_base"); fi
    RC=0
    OUT="$(cd "$actual" && env -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_DOCS_ONLY -u DEV_VALIDATE_PATHS \
      DEV_VALIDATE_SCOPED=false "$GUARD" "${replay_args[@]}" 2>&1)" || RC=$?
    [ "$RC" -eq 0 ] && grep -Fxq "guard-note: suites=1/1 reason=mapped tree=tools" <<<"$OUT" \
      && ok "$mode input $input maps its glob consumer" \
      || bad "$mode input $input maps its glob consumer" "rc=$RC out=$OUT"
  done
done
fi

# Keep the actual repository's dependency graph and workflow timing evidence.
# The configured command below is a tiny failure/repair fixture: it proves
# estimate consumption and admission, not the sampled suites' runtime.
timing="$TMP/timing-checkout"
mkdir -p "$timing"
current_files > "$TMP/timing-files"
tar -C "$REPO" --null -T "$TMP/timing-files" -cf "$TMP/timing-tree.tar"
tar -xf "$TMP/timing-tree.tar" -C "$timing"
git -C "$timing" init -q -b main
git -C "$timing" config user.name test
git -C "$timing" config user.email test@example.com
git -C "$timing" config core.hooksPath "$TMP/nohooks"
git -C "$timing" config gc.auto 0
git -C "$timing" config maintenance.auto false
timing_suite=harness-smoke.test
timing_pair=orch-shard-partition.test
timing_tests=tools/tests
timing_env=(env -i PATH="$TIMING_PATH" HOME="$TMP" LANG=C.UTF-8 LC_ALL=C TMPDIR="${TMPDIR:-$TMP}" AGENT_RUNTIME_CACHE="$TIMING_RUNTIME_CACHE" ORCH_STATE_DIR="$timing/tmp")
timing_run() {
  RC=0
  OUT="$("${timing_env[@]}" "$@" 2>&1)" || RC=$?
}
timing_preview() { # GUARD [MODE]
  if [ "${2:-range}" = full ]; then
    timing_run "$BASH" -c 'cd -- "$1" && "$2" --selection --full' _ "$timing" "$1"
  else
    timing_run "$BASH" -c 'cd -- "$1" && "$2" --selection --range "$3"' _ "$timing" "$1" "${timing_preview_base:-$timing_base}"
  fi
}
cat > "$timing/kendex.settings.toml" <<TOML
[env]
ORCH_PR_ORDER = "review-first"
DEV_VALIDATE_CMD = "$BASH $timing_tests/$timing_suite.sh"
DEV_VALIDATE_RANGE_CMD = "$BASH $timing_tests/$timing_suite.sh"
DEV_VALIDATE_SELECTION_CMD = "$GUARD --selection --range \$DEV_VALIDATE_BASE"
TOML
cat > "$timing/$timing_tests/$timing_suite.sh" <<'SH'
#!/usr/bin/env bash
printf 'attempt\n' >> tmp/attempts
grep -Fxq '# repair=done' "$0" || exit 1
printf 'validate: lanes=fixture selection=subset\n'
SH
git -C "$timing" add -A
git -C "$timing" commit -q -m fixture
timing_base="$(git -C "$timing" rev-parse HEAD)"
git -C "$timing" update-ref refs/remotes/origin/main "$timing_base"
printf '# selected\n' >> "$timing/$timing_tests/$timing_suite.sh"

# Native expected-secs is the selection preview's estimate. These values are
# independent of the parser: platform maximum 330 -> ceil(330 * 1.25) = 413.
# Partition timings cover --shell-only; guard runs combined, so neither its
# single invocation nor a selection containing it has complete coverage.
for row in 'single|413' 'pair|' 'partition|' 'full|' 'mixed|' 'uncovered|' 'shard-total|' 'unread|' 'unread-selected|' 'incomplete|'; do
  IFS='|' read -r label expected <<<"$row"
  git -C "$timing" reset -q --hard "$timing_base"
  timing_preview_base="$timing_base"
  printf '# selected\n' >> "$timing/$timing_tests/$timing_suite.sh"
  case "$label" in
    pair) printf '# selected\n' >> "$timing/$timing_tests/$timing_pair.sh" ;;
    partition)
      git -C "$timing" checkout -- "$timing_tests/$timing_suite.sh"
      printf '# selected\n' >> "$timing/$timing_tests/$timing_pair.sh" ;;
    mixed) printf '\n' >> "$timing/ui/package.json" ;;
    uncovered)
      printf '# selected\n' > "$timing/skills/orch/tests/selection_uncovered.sh"
      git -C "$timing" add skills/orch/tests/selection_uncovered.sh ;;
    shard-total)
      shard_suite=guards-tools.test
      printf '#!/usr/bin/env bash\nexit 0\n' > "$timing/$timing_tests/$shard_suite.sh"
      git -C "$timing" add "$timing_tests/$shard_suite.sh" ;;
    unread) rm "$timing/.github/workflows/skill-tests.yml" ;;
    unread-selected)
      sed 's/302-330s/unread/' "$timing/.github/workflows/skill-tests.yml" > "$TMP/unread-workflow"
      mv "$TMP/unread-workflow" "$timing/.github/workflows/skill-tests.yml" ;;
    incomplete)
      sed '/# suite sums over those legs, Linux then macOS:/d' "$timing/.github/workflows/skill-tests.yml" > "$TMP/incomplete-workflow"
      mv "$TMP/incomplete-workflow" "$timing/.github/workflows/skill-tests.yml" ;;
  esac
  case "$label" in
    unread | unread-selected | incomplete)
      git -C "$timing" add .github/workflows/skill-tests.yml
      git -C "$timing" commit -q -m timing-source
      timing_preview_base="$(git -C "$timing" rev-parse HEAD)" ;;
  esac
  if [ "$label" = full ]; then timing_preview "$GUARD" full; else timing_preview "$GUARD"; fi
  estimate="$(sed -n 's/^expected-secs=//p' <<<"$OUT")"
  [ "$RC" -eq 0 ] && [ "$estimate" = "$expected" ] && [ ! -e "$timing/tmp/attempts" ] \
    && ok "measured preview $label has estimate [$expected] without execution" \
    || bad "measured preview $label has estimate [$expected] without execution" "rc=$RC out=$OUT"
done
unset timing_preview_base
git -C "$timing" reset -q --hard "$timing_base"
printf '# selected\n' >> "$timing/$timing_tests/$timing_suite.sh"
timing_preview "$GUARD"
[ "$(sed -n '/^selection=/p' <<<"$OUT")" = selection=subset ] \
  && ok 'the measured single-suite preview is a real kendex subset' \
  || bad 'the measured single-suite preview is a real kendex subset' "$OUT"

runner=("$REPO/skills/orch/scripts/orch-runtime" validate entry)
mkdir -p "$timing/tmp"
timing_run "${runner[@]}" --worktree "$timing" --validate-mode range --base "$timing_base" --poll 1
failed_run="$(sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$OUT")"
[ "$RC" -eq 1 ] && [ "$(cat "$timing/tmp/attempts")" = attempt ] && [ -n "$failed_run" ] \
  && ok 'the native admission owner runs the within-bound original once and records failure' \
  || { bad 'the native admission owner runs the within-bound original once and records failure' "$OUT"; exit 1; }

printf '# repair=done\n' >> "$timing/$timing_tests/$timing_suite.sh"
# The focused repair proof executes the changed fixture, outside the configured
# attempt counter, just as the workflow requires before native admission.
timing_run "$BASH" -c 'cd -- "$1" && "$2" "$3"' _ "$timing" "$BASH" "$timing_tests/$timing_suite.sh"
[ "$RC" -eq 0 ] && ok 'the focused repair passes before the later run is admitted' \
  || { bad 'the focused repair passes before the later run is admitted' "$OUT"; exit 1; }
cp "$timing/tmp/attempts" "$TMP/proved-attempts"
timing_preview "$GUARD"
[ "$RC" -eq 0 ] && [ "$(sed -n '/^expected-secs=/p' <<<"$OUT")" = expected-secs=413 ] \
  && ok 'native repaired preview keeps its 413-second estimate' \
  || { bad 'native repaired preview keeps its 413-second estimate' "$OUT"; exit 1; }
# The round's later run is a new run of the same command: the failed run
# answers nothing for the repaired tree.
timing_run "${runner[@]}" --worktree "$timing" --validate-mode range --base "$timing_base" --poll 1
later_run="$(sed -n 's/^state=started run-dir=\([^ ]*\) .*$/\1/p' <<<"$OUT")"
[ "$RC" -eq 0 ] && [ -n "$later_run" ] \
  && [ "$(wc -l < "$timing/tmp/attempts")" -eq "$(( $(wc -l < "$TMP/proved-attempts") + 1 ))" ] \
  && ok 'measured admission runs the later run of the round once' \
  || { bad 'measured admission runs the later run of the round once' "$OUT"; exit 1; }
printf 'pass: %s fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
