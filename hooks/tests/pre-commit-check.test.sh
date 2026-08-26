#!/usr/bin/env bash
# Tests for the pre-commit-check hook's contract: word-order detection of a
# git commit with no shell parsing; deference to the repository's own armed
# git pre-commit hook (never a second validation) unless the command
# sidesteps it; the growth-guards package's own pre-commit script as the
# fallback gate where nothing will run; fail-closed when neither an armed
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

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

CHAIN_LOG="$TMP_ROOT/chain.log"
ERR_FILE="$TMP_ROOT/stderr"

# --- the package's pre-commit script, stubbed --------------------------------
# Written where the hook looks for it: under the repository's own
# `.agents/skills`, the first root in the search list. CHAIN_EXIT=1 plays a
# lane violation, CHAIN_EXIT=2 a guard that could not run, both in the
# chain's real wording.
install_stub_chain() {
  local scripts="$1/.agents/skills/growth-guards/scripts"
  mkdir -p "$scripts"
  cat >"$scripts/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "chain ran" >>"$CHAIN_LOG"
echo "=== pre-commit: growth-guards all"
echo "growth-guards: OK — enabled checks clean"
case "${CHAIN_EXIT:-0}" in
  1)
    echo "=== growth-guards: todo-ban"
    echo "todo-ban FAIL work marker: src/a.rs:3:the marker line"
    echo "pre-commit: violations — commit blocked; see the failures above"
    ;;
  2)
    echo "pre-commit: step 'growth-guards all' did not complete (exit 2)"
    echo "pre-commit: a guard could not complete — commit blocked; fix the errors above (bypass only with git commit --no-verify)"
    ;;
esac
if [ "${CHAIN_SKIP:-0}" != "0" ]; then
  echo "=== pre-commit: preflight not installed — skipped (no preflight skill)"
fi
exit "${CHAIN_EXIT:-0}"
EOF
  chmod +x "$scripts/pre-commit"
}

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
  : >"$CHAIN_LOG"
  set +e
  (cd "$dir" && env PATH="$NO_KENDEX_BIN" CHAIN_LOG="$CHAIN_LOG" "$@" \
    bash "$HOOK" <<<"$payload") >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
  log="$(cat "$CHAIN_LOG" 2>/dev/null || true)"
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

for fixture in "$UNARMED" "$ARMED" "$ARMED_BY_PATH" "$DISARMED" "$DISARMED_BY_PATH"; do
  install_stub_chain "$fixture"
done

# The one repository without the package, for the fail-closed case.
NO_PACKAGE="$TMP_ROOT/no-package"
mkdir -p "$NO_PACKAGE"
git -C "$NO_PACKAGE" init -q

echo "detection"

run_hook "$UNARMED" "$(payload 'ls -la')"
assert_eq "$rc" "0" "a non-commit command is left alone"
assert_not_contains "$log" "chain ran" "no guard run for a non-commit command"

run_hook "$UNARMED" '{"note":"about to commit with git"}'
assert_eq "$rc" "0" "a payload with no command field is left alone"

run_hook "$UNARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a plain git commit reaches the fallback gate"
assert_contains "$log" "chain ran" "the fallback is the guard chain"

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
  assert_eq "$rc" "2" "the commit after an escape reaches the fallback gate: $form"
  assert_contains "$log" "chain ran" "the chain ran for: $form"
done

echo
echo "unreadable payload"

run_hook "$UNARMED" '{"tool_input":{"command":123}}' CHAIN_EXIT=1
assert_eq "$rc" "2" "a command key whose value cannot be read is refused"
assert_contains "$err" "could not read the command" "the refusal names the unreadable payload"
assert_not_contains "$log" "chain ran" "no guard run on a payload the hook could not read"

run_hook "$UNARMED" $'{"tool_input":{"command":\n"git commit -m x"}}' CHAIN_EXIT=1
assert_eq "$rc" "2" "a key and value on separate lines still reach the fallback gate"
assert_contains "$log" "chain ran" "the chain ran for the split-line payload"

echo
echo "deference to an armed git hook"

run_hook "$ARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "0" "an armed .git/hooks/pre-commit gates the commit itself"
assert_not_contains "$log" "chain ran" "no second validation beside an armed hook"

run_hook "$ARMED_BY_PATH" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "0" "a core.hooksPath hook counts as armed"
assert_not_contains "$log" "chain ran" "no second validation beside a hooksPath hook"

run_hook "$ARMED" "$(payload 'git commit -am test')" CHAIN_EXIT=1
assert_eq "$rc" "0" "a short-flag cluster without n still defers"

echo
echo "a hook file git will not run is not armed"

run_hook "$DISARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a pre-commit without the execute bit falls back to the chain"
assert_contains "$log" "chain ran" "the chain ran beside the non-executable hook"

run_hook "$DISARMED_BY_PATH" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a non-executable core.hooksPath pre-commit falls back to the chain"
assert_contains "$log" "chain ran" "the chain ran beside the non-executable hooksPath hook"

echo
echo "bypassing the armed hook is refused, not half-checked"

# The fallback chain cannot stand in for git's hooks here: the same flag
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
  assert_not_contains "$log" "chain ran" "no chain run stands in for the bypassed hooks: $form"
  assert_contains "$err" "bypasses this repository's armed git hooks" "the refusal names the bypass: $form"
done

run_hook "$ARMED" "$(payload 'git commit --no-verify -m x')" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the refusal names the flag it saw"

run_hook "$ARMED_BY_PATH" "$(payload 'git commit --no-verify -m x')" CHAIN_EXIT=0
assert_eq "$rc" "2" "--no-verify beside a hooksPath hook is refused too"
assert_not_contains "$log" "chain ran" "and runs no chain there either"

echo
echo "the hook gates its working directory only"

# The contract as built: git answers the which-repository question only
# where the target has an armed hook; this hook never follows -C, cd,
# --git-dir or --work-tree. From an armed directory it defers whatever
# the target; from an unarmed one it judges itself and says so.
run_hook "$ARMED" "$(payload "git -C $UNARMED commit -m x")" CHAIN_EXIT=1
assert_eq "$rc" "0" "an armed cwd defers even when the commit is aimed at an unarmed repository"
assert_not_contains "$log" "chain ran" "the unarmed target gets no chain from here — its own hook is its gate"

run_hook "$UNARMED" "$(payload "git -C $ARMED commit -m x")" CHAIN_EXIT=1
assert_eq "$rc" "2" "an unarmed cwd runs the chain for itself whatever the target"
assert_contains "$log" "chain ran" "the chain ran in the unarmed cwd"
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
echo "fallback verdicts"

run_hook "$UNARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=0
assert_eq "$rc" "0" "a clean chain lets the commit proceed"
assert_eq "$err" "" "a clean chain with nothing skipped is silent"

run_hook "$UNARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=0 CHAIN_SKIP=1
assert_eq "$rc" "0" "a clean chain with a skipped lane still lets the commit proceed"
assert_contains "$err" "preflight not installed" "the skipped lane's own line reaches stderr"
assert_not_contains "$err" "growth-guards: OK" "only the skip line is forwarded, not the whole report"

run_hook "$UNARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_contains "$err" "todo-ban FAIL" "the chain's own output reaches stderr"
assert_contains "$err" "kendex guard install" "the block names the durable fix"

run_hook "$UNARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=2
assert_eq "$rc" "2" "a chain that could not complete blocks"
assert_contains "$err" "did not complete" "the block carries the chain's own reason"

run_hook "$NOT_A_REPO" "$(payload 'git commit -m test')" CHAIN_EXIT=1
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
  run_hook "$ARMED" "$(payload "$form")" CHAIN_EXIT=1
  assert_eq "$rc" "0" "no refusal for: $form"
  assert_not_contains "$err" "cannot enter" "no cannot-enter refusal for: $form"
done

# The JSON-escaped quoted-path form: quotes arrive as \" in the payload.
run_hook "$ARMED" '{"tool_input":{"command":"git -C \"/tmp/my repo\" commit -m x"}}' CHAIN_EXIT=1
assert_eq "$rc" "0" "a quoted path with a space is not a refusal"

run_hook "$UNARMED" '{"tool_input":{"command":"git -C \"/tmp/my repo\" commit -m x"}}' CHAIN_EXIT=1
assert_eq "$rc" "2" "the quoted-path commit still reaches the fallback gate"

echo
echo "a linked worktree is gated by the main checkout's copy"

# Linked worktrees share one hooks directory but need not carry their own
# skills, so the shim searches the MAIN checkout first. A fallback that
# looked only at this work tree would find nothing and refuse a commit the
# armed shim would have checked.
LINKED_MAIN="$TMP_ROOT/linked-main"
mkdir -p "$LINKED_MAIN"
git -C "$LINKED_MAIN" init -q
git -C "$LINKED_MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
install_stub_chain "$LINKED_MAIN"
git -C "$LINKED_MAIN" worktree add -q "$TMP_ROOT/linked-wt" 2>/dev/null
# The linked work tree carries no copy of its own.
rm -rf "$TMP_ROOT/linked-wt/.agents"

run_hook "$TMP_ROOT/linked-wt" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "the linked worktree reaches the main checkout's chain"
assert_contains "$log" "chain ran" "and it is the main checkout's script that ran"

# A linked work tree with its own copy uses that one, not the main
# checkout's: a re-vendored copy gates the tree it sits in.
install_stub_chain "$TMP_ROOT/linked-wt"
run_hook "$TMP_ROOT/linked-wt" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a work tree carrying its own copy still runs a chain"

echo
echo "the helper's baked scripts directory comes first"

# The helper the installer writes execs its baked installed_scripts before
# searching anywhere, so this lane tries it first too. Otherwise a repository
# armed from a layout the search cannot reach would be judged by one copy at
# commit time and another here. The path carries an apostrophe, which the
# installer writes shell-escaped and this lane has to decode.
SQ="'"
BAKED_ROOT="$TMP_ROOT/baked${SQ}quote"
mkdir -p "$BAKED_ROOT"
git -C "$BAKED_ROOT" init -q
mkdir -p "$BAKED_ROOT/vendor/gg/scripts"
cat >"$BAKED_ROOT/vendor/gg/scripts/pre-commit" <<'EOF'
#!/usr/bin/env bash
echo "baked chain ran" >>"$CHAIN_LOG"
echo "chain ran" >>"$CHAIN_LOG"
exit "${CHAIN_EXIT:-0}"
EOF
chmod +x "$BAKED_ROOT/vendor/gg/scripts/pre-commit"
# A helper with no delegating lines beside it: the repository is unarmed, so
# the fallback runs, and the helper is there only to name the copy. Escaped
# exactly as the installer escapes it.
ESCAPED="${BAKED_ROOT//$SQ/$SQ\\$SQ$SQ}"
{
  echo "#!/bin/sh"
  echo "installed_scripts=${SQ}${ESCAPED}/vendor/gg/scripts${SQ}"
} >"$BAKED_ROOT/.git/hooks/kendex-guards"
chmod +x "$BAKED_ROOT/.git/hooks/kendex-guards"

run_hook "$BAKED_ROOT" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "the baked copy gates the commit"
assert_contains "$log" "baked chain ran" "and it is the baked copy that ran"

echo
echo "fail closed without the package"

run_hook "$NO_PACKAGE" "$(payload 'git commit -m test')"
assert_eq "$rc" "2" "no armed hook and no package refuses the commit"
assert_contains "$err" "no growth-guards skill is installed" \
  "the refusal names what is missing"
assert_contains "$err" "kendex add --skill growth-guards" "and how to get it"

echo
echo "no kendex binary anywhere"

# Every run above already used a PATH with no kendex on it. These name the
# property directly: the armed hook and the fallback both work without it,
# which is what lets a clone gate commits on a machine that never installed
# kendex.
run_hook "$ARMED" "$(payload 'git commit -m test')"
assert_eq "$rc" "0" "an armed hook needs no kendex binary"

run_hook "$UNARMED" "$(payload 'git commit -m test')" CHAIN_EXIT=1
assert_eq "$rc" "2" "and the fallback chain runs and blocks without one"
assert_contains "$log" "chain ran" "the package's own script is what ran"

run_hook "$ARMED" "$(payload 'git commit --no-verify -m test')"
assert_eq "$rc" "2" "bypassing the armed hook is refused with or without a binary"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
