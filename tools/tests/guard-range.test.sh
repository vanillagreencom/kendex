#!/usr/bin/env bash
# tools/guard --range BASE, a fix round's validation: the default rules read
# over the changes since BASE, cargo clippy for the crates those
# changes touch, the UI checks and suite for a non-Markdown UI change, the
# skill, hook and tools suites their changed inputs map to and the suites of
# the other trees they touch, and none of what --full adds beyond that: the
# workspace test run, cross-target checks, the documentation build, the Bash
# 3.2 parse, the working-tree bot-instructions check, the decision-ID check,
# the cargo free-space floor and the class lane selection. Native lint-policy
# rows compile disposable inputs; selection rows log calls through fake-bin.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"

native_lint_policy() {
  local native_base row target selection expected native_rc native_out i
  mkdir -p "$R/crates/core/src"
  rm -- "${R:?}/crates/core/tests/existing_temp.rs"
  printf '%s\n' '[workspace]' 'resolver = "3"' 'members = ["crates/core"]' >"$R/Cargo.toml"
  # Consume the actual policy rather than maintaining another lint list.
  awk '/^\[workspace.lints.clippy\]$/ { copying=1 }
    /^\[/ && $0 != "[workspace.lints.clippy]" { copying=0 }
    copying { print }' "$REPO/Cargo.toml" >>"$R/Cargo.toml"
  cat >"$R/crates/core/Cargo.toml" <<'TOML'
[package]
name = "kendex-core"
version = "0.1.0"
edition = "2024"
autotests = false
[lints]
workspace = true
[[test]]
name = "integration"
path = "tests/main.rs"
TOML
  printf '%s\n' 'pub fn production() {}' >"$R/crates/core/src/lib.rs"
  printf '%s\n' 'fn main() {}' >"$R/crates/core/build.rs"
  printf '%s\n' '#[test]' 'fn neutral() {}' >"$R/crates/core/tests/main.rs"
  cp "$REPO/rust-toolchain.toml" "$R/rust-toolchain.toml"
  cp "$REPO/clippy.toml" "$R/clippy.toml"
  git -C "$R" add -A
  git -C "$R" commit -qm 'native lint fixture'
  native_base="$(git -C "$R" rev-parse HEAD)"
  # Cargo and Clippy are the judges. The planted function exceeds the native
  # default threshold with statements, not comments or blank source lines.
  native_long_function() {
    printf '%s\n' "$1 {" '    let mut value = 0_u32;'
    for ((i=0; i<105; i++)); do printf '%s\n' '    value = std::hint::black_box(value + 1);'; done
    printf '%s\n' '    assert_eq!(value, 105);' '}'
  }
  for row in 'production|manifest|too_many_lines' 'build-script|workspace|too_many_lines' \
    'test-helpers|manifest|pass' 'forbidden-helper|workspace|todo'; do
    IFS='|' read -r target selection expected <<<"$row"
    git -C "$R" reset -q --hard "$native_base"
    case "$target" in
      production)
        native_long_function 'pub fn production()' >"$R/crates/core/src/lib.rs"
        # The all-target check must still run after production length fails.
        printf '%s\n' 'fn forbidden() { todo!(); }' >"$R/crates/core/tests/main.rs"
        ;;
      build-script) native_long_function 'fn main()' >"$R/crates/core/build.rs" ;;
      test-helpers | forbidden-helper)
        {
          printf '%s\n' 'pub fn production() {}' '#[cfg(test)]' 'mod tests {'
          native_long_function 'fn private_helper()'
          printf '%s\n' '#[test]'
          native_long_function 'fn long_test()'
          printf '%s\n' '#[test]' 'fn calls_helper() { private_helper(); }' '}'
        } >"$R/crates/core/src/lib.rs"
        {
          native_long_function 'fn integration_helper()'
          printf '%s\n' '#[test]' 'fn calls_helper() { integration_helper(); }'
          if [ "$target" = forbidden-helper ]; then printf '%s\n' 'fn forbidden() { todo!(); }'; fi
        } >"$R/crates/core/tests/main.rs"
        ;;
    esac
    [ "$selection" != workspace ] || printf '\n' >>"$R/clippy.toml"
    (cd "$R" && cargo fmt)
    native_rc=0
    native_out="$(cd "$R" && CARGO_TARGET_DIR="$TMP/tmp/native-$target" "$GUARD" --range "$native_base" 2>&1)" || native_rc=$?
    # Clippy's lint identifier is the machine category these rows consume.
    if [ "$expected" = pass ]; then
      [ "$native_rc" -eq 0 ] && ok 'native lint policy accepts long tests and private/integration helpers' \
        || bad 'native lint policy accepts long tests and private/integration helpers' "$native_out"
    else
      [ "$native_rc" -eq 1 ] && [[ "$native_out" == *"#$expected"* ]] \
        && { [ "$target" != production ] || [[ "$native_out" == *'#todo'* ]]; } \
        && ok "native $selection lint policy refuses $target through $expected" \
        || bad "native $selection lint policy refuses $target through $expected" "$native_out"
    fi
  done
  unset -f native_long_function
  reset_world
}
native_lint_policy

CALLS="$TMP/calls"
SCAN_BIN="$TMP/scan-bin"
mkdir -p "$R/fake-bin" "$SCAN_BIN"
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
entry_points_executable
git -C "$R" commit -q -m "chore: a crate, a UI package and a skill whose suite fails"
BASE="$(git -C "$R" rev-parse HEAD)"

run_range() { # BASE [GUARD] — sets OUT, RC and LOG; GUARD defaults to the real one
  OUT=""
  RC=0
  : >"$CALLS"
  OUT="$(cd "$R" && env PATH="$SCAN_BIN:$R/fake-bin:$PATH" CALL_LOG="$CALLS" "${2:-$GUARD}" --range "$1" 2>&1 </dev/null)" || RC=$?
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
[ "$RC" -eq 0 ] && [ -z "$LOG" ] && [[ "$OUT" == *"=== skills/demo/tests/demo.test.sh"* ]] && [[ "$OUT" != *"=== skills/quiet/tests/quiet.test.sh"* ]] \
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
  grep -qFx "cargo clippy --workspace --all-targets --quiet" <<<"$LOG" \
    && ok "control: with range compiling everything the skill-only diff reaches cargo" \
    || bad "control: with range compiling everything the skill-only diff reaches cargo" "rc=$RC log=$LOG"
else
  bad "control: the full-mode compile set could not be widened to range in a guard copy"
fi
back_to_base

echo "=== what a range compiles is what it touched since its base ==="
CORE_CALLS="cargo tree -p kendex-core -e normal
cargo clippy --version
cargo clippy --manifest-path crates/core/Cargo.toml --quiet -- -D clippy::too_many_lines
cargo clippy --manifest-path crates/core/Cargo.toml --all-targets --quiet
cargo fmt --version
cargo fmt --check"
WORKSPACE_CALLS="cargo tree -p kendex-core -e normal
cargo clippy --version
cargo clippy --workspace --quiet -- -D clippy::too_many_lines
cargo clippy --workspace --all-targets --quiet
cargo fmt --version
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
  [ "$RC" -eq 0 ] && [ "$LOG" = "$want" ] && [ "$(sed -n '$p' <<<"$OUT")" = 'validate: lanes=guard-scans selection=subset' ] \
    && ok "$label" \
    || bad "$label" "rc=$RC log=$LOG out=$OUT"
  back_to_base
done
[ "$((PASS + FAIL))" -eq "$((before + ${#ROWS[@]}))" ] || { echo "a compile-set row asserted nothing" >&2; exit 2; }

echo "=== runtime manifest reads select only the reading crate's tests ==="
# The corpus producer joins a literal directory onto CARGO_MANIFEST_DIR.
# Keep the fixture read below a skill subtree to prove unrelated skill paths
# remain outside coverage, and a root read to prove unresolved paths do not
# widen that coverage.
mkdir -p "$R/crates/core/tests/quality" "$R/skills/watched" "$R/skills/unread"
printf '%s\n' 'let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills/watched");' \
  'let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");' \
  >"$R/crates/core/tests/quality/corpus.rs"
printf '# skill\n' >"$R/skills/watched/SKILL.md"
printf '# skill\n' >"$R/skills/unread/SKILL.md"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: a runtime skill reader"
runtime_base="$(git -C "$R" rev-parse HEAD)"
TEST_CALL='cargo test --manifest-path crates/core/Cargo.toml --quiet'
RUNTIME_ROWS=(
  "skills/watched/SKILL.md|$TEST_CALL"
  "skills/unread/SKILL.md|"
  "docs/unread.md|"
  "skills/watchedness/SKILL.md|"
)
for row in "${RUNTIME_ROWS[@]}"; do
  IFS='|' read -r path want <<<"$row"
  mkdir -p "$R/$(dirname "$path")"
  printf 'edit\n' >>"$R/$path"
  run_range "$runtime_base"
  [ "$RC" -eq 0 ] && [ "$LOG" = "$want" ] \
    && ok "manifest coverage for $path selects [$want]" \
    || bad "manifest coverage for $path selects [$want]" "rc=$RC log=$LOG out=$OUT"
  git -C "$R" reset -q --hard "$runtime_base"
  git -C "$R" clean -qfd -e fake-bin
done
# The configured ci-mode local route runs this same range with scoped=true.
# A selected cargo test's failure must still fail that route.
printf 'edit\n' >>"$R/skills/watched/SKILL.md"
cp "$R/fake-bin/cargo" "$TMP/cargo.saved"
printf '%s\n' '#!/usr/bin/env bash' 'echo "cargo $*" >>"$CALL_LOG"' \
  '[ "${1:-}" != test ]' >"$R/fake-bin/cargo"
RC=0
: >"$CALLS"
OUT="$(cd "$R" && env DEV_VALIDATE_SCOPED=true PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" \
  "$GUARD" --selection --range "$runtime_base" 2>&1 </dev/null)" || RC=$?
[ "$RC" -eq 1 ] && grep -qFx "$TEST_CALL" "$CALLS" \
  && grep -qFx 'guard: cargo-test=crates/core/Cargo.toml' <<<"$OUT" \
  && ok "the configured scoped route fails when the manifest reader's test fails" \
  || bad "the configured scoped route fails when the manifest reader's test fails" "rc=$RC out=$OUT"
cp "$TMP/cargo.saved" "$R/fake-bin/cargo"
back_to_base

echo "=== a range keeps its own selection whatever class it is handed ==="
# dev-validate-run hands every run the branch's change class; the lane
# selection that reads it is the full run's, and a range selects from its own
# touched set.
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
printf 'echo more\n' >>"$R/.agents/skills/demo/scripts/demo.sh"
printf '%s\n' skills/demo/scripts/demo.sh .agents/skills/demo/scripts/demo.sh >"$TMP/class-paths"
OUT=""
RC=0
: >"$CALLS"
OUT="$(cd "$R" && env DEV_VALIDATE_CLASS=render DEV_VALIDATE_DOCS_ONLY=false DEV_VALIDATE_PATHS="$TMP/class-paths" \
  PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$GUARD" --range "$BASE" 2>&1 </dev/null)" || RC=$?
[ "$RC" -eq 0 ] && [[ "$OUT" == *"=== skills/demo/tests/demo.test.sh"* ]] \
  && ok "a range handed a render class still runs the touched skill's suite" \
  || bad "a range handed a render class still runs the touched skill's suite" "rc=$RC out=$OUT"
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
[ "$RC" -eq 0 ] && [[ "$OUT" != *"guard: cargo-space-"* ]] && grep -qFx "cargo clippy --manifest-path crates/core/Cargo.toml --all-targets --quiet" "$CALLS" \
  && ok "a range under unreachable space floors still checks its crate" \
  || bad "a range under unreachable space floors still checks its crate" "rc=$RC out=$OUT"
back_to_base

echo "=== failed Rust read dependencies cannot pass the range ==="
# find produces the extractor's source set; awk and sort produce the reading
# manifest selection. Partial dependency output is not complete evidence.
REAL_FIND="$(command -v find)"
REAL_SORT="$(command -v sort)"
cat >"$R/fake-bin/find" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAIL_DEP:-}" = find ] && [ "${1:-}" = crates ] && [ "${4:-}" = -name ] && [ "${5:-}" = '*.rs' ]; then
  exit 1
fi
exec "$REAL_FIND" "$@"
SH
cat >"$R/fake-bin/awk" <<'SH'
#!/usr/bin/env bash
if [ "${FAIL_DEP:-}" = awk ] && [[ $* == *'ENVIRON["CHANGED"]'* ]]; then
  printf 'crates/core/Cargo.toml\n'
  exit 2
fi
exec "$REAL_AWK" "$@"
SH
cat >"$R/fake-bin/sort" <<'SH'
#!/usr/bin/env bash
data=$(cat) || exit 2
if [ "${FAIL_DEP:-}" = sort ] && [ "$data" = crates/core/Cargo.toml ]; then
  printf '%s\n' "$data"
  exit 2
fi
exec "$REAL_SORT" "$@" <<<"$data"
SH
chmod +x "$R/fake-bin/find" "$R/fake-bin/awk" "$R/fake-bin/sort"
range_dependency_fails() { # DEPENDENCY
  OUT=""
  RC=0
  : >"$CALLS"
  OUT="$(cd "$R" && env FAIL_DEP="$1" REAL_FIND="$REAL_FIND" REAL_AWK="$REAL_AWK" REAL_SORT="$REAL_SORT" \
    PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$GUARD" --range "$runtime_base" 2>&1 </dev/null)" || RC=$?
  LOG="$(cat "$CALLS")"
}
git -C "$R" reset -q --hard "$runtime_base"
printf 'edit\n' >>"$R/skills/watched/SKILL.md"
DEPENDENCY_ROWS=(
  "find|$WORKSPACE_CALLS"
  "awk|"
  "sort|"
)
for row in "${DEPENDENCY_ROWS[@]}"; do
  dependency="${row%%|*}"
  want="${row#*|}"
  range_dependency_fails "$dependency"
  [ "$RC" -eq 1 ] && grep -qFx 'guard: rust-reads=crates' <<<"$OUT" && [ "$LOG" = "$want" ] \
    && ok "failed $dependency refuses Rust read selection with the expected cargo calls" \
    || bad "failed $dependency refuses Rust read selection with the expected cargo calls" "rc=$RC log=$LOG out=$OUT"
done
rm -f -- "${R:?}/fake-bin/find" "${R:?}/fake-bin/awk" "${R:?}/fake-bin/sort"
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
chmod +x "$R/skills/demo/scripts/new.sh"
git -C "$R" add -N skills/demo/scripts/new.sh
run_range "$BASE"
[ "$RC" -eq 0 ] && [[ "$OUT" != *"guard: missing-render="* ]] \
  && ok "an intent-added source with its untracked render passes the render rule" \
  || bad "an intent-added source with its untracked render passes the render rule" "rc=$RC out=$OUT"
back_to_base
printf 'echo drifted\n' >>"$R/skills/demo/scripts/demo.sh"
run_range "$BASE"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: missing-render=1"* ]] && [[ "$OUT" == *"skills/demo/scripts/demo.sh -> .agents/skills/demo/scripts/demo.sh"* ]] \
  && ok "a source changed since the base without its render reds the range, naming the pair" \
  || bad "a source changed since the base without its render reds the range, naming the pair" "rc=$RC out=$OUT"
back_to_base
printf '%s\n' 'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' drop(tmp);' '}' >"$R/crates/core/tests/untracked_temp.rs"
run_range "$BASE"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: unrooted-fixture=1"* ]] && [[ "$OUT" == *"untracked_temp.rs:2"* ]] \
  && ok "an untracked test file's unrooted fixture reds the range" \
  || bad "an untracked test file's unrooted fixture reds the range" "rc=$RC out=$OUT"
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
printf '%s\n' 'schema = 7' 'is_source_catalog = true' >"$R/kendex.toml"
printf '%s\n' '[skill-instructions]' 'demo = "Rule."' >"$R/kendex-local.toml"
git -C "$R" add -A
git -C "$R" commit -q -m "chore: a configured skill instruction"
instructions_base="$(git -C "$R" rev-parse HEAD)"
cp "$R/skills/demo/SKILL.md" "$R/.agents/skills/demo/SKILL.md"
run_range "$instructions_base"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: missing-skill-instructions=1"* ]] && [[ "$OUT" == *".agents/skills/demo/SKILL.md"* ]] \
  && ok "an unstaged render without its configured block reds the range" \
  || bad "an unstaged render without its configured block reds the range" "rc=$RC out=$OUT"
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
cp "$REPO/skills/orch/tests/lib/suite-process.sh" "$M/tests/lib/suite-process.sh"
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
entry_points_executable
git -C "$R" commit -q -m "chore: two skills and hooks with suites named for their files"
mapped_base="$(git -C "$R" rev-parse HEAD)"
# The mapped skill's whole set, read from the suites the builder above wrote
# so a suite added for one rule moves no other row: MAPPED_ALL sorted as
# started() prints it, MAPPED_N its size.
mapped_suites=()
for f in "$M"/tests/*.sh; do
  [ -f "$f" ] || continue
  f="${f##*/}"
  [ "$f" = run-all.sh ] || mapped_suites+=("${f%.sh}")
done
[ "${#mapped_suites[@]}" -gt 0 ] || { echo "guard-range: mapped-suites=none dir=$M/tests" >&2; exit 2; }
MAPPED_N=${#mapped_suites[@]}
MAPPED_ALL="$(printf '%s\n' "${mapped_suites[@]}" | sort | tr '\n' ' ' | sed 's/ $//')"
# Every reader of the mapped skill's SKILL.md.
SKILL_READERS="catalogscan rootglob skillmd walker"
# A range across two trees: the hooks suites alpha's change maps to beside
# the mapped skill's for runner, one sorted list as started() prints it.
TWO_TREES="$(printf '%s\n' alpha-copilot.test.sh alpha.test.sh via-world.test.sh drives runner | sort | tr '\n' ' ' | sed 's/ $//')"
PLAIN_CATALOG="alpha.test.sh beta.test.sh catalogscan gamma.test.mjs"
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
  "a root doc with no local reader runs its catalog reader|append|skills/plain/README.md|catalogscan|$(mapped_note 0/3 skills/plain)"
  "a changed reference runs the suites of its path readers, the directory's readers and the walkers of the skill root and the skills directory|append|skills/mapped/references/table.conf|catalogscan docscan refsuse tool tool_extra walker|$(mapped_note 6/$MAPPED_N skills/mapped)"
  "a reference whose local readers reach no suite runs the local whole set and its catalog reader|append|skills/plain/references/lone.md|$PLAIN_CATALOG|$(note_for unmapped skills/plain/references/lone.md)"
  "a reference with only local comment and prose citations runs its catalog reader|append|skills/plain/references/note.md|catalogscan|$(mapped_note 0/3 skills/plain)"
  "two changed paths run the suites of both|append|skills/mapped/scripts/tool skills/mapped/tests/other.sh|other tool tool_extra|$(mapped_note 3/$MAPPED_N skills/mapped)"
  "a mapped and an unmapped path run the whole set|append|skills/mapped/scripts/tool skills/mapped/scripts/orphan|$MAPPED_ALL|$(note_for unmapped skills/mapped/scripts/orphan)"
  "with no runner a changed script runs its .test suite alone|append|skills/plain/scripts/alpha.sh|alpha.test.sh|$(mapped_note 1/3 skills/plain)"
  "with no runner a changed suite runs itself alone|append|skills/plain/tests/beta.test.sh|beta.test.sh|$(mapped_note 1/3 skills/plain)"
  "a changed hook runs its namesake suites and the suite whose helper names it|append|hooks/alpha.sh|alpha-copilot.test.sh alpha.test.sh via-world.test.sh|$(mapped_note 3/5 hooks)"
  "a changed render of a hook runs that hook's suite|append|.codex/hooks/demo.sh|demo.test.sh|$(mapped_note 1/5 hooks)"
  "a changed hooks helper runs the suite sourcing it|append|hooks/tests/lib/world.sh|via-world.test.sh|$(mapped_note 1/5 hooks)"
  "quoted find operands and an assigned workflow directory select their readers without API or brief readers|append|skills/doc-readers/workflows/flow.md|assigned-dir catalogscan quoted-find|$(mapped_note 2/9 skills/doc-readers)"
  "a quoted reference directory in an array selects its reader beside find without a printed for details brief|append|skills/doc-readers/references/guide.md|array-dir catalogscan quoted-find|$(mapped_note 2/9 skills/doc-readers)"
  "assigned schema paths used by sed select script and lib readers without briefs or unread assignments|append|skills/doc-readers/schemas/review-finding-prompt.md|assigned-lib assigned-script catalogscan quoted-find|$(mapped_note 3/9 skills/doc-readers)"
  "a changed hook no suite reaches runs the whole hooks set and says so|append|hooks/lone.sh|$HOOKS_ALL|$(note_for unmapped hooks/lone.sh)"
  "a hooks doc runs its reader alone|append|hooks/README.md|beta.test.sh|$(mapped_note 1/5 hooks)"
  "a hooks doc no file reads runs nothing|append|hooks/unused.md||$(mapped_note 0/5 hooks)"
  "a hooks file of no role runs the whole hooks set|append|hooks/settings.example|$HOOKS_ALL|$(note_for unmapped hooks/settings.example)"
)
map_row() { # HOW PATHS NOTE[;;NOTE...] — sets VERDICT
  local noted
  # shellcheck disable=SC2086 # the row's paths, split on purpose
  change "$1" $2
  run_range "$mapped_base"
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
  'docs/guide.md|subset' \
  'skills/demo/scripts/demo.sh .agents/skills/demo/scripts/demo.sh|all' \
  'skills/mapped/tests/tool.sh hooks/settings.example|all' \
  'skills/mapped/settings.example hooks/README.md|all'; do
  IFS='|' read -r path selection <<<"$row"
  map_row append "$path" none
  [ "$RC" -eq 0 ] && [ "$(sed -n '$p' <<<"$OUT")" = "validate: lanes=guard-scans selection=$selection" ] \
    && ok "the final report records $selection for $path" \
    || bad "the final report records $selection for $path" "$OUT"
done
# A file the scan cannot read is no evidence it names nothing: the skill runs
# whole, and the note names the read, not the rule. The stub points the
# named file record at a missing file so the batch read fails: a
# lib the scan passes through, a suite it ends on, and a reader of the whole
# directory.
cat >"$SCAN_BIN/awk" <<'SH'
#!/usr/bin/env bash
program=$1
shift
if [ -n "${FAIL_READ:-}" ] && [[ $program == *'function scan_file('* ]]; then
  data=$(cat) || exit 2
  edited=""
  matches=0
  while IFS= read -r record; do
    case "$record" in
      'F '*)
        path=${record#F }; path=${path#* }; path=${path#* }
        if [ "$path" = "$FAIL_READ" ]; then
          record="${record%"$path"}$path.missing"
          matches=$((matches + 1))
        fi
        ;;
    esac
    edited+="$record"$'\n'
  done <<<"$data"
  if [ "$matches" -eq 0 ]; then
    [ "${edited%$'\n'}" = "$data" ] || exit 2
  else
    [ "$matches" -eq 1 ] && [ "${edited%$'\n'}" != "$data" ] || exit 2
  fi
  exec "$REAL_AWK" "$program" "$@" <<<"$edited"
fi
exec "$REAL_AWK" "$program" "$@"
SH
chmod +x "$SCAN_BIN/awk"
range_read_fails() { # FILE
  OUT=""
  RC=0
  : >"$CALLS"
  OUT="$(cd "$R" && env FAIL_READ="$1" REAL_AWK="$REAL_AWK" PATH="$SCAN_BIN:$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$GUARD" --range "$mapped_base" 2>&1 </dev/null)" || RC=$?
}
# changed path#unreadable file
UNREAD_ROWS=(
  "skills/mapped/scripts/lib/pid.sh#skills/mapped/scripts/lib/wrap.sh"
  "skills/mapped/scripts/lib/pid.sh#skills/mapped/tests/pid_direct.sh"
  "skills/mapped/references/table.conf#skills/mapped/tests/docscan.sh"
)
for row in "${UNREAD_ROWS[@]}"; do
  IFS='#' read -r changed unread <<<"$row"
  change append "$changed"
  range_read_fails "$unread"
  [ "$RC" -eq 0 ] && [ "$(started)" = "$MAPPED_ALL" ] \
    && [[ "$OUT" == *"$(note_for unreadable "$changed")"* ]] \
    && [[ "$OUT" != *"no explanation is defined for this value"* ]] \
    && ok "an unreadable $unread runs the whole set and names the read" \
    || bad "an unreadable $unread runs the whole set and names the read" "rc=$RC started=$(started) out=$OUT"
  back_to_mapped
done
rm -- "$SCAN_BIN/awk"

# second-opinion reads assigned schema paths with sed. Its extraction must
# finish before the tree can be reused for another changed document.
ln -s "$REAL_AWK" "$SCAN_BIN/real-awk"
cat >"$SCAN_BIN/awk" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  *read_names*)
    code=$(cat) || exit 2
    if [ -f "$0.fail" ] && [[ $code == *' skills/doc-readers/'* ]]; then
      # Partial output from a failed dependency is still unreadable.
      printf 'N\t0\t/partial\n'
      exit 2
    fi
    exec "${0%/*}/real-awk" "$@" <<<"$code"
    ;;
esac
exec "${0%/*}/real-awk" "$@"
SH
chmod +x "$SCAN_BIN/awk"
DOC_ALL="$(printf '%s\n' "$D"/tests/*.sh | sed 's#.*/##; s/\.sh$//' | sort | tr '\n' ' ' | sed 's/ $//')"
DOC_CATALOG="$(printf '%s\n' $DOC_ALL catalogscan | sort | tr '\n' ' ' | sed 's/ $//')"
SCHEMA_PATH=skills/doc-readers/schemas/review-finding-prompt.md
READ_ROWS=(
  "one document|$SCHEMA_PATH|assigned-lib assigned-script catalogscan quoted-find"
  "repeated document queries|$SCHEMA_PATH skills/doc-readers/workflows/flow.md|assigned-dir assigned-lib assigned-script catalogscan quoted-find"
  "another tree before the document|hooks/README.md $SCHEMA_PATH|assigned-lib assigned-script beta.test.sh catalogscan quoted-find"
)
for row in "${READ_ROWS[@]}"; do
  IFS='|' read -r label paths want <<<"$row"
  map_row append "$paths" none
  [ "$RC" -eq 0 ] && [ "$(started)" = "$want" ] \
    && ok "checked read metadata selects readers for $label" \
    || bad "checked read metadata selects readers for $label" "$VERDICT out=$OUT"
done
touch "$SCAN_BIN/awk.fail"
map_row append "$SCHEMA_PATH" "$(note_for unreadable "$SCHEMA_PATH")"
[ "$VERDICT" = "rc=0 started=$DOC_CATALOG note=$(note_for unreadable "$SCHEMA_PATH")" ] \
  && [ "$(sed -n '$p' <<<"$OUT")" = 'validate: lanes=guard-scans selection=all' ] \
  && ok "a failed reader extraction runs the whole tree" \
  || bad "a failed reader extraction runs the whole tree" "$VERDICT out=$OUT"
rm -- "$SCAN_BIN/awk" "$SCAN_BIN/real-awk" "$SCAN_BIN/awk.fail"
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
