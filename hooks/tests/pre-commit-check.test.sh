#!/usr/bin/env bash
# Tests for the pre-commit-check hook's contract: word-order detection of a
# git commit with no shell parsing; deference to the repository's own armed
# git pre-commit hook (never a second validation); `kendex guard run
# pre-commit` as the fallback gate where nothing is armed; fail-closed when
# neither an armed hook nor the kendex binary exists. Shell forms the old
# parser refused — `$(…)`, backticks, `cd "$dir"`, unexpanded variables —
# must pass through without a refusal of their own.
#
# `kendex` is stubbed with a PATH shim that records invocations, so the
# suite needs no built binary and never runs a real guard chain.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$TEST_DIR/.." && pwd)/pre-commit-check.sh"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

KENDEX_LOG="$TMP_ROOT/kendex.log"
ERR_FILE="$TMP_ROOT/stderr"

# --- kendex PATH shim --------------------------------------------------------
BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/kendex" <<'EOF'
#!/usr/bin/env bash
echo "kendex $*" >>"$KENDEX_LOG"
if [ "${KENDEX_EXIT:-0}" != "0" ]; then
  echo "=== rust-clippy"
  echo "rust-clippy FAIL: cargo clippy --manifest-path fixture/Cargo.toml"
  echo "pre-commit: 1 violation(s) — commit blocked; see the failures above"
fi
exit "${KENDEX_EXIT:-0}"
EOF
chmod +x "$BIN_DIR/kendex"

# A PATH holding the tools the hook needs and nothing named kendex, for the
# fail-closed case. The shim dir is deliberately absent.
NO_KENDEX_BIN="$TMP_ROOT/no-kendex-bin"
mkdir -p "$NO_KENDEX_BIN"
for tool in git grep tr head bash cat; do
  ln -s "$(command -v "$tool")" "$NO_KENDEX_BIN/$tool"
done

# Run the hook from inside a directory with a raw JSON payload on stdin.
# Extra env assignments come as VAR=value args. Captures stderr in $err and
# the exit code in $rc; truncates the shim log before each run.
run_hook() {
  local dir="$1" payload="$2"
  shift 2
  : >"$KENDEX_LOG"
  set +e
  (cd "$dir" && env PATH="$BIN_DIR:$PATH" KENDEX_LOG="$KENDEX_LOG" "$@" \
    bash "$HOOK" <<<"$payload") >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
  log="$(cat "$KENDEX_LOG" 2>/dev/null || true)"
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

# --- Fixtures ----------------------------------------------------------------
UNARMED="$TMP_ROOT/unarmed"
mkdir -p "$UNARMED"
git -C "$UNARMED" init -q

ARMED="$TMP_ROOT/armed"
mkdir -p "$ARMED"
git -C "$ARMED" init -q
printf '#!/bin/sh\nexit 0\n' >"$ARMED/.git/hooks/pre-commit"
chmod +x "$ARMED/.git/hooks/pre-commit"

ARMED_BY_PATH="$TMP_ROOT/armed-by-path"
mkdir -p "$ARMED_BY_PATH" "$TMP_ROOT/custom-hooks"
git -C "$ARMED_BY_PATH" init -q
printf '#!/bin/sh\nexit 0\n' >"$TMP_ROOT/custom-hooks/pre-commit"
chmod +x "$TMP_ROOT/custom-hooks/pre-commit"
git -C "$ARMED_BY_PATH" config core.hooksPath "$TMP_ROOT/custom-hooks"

NOT_A_REPO="$TMP_ROOT/plain"
mkdir -p "$NOT_A_REPO"

echo "detection"

run_hook "$UNARMED" "$(payload 'ls -la')"
assert_eq "$rc" "0" "a non-commit command is left alone"
assert_not_contains "$log" "kendex" "no guard run for a non-commit command"

run_hook "$UNARMED" '{"note":"about to commit with git"}'
assert_eq "$rc" "0" "a payload with no command field is left alone"

run_hook "$UNARMED" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_eq "$rc" "2" "a plain git commit reaches the fallback gate"
assert_contains "$log" "kendex guard run pre-commit" "the fallback is the guard chain"

run_hook "$UNARMED" "$(payload 'git -C /somewhere/else commit -m test')" KENDEX_EXIT=1
assert_eq "$rc" "2" "git and commit separated by options are still a commit"

echo
echo "deference to an armed git hook"

run_hook "$ARMED" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_eq "$rc" "0" "an armed .git/hooks/pre-commit gates the commit itself"
assert_not_contains "$log" "kendex" "no second validation beside an armed hook"

run_hook "$ARMED_BY_PATH" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_eq "$rc" "0" "a core.hooksPath hook counts as armed"
assert_not_contains "$log" "kendex" "no second validation beside a hooksPath hook"

echo
echo "fallback verdicts"

run_hook "$UNARMED" "$(payload 'git commit -m test')" KENDEX_EXIT=0
assert_eq "$rc" "0" "a clean chain lets the commit proceed"

run_hook "$UNARMED" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_contains "$err" "rust-clippy FAIL" "the chain's own output reaches stderr"
assert_contains "$err" "kendex guard install" "the block names the durable fix"

run_hook "$NOT_A_REPO" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_eq "$rc" "0" "outside a repository there is nothing to gate here"

echo
echo "shell forms the old parser refused"

# The single quotes are the point: these payloads carry unexpanded shell.
# shellcheck disable=SC2016
for form in \
  'git -C "$repo" commit -m x' \
  'repo=$(git rev-parse --show-toplevel) && git -C "$repo" commit -m x' \
  'cd "$dir" && git commit -m x' \
  'git -C `pwd` commit -m x' \
  '(cd /target && git commit -m x)' \
  'git --git-dir=/t/.git --work-tree=/t commit -m x'; do
  run_hook "$ARMED" "$(payload "$form")" KENDEX_EXIT=1
  assert_eq "$rc" "0" "no refusal for: $form"
  assert_not_contains "$err" "cannot enter" "no cannot-enter refusal for: $form"
done

# The JSON-escaped quoted-path form: quotes arrive as \" in the payload.
run_hook "$ARMED" '{"tool_input":{"command":"git -C \"/tmp/my repo\" commit -m x"}}' KENDEX_EXIT=1
assert_eq "$rc" "0" "a quoted path with a space is not a refusal"

run_hook "$UNARMED" '{"tool_input":{"command":"git -C \"/tmp/my repo\" commit -m x"}}' KENDEX_EXIT=1
assert_eq "$rc" "2" "the quoted-path commit still reaches the fallback gate"

echo
echo "fail closed without kendex"

: >"$KENDEX_LOG"
set +e
(cd "$UNARMED" && env PATH="$NO_KENDEX_BIN" KENDEX_LOG="$KENDEX_LOG" \
  bash "$HOOK" <<<"$(payload 'git commit -m test')") >/dev/null 2>"$ERR_FILE"
rc=$?
set -e
err="$(cat "$ERR_FILE")"
assert_eq "$rc" "2" "no armed hook and no kendex binary refuses the commit"
assert_contains "$err" "kendex binary is not on PATH" "the refusal names the missing binary"

set +e
(cd "$ARMED" && env PATH="$NO_KENDEX_BIN" KENDEX_LOG="$KENDEX_LOG" \
  bash "$HOOK" <<<"$(payload 'git commit -m test')") >/dev/null 2>"$ERR_FILE"
rc=$?
set -e
assert_eq "$rc" "0" "an armed hook needs no kendex binary"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
