#!/usr/bin/env bash
# tools/guard --range BASE, a fix round's validation: the default rules read
# over the changes since BASE, cargo check and clippy for the crates those
# changes touch, the UI checks and suite for a UI change, and the suites of
# the trees they touch, with no workspace test run, cross-target check or
# documentation build. Every compiler and toolchain call is a stub in
# fake-bin that logs what it was asked.
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
printf 'pub fn core() {}\n' >"$R/crates/core/src/lib.rs"
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
OUT="$(cd "$R" && env PATH="$R/fake-bin:$PATH" CALL_LOG="$CALLS" "$GUARD" --full 2>&1 </dev/null)" || RC=$?
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
  "a UI file runs the UI checks and the UI suite|worktree|ui/src/main.ts|$UI_CALLS"
  "a markdown file inside a crate compiles nothing|worktree|crates/core/README.md|"
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
