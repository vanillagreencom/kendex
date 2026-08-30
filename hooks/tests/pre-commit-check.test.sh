#!/usr/bin/env bash
# Tests for the pre-commit-check hook's contract: the command splits into simple
# commands and only their live words are judged, a quoted word among them;
# deference to the repository's own armed git pre-commit hook (never a second
# validation) unless a word in that command sidesteps it; the refusal where
# nothing is armed, and where the payload names a command the hook cannot read.
# A `-n`, `-c` or `--no-verify` belonging to a heredoc body, another program or
# a quoted commit message passes without a refusal of its own — a bypass is a
# word whose WHOLE content is one. A construct the scanner has no rule for
# leaves the words standing to be judged; the four it names are refused unread.
#
# The package script is stubbed inside each fixture repository, so the suite
# needs no built binary, runs no real chain, and never puts `kendex` on PATH.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# HOOK_UNDER_TEST runs these assertions against a must-fail mutant of the hook.
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/pre-commit-check.sh}"

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

# A tab is word whitespace, so those are five arguments of one `cd` — but they
# are live words all the same, and the rule reads words rather than an argv.
run_hook "$UNARMED" "$(payload 'cd sub\tgit commit -m x')" CHAIN_EXIT=1
assert_eq "$rc" "2" "a tab leaves git and commit standing as live words"

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
echo "only live words are judged"

# The three refusals this rule exists to stop, all in one day: a `-n` in a
# heredoc body, a `-c` belonging to another program, and prose naming
# --no-verify in a quoted string. The quotes are JSON-escaped as the harness
# sends them; an unescaped one would end the payload before the commit.
# shellcheck disable=SC2016
both 'cat <<EOF > tmp/note.md\nrun cat -n on the file\nEOF\ngit commit -m note' 0 2 "a -n in a heredoc body"
both 'python3 -c \"print(1)\" && git commit -m x' 0 2 "another program's -c"
both 'git commit -m \"explain why --no-verify is banned\"' 0 2 "prose in a quoted message"
both 'gh pr comment 7 --body \"we never pass --no-verify\" && git commit -m x' 0 2 "prose in another program's argv"
both 'git commit -c HEAD --reset-author' 2 2 "-c anywhere in a commit is config"

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
# Joined, the flag is the argv's own; left unjoined it carries a newline and
# reads as neither flag nor command word.
both 'git commit -m x \\\n--no-verify' 2 2 "a flag joined onto the argv"

echo
echo "a bypass word is a bypass word"

# No argv model means no `--` and no option values: a word that reads as the
# flag is refused wherever it stands. Bizarre forms, and they fail closed.
both 'git commit -- --no-verify' 2 2 "a pathspec after --"
both 'git commit -m x -- -n' 2 2 "-n as a pathspec after --"
both 'git commit -F --no-verify' 2 2 "the value of an option that takes one"
both 'git commit -m a{b} --no-verify' 2 2 "a brace is expansion, not a command break"
both '{ git commit --no-verify -m x; }' 2 2 "a brace group still holds a commit"

echo
echo "a command prefix does not hide the git word"

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
both 'echo git commit --no-verify' 2 2 "a word another program would print"

# A wrapper option's operand is not a command word: `git` is an ordinary
# account name (gitolite, Gitea), and reading it as the command left the
# bypass behind it unjudged. Such a command takes the word-order rule.
both 'sudo -u git git commit --no-verify -m x' 2 2 "an operand spelled git"
both 'env -u git git commit --no-verify -m x' 2 2 "env unsetting a variable named git"

run_hook "$ARMED" "$(payload 'sudo -u git git commit --no-verify -m x')" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the operand form names the flag it saw"
run_hook "$ARMED" "$(payload 'env -u git git commit --no-verify -m x')" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the env form names the flag it saw"

# The direction the fallback has to keep: an ordinary wrapped commit still
# defers, and only a bypass word in it refuses.
both 'timeout 30 git commit -m x' 0 2 "a wrapped plain commit still defers"
both 'nice git commit -m x' 0 2 "an unwrapped-option prefix still defers"
both 'sudo -u dev git config core.hooksPath /dev/null && git commit -m x' 2 2 "a wrapped hooksPath write"

echo
echo "a construct the scanner does not model is not waved through"

# Every gap in a hand-written scanner is a fail-open, so a command word this
# lane left shell in takes the word-order rule rather than a guess: an append
# assignment is no assignment to the tokenizer, and a dynamic file descriptor
# stays a word ahead of its redirection.
both 'PATH+=:/usr/bin git commit --no-verify -m x' 2 2 "an append assignment"
both '{fd}>out git commit --no-verify -m x' 2 2 "a dynamic file descriptor"
both 'PATH+=:/usr/bin git commit -m x' 0 2 "an append assignment with no bypass"

# A quoted paren inside a substitution desynchronises the scan, and everything
# after it is guesswork. The fallback runs on an unbalanced command whatever an
# earlier one looked like — suppressing it there let this bypass through.
DESYNC="git commit --allow-empty -m x && echo \$(printf ')') && git commit --allow-empty --no-verify -m y"
both "$DESYNC" 2 2 "a substitution closing on a quoted paren"

run_hook "$ARMED" "$(payload "$DESYNC")" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the desynchronised command names the flag it saw"

echo
echo "a quoted word is a live word"

# Quoting sets a word boundary; it does not stop the word existing. The quotes
# arrive JSON-escaped, as the harness sends them.
both 'git commit \"--no-verify\" -m x' 2 2 "a quoted flag"
both 'git \"commit\" --no-verify' 2 2 "a quoted subcommand"
both '\"git\" commit --no-verify' 2 2 "a quoted command word"
run_hook "$ARMED" "$(payload 'git commit \"--no-verify\" -m x')" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the quoted flag is named unquoted"

# And the other half of the rule: a bypass is a word whose WHOLE content is
# one, so prose that merely names a flag is one long word and not the flag.
both 'git commit -m \"--no-verify should never be used\"' 0 2 "prose naming the flag"
both 'git commit -m \"prose mentioning -n inside\"' 0 2 "prose naming -n"
both 'git commit -m \"core.hooksPath is not to be touched\"' 0 2 "prose naming the key"

echo
echo "an escaped quote does not close its run"

# A backslash escapes the next character inside a double-quoted or backtick run,
# so `\"` is not the close. Read as one, everything through the next quote is
# swallowed and the live command behind it disappears.
NV="--no-""verify"
both "echo \\\"x\\\\\\\" y\\\" && git commit $NV -m \\\"x\\\"" 2 2 "an escaped double quote"
both 'echo `x\\` y` && git commit '"$NV"' -m `x`' 2 2 "an escaped backtick"

# The control: same shell, no bypass. The unarmed refusal proves the commit was
# found rather than the armed refusal arriving from swallowed text.
both "echo \\\"x\\\\\\\" y\\\" && git commit -m \\\"x\\\"" 0 2 "the same run without a bypass"
both 'echo `x\\` y` && git commit -m `x`' 0 2 "the backtick form without a bypass"

run_hook "$ARMED" "$(payload "echo \\\"x\\\\\\\" y\\\" && git commit $NV -m \\\"x\\\"")" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the escaped-quote form names the flag behind it"

# A single-quoted run takes no escapes, so this one closes at the second quote
# and the commit behind it is live. Honour the backslash there and the whole
# middle becomes one word, commit and flag with it.
both "echo 'a\\\\' && git commit $NV -m 'x'" 2 2 "a backslash inside single quotes"
both "echo 'a\\\\' && git commit -m 'x'" 0 2 "the same run without a bypass"

echo
echo "a -c word injects configuration whatever its value"

both 'git -cinclude.path=/tmp/c commit -m x' 2 2 "an attached include.path"
run_hook "$ARMED" "$(payload 'git -cinclude.path=/tmp/c commit -m x')" CHAIN_EXIT=0
assert_contains "$err" "'-cinclude.path=/tmp/c' bypasses" "the attached value is named"

echo
echo "a construct this hook does not model is refused on sight"

# Each of these hides text from the scanner, and each decode added to read one
# invites the next construct. So the construct itself is the answer: a command
# naming git that carries one is refused in either fixture, without parsing.
# The refusals do not name a bypass — nothing was parsed to find one.
unmodelled() {
  local form="$1" name="$2"
  for fixture in "$ARMED" "$UNARMED"; do
    run_hook "$fixture" "$(payload "$form")" CHAIN_EXIT=0
    assert_eq "$rc" "2" "refused on sight: $name"
    assert_contains "$err" "does not model" "the refusal names the construct: $name"
    assert_eq "$log" "" "nothing of the repository's ran: $name"
  done
}

# Double-quoted so the apostrophes survive; the $ is escaped so this shell does
# not expand it before the hook reads it as text.
ANSIC="cat <<\$'EOF'\\nbody\\nEOF\\ngit commit -m x"
unmodelled "git -c alias.c='commit $NV' c --allow-empty -m x" "an alias key defining a commit"
unmodelled "git config alias.c 'commit $NV' && git c --allow-empty -m x" "a persisted alias key"
unmodelled "$ANSIC" "ANSI-C quoting"
unmodelled 'git commit \"--no-veri\\\nfy\" -m x' "a line continuation inside quotes"
unmodelled 'x=$(( 1 << 2 )) && git commit -m x' "a shift inside arithmetic"

# Three of the four are asked only where a live word is exactly `commit`, and
# quoting joins, so this is that word.
unmodelled "git com''mit \$'--no-verify' -m x" "a quote-split commit word"

# The live word, not the word-order verdict: this construct spells the git word,
# so no argv here is a commit and only the word is left to gate on.
unmodelled "git status && \$'g''it' commit --no-verify -m x" "a construct spelling the git word"

# The KEN-866 regression: no commit word in the first two, and in the third the
# word is the pattern `commit$` rather than `commit`.
both "grep -rn 'foo\$' .git/config" 0 0 "an anchored grep over a .git path"
both "git log --oneline | grep 'fix\$'" 0 0 "a read-only log piped into an anchored grep"
both "git log --oneline | grep 'commit\$'" 0 0 "an anchored grep for the word commit"

# Declined on KEN-866, pinned so the decline cannot flip in silence: the one word
# is `\$commit`, the construct having spelled it rather than split it.
both "git \$'com''mit' --no-verify -m x" 0 0 "a commit word spelled by the construct"

# The alias key carries no commit prerequisite: it names a commit that is never
# a live word, so gating it on the word disarms it.
unmodelled "git -c alias.c='co' co --allow-empty -m x" "an alias key naming no commit"

# The controls. A command with none of these parses as before, and one naming
# no git at all is not this gate to judge however it is written.
both 'git commit -m x' 0 2 "an ordinary commit carries no trigger"
both 'git -c core.pager=cat log' 0 0 "a benign -c on a non-commit"
run_hook "$ARMED" "$(payload 'echo $'hi'')" CHAIN_EXIT=0
assert_eq "$rc" "0" "ANSI-C quoting without git is left alone"
run_hook "$ARMED" "$(payload 'x=$(( 1 << 2 ))')" CHAIN_EXIT=0
assert_eq "$rc" "0" "arithmetic without git is left alone"

echo
echo "a payload escape that spells a word is unreadable"

# A \\u escape can spell `git`, or the flag. Decoding it is one more thing to
# get wrong, so the payload takes the same fail-closed path a truncated one does.
run_hook "$ARMED" '{"tool_input":{"command":"\u0067it commit -m x"}}' CHAIN_EXIT=0
assert_eq "$rc" "2" "a \\u escape in the command is refused"
assert_contains "$err" "could not read the command" "and takes the unreadable path"
assert_eq "$log" "" "nothing of the repository's ran for the escaped payload"

# The control: an escaped backslash before a u is a literal backslash, not an
# escape, and the command behind it is read as usual.
run_hook "$UNARMED" '{"tool_input":{"command":"echo a\\u0067 && git commit -m x"}}' CHAIN_EXIT=0
assert_eq "$rc" "2" "a literal backslash-u is still parsed"
assert_contains "$err" "not armed by kendex" "and reaches the ordinary refusal"

echo
echo "only <<- accepts a tab-indented terminator"

# Strip tabs from every terminator and a tab-indented EOF ends a plain heredoc
# early, leaving the body live: one quote in it swallowed the commit behind it.
both 'cat <<EOF\n\tEOF\n\"\nEOF\ngit commit '"$NV"' -m \"x\"' 2 2 "a tab-indented EOF under <<"
# The control: under <<- it does terminate, and the body stays inert.
both 'cat <<-EOF\n\tgit commit '"$NV"' here\n\tEOF\ngit commit -m x' 0 2 "a tab-indented EOF under <<-"

echo
echo "a substitution close does not end the word"

# `$(true)#x` is one word to bash, so the hash touching the close is an
# ordinary character. Ending the word there made it a comment opener, and
# everything after it — the commit included — was discarded as a comment.
# shellcheck disable=SC2016
both 'echo $(true)#x && git commit '"$NV"' -m x' 2 2 "a hash touching a substitution close"
# shellcheck disable=SC2016
run_hook "$ARMED" "$(payload 'echo $(true)#x && git commit '"$NV"' -m x')" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the touching-hash form names the flag behind it"

# The control: a hash that is its own word still opens a comment.
# shellcheck disable=SC2016
both 'echo $(true) # x && git commit '"$NV"' -m x' 0 0 "a hash standing as its own word"

echo
echo "a construct the scanner never heard of leaves the words standing"

# Each of these desynchronised the argv parser that stood here, and each is
# closed by the rule reading live words instead: `coproc` is named nowhere.
# Double-quoted so the apostrophes survive; the $ is escaped so this shell does
# not run the substitution the hook has to read as text.
PAREN="echo \$(printf '(') && git commit --no-verify -m x"
both "$PAREN" 2 2 "a quoted paren inside a substitution"
# shellcheck disable=SC2016
both 'git >$(printf /dev/null) commit --no-verify -m x' 2 2 "a substitution as a redirection target"
both 'coproc git commit --no-verify -m x' 2 2 "a keyword this lane does not know"
# shellcheck disable=SC2016
both 'git -C $(cd /t && pwd) commit --no-verify -m x' 2 2 "an operator inside a substitution"
both 'git &>out commit --no-verify -m x' 2 2 "an &> before the subcommand"
both 'commit git' 0 0 "commit before git is not a commit"

# A heredoc that never terminates would otherwise swallow every command after
# it; the body is left live instead. The joined delimiter is the control: there
# the body IS skipped, so the words in it are not flags.
both 'cat <<EOF\ngit commit --no-verify -m x' 2 2 "an unterminated heredoc"
HEREDOC_PROSE='cat <<EO\\\nF > n.md\ngit commit --no-verify is banned here\nEOF\ngit commit -m x'
both "$HEREDOC_PROSE" 0 2 "prose in a body behind a joined delimiter"

echo
echo "a redirection is redirection wherever it stands"

# A line continuation inside the delimiter is removed, so this heredoc ends at
# EOF; recorded literally it never terminates and swallows the commit whole.
HEREDOC_JOINED='cat <<EO\\\nF > n.md\nbody\nEOF\ngit commit --no-verify -m x'
both "$HEREDOC_JOINED" 2 2 "a line continuation inside a heredoc delimiter"
run_hook "$ARMED" "$(payload "$HEREDOC_JOINED")" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the joined delimiter names the flag behind the body"

# Between the command word and its subcommand is a legal place for one, and a
# process substitution is one target rather than argv words.
both 'git {fd}>out commit --no-verify -m x' 2 2 "a named descriptor before the subcommand"
both 'git < <(printf x) commit --no-verify -m x' 2 2 "a process substitution before the subcommand"
run_hook "$ARMED" "$(payload 'git {fd}>out commit --no-verify -m x')" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the descriptor form names the flag it saw"
run_hook "$ARMED" "$(payload 'git < <(printf x) commit --no-verify -m x')" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the process-substitution form names the flag it saw"

echo
echo "forms this lane refuses rather than models"

# Declined on KEN-833 as over-refusals, not defects: the trade this lane makes
# is that an unmodelled command is refused. Pinned so a later change cannot
# turn one of them into a commit that passes.
both 'GIT_CONFIG_COUNT=1 python3 -c pass && git commit -m x' 2 2 "an assignment in front of another program"
both 'git commit -Snone -m x' 2 2 "a cluster whose attached value contains n"
both 'git commit --m --no-verify' 2 2 "an abbreviated --message"

echo
echo "a git global option owns its value"

both 'git -ccore.hooksPath=/dev/null commit -m x' 2 2 "an attached -c injection"
both 'git -C /tmp -c user.name=x commit -m y' 2 2 "a -c behind a -C with its path"
both 'git -C -c commit -m x' 2 2 "a -c standing as the -C path value"

run_hook "$ARMED" "$(payload 'git -ccore.hooksPath=/dev/null commit -m x')" CHAIN_EXIT=0
assert_contains "$err" "'-ccore.hooksPath=/dev/null' bypasses" "the attached form names the injection"

echo
echo "quoting and redirection hold the words together"

# shellcheck disable=SC2016
both 'git commit>/dev/null -n -m x' 2 2 "a redirection ends the word before it"
both 'git -C `echo ; pwd` commit --no-verify -m x' 2 2 "a backtick holds a separator inside one word"

# A redirection contributes nothing to the argv, target included: leave the
# target behind and /dev/null reads as the subcommand, so the bypass behind it
# is never judged at all.
both 'git >/dev/null commit --no-verify -m x' 2 2 "a redirection before the subcommand"
both 'git 2>/dev/null commit --no-verify -m x' 2 2 "an IO number before the operator"
both 'git commit -m x >/dev/null' 0 2 "a redirection after a plain commit"

echo
echo "a short-option cluster is read left to right"

# The cluster used to be judged by its last character: -mnote was refused for
# the n in the message, and -mfixc swallowed the real --no-verify as its value.
both 'git commit -mnote' 0 2 "an attached message containing n"
both 'git commit -mfixc --no-verify' 2 2 "a cluster ending in a value-taking letter"
both 'git commit -nm msg' 2 2 "-n before the value-taking letter"

run_hook "$ARMED" "$(payload 'git commit -mfixc --no-verify')" CHAIN_EXIT=0
assert_contains "$err" "'--no-verify' bypasses" "the attached value is not the flag behind it"

run_hook "$ARMED" "$(payload 'git commit -nm msg')" CHAIN_EXIT=0
assert_contains "$err" "'-nm' bypasses" "the refusal names the cluster carrying -n"

echo
echo "quoting inside the command word is still the command word"

# Pi's port answered this from the raw string, where `g''it` carries no `git`
# at all and the bypass behind it passed an armed gate. Both read shell.
both "g''it commit --no-verify -m x" 2 2 "quotes inside the git word"
both "g''it commit -m x" 0 2 "the same word with no bypass"

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

# Arming is the local act that says a person wants this repository's committed
# scripts run on their commits, and git clones no hooks — so a fresh checkout
# has no execution behind it and this hook adds none. Every fixture carries a
# script that would announce itself if anything ran it.
run_hook "$UNARMED" "$(payload 'git commit -m test')"
assert_eq "$rc" "2" "an unarmed repository refuses the commit"
assert_contains "$err" "not armed by kendex" "the refusal says what is wrong"
assert_contains "$err" "kendex guard install" "and names the one command that fixes it"
assert_eq "$log" "" "and the repository's own script was not run"

run_hook "$DISARMED" "$(payload 'git commit -m test')"
assert_eq "$rc" "2" "a hook git will not execute is unarmed too"
assert_eq "$log" "" "and nothing was run beside it"

# The one direction this lane must never fail in. Git skips a hook without the
# execute bit in silence, so deferring to its marker stands this lane aside for
# a gate that does not run. Both lanes are marked deliberately: the missing bit
# has to be the only thing wrong, or the pin passes on the other lane.
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
