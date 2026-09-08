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
# Every refusal opens with `pre-commit-check: <key>=<value>`, the fixed set
# hooks/AGENTS.md names, and a row pins that line whole in both fixtures beside
# the exit status. The armed refusal's value is the bypass word the hook read,
# which is what the bypass column carries; the unarmed one is the directory it
# judged, whatever the command said, since nothing gates the commit there.
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

# The hook's dependency list, in the order it checks them: the shared table
# pins it as the value of the world that has none of them.
PAYLOAD_TOOLS=jq,cat,grep

# shellcheck source=lib/payload-rows.sh
. "$HOOKS_DIR/tests/lib/payload-rows.sh"

# Judge one form in both fixtures at once. A row is
# `armed|unarmed|bypass|label|form`: the ARMED column says whether a word of
# the command reads as a bypass, the UNARMED one is the control proving the
# commit was found at all, since a form the hook never sees passes there too,
# and BYPASS is the word the armed refusal must name, `-` where it allows.
# The form stands last, so a row may hold a pipe; NOVERIFY stands for the
# bypass flag, which this file may not spell.
both_table() { # ROWS
  local row armed unarmed bypass label form field want before=$((PASS + FAIL))
  while IFS= read -r row; do
    [[ "$row" != "" ]] || continue
    IFS='|' read -r armed unarmed bypass label form <<<"$row"
    for field in "$armed" "$unarmed" "$bypass" "$label" "$form"; do
      [[ "$field" != "" ]] || { echo "both: a row with an empty field asserts nothing: $row" >&2; exit 1; }
    done
    form=${form//NOVERIFY/$NV}
    bypass=${bypass//NOVERIFY/$NV}
    run_hook "$ARMED" "$(payload "$form")"
    want="-"
    [[ "$armed" == 0 ]] || want="pre-commit-check: bypass=$bypass"
    assert_eq "rc=$rc first=$(first_line)" "rc=$armed first=$want" "armed: $label"
    run_hook "$UNARMED" "$(payload "$form")"
    want="-"
    [[ "$unarmed" == 0 ]] || want="pre-commit-check: unarmed=$UNARMED"
    assert_eq "rc=$rc first=$(first_line)" "rc=$unarmed first=$want" "unarmed: $label"
  done <<<"$1"
  [[ "$((PASS + FAIL))" -gt "$before" ]] || { echo "both: no row was asserted" >&2; exit 2; }
}

UNARMED="$(new_repo unarmed)"
ARMED="$(new_repo armed)"; arm "$ARMED" pre-commit commit-msg

echo "a git word with a later commit word is the commit"

# The two characters of the git word's prefix strip that still decide a row: a
# path and a backtick, neither of which the substitution above separates. It
# does separate a `$(`, so a command substitution already arrives as a `git`
# word and asks the strip for nothing — the `$` and `(` in the strip class are
# what keeps these rows green in a build where that substitution is not there,
# and they stay for that reason rather than because a row needs them.
both_table '0|2|-|a plain commit|git commit -m test
0|2|-|a commit on the next line|cargo fmt\ngit commit -m x
0|2|-|an absolute git path|/usr/bin/git commit -m x
0|2|-|a commit inside a command substitution|x=$(git commit -m x)
2|2|NOVERIFY|a backtick-enclosed commit|`git commit NOVERIFY -m x`
0|0|-|no commit word|git status
0|0|-|commit inside a longer word|git log --grep=commit
0|0|-|a commit word before the git word|echo commit && git status
'

echo
echo "a bypass of the armed hooks is refused"

# The two sides of the value-taking-letter rule: a cluster reads left to right,
# so -nm is the flag and -mnote is a message. A core.hooksPath key removes the
# judge this hook defers to, so it is read off the word whatever option carries
# it; those rows are the must-fail material for the two lines that catch them.
both_table '2|2|NOVERIFY|the flag|git commit NOVERIFY -m x
2|2|--no-veri|an unambiguous abbreviation|git commit --no-veri -m x
2|2|-n|the short flag|git commit -n -m x
2|2|-nm|n before the value-taking letter|git commit -nm msg
2|2|-anm|a cluster holding n behind another letter|git commit -anm x
2|2|NOVERIFY|a value-taking letter does not swallow the flag behind it|git commit -mfixc NOVERIFY
0|2|-|a cluster without n still defers|git commit -am x
0|2|-|an attached message containing n|git commit -mnote
0|2|-|a value-taking letter other than m swallows its value|git commit -Cnew
2|2|core.hooksPath=/dev/null|a -c key and its value|git -c core.hooksPath=/dev/null commit -m x
2|2|-ccore.hooksPath=/dev/null|an attached -c key|git -ccore.hooksPath=/dev/null commit -m x
2|2|core.hookspath=/dev/null|the key in another case|git -c core.hookspath=/dev/null commit -m x
2|2|--config-env=core.hooksPath=HP|a --config-env key|git --config-env=core.hooksPath=HP commit -m x
2|2|core.hooksPath|a config write|git config --local core.hooksPath /dev/null && git commit -m x
2|2|core.hooksPath|a wrapped config write|sudo -u dev git config core.hooksPath /dev/null && git commit -m x
2|2|GIT_CONFIG_KEY_0=Core.HooksPath|an environment key|GIT_CONFIG_KEY_0=Core.HooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x
2|2|GIT_CONFIG_COUNT=1|the environment count alone|GIT_CONFIG_COUNT=1 git commit -m x
0|2|-|-c reusing a message is not a key|git commit -c HEAD --reset-author
'

run_hook "$ARMED" "$(payload "git commit $NV -m x")"
assert_contains "$err" "git commit -F <file>" "the refusal names the form for a long message"

echo
payload_table "$HOOK" "git commit $NV -m x" 'git commit -m x' "$ARMED"
# The table's refusal column says the hook read the command and refused it;
# which arm refused is this suite's pin, and the armed bypass arm is the one
# that must be reached through the Copilot shape.
run_hook "$ARMED" "$(jq -nc --arg c "git commit $NV -m x" '{toolName:"bash",toolArgs:{command:$c}}')"
assert_eq "$(first_line)" "pre-commit-check: bypass=$NV" "the bypass under toolArgs is named"

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
#
# The unarmed column is the fail-open this split exists to close, and it is the
# guard's primary contract rather than a bypass question: with the separator
# left attached the hook found no commit at all, so a plain `true;git commit`
# ran in a repository nothing armed and nothing checked it. The armed column is
# the control that separating manufactures no bypass, and the word-order row is
# the control that it does not lose the word-order rule.
#
# The last two rows are what `<` and `)` decide on their own; `(` is the member
# with no measured fail-open of its own, since a `(` in front of the git word
# already comes off in the word loop.
both_table '2|2|NOVERIFY|a semicolon in front of the git word|true;git commit NOVERIFY -m x
2|2|-n|an ampersand-redirect glued to the subcommand|git commit&>/dev/null -n
2|2|-n|a redirection glued to the subcommand|git commit>/dev/null -n -m x
2|2|NOVERIFY|an and-list with no spaces|true&&git commit NOVERIFY -m x
2|2|NOVERIFY|an or-list with no spaces|true||git commit NOVERIFY -m x
2|2|NOVERIFY|a pipe with no spaces|true|git commit NOVERIFY -m x
0|2|-|a plain commit behind a separator is still a commit|true;git commit -m x
0|2|-|a backgrounded commit with no bypass|git commit -m x&
0|0|-|a commit word before the git word, across a separator|echo commit;git status
0|2|-|a redirection-in glued to the subcommand|git commit</dev/null -m x
0|2|-|a subshell whose closing paren ends the commit word|(git commit)
'

echo
echo "the two stated limits"

# Reading words rather than shell costs in both directions, and both costs are
# rows so nobody grows a tokenizer back to close either. A word the command
# spells is read wherever it stands, prose included, and quoting spares nothing
# by itself since the substitution runs before any word is looked at; a word the
# shell would assemble is not read at all.
both_table '2|2|NOVERIFY|the flag inside a quoted message|git commit -m \"explain why NOVERIFY is banned\"
0|2|-|a commit word standing beside a git word in prose|git log | grep commit
0|2|-|a commit word inside quoted parentheses|git log --oneline \"(commit)\"
0|2|-|a flag reached through a variable|F=NOVERIFY; git commit $F -m x
'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
