#!/usr/bin/env bash
# Tests for the constructs half of the pre-commit-check contract.
#
# Two classes share the word. A construct the scanner has no rule for — coproc,
# an operator inside a substitution, an append assignment — leaves the words
# standing and takes the word-order rule. The four it names are refused unread
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
unmodelled 'git commit \"--no-veri\\\nfy\" -m x' "a line continuation inside quotes"
unmodelled 'x=$(( 1 << 2 )) && git commit -m x' "a shift inside arithmetic"

# The prerequisite is read off the command with its quote characters removed, so
# a spelling the shell assembles reads as its letters. Both of these are the
# word once the quotes come out, and one of them also spells the git word.
unmodelled "git com''mit \$'--no-verify' -m x" "a quote-split commit word"
unmodelled "git \$'com''mit' --no-verify -m x" "a commit word spelled by the construct"
unmodelled "git status && \$'g''it' commit --no-verify -m x" "a construct spelling the git word"

# The alias key keeps the bare git prerequisite: it defines the commit under
# another name, so no normalizing brings the word back.
unmodelled "git -c alias.c='co' co --allow-empty -m x" "an alias key naming no commit"

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
