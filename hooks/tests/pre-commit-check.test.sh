#!/usr/bin/env bash
# Tests for the pre-commit-check hook's contract: word-order detection of a
# git commit with no shell parsing; deference to the repository's own armed
# git pre-commit hook (never a second validation) unless the command
# sidesteps it; the growth-guards package's own pre-commit script as the
# refusal where nothing is armed; fail-closed when neither an armed
# hook nor that package exists, and when the payload names a command the
# hook cannot read. Shell forms the old parser refused — `$(…)`, backticks,
# `cd "$dir"`, unexpanded variables — must pass through without a refusal of
# their own.
#
# The package script is stubbed inside each fixture repository, where the
# hook looks for it, so the suite needs no built binary, runs no real chain,
# and — the property the delegation exists for — never puts a `kendex` on
# PATH at all.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$TEST_DIR/.." && pwd)/pre-commit-check.sh"

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
for tool in git grep tr sed head bash cat env printf; do
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

NOT_A_REPO="$TMP_ROOT/plain"
mkdir -p "$NOT_A_REPO"

# Every fixture carries a package whose script would announce itself if
# anything ran it. Nothing may: this hook defers to an armed hook or
# refuses, and never runs a repository's own scripts on its behalf.
for fixture in "$UNARMED" "$ARMED" "$ARMED_BY_PATH" "$DISARMED" "$DISARMED_BY_PATH" "$HOOKS_OFF" "$HALF_ARMED"; do
  scripts="$fixture/.agents/skills/growth-guards/scripts"
  mkdir -p "$scripts"
  {
    echo "#!/usr/bin/env bash"
    echo "echo 'the repository script ran' >>\"$RAN_LOG\""
    echo "exit \${CHAIN_EXIT:-0}"
  } >"$scripts/pre-commit"
  chmod +x "$scripts/pre-commit"
done

echo "detection"

run_hook "$UNARMED" "$(payload 'ls -la')"
assert_eq "$rc" "0" "a non-commit command is left alone"
assert_eq "$log" "" "no guard run for a non-commit command"

run_hook "$UNARMED" '{"note":"about to commit with git"}'
assert_eq "$rc" "0" "a payload with no command field is left alone"

run_hook "$UNARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a plain git commit in an unarmed repo is refused"
assert_eq "$log" "" "nothing in the repository was run"

run_hook "$UNARMED" "$(payload 'git -C /somewhere/else commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "git and commit separated by options are still a commit"

echo
echo "JSON whitespace escapes separate words"

# Single quotes on purpose: the payload carries the two characters \n, as
# JSON encodes a newline in a multi-line command.
for form in \
  'cargo fmt\ngit commit -m x' \
  'cd sub\tgit commit -m x' \
  'cargo fmt\r\ngit commit -m x'; do
  run_hook "$UNARMED" "$(payload "$form")" CHAIN_EXIT=1
  assert_eq "$rc" "2" "the commit after an escape is still refused: $form"
  assert_eq "$log" "" "nothing was run for: $form"
done

echo
echo "unreadable payload"

run_hook "$UNARMED" '{"tool_input":{"command":123}}' CHAIN_EXIT=1
assert_eq "$rc" "2" "a command key whose value cannot be read is refused"
assert_contains "$err" "could not read the command" "the refusal names the unreadable payload"
assert_eq "$log" "" "no guard run on a payload the hook could not read"

run_hook "$UNARMED" $'{"tool_input":{"command":\n"git commit -m x"}}' CHAIN_EXIT=1
assert_eq "$rc" "2" "a key and value on separate lines are still refused"
assert_eq "$log" "" "nothing was run for the split-line payload"

echo
echo "deference to an armed git hook"

run_hook "$ARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "0" "an armed .git/hooks/pre-commit gates the commit itself"
assert_eq "$log" "" "no second validation beside an armed hook"

run_hook "$ARMED_BY_PATH" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a core.hooksPath hook is not armed by this lane"
assert_eq "$log" "" "no second validation beside a hooksPath hook"

run_hook "$ARMED" "$(payload 'git commit -am test')" CHAIN_EXIT=1
assert_eq "$rc" "0" "a short-flag cluster without n still defers"

echo
echo "a hook file git will not run is not armed"

run_hook "$DISARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a pre-commit without the execute bit falls back to the chain"
assert_eq "$log" "" "nothing was run beside the non-executable hook"

run_hook "$DISARMED_BY_PATH" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a non-executable core.hooksPath pre-commit falls back to the chain"
assert_eq "$log" "" "nothing was run beside the non-executable hooksPath hook"

echo
echo "bypassing the armed hook is refused, not half-checked"

# Nothing can stand in for git's hooks here: the same flag
# skips commit-msg, whose gate this hook cannot judge at PreToolUse time.
for form in \
  'git commit --no-verify -m x' \
  'git commit --no-verif -m x' \
  'git commit -n -m x' \
  'git commit -anm x' \
  'git -c core.hooksPath=/dev/null commit -m x' \
  'git -c core.hookspath=/dev/null commit -m x' \
  'git -c include.path=/tmp/alt.config commit -m x' \
  'git --config-env=core.hooksPath=HP commit -m x' \
  'GIT_CONFIG_KEY_0=Core.HooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x' \
  'GIT_CONFIG_COUNT=1 git commit -m x' \
  'git config --local core.hooksPath /dev/null && git commit -m x' \
  'git config --local --type path --includes --show-scope core.hooksPath /dev/null && git commit -m x'; do
  run_hook "$ARMED" "$(payload "$form")" CHAIN_EXIT=0
  assert_eq "$rc" "2" "refused: $form"
  assert_eq "$log" "" "nothing stands in for the bypassed hooks: $form"
  assert_contains "$err" "bypasses this repository's armed git hooks" "the refusal names the bypass: $form"
done

run_hook "$ARMED" "$(payload 'git commit --no-verify -m x')" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the refusal names the flag it saw"

run_hook "$ARMED_BY_PATH" "$(payload 'git commit --no-verify -m x')" CHAIN_EXIT=0
assert_eq "$rc" "2" "--no-verify beside a hooksPath hook is refused too"
assert_eq "$log" "" "and runs no chain there either"

echo
echo "the hook gates its working directory only"

# The contract as built: git answers the which-repository question only
# where the target has an armed hook; this hook never follows -C, cd,
# --git-dir or --work-tree. From an armed directory it defers whatever
# the target; from an unarmed one it judges itself and says so.
run_hook "$ARMED" "$(payload "git -C $UNARMED commit -m x")" CHAIN_EXIT=1
assert_eq "$rc" "0" "an armed cwd defers even when the commit is aimed at an unarmed repository"
assert_eq "$log" "" "the unarmed target gets no chain from here — its own hook is its gate"

run_hook "$UNARMED" "$(payload "git -C $ARMED commit -m x")" CHAIN_EXIT=1
assert_eq "$rc" "2" "an unarmed cwd runs the chain for itself whatever the target"
assert_eq "$log" "" "nothing was run in the unarmed cwd"
assert_contains "$err" "judged $UNARMED only" "the notice names the directory that was judged"

# The quotes arrive JSON-escaped, as the harness sends them.
# shellcheck disable=SC2016
run_hook "$UNARMED" '{"tool_input":{"command":"cd \"$dir\" && git commit -m x"}}' CHAIN_EXIT=0
assert_contains "$err" "moves repositories" "a leading cd is a repository-moving word"

run_hook "$UNARMED" "$(payload 'git commit -m x')" CHAIN_EXIT=0
assert_not_contains "$err" "moves repositories" "no notice for a commit in place"

run_hook "$NOT_A_REPO" "$(payload "git -C $UNARMED commit -m x")" CHAIN_EXIT=1
assert_eq "$rc" "0" "a non-repository cwd gates nothing"
assert_contains "$err" "moves repositories" "and says the target is elsewhere"

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
  run_hook "$ARMED" "$(payload "$form")" CHAIN_EXIT=1
  assert_eq "$rc" "0" "no refusal for: $form"
  assert_not_contains "$err" "cannot enter" "no cannot-enter refusal for: $form"
done

# The JSON-escaped quoted-path form: quotes arrive as \" in the payload.
run_hook "$ARMED" '{"tool_input":{"command":"git -C \"/tmp/my repo\" commit -m x"}}' CHAIN_EXIT=1
assert_eq "$rc" "0" "a quoted path with a space is not a refusal"

run_hook "$UNARMED" '{"tool_input":{"command":"git -C \"/tmp/my repo\" commit -m x"}}' CHAIN_EXIT=1
assert_eq "$rc" "2" "the quoted-path commit is still refused"

echo
echo "an unarmed repository is refused, never stood in for"

# Arming is the local act that says a person wants this repository's
# committed scripts run on their commits, and git clones no hooks — so a
# fresh checkout has no execution behind it and this hook adds none. The
# fixtures all carry a script that would announce itself if anything ran it.
run_hook "$UNARMED" "$(payload 'git commit -m test')"
assert_eq "$rc" "2" "an unarmed repository refuses the commit"
assert_contains "$err" "not armed by kendex" "the refusal says what is wrong"
assert_contains "$err" "kendex guard install" "and names the one command that fixes it"
assert_eq "$log" "" "and the repository's own script was not run"

run_hook "$DISARMED" "$(payload 'git commit -m test')"
assert_eq "$rc" "2" "a hook git will not execute is unarmed too"
assert_eq "$log" "" "and nothing was run beside it"

# The one direction this lane must never fail in. An executable pre-commit
# at the repository root is what `--git-path hooks` points at when the value
# is empty, so reading that directory answers about the wrong place — and
# answers "armed" for a repository whose commits git gates with nothing.
run_hook "$HALF_ARMED" "$(payload 'git commit -m test')"
assert_eq "$rc" "2" "one lane armed is not an armed repository"
assert_contains "$err" "not armed by kendex" "one lane armed is not armed"
assert_eq "$log" "" "and nothing of the repository's was run"

run_hook "$HOOKS_OFF" "$(payload 'git commit -m test')"
assert_eq "$rc" "2" "an empty core.hooksPath is hooks off, not a hooks directory"
assert_contains "$err" "not armed by kendex" "hooks switched off is not armed either"
assert_contains "$err" "kendex guard check" "and points at what does know why"
assert_eq "$log" "" "and the repository's own script was not run"

# Arming is not the remedy on its own here, but it is still the second half
# of it, so the line names both in the order they have to happen.
assert_contains "$err" "kendex guard install" "arming is named after the unset"

echo
echo "no kendex binary anywhere"

# Every run above already used a PATH with no kendex on it. The armed hook
# is what gates a commit, and git runs it with no binary involved; the
# refusal for an unarmed one needs none either.
run_hook "$ARMED" "$(payload 'git commit -m test')"
assert_eq "$rc" "0" "an armed hook needs no kendex binary"
assert_eq "$log" "" "and this hook ran nothing of its own beside it"

run_hook "$ARMED" "$(payload 'git commit --no-verify -m test')"
assert_eq "$rc" "2" "bypassing the armed hook is refused with or without a binary"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
