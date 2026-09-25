#!/usr/bin/env bash
# tools/guard --range BASE, a fix round's validation: the default rules read
# over the changes since BASE, cargo check and clippy for the crates those
# changes touch, the UI checks and suite for a non-Markdown UI change, and the
# suites of the trees they touch, and none of what --full adds beyond that: the
# workspace test run, cross-target checks, the documentation build, the Bash
# 3.2 parse, the working-tree bot-instructions check, the decision-ID check,
# the cargo free-space floor and the class lane selection. Every compiler and
# toolchain call is a stub in fake-bin that logs what it was asked.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"

CALLS="$TMP/calls"
mkdir -p "$R/fake-bin"
for tool in cargo npm; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"$CALL_LOG"\n' "$tool" >"$R/fake-bin/$tool"
  chmod +x "$R/fake-bin/$tool"
done
cat >"$R/fake-bin/rustup" <<'SH'
#!/usr/bin/env bash
printf '%s\n' aarch64-apple-darwin x86_64-pc-windows-msvc
SH
chmod +x "$R/fake-bin/rustup"

# A workspace with one crate and a UI package, and a skill whose suite fails
# whenever it runs, so a suite that runs untouched reds the row.
printf '[workspace]\n' >"$R/Cargo.toml"
mkdir -p "$R/crates/core/src" "$R/ui/src" "$R/skills/quiet/tests"
printf '[package]\nname = "kendex-core"\n\n[lints]\nworkspace = true\n' >"$R/crates/core/Cargo.toml"
# The crate includes a file from outside crates/, the shape compiled_includes
# derives, and carries a non-Rust asset of its own.
mkdir -p "$R/docs" "$R/crates/core/assets"
printf 'note\n' >"$R/docs/note.txt"
printf 'asset\n' >"$R/crates/core/assets/data.txt"
printf '%s\n' 'pub fn core() {}' 'pub const NOTE: &str = include_str!("../../../docs/note.txt");' >"$R/crates/core/src/lib.rs"
printf '{"name": "ui"}\n' >"$R/ui/package.json"
printf 'export const ui = 1;\n' >"$R/ui/src/main.ts"
printf '#!/usr/bin/env bash\nexit 1\n' >"$R/skills/quiet/tests/quiet.test.sh"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: a crate, a UI package and a skill whose suite fails"
BASE="$(git -C "$R" rev-parse HEAD)"

run_range() { # BASE [GUARD] — sets OUT, RC and LOG; GUARD defaults to the real one
  OUT=""
  RC=0
  : >"$CALLS"
  OUT="$(cd "$R" && env PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "${2:-$GUARD}" --range "$1" 2>&1 </dev/null)" || RC=$?
  LOG="$(cat "$CALLS")"
}
back_to_base() {
  git -C "$R" reset -q --hard "$BASE"
  git -C "$R" clean -qfd -e fake-bin
}

echo "=== a range touching only a skill runs that skill's suite and no cargo command ==="
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
printf 'echo more\n' >>"$R/.agents/skills/demo/scripts/demo.sh"
run_range "$BASE"
[ "$RC" -eq 0 ] && [ -z "$LOG" ] && [[ "$OUT" == *"=== skills/demo/tests/demo.test.sh"* ]] && [[ "$OUT" != *"skills/quiet"* ]] \
  && ok "the touched skill's suite runs, the untouched one does not, and cargo and npm are never called" \
  || bad "the touched skill's suite runs, the untouched one does not, and cargo and npm are never called" "rc=$RC log=$LOG out=$OUT"
# The inverse is the battery a fix round ran before range mode: the same diff
# under --full runs the workspace tests.
OUT=""
RC=0
: >"$CALLS"
OUT="$(cd "$R" && env "${GUARD_TEST_BOUNDS[@]}" PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$GUARD" --full 2>&1 </dev/null)" || RC=$?
grep -qFx "cargo test --workspace --quiet" "$CALLS" \
  && ok "inverse: the same skill-only diff under --full runs the workspace tests" \
  || bad "inverse: the same skill-only diff under --full runs the workspace tests" "rc=$RC log=$(cat "$CALLS")"
if mutant_guard 's/^\[ "\$MODE" != full \] || ! lane_on cargo_lint || rust_all=1$/! lane_on cargo_lint || rust_all=1/'; then
  run_range "$BASE" "$MUTANT_TOOLS/guard"
  grep -qFx "cargo check --workspace --all-targets" <<<"$LOG" \
    && ok "control: with range compiling everything the skill-only diff reaches cargo" \
    || bad "control: with range compiling everything the skill-only diff reaches cargo" "rc=$RC log=$LOG"
else
  bad "control: the full-mode compile set could not be widened to range in a guard copy"
fi
back_to_base

echo "=== what a range compiles is what it touched since its base ==="
CORE_CALLS="cargo tree -p kendex-core -e normal
cargo check --manifest-path crates/core/Cargo.toml --all-targets
cargo clippy --manifest-path crates/core/Cargo.toml --all-targets --quiet -- -D warnings
cargo fmt --check"
WORKSPACE_CALLS="cargo tree -p kendex-core -e normal
cargo check --workspace --all-targets
cargo clippy --workspace --all-targets --quiet -- -D warnings
cargo fmt --check"
UI_CALLS="npm run --prefix ui check:types
npm run --prefix ui check:lint
npm run --prefix ui test -- --silent"
# label|how the change sits (worktree or commit)|path appended to|every call
# guard makes, in order
ROWS=(
  "a crate's source file checks and lints that crate alone|worktree|crates/core/src/lib.rs|$CORE_CALLS"
  "a crate change committed after the base is in the range too|commit|crates/core/src/lib.rs|$CORE_CALLS"
  "an untracked shared compiler input checks and lints the workspace|worktree|Cargo.lock|$WORKSPACE_CALLS"
  "the clippy configuration checks and lints the workspace|worktree|clippy.toml|$WORKSPACE_CALLS"
  "a UI file runs the UI checks and the UI suite|worktree|ui/src/main.ts|$UI_CALLS"
  "a markdown file under ui/ runs no UI check|worktree|ui/README.md|"
  "a crate's non-Rust file checks and lints that crate|worktree|crates/core/assets/data.txt|$CORE_CALLS"
  "a file outside crates/ that compiled code includes checks and lints the workspace|worktree|docs/note.txt|$WORKSPACE_CALLS"
)
before=$((PASS + FAIL))
for row in "${ROWS[@]}"; do
  IFS='|' read -r label sits path _ <<<"$row"
  want="${row#*|*|*|}"
  printf 'x\n' >>"$R/$path"
  if [ "$sits" = commit ]; then
    git -C "$R" add -A
    git -C "$R" commit -q -m "fix: a change inside the range"
  fi
  run_range "$BASE"
  [ "$RC" -eq 0 ] && [ "$LOG" = "$want" ] \
    && ok "$label" \
    || bad "$label" "rc=$RC log=$LOG out=$OUT"
  back_to_base
done
[ "$((PASS + FAIL))" -eq "$((before + ${#ROWS[@]}))" ] || { echo "a compile-set row asserted nothing" >&2; exit 2; }
# The markdown row above is the one a missing exclusion would widen: ui/
# matches the UI arm once markdown is no longer turned away first.
printf 'x\n' >>"$R/ui/README.md"
if mutant_guard '/^    \*\.md) return 0 ;;$/d'; then
  run_range "$BASE" "$MUTANT_TOOLS/guard"
  grep -qFx "npm run --prefix ui check:types" <<<"$LOG" \
    && ok "control: without the markdown exclusion the ui/ markdown file runs the UI checks" \
    || bad "control: without the markdown exclusion the ui/ markdown file runs the UI checks" "rc=$RC log=$LOG"
else
  bad "control: the markdown exclusion could not be deleted from a guard copy"
fi
back_to_base
# Each new arm is what its row stands on: with one deleted, its row's change
# compiles nothing.
# label|path appended to|sed expression deleting the arm
ARM_CONTROLS=(
  "control: without the clippy entry a clippy.toml change compiles nothing|clippy.toml|s/ | clippy.toml) return 0 ;;$/) return 0 ;;/"
  "control: without the crate-file arm the crate asset compiles nothing|crates/core/assets/data.txt|/^      crates\/\*\/\*) add_crate \"\$f\" ;;$/d"
  "control: without the include arm the included file compiles nothing|docs/note.txt|/^    if grep -Fxq -- \"\$f\" <<<\"\$range_includes\"; then rust_all=1; fi$/d"
)
for row in "${ARM_CONTROLS[@]}"; do
  IFS='|' read -r label path expr <<<"$row"
  printf 'x\n' >>"$R/$path"
  if mutant_guard "$expr"; then
    run_range "$BASE" "$MUTANT_TOOLS/guard"
    [ "$RC" -eq 0 ] && [ -z "$LOG" ] \
      && ok "$label" \
      || bad "$label" "rc=$RC log=$LOG"
  else
    bad "$label" "the arm could not be deleted from a guard copy"
  fi
  back_to_base
done

echo "=== a range keeps its own selection whatever class it is handed ==="
# dev-validate-run hands every run the branch's change class; the lane
# selection that reads it is the full run's, and a range selects from its own
# touched set.
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
printf 'echo more\n' >>"$R/.agents/skills/demo/scripts/demo.sh"
printf '%s\n' skills/demo/scripts/demo.sh .agents/skills/demo/scripts/demo.sh >"$TMP/class-paths"
range_classed() { # GUARD
  OUT=""
  RC=0
  : >"$CALLS"
  OUT="$(cd "$R" && env DEV_VALIDATE_CLASS=render DEV_VALIDATE_DOCS_ONLY=false DEV_VALIDATE_PATHS="$TMP/class-paths" \
    PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$1" --range "$BASE" 2>&1 </dev/null)" || RC=$?
}
range_classed "$GUARD"
[ "$RC" -eq 0 ] && [[ "$OUT" == *"=== skills/demo/tests/demo.test.sh"* ]] \
  && ok "a range handed a render class still runs the touched skill's suite" \
  || bad "a range handed a render class still runs the touched skill's suite" "rc=$RC out=$OUT"
if mutant_guard 's/^if \[ "\$MODE" = full \] && \[ "\$validate_class:\$validate_docs_only" != standard:false \]; then$/if [ "$MODE" != default ] \&\& [ "$validate_class:$validate_docs_only" != standard:false ]; then/'; then
  range_classed "$MUTANT_TOOLS/guard"
  [[ "$OUT" != *"=== skills/demo/tests/demo.test.sh"* ]] \
    && ok "control: with the class selection applied to range the suite stands down" \
    || bad "control: with the class selection applied to range the suite stands down" "rc=$RC out=$OUT"
else
  bad "control: the class selection could not be widened to range in a guard copy"
fi
back_to_base

echo "=== the decision-ID check is the full run's, not the range's ==="
# The check judges the branch against the base before merge; a range leaves it
# to that full run. A shared ID in the INDEX would red the check.
mkdir -p "$R/docs/decisions"
printf '%s\n' \
  '| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |' \
  '|------|----|----------|----------|-----------|--------------|--------|------|' \
  '| 2026-01-10 | D035 | P-1 | One | Reason | Never | Active | [Full](D035-one.md) |' \
  '| 2026-01-11 | D035 | P-2 | Two | Reason | Never | Active | [Full](D035-two.md) |' \
  >"$R/docs/decisions/INDEX.md"
run_range "$BASE"
[ "$RC" -eq 0 ] && [[ "$OUT" != *"guard: decision-ids="* ]] \
  && ok "a range leaves a shared decision ID to the full run" \
  || bad "a range leaves a shared decision ID to the full run" "rc=$RC out=$OUT"
if mutant_guard 's/^if \[ "\$MODE" = full \]; then$/if [ "$MODE" != default ]; then/'; then
  run_range "$BASE" "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: decision-ids=1"* ]] \
    && ok "control: with the check widened to range the shared ID reds it" \
    || bad "control: with the check widened to range the shared ID reds it" "rc=$RC out=$OUT"
else
  bad "control: the decision-ID check could not be widened to range in a guard copy"
fi
back_to_base

echo "=== the cargo space floor is the full run's, not the range's ==="
# The floor is sized for one full run: its workspace tests and target trees.
# A range compiles only the crates it touched, so unreachable floors leave it
# compiling.
printf 'x\n' >>"$R/crates/core/src/lib.rs"
OUT=""
RC=0
: >"$CALLS"
OUT="$(cd "$R" && env GUARD_MIN_FREE_GB=1000000 GUARD_EXHAUSTED_FREE_MB=1000000000 PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$GUARD" --range "$BASE" 2>&1 </dev/null)" || RC=$?
[ "$RC" -eq 0 ] && [[ "$OUT" != *"guard: cargo-space-"* ]] && grep -qFx "cargo check --manifest-path crates/core/Cargo.toml --all-targets" "$CALLS" \
  && ok "a range under unreachable space floors still checks its crate" \
  || bad "a range under unreachable space floors still checks its crate" "rc=$RC out=$OUT"
if mutant_guard 's/^if \[ "\$MODE" = full \] && \[ -f Cargo.toml \]; then$/if [ "$MODE" != default ] \&\& [ -f Cargo.toml ]; then/'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && env GUARD_MIN_FREE_GB=1000000 GUARD_EXHAUSTED_FREE_MB=1000000000 PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$MUTANT_TOOLS/guard" --range "$BASE" 2>&1 </dev/null)" || RC=$?
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: cargo-space-"* ]] \
    && ok "control: with the floor applied to range the same run stops on space" \
    || bad "control: with the floor applied to range the same run stops on space" "rc=$RC out=$OUT"
else
  bad "control: the space floor could not be widened to range in a guard copy"
fi
back_to_base

echo "=== an include read that fails compiles the workspace ==="
# Without the derivation no change can be shown to reach no included file, so
# the range compiles everything and says why.
REAL_FIND="$(command -v find)"
cat >"$R/fake-bin/find" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAIL_FIND:-0}" -eq 1 ] && [ "${1:-}" = crates ] && [ "${4:-}" = -name ] && [ "${5:-}" = '*.rs' ]; then
  exit 1
fi
exec "$REAL_FIND" "$@"
SH
chmod +x "$R/fake-bin/find"
range_find_fails() { # GUARD
  OUT=""
  RC=0
  : >"$CALLS"
  OUT="$(cd "$R" && env FAIL_FIND=1 REAL_FIND="$REAL_FIND" PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$1" --range "$BASE" 2>&1 </dev/null)" || RC=$?
  LOG="$(cat "$CALLS")"
}
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
printf 'echo more\n' >>"$R/.agents/skills/demo/scripts/demo.sh"
range_find_fails "$GUARD"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: compiled-includes=range"* ]] && [ "$LOG" = "$WORKSPACE_CALLS" ] \
  && ok "a failed include read is a finding and the range checks the workspace" \
  || bad "a failed include read is a finding and the range checks the workspace" "rc=$RC log=$LOG out=$OUT"
if mutant_guard '/^    say compiled-includes range$/d'; then
  range_find_fails "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [[ "$OUT" != *"guard: compiled-includes="* ]] \
    && ok "control: with the finding removed the failed read passes" \
    || bad "control: with the finding removed the failed read passes" "rc=$RC out=$OUT"
else
  bad "control: the include-read finding could not be removed from a guard copy"
fi
rm -f -- "${R:?}/fake-bin/find"
back_to_base

echo "=== the default rules read the range, not only the last commit ==="
# A fix round may commit before it validates: an unrooted fixture committed
# after the base is still in the range, where the commit chain's HEAD diff no
# longer sees it.
printf '%s\n' 'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' drop(tmp);' '}' >"$R/crates/core/tests/range_temp.rs"
git -C "$R" add -A
git -C "$R" commit -q -m "test: a fixture committed inside the range"
run_range "$BASE"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: unrooted-fixture=1"* ]] && [[ "$OUT" == *"range_temp.rs:2"* ]] \
  && ok "a rule's defect committed after the base reds the range" \
  || bad "a rule's defect committed after the base reds the range" "rc=$RC out=$OUT"
OUT=""
RC=0
OUT="$(cd "$R" && env PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$GUARD" 2>&1 </dev/null)" || RC=$?
[ "$RC" -eq 0 ] \
  && ok "inverse: the commit-time run, which diffs HEAD, passes the same tree" \
  || bad "inverse: the commit-time run, which diffs HEAD, passes the same tree" "rc=$RC out=$OUT"
back_to_base

echo "=== the render and fixture rules read the range's one changed set ==="
# A fix round validates before it stages: a new source may be intent-added
# while its new render is still untracked, and a new test file may be
# untracked altogether. The compile set sees both; the rules must too.
printf '#!/usr/bin/env bash\necho new\n' >"$R/skills/demo/scripts/new.sh"
cp "$R/skills/demo/scripts/new.sh" "$R/.agents/skills/demo/scripts/new.sh"
git -C "$R" add -N skills/demo/scripts/new.sh
run_range "$BASE"
[ "$RC" -eq 0 ] && [[ "$OUT" != *"guard: missing-render="* ]] \
  && ok "an intent-added source with its untracked render passes the render rule" \
  || bad "an intent-added source with its untracked render passes the render rule" "rc=$RC out=$OUT"
if mutant_guard 's/^  render_changed=\$touched$/  render_changed=$(git -c core.quotePath=false diff --name-only --no-renames "${diff_against[@]}")/'; then
  run_range "$BASE" "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: missing-render=1"* ]] && [[ "$OUT" == *"skills/demo/scripts/new.sh -> .agents/skills/demo/scripts/new.sh"* ]] \
    && ok "control: with the render rule reading the tracked-only diff the untracked render is missed" \
    || bad "control: with the render rule reading the tracked-only diff the untracked render is missed" "rc=$RC out=$OUT"
else
  bad "control: the render rule could not be pointed back at the tracked-only diff in a guard copy"
fi
back_to_base
printf 'echo drifted\n' >>"$R/skills/demo/scripts/demo.sh"
run_range "$BASE"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: missing-render=1"* ]] && [[ "$OUT" == *"skills/demo/scripts/demo.sh -> .agents/skills/demo/scripts/demo.sh"* ]] \
  && ok "a source changed since the base without its render reds the range, naming the pair" \
  || bad "a source changed since the base without its render reds the range, naming the pair" "rc=$RC out=$OUT"
if mutant_guard 's/^  render_changed=\$touched$/  render_changed=""/'; then
  run_range "$BASE" "$MUTANT_TOOLS/guard"
  [[ "$OUT" != *"guard: missing-render="* ]] \
    && ok "control: with the range's render rule reading nothing the unsynced source passes it" \
    || bad "control: with the range's render rule reading nothing the unsynced source passes it" "rc=$RC out=$OUT"
else
  bad "control: the range's render rule could not be emptied in a guard copy"
fi
back_to_base
printf '%s\n' 'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' drop(tmp);' '}' >"$R/crates/core/tests/untracked_temp.rs"
run_range "$BASE"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: unrooted-fixture=1"* ]] && [[ "$OUT" == *"untracked_temp.rs:2"* ]] \
  && ok "an untracked test file's unrooted fixture reds the range" \
  || bad "an untracked test file's unrooted fixture reds the range" "rc=$RC out=$OUT"
if mutant_guard 's/^  done <<<"\$untracked_touched"$/  done <\/dev\/null/'; then
  run_range "$BASE" "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] \
    && ok "control: with untracked test files left out of the diff the fixture passes" \
    || bad "control: with untracked test files left out of the diff the fixture passes" "rc=$RC out=$OUT"
else
  bad "control: the untracked test files could not be dropped from the fixture diff in a guard copy"
fi
back_to_base

echo "=== the skill-instruction rule reads the working tree ==="
# A fix round validates before it stages, so a render that lost its configured
# instructions block in the working tree is the candidate the rule judges.
mkdir -p "$R/skills/demo" "$R/.agents/skills/demo"
printf '%s\n' '---' 'name: demo' '---' '# Skill' >"$R/skills/demo/SKILL.md"
{
  cat "$R/skills/demo/SKILL.md"
  printf '%s\n' '<!-- kendex:project-instructions:start -->' '<!-- kendex:project-instructions:end -->'
} >"$R/.agents/skills/demo/SKILL.md"
printf '%s\n' 'schema = 6' 'is_source_catalog = true' >"$R/kendex.toml"
printf '%s\n' '[skill-instructions]' 'demo = "Rule."' >"$R/kendex-local.toml"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: a configured skill instruction"
instructions_base="$(git -C "$R" rev-parse HEAD)"
cp "$R/skills/demo/SKILL.md" "$R/.agents/skills/demo/SKILL.md"
run_range "$instructions_base"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: missing-skill-instructions=1"* ]] && [[ "$OUT" == *".agents/skills/demo/SKILL.md"* ]] \
  && ok "an unstaged render without its configured block reds the range" \
  || bad "an unstaged render without its configured block reds the range" "rc=$RC out=$OUT"
if mutant_guard 's/^\[ "\$MODE" != default \] || worktree_reads=0$/worktree_reads=0/'; then
  run_range "$instructions_base" "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] \
    && ok "control: with the range reading the index the unstaged render passes" \
    || bad "control: with the range reading the index the unstaged render passes" "rc=$RC out=$OUT"
else
  bad "control: the range's working-tree read could not be turned into an index read in a guard copy"
fi
back_to_base

echo "=== a range with no usable base is refused before anything runs ==="
# label|arguments|expected first line
REFUSALS=(
  "a --range with no base names the argument|--range|guard: argument=--range"
  "a base that names no commit is refused, naming it|--range no-such-ref|guard: range-base=no-such-ref"
)
for row in "${REFUSALS[@]}"; do
  IFS='|' read -r label args want <<<"$row"
  OUT=""
  RC=0
  : >"$CALLS"
  # shellcheck disable=SC2086 # the argument list is the row's, split on purpose
  OUT="$(cd "$R" && env PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$GUARD" $args 2>&1 </dev/null)" || RC=$?
  [ "$RC" -eq 2 ] && [ "$(sed -n 1p <<<"$OUT")" = "$want" ] && [ ! -s "$CALLS" ] \
    && ok "$label" \
    || bad "$label" "rc=$RC out=$OUT"
done

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
