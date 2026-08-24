#!/usr/bin/env bash
# Tests for the pre-commit-check hook's contract: word-order detection of a
# git commit with no shell parsing; deference to the repository's own armed
# git pre-commit hook (never a second validation) unless the command
# sidesteps it; `kendex guard run pre-commit` as the fallback gate where
# nothing will run; fail-closed when neither an armed hook nor the kendex
# binary exists, and when the payload names a command the hook cannot read.
# Shell forms the old parser refused — `$(…)`, backticks, `cd "$dir"`,
# unexpanded variables — must pass through without a refusal of their own.
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
# KENDEX_EXIT=1 plays a lane violation, KENDEX_EXIT=2 the chain's own
# refusal (a policy it cannot load), in the chain's real wording.
BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
cat >"$BIN_DIR/kendex" <<'EOF'
#!/usr/bin/env bash
echo "kendex $*" >>"$KENDEX_LOG"
case "${KENDEX_EXIT:-0}" in
  1)
    echo "=== rust-clippy"
    echo "rust-clippy FAIL: cargo clippy --manifest-path fixture/Cargo.toml"
    echo "pre-commit: 1 violation(s) — commit blocked; see the failures above"
    ;;
  2)
    echo "pre-commit: pre-commit: legacy v1 guard settings found in kendex.settings.toml with no [guards] tables — convert them once with the guard import-v1 command"
    echo "pre-commit: a guard could not complete — commit blocked; fix the errors above"
    ;;
esac
exit "${KENDEX_EXIT:-0}"
EOF
chmod +x "$BIN_DIR/kendex"

# A PATH holding the tools the hook needs and nothing named kendex, for the
# fail-closed case. The shim dir is deliberately absent.
NO_KENDEX_BIN="$TMP_ROOT/no-kendex-bin"
mkdir -p "$NO_KENDEX_BIN"
for tool in git grep tr sed head bash cat; do
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

# A hook file git will not run: present, execute bit off. Git skips it
# silently, so it must not count as armed.
DISARMED="$TMP_ROOT/disarmed"
mkdir -p "$DISARMED"
git -C "$DISARMED" init -q
printf '#!/bin/sh\nexit 0\n' >"$DISARMED/.git/hooks/pre-commit"
chmod -x "$DISARMED/.git/hooks/pre-commit"

DISARMED_BY_PATH="$TMP_ROOT/disarmed-by-path"
mkdir -p "$DISARMED_BY_PATH" "$TMP_ROOT/disarmed-hooks"
git -C "$DISARMED_BY_PATH" init -q
printf '#!/bin/sh\nexit 0\n' >"$TMP_ROOT/disarmed-hooks/pre-commit"
chmod -x "$TMP_ROOT/disarmed-hooks/pre-commit"
git -C "$DISARMED_BY_PATH" config core.hooksPath "$TMP_ROOT/disarmed-hooks"

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
echo "JSON whitespace escapes separate words"

# Single quotes on purpose: the payload carries the two characters \n, as
# JSON encodes a newline in a multi-line command.
for form in \
  'cargo fmt\ngit commit -m x' \
  'cd sub\tgit commit -m x' \
  'cargo fmt\r\ngit commit -m x'; do
  run_hook "$UNARMED" "$(payload "$form")" KENDEX_EXIT=1
  assert_eq "$rc" "2" "the commit after an escape reaches the fallback gate: $form"
  assert_contains "$log" "kendex guard run pre-commit" "the chain ran for: $form"
done

echo
echo "unreadable payload"

run_hook "$UNARMED" '{"tool_input":{"command":123}}' KENDEX_EXIT=1
assert_eq "$rc" "2" "a command key whose value cannot be read is refused"
assert_contains "$err" "could not read the command" "the refusal names the unreadable payload"
assert_not_contains "$log" "kendex" "no guard run on a payload the hook could not read"

run_hook "$UNARMED" $'{"tool_input":{"command":\n"git commit -m x"}}' KENDEX_EXIT=1
assert_eq "$rc" "2" "a key and value on separate lines still reach the fallback gate"
assert_contains "$log" "kendex guard run pre-commit" "the chain ran for the split-line payload"

echo
echo "deference to an armed git hook"

run_hook "$ARMED" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_eq "$rc" "0" "an armed .git/hooks/pre-commit gates the commit itself"
assert_not_contains "$log" "kendex" "no second validation beside an armed hook"

run_hook "$ARMED_BY_PATH" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_eq "$rc" "0" "a core.hooksPath hook counts as armed"
assert_not_contains "$log" "kendex" "no second validation beside a hooksPath hook"

run_hook "$ARMED" "$(payload 'git commit -am test')" KENDEX_EXIT=1
assert_eq "$rc" "0" "a short-flag cluster without n still defers"

echo
echo "a hook file git will not run is not armed"

run_hook "$DISARMED" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_eq "$rc" "2" "a pre-commit without the execute bit falls back to the chain"
assert_contains "$log" "kendex guard run pre-commit" "the chain ran beside the non-executable hook"

run_hook "$DISARMED_BY_PATH" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_eq "$rc" "2" "a non-executable core.hooksPath pre-commit falls back to the chain"
assert_contains "$log" "kendex guard run pre-commit" "the chain ran beside the non-executable hooksPath hook"

echo
echo "bypassing the armed hook is not a deferral"

for form in \
  'git commit --no-verify -m x' \
  'git commit --no-verif -m x' \
  'git commit -n -m x' \
  'git commit -anm x' \
  'git -c core.hooksPath=/dev/null commit -m x'; do
  run_hook "$ARMED" "$(payload "$form")" KENDEX_EXIT=1
  assert_eq "$rc" "2" "not waved through: $form"
  assert_contains "$log" "kendex guard run pre-commit" "the chain gates: $form"
done

run_hook "$ARMED_BY_PATH" "$(payload 'git commit --no-verify -m x')" KENDEX_EXIT=1
assert_eq "$rc" "2" "--no-verify beside a hooksPath hook is not waved through either"

echo
echo "fallback verdicts"

run_hook "$UNARMED" "$(payload 'git commit -m test')" KENDEX_EXIT=0
assert_eq "$rc" "0" "a clean chain lets the commit proceed"

run_hook "$UNARMED" "$(payload 'git commit -m test')" KENDEX_EXIT=1
assert_contains "$err" "rust-clippy FAIL" "the chain's own output reaches stderr"
assert_contains "$err" "kendex guard install" "the block names the durable fix"

run_hook "$UNARMED" "$(payload 'git commit -m test')" KENDEX_EXIT=2
assert_eq "$rc" "2" "a chain that could not load its policy blocks"
assert_contains "$err" "import-v1" "the block names the policy remedy"

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

set +e
(cd "$ARMED" && env PATH="$NO_KENDEX_BIN" KENDEX_LOG="$KENDEX_LOG" \
  bash "$HOOK" <<<"$(payload 'git commit --no-verify -m test')") >/dev/null 2>"$ERR_FILE"
rc=$?
set -e
assert_eq "$rc" "2" "bypassing the armed hook with no kendex binary is refused"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
