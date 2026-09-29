#!/usr/bin/env bash
# Tests for the pre-commit-check hook. The hook header's description and
# safety lines are the one statement of what reads as a commit, where the
# no-verify flag and a core.hooksPath key are read, and the trust gate on that
# reach. Each table comment here names only what its rows pin, and the two
# expectation columns are where the armed and unarmed answers differ.
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

echo "a git call with a later commit word is the commit"

# The two characters of the git word's prefix strip that decide a row: a path
# and a leading backtick. The `$` and `(` of the strip class decide none, since
# a `$(` substitution already starts its own line; they keep these rows green
# in a build where that substitution is not there.
both_table '0|2|-|a plain commit|git commit -m test
0|2|-|a bare commit|git commit
0|2|-|a commit on the next line|cargo fmt\ngit commit -m x
0|2|-|an absolute git path|/usr/bin/git commit -m x
0|2|-|a commit inside a command substitution|x=$(git commit -m x)
2|2|NOVERIFY|a backtick-enclosed commit|`git commit NOVERIFY -m x`
0|0|-|no commit word|git status
0|0|-|commit inside a longer word|git log --grep=commit
0|0|-|a commit word before the git word|echo commit && git status
0|2|-|a commit behind an assignment|X=1 git commit
0|2|-|a commit in a brace group|{ git commit -m x; }
0|2|-|a commit as an if condition|if git commit -m x; then :; fi
0|2|-|a negated commit|! git commit -m x
0|2|-|a timed commit with the portable-format option|time -p git commit -m x
0|2|-|a coprocess commit, its keyword a JSON escape for the Bash 3.2 lint|\u0063oproc git commit -m x
0|2|-|a commit behind a leading redirection|>log git commit -m x
0|2|-|a commit behind a leading descriptor redirection|2>/dev/null git commit -m x
0|2|-|a commit behind a leading heredoc|<<EOF git commit -F -\nx\nEOF
2|2|-n|the flag in a then branch|if true; then git commit -n -m x; fi
2|2|-n|the flag in a loop body|for f in a; do git commit -n -m x; done
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
0|0|-|a hooksPath key read with no commit|git config --get core.hooksPath
0|0|-|an environment key with no commit|GIT_CONFIG_COUNT=1 git status
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
echo "the issue's read-only commands pass"

# These rows pin that the read-only commands the issue names pass.
both_table '0|0|-|a read-only pipeline whose -n is grep own|git diff | grep -n x
0|0|-|the commit verb only inside a quoted grep operand|ps aux | grep \"git commit\" | tail -n 5
'

echo
echo "the no-verify flag is read from the git word of the commit"

# The passing rows are a -n of another program beside the commit. The
# refusing rows are the flag in the commit's own git call: behind an
# assignment, a separator, a redirection or a reserved word, and in a git call
# env, command or timeout runs, which the unarmed column does not refuse.
both_table '0|2|-|-n belonging to another program beside the commit|sed -n 1,5p f && git commit -m x
0|2|-|-n beside a commit whose message is quoted|sed -n 1,5p f && git commit -m \"x\"
0|2|-|-n of tail before a commit with a quoted message|tail -n 3 tmp/log; git commit -m \"x\"
0|2|-|-n of bash before an add and a commit from a file|bash -n tools/guard && git add . && git commit -F tmp/msg
0|2|-|-n in a call before a semicolon|sed -n 1p f; git commit -m x
0|2|-|-n in a call before an or-list|sed -n 1p f || git commit -m x
0|2|-|a piped short flag before a later list member|sed -n 1p f | cat && git commit -m x
0|2|-|-n in a git call that is not the commit|git log -n 3 && git commit -m x
0|2|-|-n in a git call that is not the commit, in a quoted command|git log -n 3 && git commit -m \"x\"
0|2|-|-n in a stage the commit pipes into|git commit -m x | tail -n 5
0|2|-|-n beside a commit behind an assignment|X=1 git commit -m x && sed -n 1p f
2|2|-n|the flag in a commit behind an assignment|GIT_DIR=.git git commit -n -m x
2|2|-n|the flag in a commit that pipes into another stage|git commit -n -m x | tail -n 5
2|2|NOVERIFY|the flag behind a separator, in the commit own call|true && git commit NOVERIFY
2|2|-n|the flag behind a repository-moving option|git -C d commit -n
2|2|-n|the flag in a second commit|git commit -m a && git commit -m b -n
2|2|-n|the flag in a first commit before a second|git commit -m a -n && git commit -m b
2|2|-n|the first of two flags is the one named|git commit -n NOVERIFY -m x
2|2|-n|the flag behind a descriptor duplication|git commit -m x 2>&1 -n
2|2|-n|the flag behind an input duplication|git commit -m x 0<&3 -n
2|2|-n|the flag behind a clobbering redirection|git commit -m x >|log -n
2|2|-n|the flag in a brace group|{ git commit -n -m x; }
2|2|NOVERIFY|the flag in an if condition|if git commit NOVERIFY -m x; then :; fi
2|2|-n|the flag behind a negation|! git commit -n -m x
2|0|NOVERIFY|the flag in a git call env runs|env git commit NOVERIFY -m x
2|0|-n|the flag in a git call command runs|command git commit -n -m x
2|0|NOVERIFY|the flag in a git call timeout runs|timeout 60 git commit NOVERIFY -m x
'

echo
echo "the trust gate"

# This table is the one place the trust gate's controls live: one row per
# character of the SPLIT_TRUSTED bracket class and per process substitution, in
# its order, each a form where bash still hands the flag to git commit.
both_table '2|2|-n|a single-quoted separator in the message|git commit -m '"'"'a;b'"'"' -n
2|2|-n|a double-quoted separator in the message|git commit -m \"a;b\" -n
2|2|-n|a line continuation|git commit -m x \\\n -n
2|2|-n|a backtick substitution holding a separator|git commit -m `true;echo x` -n
2|2|-n|a parameter expansion holding a separator|git commit -m ${X:-a;b} -n
2|2|-n|an input process substitution|git commit -F <(echo x) -n
2|2|-n|an output process substitution|git commit -m x > >(cat) -n
'

# More messages a commit really writes with the flag after them, each
# holding a character of the bracket class.
both_table '2|2|-n|a single quote of one kind nested in the other|git commit -m \"'"'"'\" -m '"'"'a;b'"'"' -m \"'"'"'\" -n
2|2|NOVERIFY|escaped double quotes around a separator|git commit -m \"fix \\\"foo; bar\\\"\" NOVERIFY
2|2|-n|legacy arithmetic holding a pipe|git commit -m $[1|2] -n
2|2|NOVERIFY|a conventional header with a scope|git commit -m \"fix(KEN-1): x\" NOVERIFY
2|2|NOVERIFY|a double-quoted semicolon and a space|git commit -m \"fix: a; b\" NOVERIFY
2|2|-n|a single-quoted semicolon and a space|git commit -m '"'"'a; b'"'"' -n
2|2|NOVERIFY|a heredoc message template|git commit -m \"$(cat <<'"'"'EOF'"'"'\nfix: x\nEOF\n)\" NOVERIFY
'

echo
echo "a commit word outside a git call is not a commit"

# Each row spells git and commit where no git call holds the commit: a note,
# a message, a code span, a comment tail, another program's arguments. The last
# four also hold a -n that is not the flag.
both_table '0|0|-|a heredoc body|cat >tmp/note.md <<EOF\nThe hook refused git commit in a note.\nEOF
0|0|-|a quoted heredoc delimiter|cat <<'"'"'EOF'"'"' >tmp/note.md\nPlease run git commit later.\nEOF
0|0|-|a code span in a quoted heredoc note|cat <<'"'"'EOF'"'"' >tmp/note.md\nThe hook refused `git commit` in a heredoc.\nEOF
0|0|-|a code span in a single-quoted body|gh pr comment 1 --body '"'"'Run `git commit` after the fix.'"'"'
0|0|-|a quoted message spelling git commit|notify -m \"run git commit after the fix\"
0|0|-|a printf of a note|printf %s \"git commit was refused\" >tmp/note
0|0|-|a comment tail|ls # git commit
0|0|-|xargs launching git commit|printf %s x | xargs git commit -m x
0|0|-|a commit word standing beside a git word in prose|git log | grep commit
0|0|-|a commit word inside quoted parentheses|git log --oneline \"(commit)\"
0|0|-|git and commit in separate stages, -n of head|git log --oneline | grep commit | head -n 3
0|0|-|git and commit in separate stages, -n of tail|ps aux | grep git | grep commit | tail -n 5
0|0|-|git and commit in separate stages, -n of git log|git log -n 3 | grep commit
0|0|-|the -n of xargs in front of the git word|printf %s x | xargs -n 1 git commit -m x
'

echo
echo "the stated limits"

# Each row is a form where reading words rather than shell gives an answer
# bash would not: a note or a -n of another stage refused, a line of quoted
# text or a heredoc body read as a commit, a commit in a backtick substitution
# behind another word not found where nothing is armed, and a flag the shell
# or another program hands git unseen.
both_table '2|2|NOVERIFY|the flag inside the commit own quoted message|git commit -m \"explain why NOVERIFY is banned\"
2|0|NOVERIFY|a quoted note spelling git commit and the flag|notify -m \"run git commit NOVERIFY after the fix\"
2|0|-n|a heredoc note spelling git commit and the flag|cat >tmp/note.md <<EOF\nPlease run git commit -n later.\nEOF
2|2|-n|-n in a stage a commit with a quoted message pipes into|git commit -m \"x\" | tail -n 5
0|2|-|a flag reached through a variable|F=NOVERIFY; git commit $F -m x
0|2|-|a heredoc body line leading with git commit|cat >tmp/note.md <<EOF\ngit commit -F tmp/msg\nEOF
0|2|-|quoted text with a separator ahead of git commit|echo \"done; git commit next\"
0|0|-|a commit in a backtick substitution behind an assignment|x=`git commit -m x`
2|0|-n|the flag in a backtick substitution behind an assignment|x=`git commit -n -m x`
0|0|-|a commit in a backtick substitution as an argument|echo `git commit -m x`
0|0|-|the flag piped into xargs|printf %s NOVERIFY | xargs git commit -m x
0|0|-|the flag in a heredoc body fed to xargs|xargs git commit -m x <<EOF\n-n\nEOF
0|0|-|the flag in a file parallel reads|printf %s -n >f; parallel -a f git commit -m x
'

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
