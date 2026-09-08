#!/usr/bin/env bash
# Tests for the pre-commit-check hook. Three things decide a verdict: whether
# the command's whitespace-separated words hold a `git` word and a later
# `commit` word, whether the working directory's git hooks are armed, and
# whether a word of that command is --no-verify, a short cluster holding -n, or
# a word carrying a core.hooksPath key.
#
# One rewrite runs first: every metacharacter bash(1) lists that is not
# whitespace (| & ; ( ) < >) becomes a space, so a word bash would have
# separated is separated here too. Nothing is deleted. A word is therefore seen
# only where the command already spells it, so a bypass the shell would join,
# unquote or expand into the word is not seen here and reaches git. The reading
# runs the other way too, so a `git` word, a `commit` word and a bypass word the
# split leaves standing count wherever they stand, a message and a comment tail
# included. Both directions are pinned below; the two expectation columns are
# where the armed and unarmed answers differ.
#
# HOOK_UNDER_TEST runs this suite against another hook file, which is how the
# must-fail control checks that these assertions can go red.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail

# The fixture's own git calls must build the fixture, not whatever repository
# a wrapper's redirection variables name.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS_DIR/pre-commit-check.sh}"

# shellcheck source=lib/pre-commit-world.sh
. "$HOOKS_DIR/tests/lib/pre-commit-world.sh"

# shellcheck source=lib/payload-rows.sh
. "$HOOKS_DIR/tests/lib/payload-rows.sh"

# Judge one form in both fixtures at once. The ARMED expectation says whether a
# word of the command reads as a bypass; the UNARMED one is the control proving
# the commit was found at all, since a form the hook never sees passes there too.
both() {
  local form="$1" want_armed="$2" want_unarmed="$3" name="$4"
  run_hook "$ARMED" "$(payload "$form")"
  assert_eq "$rc" "$want_armed" "armed: $name"
  [[ "$want_armed" == 2 ]] && assert_contains "$err" "would skip this repository's armed git hooks" "armed refusal names a bypass: $name"
  run_hook "$UNARMED" "$(payload "$form")"
  assert_eq "$rc" "$want_unarmed" "unarmed: $name"
  [[ "$want_unarmed" == 2 ]] && assert_contains "$err" "not armed by kendex" "unarmed refusal names the arming: $name"
  return 0
}

UNARMED="$(new_repo unarmed)"
ARMED="$(new_repo armed)"; arm "$ARMED" pre-commit commit-msg

echo "a git word with a later commit word is the commit"

both 'git commit -m test' 0 2 "a plain commit"
both 'cargo fmt\ngit commit -m x' 0 2 "a commit on the next line"
# The two characters of the git word's prefix strip that still decide a row: a
# path and a backtick, neither of which the substitution above separates. It
# does separate a `$(`, so a command substitution already arrives as a `git`
# word and asks the strip for nothing — the `$` and `(` in the strip class are
# what keeps these rows green in a build where that substitution is not there,
# and they stay for that reason rather than because a row needs them.
both '/usr/bin/git commit -m x' 0 2 "an absolute git path"
# shellcheck disable=SC2016
both 'x=$(git commit -m x)' 0 2 "a commit inside a command substitution"
both '`git commit '"$NV"' -m x`' 2 2 "a backtick-enclosed commit"
both 'git status' 0 0 "no commit word"
both 'git log --grep=commit' 0 0 "commit inside a longer word"
both 'echo commit && git status' 0 0 "a commit word before the git word"

echo
echo "a bypass of the armed hooks is refused"

both "git commit $NV -m x" 2 2 "the flag"
both 'git commit --no-veri -m x' 2 2 "an unambiguous abbreviation"
both 'git commit -n -m x' 2 2 "the short flag"
# The two sides of the value-taking-letter rule: a cluster reads left to right,
# so -nm is the flag and -mnote is a message.
both 'git commit -nm msg' 2 2 "n before the value-taking letter"
both 'git commit -anm x' 2 2 "a cluster holding n behind another letter"
both 'git commit -mfixc '"$NV" 2 2 "a value-taking letter does not swallow the flag behind it"
both 'git commit -am x' 0 2 "a cluster without n still defers"
both 'git commit -mnote' 0 2 "an attached message containing n"
# Every value-taking letter, not just m: -Cnew reuses another commit's message,
# so the n after it is that message's and not the flag.
both 'git commit -Cnew' 0 2 "a value-taking letter other than m swallows its value"
# A core.hooksPath key removes the judge this hook defers to, so it is read off
# the word whatever option carries it. These are the forms the word test
# catches, and the must-fail material for the two lines that catch them.
both 'git -c core.hooksPath=/dev/null commit -m x' 2 2 "a -c key and its value"
both 'git -ccore.hooksPath=/dev/null commit -m x' 2 2 "an attached -c key"
both 'git -c core.hookspath=/dev/null commit -m x' 2 2 "the key in another case"
both 'git --config-env=core.hooksPath=HP commit -m x' 2 2 "a --config-env key"
both 'git config --local core.hooksPath /dev/null && git commit -m x' 2 2 "a config write"
both 'sudo -u dev git config core.hooksPath /dev/null && git commit -m x' 2 2 "a wrapped config write"
both 'GIT_CONFIG_KEY_0=Core.HooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x' 2 2 "an environment key"
both 'GIT_CONFIG_COUNT=1 git commit -m x' 2 2 "the environment count alone"
both 'git commit -c HEAD --reset-author' 0 2 "-c reusing a message is not a key"

run_hook "$ARMED" "$(payload "git commit $NV -m x")"
assert_contains "$err" "The word '--no-verify' would skip" "the refusal names the flag it saw"
assert_contains "$err" "git commit -F <file>" "and the one for a long message"

echo
payload_table "$HOOK" "git commit $NV -m x" 'git commit -m x' "$ARMED"
# The table's refusal column says the hook read the command and refused it;
# which arm refused is this suite's pin, and the armed bypass arm is the one
# that must be reached through the Copilot shape.
run_hook "$ARMED" "$(jq -nc --arg c "git commit $NV -m x" '{toolName:"bash",toolArgs:{command:$c}}')"
assert_contains "$err" "would skip this repository's armed git hooks" "the bypass under toolArgs is named"

run_hook "$UNARMED" '{"note":"about to commit with git"}'
assert_eq "$rc" "0" "a payload with no command field is left alone"
# A command that splits into no words at all. On bash before 4.4 expanding a
# zero-element array under `set -u` aborts, so the clean exit is pinned rather
# than assumed; this suite is run against bash 3.2 as well as the host's.
run_hook "$UNARMED" "$(payload '   \t  ')"
assert_eq "$rc" "0" "a whitespace-only command exits clean"
assert_eq "$err" "" "and says nothing"

echo
echo "a metacharacter separates words here as it does in bash"

# bash(1) calls these metacharacters and lists nine: | & ; ( ) < > space tab
# newline. Space, tab and newline are IFS; these are the other seven, taken as
# the class rather than as the forms that were reported. Left attached, each
# hid a word bash would have separated, so `true;git` was no git word and
# `commit&` no commit word.
both 'true;git commit '"$NV"' -m x' 2 2 "a semicolon in front of the git word"
both 'git commit&>/dev/null -n' 2 2 "an ampersand-redirect glued to the subcommand"
both 'git commit>/dev/null -n -m x' 2 2 "a redirection glued to the subcommand"
both 'true&&git commit '"$NV"' -m x' 2 2 "an and-list with no spaces"
both 'true||git commit '"$NV"' -m x' 2 2 "an or-list with no spaces"
both 'true|git commit '"$NV"' -m x' 2 2 "a pipe with no spaces"

run_hook "$ARMED" "$(payload 'true;git commit '"$NV"' -m x')"
assert_contains "$err" "The word '--no-verify' would skip" "the refusal names the flag behind the separator"

# The unarmed column is the fail-open this split exists to close, and it is the
# guard's primary contract rather than a bypass question: with the separator
# left attached the hook found no commit at all, so a plain `true;git commit`
# ran in a repository nothing armed and nothing checked it. The armed column is
# the control that separating manufactures no bypass, and the last row is the
# control that it does not lose the word-order rule.
both 'true;git commit -m x' 0 2 "a plain commit behind a separator is still a commit"
both 'git commit -m x&' 0 2 "a backgrounded commit with no bypass"
both 'echo commit;git status' 0 0 "a commit word before the git word, across a separator"

# A row for every substitution the rows above leave undecided, because a class
# is only a class where each member is measured: delete one line of the seven
# and something here must go red. The rows above answer `>`, `;`, `&` and `|`;
# these two are what `<` and `)` decide on their own. `(` is the member with no
# measured fail-open of its own, since a `(` in front of the git word already
# comes off in the word loop.
both 'git commit</dev/null -m x' 0 2 "a redirection-in glued to the subcommand"
both '(git commit)' 0 2 "a subshell whose closing paren ends the commit word"

echo
echo "the two stated limits"

# Reading words rather than shell costs in both directions, and both costs are
# rows so nobody grows a tokenizer back to close either. A word the command
# spells is read wherever it stands, prose included, and quoting spares nothing
# by itself since the substitution runs before any word is looked at; a word the
# shell would assemble is not read at all.
both 'git commit -m \"explain why '"$NV"' is banned\"' 2 2 "the flag inside a quoted message"
both 'git log | grep commit' 0 2 "a commit word standing beside a git word in prose"
both 'git log --oneline \"(commit)\"' 0 2 "a commit word inside quoted parentheses"
# shellcheck disable=SC2016
both 'F='"$NV"'; git commit $F -m x' 0 2 "a flag reached through a variable"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
