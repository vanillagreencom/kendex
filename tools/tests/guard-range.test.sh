#!/usr/bin/env bash
# tools/guard --range BASE, a fix round's validation: the default rules read
# over the changes since BASE, cargo clippy for the crates those
# changes touch, the UI checks and suite for a non-Markdown UI change, the
# suites a touched skill's changed files map to and the suites of the other
# trees they touch, and none of what --full adds beyond that: the
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
  grep -qFx "cargo clippy --workspace --all-targets --quiet -- -D warnings" <<<"$LOG" \
    && ok "control: with range compiling everything the skill-only diff reaches cargo" \
    || bad "control: with range compiling everything the skill-only diff reaches cargo" "rc=$RC log=$LOG"
else
  bad "control: the full-mode compile set could not be widened to range in a guard copy"
fi
back_to_base

echo "=== what a range compiles is what it touched since its base ==="
CORE_CALLS="cargo tree -p kendex-core -e normal
cargo clippy --manifest-path crates/core/Cargo.toml --all-targets --quiet -- -D warnings
cargo fmt --check"
WORKSPACE_CALLS="cargo tree -p kendex-core -e normal
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
  "control: without tools/rust-reads' build rows a clippy.toml change compiles nothing|clippy.toml|s/\$1 == \"build\" \&\& /\$1 == \"none\" \&\& /"
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
if mutant_guard 's/^if \[ "\$MODE" = full \] && \[ -n "\$validate_class" \]; then$/if [ "$MODE" != default ] \&\& [ -n "$validate_class" ]; then/'; then
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
[ "$RC" -eq 0 ] && [[ "$OUT" != *"guard: cargo-space-"* ]] && grep -qFx "cargo clippy --manifest-path crates/core/Cargo.toml --all-targets --quiet -- -D warnings" "$CALLS" \
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
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: rust-reads=crates"* ]] && [ "$LOG" = "$WORKSPACE_CALLS" ] \
  && ok "a failed include read is a finding and the range checks the workspace" \
  || bad "a failed include read is a finding and the range checks the workspace" "rc=$RC log=$LOG out=$OUT"
if mutant_guard '/^  say rust-reads crates$/d'; then
  range_find_fails "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [[ "$OUT" != *"guard: rust-reads="* ]] \
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

echo "=== a range runs the suites a skill's changed files map to ==="
# A skill run through the real orch runner: each suite prints a count and
# passes, so which ones ran is read from the runner's start lines. tool is a
# substring of tool_extra and toolbox, so only a whole-name selection runs it
# alone. lib/pid.sh is reached by wrapped through lib/wrap.sh, by deep through
# lib/alpha.sh and then lib/wrap.sh, which the scan meets in that order only
# on its second pass, and by runner and drives through scripts/runner, which
# sources it: runner is named for that script and drives names it. pyuse
# names lib/mod.py, a module an import reaches without spelling its path.
# helped reaches scripts/driven only through tests/lib/helper.sh, which names
# it; nothing names tests/lib/lonely.sh. battery names the runner and skilldoc
# names SKILL.md, so the arms that turn those two away are what keep each from
# mapping to its namer alone.
M="$R/skills/mapped"
mkdir -p "$M/scripts/lib" "$M/tests/lib" "$M/tests/fixtures"
cp "$REPO/skills/orch/tests/run-all.sh" "$M/tests/run-all.sh"
cp "$REPO/skills/orch/tests/lib/git-env.sh" "$M/tests/lib/git-env.sh"
printf 'pid=1\n' >"$M/scripts/lib/pid.sh"
printf 'source "${BASH_SOURCE[0]%%/*}/pid.sh"\n' >"$M/scripts/lib/wrap.sh"
printf 'source "${BASH_SOURCE[0]%%/*}/wrap.sh"\n' >"$M/scripts/lib/alpha.sh"
printf 'VALUE = 1\n' >"$M/scripts/lib/mod.py"
printf '#!/usr/bin/env bash\necho tool\n' >"$M/scripts/tool"
printf '#!/usr/bin/env bash\necho orphan\n' >"$M/scripts/orphan"
printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/lib/pid.sh"\n' >"$M/scripts/runner"
printf '#!/usr/bin/env bash\necho driven\n' >"$M/scripts/driven"
printf 'fixture\n' >"$M/tests/fixtures/x.sh"
printf 'drive() { "$SKILL/../../scripts/driven"; }\n' >"$M/tests/lib/helper.sh"
printf 'lonely=1\n' >"$M/tests/lib/lonely.sh"
printf -- '---\nname: mapped\n---\n' >"$M/SKILL.md"
suite_naming() { # NAME [TEXT] — a passing suite whose comment holds TEXT
  printf '#!/usr/bin/env bash\n# %s\necho "pass: 1   fail: 0"\n' "${2:-}" >"$M/tests/$1.sh"
}
for s in tool tool_extra toolbox other runner; do suite_naming "$s"; done
suite_naming pid_direct 'names ../scripts/lib/pid.sh'
suite_naming wrapped 'names ../scripts/lib/wrap.sh'
suite_naming deep 'names ../scripts/lib/alpha.sh'
suite_naming drives 'runs ../scripts/runner'
suite_naming pyuse 'reads ../scripts/lib/mod.py'
suite_naming helped 'sources lib/helper.sh'
suite_naming battery 'runs ../tests/run-all.sh'
suite_naming skilldoc 'reads ../SKILL.md'
# A skill with no runner: each suite runs by its own file, a .test suffix
# included, and a node suite beside the shell ones.
P="$R/skills/plain"
mkdir -p "$P/scripts" "$P/tests"
printf '#!/usr/bin/env bash\necho a\n' >"$P/scripts/alpha.sh"
printf '#!/usr/bin/env bash\necho b\n' >"$P/scripts/beta.sh"
for s in alpha beta; do printf '#!/usr/bin/env bash\necho ok\n' >"$P/tests/$s.test.sh"; done
printf '%s\n' "import test from 'node:test';" "test('gamma', () => {});" >"$P/tests/gamma.test.mjs"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: two skills with suites named for their files"
mapped_base="$(git -C "$R" rev-parse HEAD)"
MAPPED_ALL="battery deep drives helped other pid_direct pyuse runner skilldoc tool tool_extra toolbox wrapped"
PLAIN_ALL="alpha.test.sh beta.test.sh gamma.test.mjs"
note_for() { printf 'guard-note: suites=all reason=%s path=%s' "$1" "$2"; }
mapped_note() { printf 'guard-note: suites=%s reason=mapped skill=skills/%s' "$1" "$2"; }
# The suites that started: the runner's start lines, and the file headers the
# guard prints for a skill with no runner.
started() {
  printf '%s\n' "$OUT" | sed -n 's/^start suite=//p; s#^=== skills/plain/tests/##p' | sort | tr '\n' ' ' | sed 's/ $//'
}
back_to_mapped() {
  git -C "$R" reset -q --hard "$mapped_base"
  git -C "$R" clean -qfd -e fake-bin
}
change() { # HOW PATH... — append to each, or delete each
  local how="$1" p
  shift
  for p in "$@"; do
    case "$how" in
      append) printf '# changed\n' >>"$R/$p" ;;
      delete) rm -- "${R:?}/$p" ;;
      *) echo "change: no way named $how" >&2; exit 2 ;;
    esac
  done
}
# One row per arm of mapped_suites and per entry of skill_files.
# label|how|paths, space-separated|suites that start, sorted|the note, or none
MAP_ROWS=(
  "a changed suite runs itself alone|append|skills/mapped/tests/tool.sh|tool|$(mapped_note 1/13 mapped)"
  "a changed script runs each suite named for it, not one its name only begins|append|skills/mapped/scripts/tool|tool tool_extra|$(mapped_note 2/13 mapped)"
  "a changed lib runs every suite reaching it through libs, scripts and names|append|skills/mapped/scripts/lib/pid.sh|deep drives pid_direct runner wrapped|$(mapped_note 5/13 mapped)"
  "a changed script reaches a suite through a tests/lib helper naming it|append|skills/mapped/scripts/driven|helped|$(mapped_note 1/13 mapped)"
  "a changed tests/lib helper runs the suite sourcing it|append|skills/mapped/tests/lib/helper.sh|helped|$(mapped_note 1/13 mapped)"
  "a deleted suite nothing names runs nothing|delete|skills/mapped/tests/other.sh||$(mapped_note 0/12 mapped)"
  "a deleted tests/lib helper nothing names runs the whole set and says so|delete|skills/mapped/tests/lib/lonely.sh|$MAPPED_ALL|$(note_for unmapped skills/mapped/tests/lib/lonely.sh)"
  "a changed script no suite reaches runs the whole set and says so|append|skills/mapped/scripts/orphan|$MAPPED_ALL|$(note_for unmapped skills/mapped/scripts/orphan)"
  "a Python module under lib runs the whole set and says so|append|skills/mapped/scripts/lib/mod.py|$MAPPED_ALL|$(note_for unmapped skills/mapped/scripts/lib/mod.py)"
  "a deleted fixture under tests runs the whole set and says so|delete|skills/mapped/tests/fixtures/x.sh|$MAPPED_ALL|$(note_for unmapped skills/mapped/tests/fixtures/x.sh)"
  "a changed runner runs the whole set and says so|append|skills/mapped/tests/run-all.sh|$MAPPED_ALL|$(note_for unmapped skills/mapped/tests/run-all.sh)"
  "a changed SKILL.md runs the whole set and says so|append|skills/mapped/SKILL.md|$MAPPED_ALL|$(note_for unmapped skills/mapped/SKILL.md)"
  "two changed paths run the suites of both|append|skills/mapped/scripts/tool skills/mapped/tests/other.sh|other tool tool_extra|$(mapped_note 3/13 mapped)"
  "a mapped and an unmapped path run the whole set|append|skills/mapped/scripts/tool skills/mapped/scripts/orphan|$MAPPED_ALL|$(note_for unmapped skills/mapped/scripts/orphan)"
  "with no runner a changed script runs its .test suite alone|append|skills/plain/scripts/alpha.sh|alpha.test.sh|$(mapped_note 1/3 plain)"
  "with no runner a changed suite runs itself alone|append|skills/plain/tests/beta.test.sh|beta.test.sh|$(mapped_note 1/3 plain)"
)
map_row() { # HOW PATHS NOTE [GUARD] — sets VERDICT
  local noted
  # shellcheck disable=SC2086 # the row's paths, split on purpose
  change "$1" $2
  run_range "$mapped_base" "${4:-$GUARD}"
  if [ "$3" = none ]; then
    noted=$([[ "$OUT" != *"guard-note: suites="* ]] && echo none || echo noted)
  else
    noted=$([[ "$OUT" == *"$3"* ]] && echo "$3" || echo missing)
  fi
  # A note whose reason has no explanation arm prints the broken-guard line.
  [[ "$OUT" != *"no explanation is defined for this value"* ]] || noted=unexplained
  VERDICT="rc=$RC started=$(started) note=$noted"
  back_to_mapped
}
before=$((PASS + FAIL))
for row in "${MAP_ROWS[@]}"; do
  IFS='|' read -r label how paths want note <<<"$row"
  map_row "$how" "$paths" "$note"
  [ "$VERDICT" = "rc=0 started=$want note=$note" ] \
    && ok "$label" \
    || bad "$label" "$VERDICT out=$OUT"
done
[ "$((PASS + FAIL))" -eq "$((before + ${#MAP_ROWS[@]}))" ] || { echo "a suite-map row asserted nothing" >&2; exit 2; }
change append skills/mapped/tests/tool.sh
OUT=""
RC=0
OUT="$(cd "$R" && env "${GUARD_TEST_BOUNDS[@]}" PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$GUARD" --full 2>&1 </dev/null)" || RC=$?
[ "$(started)" = "$MAPPED_ALL" ] \
  && ok "inverse: the same one-suite diff under --full runs the whole set" \
  || bad "inverse: the same one-suite diff under --full runs the whole set" "rc=$RC started=$(started)"
back_to_mapped
# Each rule is what its row stands on: with it broken, the row's diff runs
# another set.
# label#how#paths#sed expression breaking the rule#suites that start, sorted
MAP_CONTROLS=(
  "control: without the suite arm the changed suite runs the whole set#append#skills/mapped/tests/tool.sh#s/^    if grep -Fxq -- \"\$f\" <<<\"\$suites\"; then$/    if false; then/#$MAPPED_ALL"
  "control: without the deleted-suite arm a deleted suite runs the whole set#delete#skills/mapped/tests/other.sh#s/\] || return 0 ;;$/] || return 1 ;;/#battery deep drives helped pid_direct pyuse runner skilldoc tool tool_extra toolbox wrapped"
  "control: with the deleted-suite arm taking any path under tests a deleted helper runs nothing#delete#skills/mapped/tests/lib/lonely.sh#s/^      tests\/\*\/\*) ;;$/      tests\/never) ;;/#"
  "control: with names handed to the runner as substrings the changed suite runs its namesakes#append#skills/mapped/tests/tool.sh#s/filters+=(\"=\${t%.sh}\")/filters+=(\"\${t%.sh}\")/#tool tool_extra toolbox"
  "control: without the name-and-dash arm the script's second suite stands down#append#skills/mapped/scripts/tool#s/case \"\$base\" in \"\$name\" | \"\$name\"-\*)/case \"\$base\" in \"\$name\")/#tool"
  "control: without the scan's second pass the suites two files away stand down#append#skills/mapped/scripts/lib/pid.sh#/^          found=1$/d#drives pid_direct runner wrapped"
  "control: without the scan growing its needles only what names the lib itself runs#append#skills/mapped/scripts/lib/pid.sh#/needles+=(-e/d#pid_direct runner"
  "control: without the name rule for a reached script its named suite stands down#append#skills/mapped/scripts/lib/pid.sh#s/^      scripts\/\*)$/      scripts\/none)/#deep drives pid_direct wrapped"
  "control: with skill_files missing top-level scripts the lib's script and its suites stand down#append#skills/mapped/scripts/lib/pid.sh#s| \"\$1\"/scripts/\* \"\$1\"/scripts/\*/\*| \"\$1\"/scripts/*/*|#deep pid_direct wrapped"
  "control: with skill_files missing scripts subdirectories the lib chain stands down#append#skills/mapped/scripts/lib/pid.sh#s| \"\$1\"/scripts/\*/\* \"\$1\"/tests/lib/\*| \"\$1\"/tests/lib/*|#drives pid_direct runner"
  "control: with skill_files missing tests/lib the helper's suite goes unreached and the whole set runs#append#skills/mapped/scripts/driven#s| \"\$1\"/tests/lib/\*; do|; do|#$MAPPED_ALL"
  "control: without tests/lib in the scanned-path arm a changed helper runs the whole set#append#skills/mapped/tests/lib/helper.sh#s/^    scripts\/\*\/\*.sh | tests\/lib\/\*.sh) ;;$/    scripts\/*\/*.sh) ;;/#$MAPPED_ALL"
  "control: without the subdirectory arm the Python module runs only its namer#append#skills/mapped/scripts/lib/mod.py#/^    scripts\/\*\/\* | tests\/\*\/\*) return 1 ;;$/d#pyuse"
  "control: without the runner arm a changed runner runs only its namer#append#skills/mapped/tests/run-all.sh#/^    tests\/run-all.sh) return 1 ;;$/d#battery"
  "control: without the catch-all arm a changed SKILL.md runs only its namer#append#skills/mapped/SKILL.md#/^    \*) return 1 ;;$/d#skilldoc"
  "control: without the whole-set fallback the unmapped script runs nothing#append#skills/mapped/scripts/orphan#s/unmapped path=\$f\"; run=all; break ;;/unmapped path=\$f\"; break ;;/#"
  "control: with each path's suites overwriting the last only the last path's run#append#skills/mapped/scripts/tool skills/mapped/tests/other.sh#s/^            run=\"\$run\$sel$/            run=\"\$sel/#other"
  "control: with the no-runner loop reading the whole set every suite runs#append#skills/plain/scripts/alpha.sh#s/^        done <<<\"\$run\"$/        done <<<\"\$(skill_suites \"\$d\")\"/#$PLAIN_ALL"
  "control: without the .test strip the script's suite goes unmatched and the whole set runs#append#skills/plain/scripts/alpha.sh#/base=\"\${base%.test}\"/d#$PLAIN_ALL"
)
for row in "${MAP_CONTROLS[@]}"; do
  IFS='#' read -r label how paths expr want <<<"$row"
  if mutant_guard "$expr"; then
    map_row "$how" "$paths" none "$MUTANT_TOOLS/guard"
    [[ "$VERDICT" == *" started=$want note="* ]] \
      && ok "$label" \
      || bad "$label" "$VERDICT out=$OUT"
  else
    bad "$label" "the rule could not be broken in a guard copy"
  fi
done
# The narrowed run's note is the reader's one sign that the set was cut.
if mutant_guard '/note suites "\$(count_lines/d'; then
  map_row append skills/mapped/tests/tool.sh "$(mapped_note 1/13 mapped)" "$MUTANT_TOOLS/guard"
  [[ "$VERDICT" == *" started=tool note=missing" ]] \
    && ok "control: without the narrowed-run note the one-suite run says nothing of the cut" \
    || bad "control: without the narrowed-run note the one-suite run says nothing of the cut" "$VERDICT out=$OUT"
else
  bad "control: the narrowed-run note could not be removed from a guard copy"
fi
# A file the scan cannot read is no evidence it names nothing: the skill runs
# whole, and the note names the read, not the rule. The stub fails the scan's
# grep alone, the one that passes -qF, on the file FAIL_GREP names: a lib the
# scan passes through, and a suite it ends on.
REAL_GREP="$(command -v grep)"
cat >"$R/fake-bin/grep" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do :; done
if [ -n "${FAIL_GREP:-}" ] && [ "$1" = -qF ] && [ "$a" = "$FAIL_GREP" ]; then
  echo "grep: $a: Permission denied" >&2
  exit 2
fi
exec "$REAL_GREP" "$@"
SH
chmod +x "$R/fake-bin/grep"
range_grep_fails() { # FILE GUARD
  OUT=""
  RC=0
  : >"$CALLS"
  OUT="$(cd "$R" && env FAIL_GREP="$1" REAL_GREP="$REAL_GREP" PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$2" --range "$mapped_base" 2>&1 </dev/null)" || RC=$?
}
# unreadable file|suites that start once the failed read counts as no match
UNREAD_ROWS=(
  "skills/mapped/scripts/lib/wrap.sh|drives pid_direct runner"
  "skills/mapped/tests/pid_direct.sh|deep drives runner wrapped"
)
for row in "${UNREAD_ROWS[@]}"; do
  IFS='|' read -r unread lenient <<<"$row"
  change append skills/mapped/scripts/lib/pid.sh
  range_grep_fails "$unread" "$GUARD"
  [ "$RC" -eq 0 ] && [ "$(started)" = "$MAPPED_ALL" ] \
    && [[ "$OUT" == *"$(note_for unreadable skills/mapped/scripts/lib/pid.sh)"* ]] \
    && [[ "$OUT" != *"no explanation is defined for this value"* ]] \
    && ok "an unreadable $unread runs the whole set and names the read" \
    || bad "an unreadable $unread runs the whole set and names the read" "rc=$RC started=$(started) out=$OUT"
  if mutant_guard 's/^        \*) return 2 ;;$/        *) ;;/'; then
    range_grep_fails "$unread" "$MUTANT_TOOLS/guard"
    [ "$(started)" = "$lenient" ] \
      && ok "control: with the failed read of $unread taken as no match the set shrinks silently" \
      || bad "control: with the failed read of $unread taken as no match the set shrinks silently" "rc=$RC started=$(started) out=$OUT"
  else
    bad "control: the failed read could not be taken as no match in a guard copy"
  fi
  back_to_mapped
done
rm -f -- "${R:?}/fake-bin/grep"
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
