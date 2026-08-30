#!/usr/bin/env bash
# Tests for the pre-commit-check hook's contract: the command splits into
# simple commands and only a `git` invocation's argv is judged; deference to
# the repository's own armed git pre-commit hook (never a second validation)
# unless that argv sidesteps it; the refusal where nothing is armed;
# fail-closed when no armed hook exists, and when the payload names a command
# the hook cannot read. Shell forms the hook does not run — `$(…)`,
# backticks, `cd "$dir"`, unexpanded variables — must pass through without a
# refusal of their own, and so must a `-n`, `-c` or `--no-verify` belonging to
# a heredoc body, another program, or a quoted commit message.
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
# the git argv carries a bypass; the UNARMED one is the control proving the
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
echo "JSON newline escapes end a command"

# Single quotes on purpose: the payload carries the two characters \n, as
# JSON encodes a newline in a multi-line command.
for form in \
  'cargo fmt\ngit commit -m x' \
  'cargo fmt\r\ngit commit -m x'; do
  run_hook "$UNARMED" "$(payload "$form")" CHAIN_EXIT=1
  assert_eq "$rc" "2" "the commit on the next line is still refused: $form"
  assert_eq "$log" "" "nothing was run for: $form"
done

# A tab is word whitespace to the shell, never a command separator: that
# payload is one `cd` with five arguments, and no commit for this lane to gate.
run_hook "$UNARMED" "$(payload 'cd sub\tgit commit -m x')" CHAIN_EXIT=1
assert_eq "$rc" "0" "a tab makes arguments of git commit, not a command"

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

echo
echo "only a git argv is judged"

# The three refusals this rule exists to stop, all of them in one day: a `-n`
# in a heredoc body, a `-c` belonging to another program, and prose naming
# --no-verify inside a quoted string. The quotes are JSON-escaped because the
# harness sends them that way, and an unescaped one would end the payload
# string before the commit.
# shellcheck disable=SC2016
both 'cat <<EOF > tmp/note.md\nrun cat -n on the file\nEOF\ngit commit -m note' 0 2 "a -n in a heredoc body"
both 'python3 -c \"print(1)\" && git commit -m x' 0 2 "another program's -c"
both 'git commit -m \"explain why --no-verify is banned\"' 0 2 "prose in a quoted message"
both 'gh pr comment 7 --body \"we never pass --no-verify\" && git commit -m x' 0 2 "prose in another program's argv"
both 'git commit -c HEAD --reset-author' 0 2 "-c after commit is --reedit-message"

# The same forms with the flag moved into the commit's own argv.
# shellcheck disable=SC2016
both 'cat <<EOF > tmp/note.md\nrun cat -n on the file\nEOF\ngit commit -n -m note' 2 2 "the heredoc form with -n in the argv"
both 'python3 -c \"print(1)\" && git commit --no-verify -m x' 2 2 "the python3 form with the flag in the argv"
both 'git commit -m \"explain why --no-verify is banned\" --no-verify' 2 2 "the quoted-message form with the flag in the argv"
both 'gh pr comment 7 --body \"we never pass --no-verify\" && git -c core.hooksPath=/dev/null commit -m x' 2 2 "the gh form with config injected"

echo
echo "a heredoc body is text, not shell"

# A body line that begins with `git` is prose about a commit, not a commit; the
# body is skipped whole, so no quote in it opens anything either. Without that,
# one apostrophe swallowed every separator after it and the real commit behind
# the heredoc went unjudged in both fixtures.
# shellcheck disable=SC2016
both 'cat > note.md <<EOF\ngit commit --no-verify is banned in this repo\nEOF\ngit commit -m x' 0 2 "a body line beginning with git"
both 'cat <<EOF >> notes.md\ndon'"'"'t forget\nEOF\ngit commit --no-verify -m x' 2 2 "an apostrophe in the body hides nothing"
both 'cat <<EOF > n.md\nsay \"hi\nEOF\ngit commit -m x' 0 2 "an unpaired double quote in the body"
both 'cat <<-EOF > n.md\n\tgit commit -n here\n\tEOF\ngit commit -m x' 0 2 "<<- with a tab-indented terminator"
both 'cat <<\"END\" > n.md\ngit commit -n here\nEND\ngit commit -m x' 0 2 "a quoted delimiter"
both 'git commit -m x <<< ignored' 0 2 "a here-string is not a heredoc"

echo
echo "a comment is text"

both 'git commit -m x  # never --no-verify' 0 2 "a trailing comment naming --no-verify"
both 'git commit -m x # -n' 0 2 "a trailing comment naming -n"
both 'git commit -m x#y --no-verify' 2 2 "a mid-word hash is an ordinary character"

echo
echo "a backslash-newline joins lines"

# hooks/block-unsafe-rm.sh folds the same sequence before its separator split.
# Left alone it puts a newline inside the word, and the command after it goes
# unjudged in both fixtures.
# shellcheck disable=SC2016
both 'git status && \\\ngit commit --no-verify -m x' 2 2 "a bypass on the continued line"
both 'cargo fmt && \\\ngit commit -m x' 0 2 "a plain commit on the continued line"

echo
echo "git option boundaries hold"

both 'git commit -- --no-verify' 0 2 "a pathspec after --"
both 'git commit -m x -- -n' 0 2 "-n as a pathspec after --"
both 'git commit -F --no-verify' 0 2 "-F takes its value"
both 'git commit -m a{b} --no-verify' 2 2 "a brace is expansion, not a command break"
both '{ git commit --no-verify -m x; }' 2 2 "a brace group still holds a commit"

echo
echo "a command prefix does not hide the git argv"

# main's word-order rule caught every one of these without reading a prefix at
# all, so a prefix this lane cannot resolve must not read as not-a-git-command.
both 'sudo git commit --no-verify -m x' 2 2 "sudo"
both 'sudo -E git commit -n -m x' 2 2 "sudo with its own option"
both 'sudo -u dev git commit --no-verify -m x' 2 2 "sudo with an option and a value"
both 'env git commit -n -m x' 2 2 "env"
both 'env -i git commit -n -m x' 2 2 "env -i"
both '/usr/bin/env -i git -c core.hooksPath=/dev/null commit -m x' 2 2 "an absolute env injecting config"
both 'nice git commit -n -m x' 2 2 "nice"
both 'timeout 30 git commit -n -m x' 2 2 "timeout with its duration"
both 'stdbuf -o0 git commit -n -m x' 2 2 "stdbuf with its own option"
both '/usr/bin/git commit --no-verify -m x' 2 2 "an absolute git path"
both 'echo git commit --no-verify' 0 0 "a word outside any argv is still text"

echo
echo "quoting and redirection hold the argv together"

# shellcheck disable=SC2016
both 'git commit>/dev/null -n -m x' 2 2 "a redirection ends the word before it"
both 'git -C `echo ; pwd` commit --no-verify -m x' 2 2 "a backtick holds a separator inside one word"

echo
echo "a command whose quoting never closes is judged, not skipped"

# The parser cannot tokenize this, so the word-order rule it replaced stands in
# rather than the commit passing unjudged: an unbalanced quote otherwise
# swallows every separator after it, the commit with it.
# shellcheck disable=SC2016
both 'echo don'"'"'t && git commit --no-verify -m x' 2 2 "an unbalanced quote before a bypass"
both 'echo don'"'"'t && git commit -m x' 0 2 "an unbalanced quote before a plain commit"

run_hook "$UNARMED" "$(payload 'GIT_DIR=/elsewhere/.git git commit -m x')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a GIT_DIR assignment is still a commit"
assert_contains "$err" "moves repositories" "and the notice says the commit may land elsewhere"

run_hook "$UNARMED" "$(payload 'GIT_WORK_TREE=/elsewhere git commit -m x')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a GIT_WORK_TREE assignment is still a commit"
assert_contains "$err" "moves repositories" "and its notice says so too"

run_hook "$UNARMED" '{"tool_input":{"command":"git commit -m x' CHAIN_EXIT=1
assert_eq "$rc" "2" "a command string that never ends is refused"
assert_contains "$err" "could not read the command" "and the refusal names the unreadable payload"
assert_eq "$log" "" "nothing was run for the unterminated payload"

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
# Both lanes marked, one of them without the bit git needs. Git skips such
# a hook in silence, so deferring to its marker stands this lane aside for
# a gate that does not run. Both lanes are marked deliberately: the missing
# bit has to be the only thing wrong, or the pin passes on the other lane.
run_hook "$MARKED_NOT_EXEC" "$(payload 'git commit -m test')"
assert_eq "$rc" "2" "a marked hook without the execute bit is not armed"
assert_contains "$err" "not armed by kendex" "and the refusal says so"
assert_eq "$log" "" "and nothing of the repository's was run"

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
