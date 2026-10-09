#!/usr/bin/env bash
# tools/guard --range BASE, a fix round's validation: the default rules read
# over the changes since BASE, cargo clippy for the crates those
# changes touch, the UI checks and suite for a non-Markdown UI change, the
# skill, hook and tools suites their changed inputs map to and the suites of
# the other trees they touch, and none of what --full adds beyond that: the
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
  && [ "$(sed -n '$p' <<<"$OUT")" = 'validate: lanes=guard-scans selection=all' ] \
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
  "a docs-only range runs no suite|worktree|docs/guide.md|"
  "a workflow-only range runs no suite|worktree|.github/workflows/skill-tests.yml|"
  "a crate's non-Rust file checks and lints that crate|worktree|crates/core/assets/data.txt|$CORE_CALLS"
  "a file outside crates/ that compiled code includes checks and lints the workspace|worktree|docs/note.txt|$WORKSPACE_CALLS"
)
before=$((PASS + FAIL))
for row in "${ROWS[@]}"; do
  IFS='|' read -r label sits path _ <<<"$row"
  want="${row#*|*|*|}"
  mkdir -p "$R/$(dirname "$path")"
  printf 'x\n' >>"$R/$path"
  if [ "$sits" = commit ]; then
    git -C "$R" add -A
    git -C "$R" commit -q -m "fix: a change inside the range"
  fi
  run_range "$BASE"
  [ "$RC" -eq 0 ] && [ "$LOG" = "$want" ] && [ "$(sed -n '$p' <<<"$OUT")" = 'validate: lanes=guard-scans selection=all' ] \
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
# lib/alpha.sh and then lib/wrap.sh, and by runner and drives through
# scripts/runner, which sources it: runner is named for that script and
# drives names it; cited names pid.sh only on a comment line. scripts/caller
# runs scripts/tool, and the suite caller is named for it; scripts/front
# sources scripts/base, and the suite front is named for it. pyuse names
# lib/mod.py, a module an import reaches without spelling its path. helped
# reaches scripts/driven only through tests/lib/helper.sh, which names it,
# probed through tests/lib/probe.py, a test module that runs it, and the
# suite wrap names driven and shares lib/wrap.sh's name; nothing
# names tests/lib/lonely.sh, and longer names only a script whose name
# begins with orphan's. references/table.conf is read by tool through
# its path, read whole by docscan's glob and by
# lib/refs.sh, which refsuse sources, and met by walker's find over the skill
# root and catalogscan's over the skills directory; driven reads another
# reference, and toolbox names a table.conf of another directory. skillmd
# reads SKILL.md, and rootglob globs the skill root. flowread names
# workflows/flow.md and flowdir globs its directory; beside the two walkers,
# tablecheck alone reads schemas/rec.md, through a table row it joins onto
# the skill root, and settings.example has no role. In plain, alpha.sh's
# comment cites note.md, beta's prose names it without its directory, and
# nothing reads it,
# lonely.sh, which no suite reaches, alone reads lone.md, nothing reads
# README.md, and scripts/empty.sh is an empty file the reader pass reads as no
# read.
M="$R/skills/mapped"
mkdir -p "$M/scripts/lib" "$M/tests/lib" "$M/tests/fixtures" "$M/references" "$M/workflows" "$M/schemas"
cp "$REPO/skills/orch/tests/run-all.sh" "$M/tests/run-all.sh"
cp "$REPO/skills/orch/tests/lib/git-env.sh" "$M/tests/lib/git-env.sh"
cp "$REPO/skills/orch/scripts/lib/lane-state.sh" "$M/scripts/lib/lane-state.sh"
mkdir -p "$R/skills/github/scripts/lib"
cp "$REPO/skills/github/scripts/lib/group-leader.sh" "$R/skills/github/scripts/lib/group-leader.sh"
printf 'pid=1\n' >"$M/scripts/lib/pid.sh"
printf 'source "${BASH_SOURCE[0]%%/*}/pid.sh"\n' >"$M/scripts/lib/wrap.sh"
printf 'source "${BASH_SOURCE[0]%%/*}/wrap.sh"\n' >"$M/scripts/lib/alpha.sh"
printf 'VALUE = 1\n' >"$M/scripts/lib/mod.py"
printf '#!/usr/bin/env bash\ncat "$(dirname "$0")/../references/table.conf"\n' >"$M/scripts/tool"
printf 'key=1\n' >"$M/references/table.conf"
printf 'for f in "${BASH_SOURCE[0]%%/*}/../../references"/*; do :; done\n' >"$M/scripts/lib/refs.sh"
printf '#!/usr/bin/env bash\necho orphan\n' >"$M/scripts/orphan"
printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/lib/pid.sh"\n' >"$M/scripts/runner"
printf '#!/usr/bin/env bash\n"$(dirname "$0")/tool"\n' >"$M/scripts/caller"
printf 'BASE=1\n' >"$M/scripts/base"
printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/base"\n' >"$M/scripts/front"
printf '#!/usr/bin/env bash\ncat "$(dirname "$0")/../references/unrelated.conf"\n' >"$M/scripts/driven"
printf 'fixture\n' >"$M/tests/fixtures/x.sh"
printf 'drive() { "$SKILL/../../scripts/driven"; }\n' >"$M/tests/lib/helper.sh"
printf 'lonely=1\n' >"$M/tests/lib/lonely.sh"
printf 'import subprocess\nsubprocess.run([HERE + "/../../scripts/driven"])\n' >"$M/tests/lib/probe.py"
printf -- '---\nname: mapped\n---\n\n# Mapped\n' >"$M/SKILL.md"
printf '# Flow\n' >"$M/workflows/flow.md"
printf '# Record\n' >"$M/schemas/rec.md"
mkdir -p "$M/scripts/plugin/hooks" "$M/scripts/plugin/.claude-plugin" "$M/scripts/unused"
printf 'export {};\n' >"$M/scripts/plugin/hooks/x.js"
printf '{}\n' >"$M/scripts/plugin/.claude-plugin/plugin.json"
printf '{}\n' >"$M/scripts/unused/data.json"
printf '#!/usr/bin/env bash\ngh api repos/demo/actions/workflows\n' >"$M/scripts/api"
# open-terminal prints these launch prompts; their workflow prose reads no doc.
cat >"$M/scripts/brief" <<'SH'
#!/usr/bin/env bash
case "$TRACKER:$HARNESS" in
linear:codex)    printf "codex %s'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for %s.%s'\n" "$flags" "$item" "$unattended" ;;
linear:copilot)  printf "copilot %s-i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for %s.%s'\n" "$flags" "$item" "$unattended" ;;
github:codex)    printf "codex %s'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for github %s#%s.%s'\n" "$flags" "$repo" "$item" "$unattended" ;;
github:copilot)  printf "copilot %s-i 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for github %s#%s.%s'\n" "$flags" "$repo" "$item" "$unattended" ;;
esac
SH
printf 'brief="Read .agents/skills/mapped/SKILL.md"\n' >"$M/scripts/lib/brief.sh"
printf '#!/usr/bin/env bash\ncat "$(dirname "$0")/../workflows/flow.md"\n' >"$M/scripts/readflow"
printf 'key=1\n' >"$M/settings.example"
suite_naming() { # NAME [TEXT] — a passing suite whose code holds TEXT
  printf '#!/usr/bin/env bash\n: "%s"\necho "pass: 1   fail: 0"\n' "${2:-}" >"$M/tests/$1.sh"
}
for s in tool tool_extra other runner caller front; do suite_naming "$s"; done
suite_running() { # NAME LINE — a passing suite that runs LINE first
  printf '#!/usr/bin/env bash\n%s\necho "pass: 1   fail: 0"\n' "$2" >"$M/tests/$1.sh"
}
suite_running toolbox 'echo "see ../fixtures/table.conf"'
suite_running docscan ': "$(dirname "$0")/../references"/*.md'
suite_running walker 'SKILL_DIR="$(dirname "$0")/.."; find "$SKILL_DIR" -name "*.md" >/dev/null'
suite_running catalogscan 'REPO_ROOT="$(dirname "$0")/../../.."; find "$REPO_ROOT/skills" -name "*.md" >/dev/null'
suite_running skillmd 'grep -c name "$(dirname "$0")/../SKILL.md" >/dev/null'
suite_running rootglob 'SKILL_DIR="$(dirname "$0")/.."; for f in "$SKILL_DIR"/*.md; do :; done'
suite_running flowread ': "$(dirname "$0")/../workflows/flow.md"'
suite_running flowdir 'SKILL_DIR="$(dirname "$0")/.."; : "$SKILL_DIR/workflows"/*.md'
printf '%s\n' '#!/usr/bin/env bash' 'HERE="$(dirname "$0")/.."' 'while IFS= read -r rel; do grep -q Record "$HERE/$rel"; done <<'"'"'TABLE'"'"'' \
  'schemas/rec.md' 'TABLE' 'echo "pass: 1   fail: 0"' >"$M/tests/tablecheck.sh"
suite_naming refsuse 'sources ../scripts/lib/refs.sh'
suite_naming pid_direct 'names ../scripts/lib/pid.sh'
suite_naming wrapped 'names ../scripts/lib/wrap.sh'
suite_naming deep 'names ../scripts/lib/alpha.sh'
suite_naming drives 'runs ../scripts/runner'
suite_naming pyuse 'reads ../scripts/lib/mod.py'
suite_naming plugin 'reads ../scripts/plugin'
suite_naming api 'runs ../scripts/api; calls repos/demo/actions/workflows'
suite_naming brief 'runs ../scripts/brief; reads ../scripts/lib/brief.sh'
suite_naming readflow
suite_naming helped 'sources lib/helper.sh'
suite_naming probed 'runs lib/probe.py'
suite_naming wrap 'runs ../scripts/driven'
suite_naming longer 'runs ../scripts/orphan-twin'
printf '#!/usr/bin/env bash\n# names ../scripts/lib/pid.sh\necho "pass: 1   fail: 0"\n' >"$M/tests/cited.sh"
# A skill with no runner: each suite runs by its own file, a .test suffix
# included, and a node suite beside the shell ones.
P="$R/skills/plain"
mkdir -p "$P/scripts" "$P/tests" "$P/references"
printf '# Note\n' >"$P/references/note.md"
printf '# Lone\n' >"$P/references/lone.md"
printf '# Plain\n' >"$P/README.md"
printf '#!/usr/bin/env bash\ncat "$(dirname "$0")/../references/lone.md"\n' >"$P/scripts/lonely.sh"
printf '#!/usr/bin/env bash\n# cat ../references/note.md\necho a\n' >"$P/scripts/alpha.sh"
printf '#!/usr/bin/env bash\necho b\n' >"$P/scripts/beta.sh"
: >"$P/scripts/empty.sh"
for s in alpha beta; do printf '#!/usr/bin/env bash\necho ok\n' >"$P/tests/$s.test.sh"; done
printf 'echo "see note.md"\n' >>"$P/tests/beta.test.sh"
printf '%s\n' "import test from 'node:test';" "test('gamma', () => {});" >"$P/tests/gamma.test.mjs"
# hooks/ beside the world's demo hook and its suite, which run by file: alpha
# has two suites named for it and a third that reaches it through the
# helper tests/lib/world.sh; beta's suite names it, and nothing reads lone.
H="$R/hooks"
mkdir -p "$H/tests/lib"
for h in alpha beta lone; do printf '#!/usr/bin/env bash\necho %s\n' "$h" >"$H/$h.sh"; done
printf '# Hooks\n' >"$H/README.md"
printf 'HOOK="$HOOKS_DIR/alpha.sh"\n' >"$H/tests/lib/world.sh"
hook_suite() { # NAME LINE — a passing hook suite that runs LINE first
  printf '#!/usr/bin/env bash\n%s\necho ok\n' "$2" >"$H/tests/$1.test.sh"
}
hook_suite alpha ': ../alpha.sh'
hook_suite alpha-copilot ':'
hook_suite via-world '. "$(dirname "$0")/lib/world.sh"'
hook_suite beta 'cat "$(dirname "$0")/../README.md"; : ../beta.sh'
# Shipped directory reads: workflow_helpers.sh's quoted find operands,
# workflow-state-init-guard-lint's W assignment and iced-rs's SOURCES array.
# second-opinion reads each assigned schema_file through sed. Keep these
# apart from the other mapping rows so a reader case changes no older set.
D="$R/skills/doc-readers"
mkdir -p "$D/scripts/lib" "$D/tests" "$D/workflows" "$D/references" "$D/schemas"
printf '# Flow\n' >"$D/workflows/flow.md"
printf '# Reference\n' >"$D/references/guide.md"
printf '# Prompt\n' >"$D/schemas/review-finding-prompt.md"
M_SAVED=$M
M=$D
suite_running quoted-find 'SKILL_DIR="$(dirname "$0")/.."; find "$SKILL_DIR/workflows" "$SKILL_DIR/references" "$SKILL_DIR/schemas" -type f -name "*.md" >/dev/null'
suite_running assigned-dir 'SKILL_DIR="$(dirname "$0")/.."
W="$SKILL_DIR/workflows"
grep -r Flow "$W" >/dev/null'
suite_running array-dir 'SKILL_DIR="$(dirname "$0")/.."
SOURCES=("$SKILL_DIR/references")
grep -r Reference "${SOURCES[@]}" >/dev/null'
suite_naming assigned-script 'runs ../scripts/schema'
suite_naming assigned-lib 'sources ../scripts/lib/schema.sh'
suite_naming api 'calls "repos/demo/actions/workflows"'
suite_naming brief 'runs ../scripts/brief; sources ../scripts/lib/brief.sh'
suite_naming unused 'runs ../scripts/unused'
suite_naming printed-path 'runs ../scripts/printed-path'
M=$M_SAVED
for f in "$D/scripts/schema" "$D/scripts/lib/schema.sh"; do
  cat >"$f" <<'SH'
#!/usr/bin/env bash
read_schema() {
  local schema_file="$SCRIPT_DIR/../schemas/review-finding-prompt.md"
  schema=$(sed 's/Prompt/Fixture/g' "$schema_file")
}
read_other_schema() {
  local schema_file="$SCRIPT_DIR/../schemas/review-finding-prompt.md"
  schema=$(sed 's/Prompt/Fixture/g' "${schema_file}")
}
SH
done
printf '#!/usr/bin/env bash\nprintf "Read .agents/skills/doc-readers/workflows and schemas/review-finding-prompt.md"\n' >"$D/scripts/brief"
printf '%s\n' 'printf "Read references/guide.md for details"' >>"$D/scripts/brief"
printf 'brief="Read .agents/skills/doc-readers/schemas/review-finding-prompt.md"\n' >"$D/scripts/lib/brief.sh"
printf '#!/usr/bin/env bash\nschema_file="$SCRIPT_DIR/../schemas/review-finding-prompt.md"\n' >"$D/scripts/unused"
printf '#!/usr/bin/env bash\nschema_file="$SCRIPT_DIR/../schemas/review-finding-prompt.md"\nprintf "%%s\\n" "$schema_file"\n' >"$D/scripts/printed-path"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: two skills and hooks with suites named for their files"
mapped_base="$(git -C "$R" rev-parse HEAD)"
# The mapped skill's whole set, read from the suites the builder above wrote
# so a suite added for one rule moves no other row: MAPPED_ALL sorted as
# started() prints it, MAPPED_N its size, MAPPED_BUT_OTHER the set once
# other.sh is deleted.
mapped_suites=()
for f in "$M"/tests/*.sh; do
  [ -f "$f" ] || continue
  f="${f##*/}"
  [ "$f" = run-all.sh ] || mapped_suites+=("${f%.sh}")
done
[ "${#mapped_suites[@]}" -gt 0 ] || { echo "guard-range: mapped-suites=none dir=$M/tests" >&2; exit 2; }
MAPPED_N=${#mapped_suites[@]}
MAPPED_ALL="$(printf '%s\n' "${mapped_suites[@]}" | sort | tr '\n' ' ' | sed 's/ $//')"
MAPPED_BUT_OTHER="$(printf '%s\n' "${mapped_suites[@]}" | sed '/^other$/d' | sort | tr '\n' ' ' | sed 's/ $//')"
[ "$MAPPED_BUT_OTHER" != "$MAPPED_ALL" ] || { echo "guard-range: mapped-suite=missing name=other" >&2; exit 2; }
# Every reader of the mapped skill's SKILL.md.
SKILL_READERS="catalogscan rootglob skillmd walker"
# A range across two trees: the hooks suites alpha's change maps to beside
# the mapped skill's for runner, one sorted list as started() prints it.
TWO_TREES="$(printf '%s\n' alpha-copilot.test.sh alpha.test.sh via-world.test.sh drives runner | sort | tr '\n' ' ' | sed 's/ $//')"
# The same range with the mapped skill read from the hooks scan: its whole set.
TWO_TREES_ONE_SCAN="$(printf '%s\n' alpha-copilot.test.sh alpha.test.sh via-world.test.sh $MAPPED_ALL | sort | tr '\n' ' ' | sed 's/ $//')"
PLAIN_ALL="alpha.test.sh beta.test.sh gamma.test.mjs"
HOOKS_ALL="alpha-copilot.test.sh alpha.test.sh beta.test.sh demo.test.sh via-world.test.sh"
note_for() { printf 'guard-note: suites=all reason=%s path=%s' "$1" "$2"; }
mapped_note() { printf 'guard-note: suites=%s reason=mapped tree=%s' "$1" "$2"; }
# The suites that started: the runner's start lines, and the file headers the
# guard prints for a tree with no runner, or for the mapped skill once its
# runner is deleted.
started() {
  printf '%s\n' "$OUT" | sed -n 's/^start suite=//p; s#^=== skills/plain/tests/##p; s#^=== hooks/tests/##p; s#^=== skills/doc-readers/tests/\(.*\)\.sh$#\1#p; /run-all\.sh/!s#^=== skills/mapped/tests/\(.*\)\.sh$#\1#p' | sort | tr '\n' ' ' | sed 's/ $//'
}
back_to_mapped() {
  git -C "$R" reset -q --hard "$mapped_base"
  git -C "$R" clean -qfd -e fake-bin
}
change() { # HOW PATH... — append to each or delete each
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
# One row per arm of mapped_suites and path_role and per entry of skill_files.
# label|how|paths, space-separated|suites that start, sorted|the note, or none
MAP_ROWS=(
  "a changed suite runs itself alone|append|skills/mapped/tests/tool.sh|tool|$(mapped_note 1/$MAPPED_N skills/mapped)"
  "a changed script runs each suite named for it, not one its name only begins nor one named for a script running it|append|skills/mapped/scripts/tool|tool tool_extra|$(mapped_note 2/$MAPPED_N skills/mapped)"
  "a changed script runs the suite that reads it beside the one named for it|append|skills/mapped/scripts/runner|drives runner|$(mapped_note 2/$MAPPED_N skills/mapped)"
  "a changed script another script sources runs the suite named for its sourcer|append|skills/mapped/scripts/base|front|$(mapped_note 1/$MAPPED_N skills/mapped)"
  "a range across two trees runs each tree's narrowed set and notes both|append|hooks/alpha.sh skills/mapped/scripts/runner|$TWO_TREES|$(mapped_note 3/5 hooks);;$(mapped_note 2/$MAPPED_N skills/mapped)"
  "a changed lib runs every suite reaching it through libs, scripts and names, and none citing it in a comment|append|skills/mapped/scripts/lib/pid.sh|deep drives pid_direct runner wrapped|$(mapped_note 5/$MAPPED_N skills/mapped)"
  "a changed script reaches a suite through a tests/lib helper or test module naming it, and a suite sharing a lib's name carries none of the lib's readers|append|skills/mapped/scripts/driven|helped probed wrap|$(mapped_note 3/$MAPPED_N skills/mapped)"
  "a changed tests/lib helper runs the suite sourcing it|append|skills/mapped/tests/lib/helper.sh|helped|$(mapped_note 1/$MAPPED_N skills/mapped)"
  "a deleted suite nothing names runs nothing|delete|skills/mapped/tests/other.sh||$(mapped_note 0/$((MAPPED_N - 1)) skills/mapped)"
  "a deleted tests/lib helper nothing names runs the whole set and says so|delete|skills/mapped/tests/lib/lonely.sh|$MAPPED_ALL|$(note_for unmapped skills/mapped/tests/lib/lonely.sh)"
  "a changed script no suite names whole, though one names a longer name it begins, runs the whole set and says so|append|skills/mapped/scripts/orphan|$MAPPED_ALL|$(note_for unmapped skills/mapped/scripts/orphan)"
  "a Python module under lib runs its file reader and folder readers|append|skills/mapped/scripts/lib/mod.py|brief deep drives pid_direct pyuse refsuse runner wrapped|$(mapped_note 8/$MAPPED_N skills/mapped)"
  "plugin modules run suites naming their enclosing folder|append|skills/mapped/scripts/plugin/hooks/x.js skills/mapped/scripts/plugin/.claude-plugin/plugin.json|plugin|$(mapped_note 1/$MAPPED_N skills/mapped)"
  "a module no suite names runs nothing|append|skills/mapped/scripts/unused/data.json||$(mapped_note 0/$MAPPED_N skills/mapped)"
  "a changed file of no role at the skill root runs the whole set and says so|append|skills/mapped/settings.example|$MAPPED_ALL|$(note_for unmapped skills/mapped/settings.example)"
  "a deleted fixture under tests runs the whole set and says so|delete|skills/mapped/tests/fixtures/x.sh|$MAPPED_ALL|$(note_for unmapped skills/mapped/tests/fixtures/x.sh)"
  "a changed runner runs the whole set and says so|append|skills/mapped/tests/run-all.sh|$MAPPED_ALL|$(note_for unmapped skills/mapped/tests/run-all.sh)"
  "a deleted runner runs the whole set by file and says so|delete|skills/mapped/tests/run-all.sh|$MAPPED_ALL|$(note_for unmapped skills/mapped/tests/run-all.sh)"
  "a changed SKILL.md runs its readers without the shipped workflow for launch briefs|append|skills/mapped/SKILL.md|$SKILL_READERS|$(mapped_note 4/$MAPPED_N skills/mapped)"
  "a changed workflow doc reaches its file and glob readers and its script reader but no API reader|append|skills/mapped/workflows/flow.md|catalogscan flowdir flowread readflow walker|$(mapped_note 5/$MAPPED_N skills/mapped)"
  "a changed schema doc runs the walkers and the suite naming it in a table it joins onto the skill root|append|skills/mapped/schemas/rec.md|catalogscan tablecheck walker|$(mapped_note 3/$MAPPED_N skills/mapped)"
  "a root doc no file reads runs nothing|append|skills/plain/README.md||$(mapped_note 0/3 skills/plain)"
  "a changed reference runs the suites of its path readers, the directory's readers and the walkers of the skill root and the skills directory|append|skills/mapped/references/table.conf|catalogscan docscan refsuse tool tool_extra walker|$(mapped_note 6/$MAPPED_N skills/mapped)"
  "a reference read only by a script no suite reaches runs the whole set and says so|append|skills/plain/references/lone.md|$PLAIN_ALL|$(note_for unmapped skills/plain/references/lone.md)"
  "a reference only a comment and prose cite runs nothing|append|skills/plain/references/note.md||$(mapped_note 0/3 skills/plain)"
  "two changed paths run the suites of both|append|skills/mapped/scripts/tool skills/mapped/tests/other.sh|other tool tool_extra|$(mapped_note 3/$MAPPED_N skills/mapped)"
  "a mapped and an unmapped path run the whole set|append|skills/mapped/scripts/tool skills/mapped/scripts/orphan|$MAPPED_ALL|$(note_for unmapped skills/mapped/scripts/orphan)"
  "with no runner a changed script runs its .test suite alone|append|skills/plain/scripts/alpha.sh|alpha.test.sh|$(mapped_note 1/3 skills/plain)"
  "with no runner a changed suite runs itself alone|append|skills/plain/tests/beta.test.sh|beta.test.sh|$(mapped_note 1/3 skills/plain)"
  "a changed hook runs its namesake suites and the suite whose helper names it|append|hooks/alpha.sh|alpha-copilot.test.sh alpha.test.sh via-world.test.sh|$(mapped_note 3/5 hooks)"
  "a changed render of a hook runs that hook's suite|append|.codex/hooks/demo.sh|demo.test.sh|$(mapped_note 1/5 hooks)"
  "a changed hooks helper runs the suite sourcing it|append|hooks/tests/lib/world.sh|via-world.test.sh|$(mapped_note 1/5 hooks)"
  "quoted find operands and an assigned workflow directory select their readers without API or brief readers|append|skills/doc-readers/workflows/flow.md|assigned-dir quoted-find|$(mapped_note 2/9 skills/doc-readers)"
  "a quoted reference directory in an array selects its reader beside find without a printed for details brief|append|skills/doc-readers/references/guide.md|array-dir quoted-find|$(mapped_note 2/9 skills/doc-readers)"
  "assigned schema paths used by sed select script and lib readers without briefs or unread assignments|append|skills/doc-readers/schemas/review-finding-prompt.md|assigned-lib assigned-script quoted-find|$(mapped_note 3/9 skills/doc-readers)"
  "a changed hook no suite reaches runs the whole hooks set and says so|append|hooks/lone.sh|$HOOKS_ALL|$(note_for unmapped hooks/lone.sh)"
  "a hooks doc runs its reader alone|append|hooks/README.md|beta.test.sh|$(mapped_note 1/5 hooks)"
  "a hooks doc no file reads runs nothing|append|hooks/unused.md||$(mapped_note 0/5 hooks)"
  "a hooks file of no role runs the whole hooks set|append|hooks/settings.example|$HOOKS_ALL|$(note_for unmapped hooks/settings.example)"
)
map_row() { # HOW PATHS NOTE[;;NOTE...] [GUARD] — sets VERDICT
  local noted
  # shellcheck disable=SC2086 # the row's paths, split on purpose
  change "$1" $2
  run_range "$mapped_base" "${4:-$GUARD}"
  if [ "$3" = none ]; then
    noted=$([[ "$OUT" != *"guard-note: suites="* ]] && echo none || echo noted)
  else
    # Several notes, joined by `;;`, must each be printed.
    noted="$3"
    local want_note
    while IFS= read -r want_note; do
      [[ "$OUT" == *"$want_note"* ]] || noted=missing
    done <<<"${3//;;/$'\n'}"
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
# dev-validate-run consumes this machine-readable final line.
for row in \
  'skills/mapped/tests/tool.sh|subset' \
  'skills/mapped/settings.example|all' \
  'hooks/README.md|subset' \
  'hooks/settings.example|all' \
  'docs/guide.md|all' \
  'skills/demo/scripts/demo.sh .agents/skills/demo/scripts/demo.sh|all' \
  'skills/mapped/tests/tool.sh hooks/settings.example|all' \
  'skills/mapped/settings.example hooks/README.md|all'; do
  IFS='|' read -r path selection <<<"$row"
  map_row append "$path" none
  [ "$RC" -eq 0 ] && [ "$(sed -n '$p' <<<"$OUT")" = "validate: lanes=guard-scans selection=$selection" ] \
    && ok "the final report records $selection for $path" \
    || bad "the final report records $selection for $path" "$OUT"
done
for row in \
  'skills/mapped/tests/tool.sh|subset|s/^            \[ "\$suite_selection" = all \] || suite_selection=subset$/            [ "$suite_selection" = all ] || suite_selection=all/' \
  'skills/mapped/settings.example|all|s/^          suite_selection=all$/          suite_selection=subset/' \
  'docs/guide.md|all|s/^suite_selection=""$/suite_selection=subset/' \
  'skills/demo/scripts/demo.sh .agents/skills/demo/scripts/demo.sh|all|s/^          if \[ "\$selected_count" -lt "\$total_count" \]; then$/          if true; then/'; do
  IFS='|' read -r path selection expr <<<"$row"
  if mutant_guard "$expr"; then
    map_row append "$path" none "$MUTANT_TOOLS/guard"
    [ "$RC" -eq 0 ] && [ "$(sed -n '$p' <<<"$OUT")" != "validate: lanes=guard-scans selection=$selection" ] \
      && ok "control: the changed report decision fails the $selection assertion" \
      || bad "control: the changed report decision fails the $selection assertion" "$OUT"
  else
    bad "control: the report decision could not be changed"
  fi
done
# Each rule is what its row stands on: with it broken, the row's diff runs
# another set.
# label~how~paths~sed expression breaking the rule~suites that start, sorted
MAP_CONTROLS=(
  "control: without the reach's suites the changed suite runs the whole set~append~skills/mapped/tests/tool.sh~s/^    if \[ -n \"\${reached\[i\]-}\" \] \&\& \[ \"\${SCAN_ROLE\[i\]}\" = suite \]; then$/    if false; then/~$MAPPED_ALL"
  "control: without the reach's suites the suite reading the changed script stands down~append~skills/mapped/scripts/runner~s/^    if \[ -n \"\${reached\[i\]-}\" \] \&\& \[ \"\${SCAN_ROLE\[i\]}\" = suite \]; then$/    if false; then/~runner"
  "control: without the deleted-suite arm a deleted suite runs the whole set~delete~skills/mapped/tests/other.sh~s/\] || return 0 ;;$/] || return 1 ;;/~$MAPPED_BUT_OTHER"
  "control: with the deleted-suite arm taking any path under tests a deleted helper runs nothing~delete~skills/mapped/tests/lib/lonely.sh~s/^      tests\/\*\/\*) ;;$/      tests\/never) ;;/~"
  "control: with names handed to the runner as substrings the changed suite runs its namesakes~append~skills/mapped/tests/tool.sh~s/filters+=(\"=\${t%.sh}\")/filters+=(\"\${t%.sh}\")/~tool tool_extra toolbox"
  "control: without the name-and-dash arm the script's second suite stands down~append~skills/mapped/scripts/tool~s/case \"\$base\" in \"\$name\" | \"\$name\"-\*)/case \"\$base\" in \"\$name\")/~tool"
  "control: with names matched by their start a script whose name begins another's runs that one's reader~append~skills/mapped/scripts/orphan~s/\"\$nl\/\$n\$nl\"/\"\$nl\/\$n\"/~longer"
  "control: with a top-level script's name matched in every file the suite of a script running it runs~append~skills/mapped/scripts/tool~s/^          \*) names=\${SCAN_SOURCED\[i\]} ;;$/          *) ;;/~caller tool tool_extra"
  "control: without the source-line needle the script a script sources goes unreached and the whole set runs~append~skills/mapped/scripts/base~s/^          \*) names=\${SCAN_SOURCED\[i\]} ;;$/          *) names=\"\" ;;/~$MAPPED_ALL"
  "control: with one scan loaded for every tree the second tree's path reaches nothing and its whole set runs~append~hooks/alpha.sh skills/mapped/scripts/runner~s/\[ \"\${SCAN_DIR-}\" = \"\$dir\" \] || scan_load/[ -n \"\${SCAN_DIR-}\" ] || scan_load/~$TWO_TREES_ONE_SCAN"
  "control: with a suite adding its name the readers of the lib sharing it run~append~skills/mapped/scripts/driven~s/^    suite) ;;$/    suite) next_any+=(\"\${2##*\/}\") ;;/~deep helped probed wrap wrapped"
  "control: with comment lines read as code the suite citing a lib in a comment runs~append~skills/mapped/scripts/lib/pid.sh~s/'^\[\[:space:\]\]\*/'^NEVER/~cited deep drives pid_direct runner wrapped"
  "control: with one pass of the scan the suites two files away stand down~append~skills/mapped/scripts/lib/pid.sh~s/^  while \[ \"\${#next_any\[@\]}\" -gt 0 \] || \[ \"\${#next_script\[@\]}\" -gt 0 \]; do$/  for _ in 1; do/~pid_direct runner"
  "control: without a joining file adding its needle only the suite naming the lib itself runs~append~skills/mapped/scripts/lib/pid.sh~/^      reach_join \"\${SCAN_ROLE\[i\]}\" \"\${SCAN_PATH\[i\]}\" || return 3$/d~pid_direct"
  "control: without the name rule for a reached script its named suite stands down~append~skills/mapped/scripts/lib/pid.sh~s/^  for f in \${reach_scripts\[@\]+\"\${reach_scripts\[@\]}\"}; do$/  for f in; do/~deep drives pid_direct wrapped"
  "control: with skill_files missing top-level scripts the lib's script and its suites stand down~append~skills/mapped/scripts/lib/pid.sh~s| \"\$1\"/scripts/\* \"\$1\"/scripts/\*/\*| \"\$1\"/scripts/*/*|~deep pid_direct wrapped"
  "control: with skill_files missing scripts subdirectories the lib chain stands down~append~skills/mapped/scripts/lib/pid.sh~s| \"\$1\"/scripts/\*/\* \"\$1\"/tests/lib/\*| \"\$1\"/tests/lib/*|~drives pid_direct runner"
  "control: with skill_files missing tests/lib the helper's suite goes unreached~append~skills/mapped/scripts/driven~s| \"\$1\"/tests/lib/\* \"\$1\"/tests/\*.sh| \"\$1\"/tests/*.sh|~wrap"
  "control: without tests/lib in the scanned-path arm a changed helper runs the whole set~append~skills/mapped/tests/lib/helper.sh~/^    \*:tests\/lib\/\*.sh | \*:tests\/lib\/\*.bash) echo helper ;;$/d~$MAPPED_ALL"
  "control: without a module's folder seed only its file readers run~append~skills/mapped/scripts/plugin/hooks/x.js~/^      next_any+=(\"\${name%%\/\*}\")$/d~"
  "control: with module rejection restored a module runs the whole set~append~skills/mapped/scripts/unused/data.json~s/in test-module) return 1/in module | test-module) return 1/~$MAPPED_ALL"
  "control: without the hook doc role README runs the whole hooks set~append~hooks/README.md~/^    hooks:\*.md) echo doc ;;$/d~$HOOKS_ALL"
  "control: without the script read filter a printed brief reaches its suites~append~skills/mapped/SKILL.md~/^      script | lib)$/,/^        ;;$/d~brief catalogscan rootglob skillmd walker"
  "control: with bare for recognized as a read command the shipped launch briefs reach their suite~append~skills/mapped/SKILL.md~s/(cat|grep|sed|awk|head|tail|read|find)/(cat|grep|sed|awk|head|tail|read|find|for)/~brief catalogscan rootglob skillmd walker"
  "control: without cat as a read command the workflow script reader stands down~append~skills/mapped/workflows/flow.md~s/(cat|grep|sed|awk|head|tail|read|find)/(grep|sed|awk|head|tail|read|find)/~catalogscan flowdir flowread walker"
  'control: without quoted directory paths the find and assigned directory readers stand down~append~skills/doc-readers/workflows/flow.md~s/|\[\\"'"'"'\](.*$/"/~'
  'control: without quoted directory paths the array and find readers stand down~append~skills/doc-readers/references/guide.md~s/|\[\\"'"'"'\](.*$/"/~'
  'control: without path assignments the sed readers stand down~append~skills/doc-readers/schemas/review-finding-prompt.md~s/assignment_names\[++assignments\] = name/assignment_names[++assignments] = "NEVER"/~quoted-find'
  'control: without variable reads unread and printed assignments select their suites~append~skills/doc-readers/schemas/review-finding-prompt.md~s/if (read_names\[assignment_names\[i\]\])/if (1)/~assigned-lib assigned-script printed-path quoted-find unused'
  'control: with any directory mention counted the API suite joins~append~skills/mapped/workflows/flow.md~s#^      dir=.*#      dir="/${rel%%/*}(/?\\$|/[^[:alnum:]._-]|[^/[:alnum:]._-])"#~api catalogscan flowdir flowread readflow walker'
  "control: with a test module matching a script only on a source line the suite using it stands down~append~skills/mapped/scripts/driven~s/^          suite | helper | test-module) ;;$/          suite | helper) ;;/~helped wrap"
  "control: without the runner arm a deleted runner runs nothing~delete~skills/mapped/tests/run-all.sh~/^    \*:tests\/run-all.sh) return 1 ;;$/d~"
  "control: without the references arm a changed reference runs the whole set~append~skills/mapped/references/table.conf~s/^    \*:references\/\* | \*.md) echo doc ;;$/    *.md) echo doc ;;/~$MAPPED_ALL"
  "control: without the .md arm a changed SKILL.md runs the whole set~append~skills/mapped/SKILL.md~s/^    \*:references\/\* | \*.md) echo doc ;;$/    *:references\/*) echo doc ;;/~$MAPPED_ALL"
  "control: with no skill-root pattern for a root doc the root's globber stands down~append~skills/mapped/SKILL.md~s/^    \*) dir='.*' ;;$/    *) dir=NEVER ;;/~catalogscan skillmd walker"
  "control: with every doc's directory read as references the workflow directory's globber stands down~append~skills/mapped/workflows/flow.md~s|dir=\"/\\\${rel%%/\\*}(|dir=\"/references(|~catalogscan docscan flowread readflow refsuse walker"
  'control: with the reference matched by its bare name the suite naming table.conf in another directory runs~append~skills/mapped/references/table.conf~s|for pattern in "/[$]rel"|for pattern in "/${rel:11}"|~catalogscan docscan refsuse tool tool_extra toolbox walker'
  "control: with comment lines read as code the script citing a reference in a comment runs its suite~append~skills/plain/references/note.md~s/'^\[\[:space:\]\]\*/'^NEVER/~alpha.test.sh"
  'control: without the whole-token match the suite reading the schema doc through a table stands down~append~skills/mapped/schemas/rec.md~s/"[$]token" "[$]dir"/"NEVER" "$dir"/~catalogscan walker'
  'control: without the directory-reader match the glob readers stand down~append~skills/mapped/references/table.conf~s/"[$]token" "[$]dir"/"$token" "NEVER"/~catalogscan tool tool_extra walker'
  'control: with the directory pattern taking any reference path a reader of another reference runs~append~skills/mapped/references/table.conf~s,}(/?\\\$|,}(/|/?\\\$|,~catalogscan docscan helped probed refsuse tool tool_extra walker wrap'
  "control: without the readers seeding the scan only the suites reading the reference run~append~skills/mapped/references/table.conf~/^  if \[ \"\$role\" = doc \]; then$/,/^  else$/s/reach_join .*/:/~catalogscan docscan walker"
  "control: with a skill-root variable no longer taken as a walk start the skill-root walker stands down~append~skills/mapped/references/table.conf~s/\[A-Z_\]\*SKILL\[A-Z_\]\*/NEVER/~catalogscan docscan refsuse tool tool_extra"
  "control: with a path ending in /skills no longer taken as a walk start the skills-directory walker stands down~append~skills/mapped/references/table.conf~s,\*/skills)\"?,*/NEVER)\"?,~docscan refsuse tool tool_extra walker"
  "control: with a reference whose readers reach no suite taken as read by none it runs nothing~append~skills/plain/references/lone.md~s/^      tests\/\*\/\*) ;;$/      references\/*) return 0 ;; tests\/*\/*) ;;/~"
  "control: without the no-reader arm a reference only a comment and prose cite runs the whole set~append~skills/plain/references/note.md~s/^    \[ -n \"\$readers\" \] || return 0$/    [ -n \"\$readers\" ] || return 1/~$PLAIN_ALL"
  "control: with an empty file taken as unreadable a reference only a comment and prose cite runs the whole set~append~skills/plain/references/note.md~s/ || \[ \$? -eq 1 \] || return 2$/ || return 2/~$PLAIN_ALL"
  "control: without the whole-set fallback the unmapped script runs nothing~append~skills/mapped/scripts/orphan~s/unmapped path=\$f\"; run=all; break ;;/unmapped path=\$f\"; break ;;/~"
  "control: with each path's suites overwriting the last only the last path's run~append~skills/mapped/scripts/tool skills/mapped/tests/other.sh~s/^            run=\"\$run\$sel$/            run=\"\$sel/~other"
  "control: with the no-runner loop reading the whole set every suite runs~append~skills/plain/scripts/alpha.sh~s/^        done <<<\"\$run\"$/        done <<<\"\$(skill_suites \"\$d\")\"/~$PLAIN_ALL"
  "control: without the .test strip the script's suite goes unmatched and the whole set runs~append~skills/plain/scripts/alpha.sh~/base=\"\${base%.test}\"/d~$PLAIN_ALL"
  "control: with the mapping taking skills alone a changed hook runs the whole hooks set~append~hooks/alpha.sh~s/ in skills\/\* | hooks | tools) run=\"\" ;;/ in skills\/* | tools) run=\"\" ;;/~$HOOKS_ALL"
  "control: with a render's path kept whole a changed hook render runs the whole hooks set~append~.codex/hooks/demo.sh~s/^        rel=\"\${f#\*hooks\/}\"$/        rel=\"\$f\"/~$HOOKS_ALL"
  "control: without the hook arm a changed hook runs the whole hooks set~append~hooks/alpha.sh~/^    hooks:\*.sh) echo script ;;$/d~$HOOKS_ALL"
)
for row in "${MAP_CONTROLS[@]}"; do
  IFS='~' read -r label how paths expr want <<<"$row"
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
if mutant_guard '/^          note suites "\$selected_count\/\$total_count reason=mapped tree=\$d"$/d'; then
  map_row append skills/mapped/tests/tool.sh "$(mapped_note 1/$MAPPED_N skills/mapped)" "$MUTANT_TOOLS/guard"
  [[ "$VERDICT" == *" started=tool note=missing" ]] \
    && ok "control: without the narrowed-run note the one-suite run says nothing of the cut" \
    || bad "control: without the narrowed-run note the one-suite run says nothing of the cut" "$VERDICT out=$OUT"
else
  bad "control: the narrowed-run note could not be removed from a guard copy"
fi
# A path no arm gives a role is the catch-all's: with that arm gone, the role
# mapped_suites hands reach_join is none it knows, and the guard reds as
# broken rather than scanning the path; with reach_join's refusal gone too,
# the broken state passes as an unmapped path.
CATCH_ALL='/^    \*) return 1 ;;$/d'
if mutant_guard "$CATCH_ALL"; then
  map_row append skills/mapped/settings.example none "$MUTANT_TOOLS/guard"
  [[ "$VERDICT" == "rc=1 started=$MAPPED_ALL "* ]] && [[ "$OUT" == *"guard: mapped-suites=3 path=skills/mapped/settings.example"* ]] \
    && ok "control: without the catch-all arm a changed file of no role reds the guard as broken" \
    || bad "control: without the catch-all arm a changed file of no role reds the guard as broken" "$VERDICT out=$OUT"
else
  bad "control: the catch-all arm could not be deleted from a guard copy"
fi
if mutant_guard "$CATCH_ALL; /^    \*) return 3 ;;$/d"; then
  map_row append skills/mapped/settings.example none "$MUTANT_TOOLS/guard"
  [[ "$VERDICT" == "rc=0 started=$MAPPED_ALL "* ]] && [[ "$OUT" != *"guard: mapped-suites="* ]] \
    && ok "control: without reach_join's refusal the role-less path passes silently" \
    || bad "control: without reach_join's refusal the role-less path passes silently" "$VERDICT out=$OUT"
else
  bad "control: reach_join's refusal could not be deleted from a guard copy"
fi
# A file the scan cannot read is no evidence it names nothing: the skill runs
# whole, and the note names the read, not the rule. The stub fails the scan's
# read, the grep -v that drops comment lines, of the file FAIL_GREP names: a
# lib the scan passes through, a suite it ends on, and a reader of the whole
# directory.
REAL_GREP="$(command -v grep)"
cat >"$R/fake-bin/grep" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do :; done
if [ -n "${FAIL_GREP:-}" ] && [ "$1" = -v ] && [ "$a" = "$FAIL_GREP" ]; then
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
# The one rule: the read's failure is not taken as a file naming nothing.
LENIENT='s/^\(    code=.*\) || \[ \$? -eq 1 \] || return 2$/\1 || true/'
# changed path#unreadable file#suites that start once its failed read is
# taken as no match
UNREAD_ROWS=(
  "skills/mapped/scripts/lib/pid.sh#skills/mapped/scripts/lib/wrap.sh#drives pid_direct runner"
  "skills/mapped/scripts/lib/pid.sh#skills/mapped/tests/pid_direct.sh#deep drives runner wrapped"
  "skills/mapped/references/table.conf#skills/mapped/tests/docscan.sh#catalogscan refsuse tool tool_extra walker"
)
for row in "${UNREAD_ROWS[@]}"; do
  IFS='#' read -r changed unread lenient <<<"$row"
  change append "$changed"
  range_grep_fails "$unread" "$GUARD"
  [ "$RC" -eq 0 ] && [ "$(started)" = "$MAPPED_ALL" ] \
    && [[ "$OUT" == *"$(note_for unreadable "$changed")"* ]] \
    && [[ "$OUT" != *"no explanation is defined for this value"* ]] \
    && ok "an unreadable $unread runs the whole set and names the read" \
    || bad "an unreadable $unread runs the whole set and names the read" "rc=$RC started=$(started) out=$OUT"
  if mutant_guard "$LENIENT"; then
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

# second-opinion reads assigned schema paths with sed. Its extraction must
# finish before the tree can be reused for another changed document.
ln -s "$REAL_AWK" "$R/fake-bin/real-awk"
cat >"$R/fake-bin/awk" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *read_names*)
    printf 'extract\n' >>"$0.log"
    if [ -f "$0.fail" ]; then
      # Partial output from a failed dependency is still unreadable.
      printf 'sed "$schema_file"\n'
      exit 2
    fi
    ;;
esac
exec "${0%/*}/real-awk" "$@"
SH
chmod +x "$R/fake-bin/awk"
READ_LOG="$R/fake-bin/awk.log"
DOC_ALL="$(printf '%s\n' "$D"/tests/*.sh | sed 's#.*/##; s/\.sh$//' | sort | tr '\n' ' ' | sed 's/ $//')"
SCHEMA_PATH=skills/doc-readers/schemas/review-finding-prompt.md
READ_ROWS=(
  "one document|$SCHEMA_PATH|assigned-lib assigned-script quoted-find"
  "repeated document queries|$SCHEMA_PATH skills/doc-readers/workflows/flow.md|assigned-dir assigned-lib assigned-script quoted-find"
  "another tree before the document|hooks/README.md $SCHEMA_PATH|assigned-lib assigned-script beta.test.sh quoted-find"
)
single_extractions=""
for row in "${READ_ROWS[@]}"; do
  IFS='|' read -r label paths want <<<"$row"
  : >"$READ_LOG"
  map_row append "$paths" none
  extractions="$(wc -l <"$READ_LOG" | tr -d ' ')"
  [ "$RC" -eq 0 ] && [ "$(started)" = "$want" ] \
    && ok "checked read metadata selects readers for $label" \
    || bad "checked read metadata selects readers for $label" "$VERDICT out=$OUT"
  case "$label" in
    'one document') single_extractions=$extractions ;;
    'repeated document queries')
      [ "$extractions" -gt 0 ] && [ "$extractions" = "$single_extractions" ] \
        && ok "another document reuses the completed extraction" \
        || bad "another document reuses the completed extraction" "single=$single_extractions repeated=$extractions"
      ;;
  esac
done
# Breaking the tree reset must redden the cross-tree reader assertion.
if mutant_guard '/^  SCAN_READ_CODE=()$/d'; then
  map_row append "hooks/README.md $SCHEMA_PATH" none "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$(started)" != 'assigned-lib assigned-script beta.test.sh quoted-find' ] \
    && ok "control: retained read metadata fails the next tree's reader assertion" \
    || bad "control: retained read metadata fails the next tree's reader assertion" "$VERDICT out=$OUT"
else
  bad "control: the read metadata reset could not be removed"
fi
# Reloading for every document breaks the extraction reuse assertion.
if mutant_guard 's/\[ "${SCAN_DIR-}" = "$dir" \] || scan_load/scan_load/'; then
  : >"$READ_LOG"
  map_row append "$SCHEMA_PATH skills/doc-readers/workflows/flow.md" none "$MUTANT_TOOLS/guard"
  extractions="$(wc -l <"$READ_LOG" | tr -d ' ')"
  [ "$RC" -eq 0 ] && [ "$extractions" -gt "$single_extractions" ] \
    && ok "control: repeated extraction fails the reuse assertion" \
    || bad "control: repeated extraction fails the reuse assertion" "single=$single_extractions repeated=$extractions $VERDICT"
else
  bad "control: extraction reuse could not be removed"
fi
touch "$R/fake-bin/awk.fail"
map_row append "$SCHEMA_PATH" "$(note_for unreadable "$SCHEMA_PATH")"
[ "$VERDICT" = "rc=0 started=$DOC_ALL note=$(note_for unreadable "$SCHEMA_PATH")" ] \
  && [ "$(sed -n '$p' <<<"$OUT")" = 'validate: lanes=guard-scans selection=all' ] \
  && ok "a failed reader extraction runs the whole tree" \
  || bad "a failed reader extraction runs the whole tree" "$VERDICT out=$OUT"
if mutant_guard '/<<<"\$code") || return 2$/s/|| return 2/|| true/'; then
  map_row append "$SCHEMA_PATH" none "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$(started)" != "$DOC_ALL" ] \
    && ok "control: ignoring the extraction failure skips the whole-tree fallback" \
    || bad "control: ignoring the extraction failure skips the whole-tree fallback" "$VERDICT out=$OUT"
else
  bad "control: reader extraction failure could not be ignored"
fi
rm -f -- "${R:?}/fake-bin/awk" "$R/fake-bin/real-awk" "$READ_LOG" "$R/fake-bin/awk.fail"
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
