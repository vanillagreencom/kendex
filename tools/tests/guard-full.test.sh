#!/usr/bin/env bash
# tools/guard --full, the completion run: the working-tree bot-instructions
# check, the cross-target compile of core and the CLI, the suites of the trees
# the branch touched, and a test binary's death by a signal named apart from
# a failing test. Every compiler and toolchain call is a stub in fake-bin.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"

echo "=== bot instructions: full validation reads the worktree; the staged check is the chain's lane ==="
BOT="$REPO/.agents/skills/bot-instructions/scripts/bot-instructions"
printf '\n[bot-instructions.bots]\ncodex = true\ncopilot = true\n' >>"$R/kendex.toml"
printf '\n## Code Review Rules\n\nFixture rules.\n' >>"$R/AGENTS.md"
git -C "$R" add -A
"$BOT" adopt --repo "$R" >/dev/null
"$BOT" render --repo "$R" >/dev/null
git -C "$R" add -A
run_guard
[ "$RC" -eq 0 ] && ok "matching staged bot output passes" || bad "matching staged bot output passes" "$OUT"
printf '\nStale instructions.\n' >>"$R/.github/copilot-instructions.md"
run_guard
[ "$RC" -eq 0 ] && ok "commit checks ignore unstaged bot edits" || bad "commit checks ignore unstaged bot edits" "$OUT"
FULL_GUARD=1
run_guard
[ "$RC" -eq 1 ] && [[ "$OUT" == *"drift:"*".github/copilot-instructions.md"* ]] \
  && [[ "$OUT" == *"guard: bot instruction check failed"* ]] \
  && ok "full validation rejects stale worktree bot output" \
  || bad "full validation rejects stale worktree bot output" "rc=$RC out=$OUT"
FULL_GUARD=0
git -C "$R" add .github/copilot-instructions.md
"$BOT" render --repo "$R" >/dev/null
run_guard
# The commit-guards pre-commit chain runs `bot-instructions check --staged`
# as its own lane before this script; a second staged run here would judge
# the same index twice.
[ "$RC" -eq 0 ] && [[ "$OUT" != *"drift:"* ]] \
  && ok "commit checks leave the staged bot check to the chain's lane" \
  || bad "commit checks leave the staged bot check to the chain's lane" "rc=$RC out=$OUT"
git -C "$R" reset -q --hard HEAD
rm -rf -- "$R/.github"

FULL_GUARD=1
echo "=== full validation compiles every cross target ==="
mkdir -p "$R/fake-bin"
cat >"$R/fake-bin/rustup" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "target list --installed" ]
[ "${RUSTUP_LIST_RESULT:-0}" -eq 0 ]
# Space-separated in, one target per line out, the shape guard greps.
for t in ${RUSTUP_INSTALLED_TARGETS:-}; do printf '%s\n' "$t"; done
SH
cat >"$R/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CARGO_CALL_LOG"
for t in ${CROSS_CHECK_FAIL:-}; do
  if [ "$*" = "check -p kendex-core -p kendex-cli --all-targets --target $t" ]; then
    exit 1
  fi
done
SH
chmod +x "$R/fake-bin/rustup" "$R/fake-bin/cargo"
printf '[workspace]\n' >"$R/Cargo.toml"
git -C "$R" add Cargo.toml
CARGO_CALL_LOG="$TMP/cargo-calls"
# The platforms the release builds and this host does not run. Written out
# here on purpose: a list read back from guard would pass whatever guard
# named.
APPLE=aarch64-apple-darwin
WINDOWS=x86_64-pc-windows-msvc
BOTH="$APPLE $WINDOWS"
check_call() { # TARGET — the one cargo line guard is allowed to run for it
  printf 'check -p kendex-core -p kendex-cli --all-targets --target %s' "$1"
}
: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_LIST_RESULT=1
[ "$RC" -ne 0 ] && case "$OUT" in *"rustup could not list installed targets"*) true ;; *) false ;; esac \
  && ok "a failed installed-target lookup blocks guard" \
  || bad "a failed installed-target lookup blocks guard" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS=x86_64-unknown-linux-gnu
[ "$RC" -ne 0 ] &&
  case "$OUT" in *"Rust target $APPLE is not installed"*) true ;; *) false ;; esac &&
  case "$OUT" in *"Rust target $WINDOWS is not installed"*) true ;; *) false ;; esac \
  && ok "every missing target is refused with its own install command" \
  || bad "every missing target is refused with its own install command" "rc=$RC out=$OUT"
if grep -qE -- "--target ($APPLE|$WINDOWS)\$" "$CARGO_CALL_LOG"; then
  bad "a missing target is not handed to cargo" "$(cat "$CARGO_CALL_LOG")"
else
  ok "a missing target is not handed to cargo"
fi
: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$WINDOWS"
[ "$RC" -ne 0 ] && case "$OUT" in *"Rust target $APPLE is not installed"*) true ;; *) false ;; esac &&
  [ "$(grep -cFx "$(check_call "$WINDOWS")" "$CARGO_CALL_LOG")" -eq 1 ] \
  && ok "a missing target does not stop the targets after it" \
  || bad "a missing target does not stop the targets after it" "rc=$RC out=$OUT log=$(cat "$CARGO_CALL_LOG")"
for failing in "$APPLE" "$WINDOWS"; do
  : >"$CARGO_CALL_LOG"
  run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$BOTH" CROSS_CHECK_FAIL="$failing"
  [ "$RC" -ne 0 ] && case "$OUT" in *"$failing core and CLI test targets failed to compile"*) true ;; *) false ;; esac \
    && ok "a failing $failing compiler verdict blocks guard, naming it" \
    || bad "a failing $failing compiler verdict blocks guard, naming it" "rc=$RC out=$OUT"
done
: >"$CARGO_CALL_LOG"
run_guard PATH="$R/fake-bin:$PATH" CARGO_CALL_LOG="$CARGO_CALL_LOG" RUSTUP_INSTALLED_TARGETS="$BOTH"
[ "$RC" -eq 0 ] \
  && ok "installed targets that all compile reach the host suite" \
  || bad "installed targets that all compile reach the host suite" "rc=$RC out=$OUT"
[ "$(grep -cFx "$(check_call "$APPLE")" "$CARGO_CALL_LOG")" -eq 1 ] &&
  [ "$(grep -cFx "$(check_call "$WINDOWS")" "$CARGO_CALL_LOG")" -eq 1 ] \
  && ok "guard asks cargo once for every cross target's core and CLI tests" \
  || bad "guard asks cargo once for every cross target's core and CLI tests" "$(cat "$CARGO_CALL_LOG")"
FULL_GUARD=0
git -C "$R" reset -q HEAD -- Cargo.toml
rm -f "$R/Cargo.toml"

echo "=== full validation runs the suites of the trees the branch touched ==="
FULL_GUARD=1
# A second skill whose suite fails whenever it runs: the selection is proven
# by that suite staying silent until its tree is touched.
mkdir -p "$R/skills/quiet/tests"
printf '#!/usr/bin/env bash\nexit 1\n' >"$R/skills/quiet/tests/quiet.test.sh"
git -C "$R" add skills/quiet
git -C "$R" commit -q -m "chore: a skill whose suite fails"
printf 'echo more\n' >>"$R/skills/demo/scripts/demo.sh"
printf 'echo more\n' >>"$R/.agents/skills/demo/scripts/demo.sh"
run_guard
[ "$RC" -eq 0 ] && [[ "$OUT" == *"=== skills/demo/tests/demo.test.sh"* ]] && [[ "$OUT" != *"skills/quiet"* ]] \
  && ok "a touched skill's suite runs in full validation and an untouched skill's does not" \
  || bad "a touched skill's suite runs in full validation and an untouched skill's does not" "rc=$RC out=$OUT"
printf 'echo touched\n' >>"$R/skills/quiet/tests/quiet.test.sh"
run_guard
[ "$RC" != 0 ] && [[ "$OUT" == *"skills/quiet suite failed"* ]] \
  && ok "a touched skill's failing suite reds full validation, naming the skill" \
  || bad "a touched skill's failing suite reds full validation, naming the skill" "rc=$RC out=$OUT"
if mutant_guard '/suite failed (\$t)/d'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" --full 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] \
    && ok "control: with the suite lane deleted the failing suite passes" \
    || bad "control: with the suite lane deleted the failing suite passes" "rc=$RC out=$OUT"
else
  bad "control: the suite lane could not be deleted from a guard copy"
fi
FULL_GUARD=0
git -C "$R" checkout -q -- skills .agents

# The touched set is the branch diff against origin/main plus the working
# tree. A move out of one tree into another, committed past origin/main so the
# working tree is clean and the branch diff is the only read that sees it,
# names the tree it left: that tree's suite runs.
FULL_GUARD=1
suite_lane_head="$(git -C "$R" rev-parse HEAD)"
mkdir -p "$R/skills/quiet/scripts"
printf '#!/usr/bin/env bash\necho quiet\n' >"$R/skills/quiet/scripts/quiet.sh"
# A second script stays behind so the move leaves no empty roster directory.
printf '#!/usr/bin/env bash\necho stays\n' >"$R/skills/quiet/scripts/stays.sh"
git -C "$R" add skills/quiet
git -C "$R" commit -q -m "chore: a script in the quiet skill"
git -C "$R" update-ref refs/remotes/origin/main HEAD
git -C "$R" mv skills/quiet/scripts/quiet.sh hooks/quiet.sh
git -C "$R" commit -q -m "chore: move the quiet script into hooks"
run_guard
[ "$RC" != 0 ] && [[ "$OUT" == *"skills/quiet suite failed"* ]] \
  && ok "a committed move out of a skill runs the suite of the tree it left" \
  || bad "a committed move out of a skill runs the suite of the tree it left" "rc=$RC out=$OUT"
if mutant_guard 's/diff --no-renames --name-only "\$suites_base"/diff --name-only "$suites_base"/'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$MUTANT_TOOLS/guard" --full 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] \
    && ok "control: with rename detection back on the branch diff the source tree's suite stays silent" \
    || bad "control: with rename detection back on the branch diff the source tree's suite stays silent" "rc=$RC out=$OUT"
else
  bad "control: --no-renames could not be removed from the branch diff in a guard copy"
fi

# A branch diff that fails must red the lane by itself: the working-tree read
# beside it succeeds, so only the diff's own status can carry the failure.
git -C "$R" update-ref refs/remotes/origin/main HEAD
cat >"$R/fake-bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
is_suite_diff=0
last=""
for arg in "$@"; do last="$arg"; done
if [[ " $* " == *" diff "* && " $* " == *" --no-renames "* && "$last" == "--" ]]; then
  is_suite_diff=1
fi
[ "${FAIL_SUITE_DIFF:-0}" -eq 1 ] && [ "$is_suite_diff" -eq 1 ] && exit 2
exec "$REAL_GIT" "$@"
SH
chmod +x "$R/fake-bin/git"
run_guard PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" FAIL_SUITE_DIFF=1
[ "$RC" != 0 ] && [[ "$OUT" == *"the touched-file set for the suite lane could not be read"* ]] \
  && ok "a failed branch diff reds the suite lane beside a good working-tree read" \
  || bad "a failed branch diff reds the suite lane beside a good working-tree read" "rc=$RC out=$OUT"
if mutant_guard 's/{ branch_touched=""; say "the touched-file set for the suite lane could not be read (branch diff)"; }/branch_touched=""/'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" FAIL_SUITE_DIFF=1 "$MUTANT_TOOLS/guard" --full 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] \
    && ok "control: with the diff's status unchecked the failed diff passes" \
    || bad "control: with the diff's status unchecked the failed diff passes" "rc=$RC out=$OUT"
else
  bad "control: the branch diff's status check could not be removed from a guard copy"
fi
rm -f "$R/fake-bin/git"
git -C "$R" reset -q --hard "$suite_lane_head"
git -C "$R" update-ref -d refs/remotes/origin/main
FULL_GUARD=0

echo "=== a test binary's death by a signal is named apart from a failing test ==="
FULL_GUARD=1
# A workspace for the test run; the rustup stub above answers the cross-target
# lookup with both targets installed.
printf '[workspace]\n' >"$R/Cargo.toml"
cat >"$R/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "test --workspace --quiet" ] || exit 0
printf '%s\n' "$CARGO_TEST_STDERR" >&2
exit 101
SH
chmod +x "$R/fake-bin/cargo"
# cargo's own report of a runner whose executable died, as it prints it.
DEATH="$(printf '%s\n' \
  'error: test failed, to rerun pass `-p kendex-core --test review_fixes`' \
  '' \
  'Caused by:' \
  '  process didn'"'"'t exit successfully: `target/debug/deps/review_fixes-ff58 --quiet` (signal: 11, SIGSEGV: invalid memory reference)')"
ASSERTION="$(printf '%s\n' \
  'test a_case ... FAILED' \
  'error: test failed, to rerun pass `-p kendex-core --test review_fixes`')"
# The same death line for a compiler cargo launched, under cargo's compile
# failure rather than its test failure.
COMPILER_DEATH="$(printf '%s\n' \
  'error: could not compile `kendex-core` (lib test)' \
  '' \
  'Caused by:' \
  '  process didn'"'"'t exit successfully: `rustc --crate-name kendex_core ...` (signal: 9, SIGKILL: kill)')"
run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$DEATH"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: a test binary died by a signal"*"review_fixes-ff58"*"SIGSEGV"* ]] \
  && [[ "$OUT" != *"guard: tests failed"* ]] \
  && ok "a runner killed by a signal is reported as the artifact's death, not a failing test" \
  || bad "a runner killed by a signal is reported as the artifact's death, not a failing test" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$ASSERTION"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: tests failed"* ]] && [[ "$OUT" != *"died by a signal"* ]] \
  && ok "a failing assertion still reads as tests failed" \
  || bad "a failing assertion still reads as tests failed" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$COMPILER_DEATH"
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: tests failed"* ]] && [[ "$OUT" != *"died by a signal"* ]] \
  && ok "a compiler killed by a signal is not named as a test binary's death" \
  || bad "a compiler killed by a signal is not named as a test binary's death" "rc=$RC out=$OUT"
if mutant_guard 's/if \[ -n "\$death" \]; then/if false; then/'; then
  OUT=""
  RC=0
  OUT="$(cd "$R" && PATH="$R/fake-bin:$PATH" RUSTUP_INSTALLED_TARGETS="$BOTH" CARGO_TEST_STDERR="$DEATH" "$MUTANT_TOOLS/guard" --full 2>&1)" || RC=$?
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: tests failed"* ]] && [[ "$OUT" != *"died by a signal"* ]] \
    && ok "control: with the death check removed the same death reads as tests failed" \
    || bad "control: with the death check removed the same death reads as tests failed" "rc=$RC out=$OUT"
else
  bad "control: the death check could not be removed from a guard copy"
fi
rm -f "$R/Cargo.toml"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
