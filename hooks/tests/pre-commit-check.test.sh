#!/usr/bin/env bash
# Tests for the pre-commit-check hook. Three things decide a verdict: whether
# the command's whitespace-separated words hold a `git` word and a later
# `commit` word, whether the working directory's git hooks are armed, and
# whether a word of that command is --no-verify or a short cluster holding -n.
#
# One rewrite runs first: every metacharacter bash(1) lists that is not
# whitespace (| & ; ( ) < >) becomes a space, so a word bash would have
# separated is separated here too. Nothing is deleted. A word is therefore seen
# only where the command already spells it, so a bypass the shell would join,
# unquote or expand into the word is not seen here and reaches git. The reading
# runs the other way too: a `git` word, a `commit` word and a bypass word the
# split leaves standing each count wherever they stand, a message, a heredoc
# body and a comment tail included. Both directions are pinned below, examples
# included, because a claim about which form falls on which side belongs in a
# row that reds and not in a comment; the two expectation columns are where the
# armed and unarmed answers differ.
#
# HOOK_UNDER_TEST runs this suite against another hook file, which is how the
# must-fail control checks that these assertions can go red.
set -euo pipefail

HOOKS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS_DIR/pre-commit-check.sh}"

# The bypass flag and the installer's marker, both assembled: this repository's
# own hook refuses a command spelling the first out, and a file carrying the
# second reads as a shim.
NV="--no-""verify"
GG_MARK="# kendex-""guards-hook"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT
ERR_FILE="$TMP_ROOT/stderr"
# Anything a fixture's own script writes when something runs it. Nothing
# should: this hook defers or refuses, and never stands in.
RAN_LOG="$TMP_ROOT/ran.log"

# A PATH holding the tools the hook needs and nothing named kendex. No lane of
# this hook may depend on the binary. HOOK_TOOLS widens it for the must-fail
# control, whose hook reaches for tools this one does not.
HOOK_TOOLS="${HOOK_TOOLS:-git grep jq bash cat env printf}"
NO_KENDEX_BIN="$TMP_ROOT/no-kendex-bin"
mkdir -p "$NO_KENDEX_BIN"
for tool in $HOOK_TOOLS; do
  target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$NO_KENDEX_BIN/$tool"
done

run_hook() {
  local dir="$1" payload="$2"
  shift 2
  set +e
  (cd "$dir" && env PATH="$NO_KENDEX_BIN" "$@" bash "$HOOK" <<<"$payload") >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
  log="$(cat "$RAN_LOG" 2>/dev/null || true)"
}

payload() { printf '{"tool_input":{"command":"%s"}}' "$1"; }

assert_eq() {
  if [[ "$1" == "$2" ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}
assert_contains() {
  if [[ "$1" == *"$2"* ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}
assert_not_contains() {
  if [[ "$1" != *"$2"* ]]; then PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected NOT to contain: %s\n        got:      %s\n' "$3" "$2" "$1"; fi
}

# Judge one form in both fixtures at once. The ARMED expectation says whether a
# word of the command reads as a bypass; the UNARMED one is the control proving
# the commit was found at all, since a form the hook never sees passes there too.
both() {
  local form="$1" want_armed="$2" want_unarmed="$3" name="$4"
  run_hook "$ARMED" "$(payload "$form")"
  assert_eq "$rc" "$want_armed" "armed: $name"
  [[ "$want_armed" == 2 ]] && assert_contains "$err" "would skip this repository's armed git hooks" "armed refusal names a bypass: $name"
  assert_eq "$log" "" "armed: nothing of the repository's ran: $name"
  run_hook "$UNARMED" "$(payload "$form")"
  assert_eq "$rc" "$want_unarmed" "unarmed: $name"
  [[ "$want_unarmed" == 2 ]] && assert_contains "$err" "not armed by kendex" "unarmed refusal names the arming: $name"
  assert_eq "$log" "" "unarmed: nothing of the repository's ran: $name"
}

# --- Fixtures ----------------------------------------------------------------
arm() {
  local dir="$1" lane
  for lane in "${@:2}"; do
    printf '#!/bin/sh\nexit 0 %s\n' "$GG_MARK" >"$dir/.git/hooks/$lane"
    chmod +x "$dir/.git/hooks/$lane"
  done
}
new_repo() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir"
  git -C "$dir" init -q
  # A script that announces itself if anything runs it. Nothing may.
  mkdir -p "$dir/.agents/skills/growth-guards/scripts"
  printf '#!/usr/bin/env bash\necho ran >>"%s"\n' "$RAN_LOG" >"$dir/.agents/skills/growth-guards/scripts/pre-commit"
  chmod +x "$dir/.agents/skills/growth-guards/scripts/pre-commit"
  printf '%s' "$dir"
}
UNARMED="$(new_repo unarmed)"
ARMED="$(new_repo armed)"; arm "$ARMED" pre-commit commit-msg
# A hook git will not run: present, execute bit off. Git skips it silently.
DISARMED="$(new_repo disarmed)"; arm "$DISARMED" pre-commit commit-msg
chmod -x "$DISARMED/.git/hooks/pre-commit"
# One lane armed and not the other. Deferring here waives the commit-msg gate.
HALF_ARMED="$(new_repo half-armed)"; arm "$HALF_ARMED" pre-commit
# core.hooksPath set and EMPTY switches hooks off, and git's answer misleads:
# `rev-parse --git-path hooks` reports `./`, so the directory resolves to the
# repository root. This fixture puts an executable pre-commit exactly there.
HOOKS_OFF="$(new_repo hooks-off)"
git -C "$HOOKS_OFF" config core.hooksPath ""
printf '#!/bin/sh\nexit 0\n' >"$HOOKS_OFF/pre-commit"; chmod +x "$HOOKS_OFF/pre-commit"
# Marked and executable, but reached through core.hooksPath: a redirect is not
# armed, whatever it points at.
ARMED_BY_PATH="$(new_repo armed-by-path)"; arm "$ARMED_BY_PATH" pre-commit commit-msg
mkdir -p "$TMP_ROOT/custom-hooks"
cp "$ARMED_BY_PATH/.git/hooks/pre-commit" "$ARMED_BY_PATH/.git/hooks/commit-msg" "$TMP_ROOT/custom-hooks/"
git -C "$ARMED_BY_PATH" config core.hooksPath "$TMP_ROOT/custom-hooks"
NOT_A_REPO="$TMP_ROOT/plain"; mkdir -p "$NOT_A_REPO"
# Everything the hook needs except jq, so the missing-tool lane is measured
# rather than asserted from an unreachable interpreter.
NO_JQ_BIN="$TMP_ROOT/no-jq-bin"
mkdir -p "$NO_JQ_BIN"
for tool in git grep bash cat env printf; do
  target="$(command -v "$tool" 2>/dev/null)" && ln -sf "$target" "$NO_JQ_BIN/$tool"
done

echo "a git word with a later commit word is the commit"

both 'git commit -m test' 0 2 "a plain commit"
both 'git -C /somewhere/else commit -m test' 0 2 "git and commit separated by options"
both 'cargo fmt\ngit commit -m x' 0 2 "a commit on the next line"
both 'sudo git commit -m x' 0 2 "a wrapper in front of git"
both '/usr/bin/git commit -m x' 0 2 "an absolute git path"
# The allow side of the over-refusal shapes pinned further down. Without these
# a change that refused every quoted message, or every command carrying a
# redirection, would still show green on the allow side.
both 'git commit -m \"a quoted message\"' 0 2 "a quoted message with no bypass"
both 'git commit -m x >/dev/null' 0 2 "a redirection after a plain commit"
both 'git status' 0 0 "no commit word"
both 'git log --grep=commit' 0 0 "commit inside a longer word"
both "git log | grep 'commit'" 0 0 "a quoted commit word in an ordinary grep"
both 'git config alias.st status' 0 0 "a config write with no commit"
both 'echo commit && git status' 0 0 "a commit word before the git word"

run_hook "$UNARMED" '{"note":"about to commit with git"}'
assert_eq "$rc" "0" "a payload with no command field is left alone"

# A command that splits into no words at all. On bash before 4.4 expanding a
# zero-element array under `set -u` aborts, so the clean exit is pinned rather
# than assumed; this suite is run against bash 3.2 as well as the host's.
for empty in '' ' ' '   \t  ' '\n\n'; do
  run_hook "$UNARMED" "$(payload "$empty")"
  assert_eq "$rc" "0" "an empty or whitespace-only command exits clean: [$empty]"
  assert_eq "$err" "" "and says nothing: [$empty]"
done

run_hook "$UNARMED" '{"tool_input":{"command":""}}'
assert_eq "$rc" "0" "an empty command string is left alone"

echo
echo "an unreadable payload is refused, never skipped"

run_hook "$UNARMED" '{"tool_input":{"command":123}}'
assert_eq "$rc" "2" "a command that is not a string is refused"
assert_contains "$err" "not valid JSON, or names a command that is not a string" "the refusal names the payload"
assert_eq "$log" "" "nothing ran for the unreadable payload"

run_hook "$UNARMED" '{"tool_input":{"command":"git commit -m x'
assert_eq "$rc" "2" "a command string that never ends is refused"
assert_contains "$err" "not valid JSON" "and takes the same path"

run_hook "$UNARMED" "$(payload 'git commit -m x')" PATH="$NO_JQ_BIN"
assert_eq "$rc" "2" "a PATH without jq refuses rather than skipping the guard"
assert_contains "$err" "jq, cat and grep are required" "and says which tools are missing"

# jq decodes what the payload spells, so an escape spelling `git` is that word.
run_hook "$UNARMED" '{"tool_input":{"command":"\u0067it commit -m x"}}'
assert_eq "$rc" "2" "a \\u escape spelling git is decoded and judged"
assert_contains "$err" "not armed by kendex" "and reaches the ordinary refusal"

echo
echo "an armed repository gates its own commit"

run_hook "$ARMED" "$(payload 'git commit -m test')"
assert_eq "$rc" "0" "an armed .git/hooks pair gates the commit itself"
assert_eq "$log" "" "no second validation beside an armed hook"

for fixture in "$DISARMED" "$HALF_ARMED" "$HOOKS_OFF" "$ARMED_BY_PATH"; do
  run_hook "$fixture" "$(payload 'git commit -m test')"
  assert_eq "$rc" "2" "not armed: $(basename "$fixture")"
  assert_contains "$err" "not armed by kendex" "and the refusal says so: $(basename "$fixture")"
  assert_eq "$log" "" "and nothing of the repository's ran: $(basename "$fixture")"
done

run_hook "$UNARMED" "$(payload 'git commit -m test')"
assert_contains "$err" "kendex guard install" "the unarmed refusal names the command that fixes it"
assert_contains "$err" "kendex guard check" "and the one that explains it"

echo
echo "a bypass of the armed hooks is refused"

both "git commit $NV -m x" 2 2 "the flag"
both 'git commit --no-veri -m x' 2 2 "an unambiguous abbreviation"
both 'git commit -n -m x' 2 2 "the short flag"
both 'git commit -anm x' 2 2 "a cluster holding n"
both 'git commit -nm msg' 2 2 "n before the value-taking letter"
both 'git commit -am x' 0 2 "a cluster without n still defers"
both 'git commit -mnote' 0 2 "an attached message containing n"
both 'git commit -mfixc '"$NV" 2 2 "a value-taking letter does not swallow the flag behind it"

run_hook "$ARMED" "$(payload "git commit $NV -m x")"
assert_contains "$err" "The word '--no-verify' would skip" "the refusal names the flag it saw"
run_hook "$ARMED" "$(payload 'git commit -nm msg')"
assert_contains "$err" "The word '-nm' would skip" "and names the cluster carrying it"
assert_contains "$err" "reads whitespace-separated words, not shell" "the refusal says why text counts"
assert_contains "$err" "split the command so the text and the commit are separate calls" "and gives the cheapest rewrite"
assert_contains "$err" "git commit -F <file>" "and the one for a long message"
assert_contains "$err" "commit without that word" "and what to do when the flag was meant"

echo
echo "a config key that switches the armed hook off is a bypass"

# The premise of this hook is that git's armed hook judges the commit. A
# core.hooksPath key removes the judge, so it skips the same two gates the
# flag does. The key is read off the word, whatever option carries it, and
# these are the forms main refuses today — the must-fail material for the
# three lines that catch them.
both 'git -c core.hooksPath=/dev/null commit -m x' 2 2 "a -c key and its value"
both 'git -ccore.hooksPath=/dev/null commit -m x' 2 2 "an attached -c key"
both 'git -c core.hookspath=/dev/null commit -m x' 2 2 "the key in another case"
both 'git --config-env=core.hooksPath=HP commit -m x' 2 2 "a --config-env key"
both 'git config --local core.hooksPath /dev/null && git commit -m x' 2 2 "a config write"
both 'sudo -u dev git config core.hooksPath /dev/null && git commit -m x' 2 2 "a wrapped config write"
both '/usr/bin/env -i git -c core.hooksPath=/dev/null commit -m x' 2 2 "a key behind a wrapper"
both 'GIT_CONFIG_KEY_0=Core.HooksPath GIT_CONFIG_VALUE_0=/dev/null git commit -m x' 2 2 "an environment key"
both 'GIT_CONFIG_COUNT=1 git commit -m x' 2 2 "the environment count alone"

run_hook "$ARMED" "$(payload 'git -ccore.hooksPath=/dev/null commit -m x')"
assert_contains "$err" "'-ccore.hooksPath=/dev/null' would skip" "the refusal names the whole word carrying the key"

# Not configuration, and pinned so the rule stays about the key rather than
# about -c. `git commit -c HEAD` reuses another commit's message.
both 'git commit -c HEAD --reset-author' 0 2 "-c reusing a message is not a key"
both 'git -C /tmp -c user.name=x commit -m y' 0 2 "a -c key that is not the hooks path"

echo
echo "the hook gates its working directory only"

run_hook "$ARMED" "$(payload "git -C $UNARMED commit -m x")"
assert_eq "$rc" "0" "an armed cwd defers whatever the commit is aimed at"
run_hook "$UNARMED" "$(payload "git -C $ARMED commit -m x")"
assert_eq "$rc" "2" "an unarmed cwd judges itself whatever the target"
assert_contains "$err" "judged $UNARMED only" "and the notice names the directory it judged"
run_hook "$NOT_A_REPO" "$(payload "git -C $UNARMED commit -m x")"
assert_eq "$rc" "0" "a non-repository cwd gates nothing"
assert_contains "$err" "moves repositories" "and says the target is elsewhere"
run_hook "$UNARMED" "$(payload 'git commit -m x')"
assert_not_contains "$err" "moves repositories" "no notice for a commit in place"
for form in 'cd sub && git commit -m x' 'GIT_DIR=/e/.git git commit -m x' 'GIT_WORK_TREE=/e git commit -m x'; do
  run_hook "$UNARMED" "$(payload "$form")"
  assert_contains "$err" "moves repositories" "a repository-moving word is named: $form"
done

echo
echo "a substitution prefix does not hide the git word (KEN-884)"

# The two forms the tokenizer this replaced read as one inert word each, so an
# armed repository accepted the commit the hook exists to stop. Reading words
# rather than shell, the prefix simply comes off the git word.
both '`git commit '"$NV"' -m x`' 2 2 "a backtick-enclosed commit"
both 'x=$(git commit '"$NV"' -m x)' 2 2 "a commit inside a command substitution"
both '`git commit -m x`' 0 2 "the backtick form with no bypass"
both 'x=$(git commit -m x)' 0 2 "the substitution form with no bypass"

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
both '(git commit -m x)' 0 2 "a subshell with no bypass"
both 'git commit -m x&' 0 2 "a backgrounded commit with no bypass"
both 'echo commit;git status' 0 0 "a commit word before the git word, across a separator"

# A row for every substitution the rows above leave undecided, because a class
# is only a class where each member is measured: delete one line of the seven
# and something here must go red. The rows above answer `>`, `;`, `&` and `|`;
# these two are what `<` and `)` decide on their own. `(` is the member with no
# measured fail-open of its own, since a `(` in front of the git word already
# comes off in the word loop, so what it decides sits on the over-refusal side
# and its rows are in the trade section with the rest of that cost.
both 'git commit</dev/null -m x' 0 2 "a redirection-in glued to the subcommand"
both '(git commit)' 0 2 "a subshell whose closing paren ends the commit word"

echo
echo "the split is not pathname expansion"

# `set -f` around the word split is the only thing keeping the command's text
# from being matched against the working directory. Without it a repository
# holding a file named for the flag turns an ordinary glob into a bypass word,
# which is this hook reading a word no shell handed it. The decoys get their
# own fixture so no other form here is judged against them.
GLOB="$(new_repo glob)"; arm "$GLOB" pre-commit commit-msg
: >"$GLOB/$NV"
: >"$GLOB/commit"
run_hook "$GLOB" "$(payload 'git commit -m x *')"
assert_eq "$rc" "0" "a glob is not expanded against a decoy named for the flag"
assert_eq "$log" "" "nothing of the repository's ran for the glob"

echo
echo "the trade: text that reads as a bypass is refused"

# The hook reads no shell, so a flag spelled inside a message, a heredoc body or
# a comment tail is a word like any other, and so is a `commit` word the split
# leaves standing beside a `git` word. Pinned so the refusal stays a stated
# limit rather than a surprise, and so nobody grows a tokenizer back to fix it.
#
# Quoting spares nothing by itself. The metacharacters are substituted before
# any word is looked at, so one standing inside the quotes splits the quote off
# the word it was protecting. The quoted `commit` up in the first section
# survives only because no metacharacter stands in it, and the quoted rows
# below are ordinary read-only commands where one does. They are the measured
# cost of the split rather than an exception to a rule about quotes, which is
# why they are rows and not a sentence.
both 'git commit -m \"explain why '"$NV"' is banned\"' 2 2 "the flag inside a quoted message"
both 'git commit -m \"prose mentioning -n inside\"' 2 2 "-n inside a quoted message"
both 'git commit -m x  # never '"$NV" 2 2 "the flag in a comment tail"
both 'cat <<EOF > n.md\nrun cat -n on the file\nEOF\ngit commit -m note' 2 2 "-n in a heredoc body"
both 'git log | grep commit' 0 2 "an unquoted commit word in an ordinary grep"
both 'git log --oneline \"(commit)\"' 0 2 "a commit word inside quoted parentheses"
both "git log --oneline | grep 'fix(commit)'" 0 2 "a conventional-commit scope grep"
both 'git log --grep=\"<commit>\"' 0 2 "a commit placeholder in angle brackets"
both 'echo \"usage: git cherry-pick <commit>\"' 0 2 "a usage line naming a commit placeholder"

echo
echo "the forms this hook does not see"

# Where the model stops. A bypass is seen only where a whitespace-separated
# word already spells it, so anything the shell would join, unquote or expand
# into the word is invisible here. Every form below reaches git as the bypass
# it spells, as a flag word bash assembles or, in the last row, as a config key
# git reads out of a file, so where the hooks are armed they are switched off
# and nothing checks that commit. The unarmed column is not the same answer and
# is why it is a column: where the `git` and `commit` words are themselves in
# the command the commit is still refused, and only the rows that hide one of
# them go through in both. That is the stated limit and not a gap to close: the
# character deletions that once reached the first three groups refused
# read-only commands whose text held these words, and they are the frozen
# lexical-scanner class. Pinned so the limit is what the suite enforces, and
# every expectation here was measured by running the hook.

# Quoting, which can hide the git word, the commit word or the flag.
both 'g'"''"'it commit '"$NV"' -m x' 0 0 "quotes inside the git word"
both 'git \"commit\" '"$NV" 0 0 "a quoted subcommand"
both '\"git\" commit '"$NV" 0 0 "a quoted command word"
both 'git commit \"'"$NV"'\" -m x' 0 2 "a quoted flag"

# A backslash and a line continuation, both of which bash removes and this
# hook keeps.
both 'g\\it commit '"$NV"' -m x' 0 0 "a backslash inside the git word"
both 'git com\\mit '"$NV"' -m x' 0 0 "a backslash inside the subcommand"
both 'git commit --no-ver\\ify -m x' 0 2 "a backslash inside the flag"
both 'git com\\\nmit '"$NV"' -m x' 0 0 "a line continuation inside the subcommand"
both 'git commit --no-ver\\\nify -m x' 0 2 "a line continuation inside the flag"

# A brace expansion, which bash joins to the word around it.
both 'git commit --no-{verify,x} -m x' 0 2 "a brace expansion assembling the flag"

# Expansion, the far side of the same boundary: the characters are not in the
# command at all, so no rewrite over characters that are present could reach
# these however far it went.
both "git commit \$'\\\\x2d\\\\x6e' -m x" 0 2 "ANSI-C quoting spelling the short flag"
# shellcheck disable=SC2016
both 'F='"$NV"'; git commit $F -m x' 0 2 "a flag reached through a variable"
both 'git -cinclude.path=/tmp/c commit -m x' 0 2 "a key reached through an include.path"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
