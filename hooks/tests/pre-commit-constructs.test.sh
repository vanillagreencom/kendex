#!/usr/bin/env bash
# Tests for the constructs half of the pre-commit-check contract.
#
# Two classes share the word. A construct the scanner has no rule for — coproc,
# an operator inside a substitution, an append assignment — leaves the words
# standing and takes the word-order rule. The ones it names are refused unread
# instead, each behind its own prerequisite: a construct whose purpose is hiding
# the commit cannot be gated on seeing one.
set -euo pipefail

# shellcheck source=lib/pre-commit-harness.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/pre-commit-harness.sh"
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

echo "a construct this hook does not model is refused on sight"

# Each of these hides text from the scanner, and each decode added to read one
# invites the next construct. So the construct itself is the answer.
#
# Double-quoted so the apostrophes survive; the $ is escaped so this shell does
# not expand it before the hook reads it as text.
ANSIC="cat <<\$'EOF'\\nbody\\nEOF\\ngit commit -m x"
unmodelled "git -c alias.c='commit $NV' c --allow-empty -m x" "an alias key defining a commit"
unmodelled "git config alias.c 'commit $NV' && git c --allow-empty -m x" "a persisted alias key"
unmodelled "$ANSIC" "ANSI-C quoting"
unmodelled 'x=$(( 1 << 2 )) && git commit -m x' "a shift inside arithmetic"

# The prerequisite takes either answer to where the commit is, and each of these
# has only one of them.
#
# The first two have only the assembled word: the alias value spells the commit
# out of an escape and across a continuation, so no text of the command ever
# holds it. The third has only the text: the scanner reads the shift as a
# heredoc opener, and the body it then skips swallows the commit line bash does
# run, so no live word holds it either. Behind a real heredoc that same body is
# the control — there bash runs nothing in it, and it passes.
unmodelled 'git config alias.c \"com\\\nmit -n\" && git c --allow-empty -m x' "a commit assembled in an alias value"
unmodelled 'git config alias.c com\\mit && git c '"$NV"' -m x' "a commit escaped in an alias value"
unmodelled 'x=$(( 1 << EOF ))\ngit commit '"$NV"' -m x\nEOF\ngit status' "a shift whose body swallows the commit"
both 'cat <<EOF\ngit commit '"$NV"' -m x\nEOF\ngit status' 0 0 "the same body behind a real heredoc"

# The prerequisite is read off the command with its quote characters removed, so
# a spelling the shell assembles reads as its letters. Both of these are the
# word once the quotes come out, and one of them also spells the git word.
unmodelled "git com''mit \$'--no-verify' -m x" "a quote-split commit word"
unmodelled "git \$'com''mit' --no-verify -m x" "a commit word spelled by the construct"
unmodelled "git status && \$'g''it' commit --no-verify -m x" "a construct spelling the git word"

# An alias key carried inline keeps the bare git prerequisite: it renames the
# subcommand of this very invocation, so no normalizing brings the word back.
# It is read off the live words, so a key the shell assembles across a line
# continuation is that key however the text was written, and the same text in a
# heredoc body is no word at all.
unmodelled "git -c alias.c='co' co --allow-empty -m x" "an inline alias key naming no commit"
unmodelled 'git -c alias.c\\\n=com\\\nmit c '"$NV"' -m x' "a key split across a continuation"
unmodelled 'git -c \"ali\\\nas.c=com\\\nmit -n\" c --allow-empty -m x' "a key split inside quotes"
both 'cat <<EOF\ngit -c alias.c=co co\nEOF\ngit status' 0 0 "an alias key in a heredoc body"

# The KEN-870 regression. A trigger fires where the construct can change what
# the command runs, not wherever its text appears. A key written to the config
# runs nothing here — it takes effect on later commands, which arrive as their
# own payloads — so it is judged behind the commit word like any other text, and
# a body hiding the commit in a script it names is out of model exactly as that
# script is. A line continuation inside quotes is joined rather than named, so
# what is judged is the word it assembles: a flag either side of the break is
# that flag, and a message either side of it is prose.
both "git config alias.st status" 0 0 "an alias key written and never run"
both "git config alias.c 'status' && git c" 0 0 "an alias written and used, naming no commit"
both 'git commit \"a\\\nb\"' 0 2 "a continuation inside a message"
both 'git commit \"--no-veri\\\nfy\" -m x' 2 2 "a continuation assembling the flag"
both 'git commit -m \"line one\\nline two\"' 0 2 "a message spanning lines without a backslash"

# The KEN-866 regression. Removing quote characters joins fragments and moves
# nothing else, so a pattern anchored to end-of-line still names no commit.
both "grep -rn 'foo\$' .git/config" 0 0 "an anchored grep over a .git path"
both "git log --oneline | grep 'fix\$'" 0 0 "a read-only log piped into an anchored grep"
both "git status --short | grep 'M\$'" 0 0 "an anchored grep over a status listing"
both "git log --grep='fix\$' | head" 0 0 "an ANSI-C opener inside a log pattern"
both 'git log --grep=\"foo\\\nbar\"' 0 0 "a continued pattern naming no commit"

# Accepted on KEN-866 and pinned so it cannot flip in silence: the pattern
# supplies the word, and no text test can tell it from the subcommand.
unmodelled "git log --oneline | grep 'commit\$'" "an anchored grep for the word commit"

# The controls. A command with none of these parses as before, and one naming
# no git at all is not this gate to judge however it is written.
both 'git commit -m x' 0 2 "an ordinary commit carries no trigger"
both 'git -c core.pager=cat log' 0 0 "a benign -c on a non-commit"
run_hook "$ARMED" "$(payload 'echo $'hi'')" CHAIN_EXIT=0
assert_eq "$rc" "0" "ANSI-C quoting without git is left alone"
run_hook "$ARMED" "$(payload 'x=$(( 1 << 2 ))')" CHAIN_EXIT=0
assert_eq "$rc" "0" "arithmetic without git is left alone"

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

finish
