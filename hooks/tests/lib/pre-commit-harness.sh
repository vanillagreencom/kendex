# Shared fixtures and assertions for the pre-commit-check suites. Sourced, never
# run: hooks/tests/pre-commit-check.test.sh judges the contract, and
# hooks/tests/pre-commit-constructs.test.sh judges the constructs.
#
# The package script is stubbed inside each fixture repository, where the hook
# looks for it, so the suites need no built binary, run no real chain, and never
# put `kendex` on PATH at all.
#
# HOOK_UNDER_TEST runs these assertions against a must-fail mutant of the hook.
# Set here as well as in each suite: this file's own body relies on it, and a
# suite that forgot it must not get fixtures built without it.
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS_DIR/pre-commit-check.sh}"

# The bypass flag, assembled because this repository's own hook refuses a
# command that spells it out.
NV="--no-""verify"

# The marker the growth-guards installer ends its delegating line with, and
# the only thing that makes a hook file ours as far as this lane is
# concerned. Assembled so this file is not itself mistaken for a shim.
GG_MARK="# kendex-""guards-hook"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ERR_FILE="$TMP_ROOT/stderr"
# Anything a fixture's own script writes when something runs it. Nothing
# should ever run one: this hook defers or refuses, and never stands in.
RAN_LOG="$TMP_ROOT/ran.log"

# A PATH holding the tools the hook needs and nothing named kendex. Every
# run uses it: no lane of this hook may depend on the binary any more.
NO_KENDEX_BIN="$TMP_ROOT/no-kendex-bin"
mkdir -p "$NO_KENDEX_BIN"
for tool in git grep awk tr sed head bash cat env printf; do
  target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$NO_KENDEX_BIN/$tool"
done

# Run the hook from inside a directory with a raw JSON payload on stdin.
# Extra env assignments come as VAR=value args. Captures stderr in $err and
# the exit code in $rc; truncates the shim log before each run.
run_hook() {
  local dir="$1" payload="$2"
  shift 2
  set +e
  (cd "$dir" && env PATH="$NO_KENDEX_BIN" "$@" \
    bash "$HOOK" <<<"$payload") >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
  log="$(cat "$RAN_LOG" 2>/dev/null || true)"
}

payload() {
  printf '{"tool_input":{"command":"%s"}}' "$1"
}

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

assert_not_contains() {
  local got="$1" needle="$2" name="$3"
  if [[ "$got" != *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected NOT to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

# Judge one form in both fixtures at once. The ARMED expectation says whether
# the words carry a bypass; the UNARMED one is the control proving the
# commit was found at all, since a form the hook never sees passes there too.
both() {
  local form="$1" want_armed="$2" want_unarmed="$3" name="$4"
  run_hook "$ARMED" "$(payload "$form")" CHAIN_EXIT=1
  assert_eq "$rc" "$want_armed" "armed: $name"
  if [[ "$want_armed" == 2 ]]; then
    assert_contains "$err" "bypasses this repository's armed git hooks" "armed refusal names a bypass: $name"
  else
    assert_not_contains "$err" "bypasses" "armed: nothing read as a bypass: $name"
  fi
  assert_eq "$log" "" "armed: nothing of the repository's ran: $name"
  run_hook "$UNARMED" "$(payload "$form")" CHAIN_EXIT=1
  assert_eq "$rc" "$want_unarmed" "unarmed: $name"
  if [[ "$want_unarmed" == 2 ]]; then
    assert_contains "$err" "not armed by kendex" "unarmed refusal names the arming: $name"
  fi
  assert_eq "$log" "" "unarmed: nothing of the repository's ran: $name"
}

# --- Fixtures ----------------------------------------------------------------
UNARMED="$TMP_ROOT/unarmed"
mkdir -p "$UNARMED"
git -C "$UNARMED" init -q

ARMED="$TMP_ROOT/armed"
mkdir -p "$ARMED"
git -C "$ARMED" init -q
for lane in pre-commit commit-msg; do
  printf '#!/bin/sh\nexit 0 %s\n' "$GG_MARK" >"$ARMED/.git/hooks/$lane"
  chmod +x "$ARMED/.git/hooks/$lane"
done

ARMED_BY_PATH="$TMP_ROOT/armed-by-path"
mkdir -p "$ARMED_BY_PATH" "$TMP_ROOT/custom-hooks"
git -C "$ARMED_BY_PATH" init -q
for lane in pre-commit commit-msg; do
  printf '#!/bin/sh\nexit 0 %s\n' "$GG_MARK" >"$TMP_ROOT/custom-hooks/$lane"
  chmod +x "$TMP_ROOT/custom-hooks/$lane"
done
git -C "$ARMED_BY_PATH" config core.hooksPath "$TMP_ROOT/custom-hooks"

# A hook file git will not run: present, execute bit off. Git skips it
# silently, so it must not count as armed.
DISARMED="$TMP_ROOT/disarmed"
mkdir -p "$DISARMED"
git -C "$DISARMED" init -q
printf '#!/bin/sh\nexit 0 %s\n' "$GG_MARK" >"$DISARMED/.git/hooks/pre-commit"
chmod -x "$DISARMED/.git/hooks/pre-commit"

DISARMED_BY_PATH="$TMP_ROOT/disarmed-by-path"
mkdir -p "$DISARMED_BY_PATH" "$TMP_ROOT/disarmed-hooks"
git -C "$DISARMED_BY_PATH" init -q
printf '#!/bin/sh\nexit 0 %s\n' "$GG_MARK" >"$TMP_ROOT/disarmed-hooks/pre-commit"
chmod -x "$TMP_ROOT/disarmed-hooks/pre-commit"
git -C "$DISARMED_BY_PATH" config core.hooksPath "$TMP_ROOT/disarmed-hooks"

# core.hooksPath set and EMPTY switches hooks off, and git's answer about it
# misleads: `rev-parse --git-path hooks` reports `./`, so the directory
# resolves to the repository root. This fixture puts an executable
# `pre-commit` exactly there — the trap — while git runs nothing at all.
HOOKS_OFF="$TMP_ROOT/hooks-off"
mkdir -p "$HOOKS_OFF"
git -C "$HOOKS_OFF" init -q
git -C "$HOOKS_OFF" config core.hooksPath ""
printf '#!/bin/sh\nexit 0\n' >"$HOOKS_OFF/pre-commit"
chmod +x "$HOOKS_OFF/pre-commit"

# One lane armed and not the other. Deferring here would hand the commit to
# a gate that checks content and accepts any message, and would waive the one
# thing this hook can still do about it.
HALF_ARMED="$TMP_ROOT/half-armed"
mkdir -p "$HALF_ARMED"
git -C "$HALF_ARMED" init -q
printf '#!/bin/sh\nexit 0 %s\n' "$GG_MARK" >"$HALF_ARMED/.git/hooks/pre-commit"
chmod +x "$HALF_ARMED/.git/hooks/pre-commit"

# Marked on both lanes, and one of them is a file git will not execute.
MARKED_NOT_EXEC="$TMP_ROOT/marked-not-exec"
mkdir -p "$MARKED_NOT_EXEC"
git -C "$MARKED_NOT_EXEC" init -q
for lane in pre-commit commit-msg; do
  printf '#!/bin/sh\nexit 0 %s\n' "$GG_MARK" >"$MARKED_NOT_EXEC/.git/hooks/$lane"
  chmod +x "$MARKED_NOT_EXEC/.git/hooks/$lane"
done
chmod -x "$MARKED_NOT_EXEC/.git/hooks/pre-commit"

NOT_A_REPO="$TMP_ROOT/plain"
mkdir -p "$NOT_A_REPO"

# Every fixture carries a package whose script would announce itself if
# anything ran it. Nothing may: this hook defers to an armed hook or
# refuses, and never runs a repository's own scripts on its behalf.
for fixture in "$UNARMED" "$ARMED" "$ARMED_BY_PATH" "$DISARMED" "$DISARMED_BY_PATH" "$HOOKS_OFF" "$HALF_ARMED" "$MARKED_NOT_EXEC"; do
  scripts="$fixture/.agents/skills/growth-guards/scripts"
  mkdir -p "$scripts"
  {
    echo "#!/usr/bin/env bash"
    echo "echo 'the repository script ran' >>\"$RAN_LOG\""
    echo "exit \${CHAIN_EXIT:-0}"
  } >"$scripts/pre-commit"
  chmod +x "$scripts/pre-commit"
done
# Refused on sight in either fixture, naming the construct and no bypass:
# nothing was parsed to find one.
unmodelled() {
  local form="$1" name="$2"
  for fixture in "$ARMED" "$UNARMED"; do
    run_hook "$fixture" "$(payload "$form")" CHAIN_EXIT=0
    assert_eq "$rc" "2" "refused on sight: $name"
    assert_contains "$err" "does not model" "the refusal names the construct: $name"
    assert_eq "$log" "" "nothing of the repository's ran: $name"
  done
}

# The tally every suite ends with.
finish() {
  echo
  printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
  [[ "$FAIL" -eq 0 ]]
}
