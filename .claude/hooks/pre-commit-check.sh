#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: On a git commit, defer to the working directory's armed git hooks — both pre-commit and commit-msg, marked and executable (kendex guard install arms them). Otherwise the commit is refused naming that command: arming is the local act that says a person wants this repository's committed scripts run on their commits, and this hook never runs them on their behalf. Where one is armed, a command carrying a word that would skip it is refused: the no-verify flag, a short-option cluster holding that letter, or a word carrying a core.hooksPath key (an attached -c value, the value after a bare -c, a --config-env, a git config argument, a GIT_CONFIG_* assignment). Git would skip the commit-msg hook too, and nothing here can check the message. A commit is a `git` word with a later `commit` word, both read as whitespace-separated words of the command after quote characters are dropped and redirection operators are turned into spaces, which is what bash would hand git; a leading path, backtick or `$(` comes off the git word, and nothing comes off the commit word. Gates the working directory only: a commit aimed at another repository is gated by that repository's own armed hook, and by nothing here.
# safety: Reads no shell. Two character-for-character rewrites come first, because the word bash hands git is not always the word written: every quote character is dropped and every `<` and `>` becomes a space, so `g''it commit --no-verify` and `git commit>/dev/null -n` are the bypassed commits they will be by the time git sees them. Neither rewrite remembers anything about the character before it, and nothing here tracks a quoted run, a heredoc or a substitution depth. A word is then text between spaces, so `git log | grep 'commit'` counts as a commit, and a bypass written inside a quoted message, a heredoc body or a comment tail is refused as if it were the flag; the refusal says so and names the rewrite. The reverse still holds: a bypass assembled out of anything but quotes and redirections is invisible here, and so is a key reached through an include.path rather than spelled in a word. Git's own armed hooks are the control, and this hook only decides whether to defer to them.
# timeout: 60
# ---

set -euo pipefail

# The marker the growth-guards installer ends every hook line it writes with.
MARKER="# kendex-guards-hook"

# jq is the only reader of the payload, and grep is what reads the marker out of
# a hook file. Without them the command cannot be read, or an armed repository
# cannot be told from an unarmed one, and this hook refuses either way.
if ! command -v jq >/dev/null 2>&1 || ! command -v cat >/dev/null 2>&1 \
  || ! command -v grep >/dev/null 2>&1; then
  echo "pre-commit-check: jq, cat and grep are required to read the hook payload; refusing rather than skipping the guard" >&2
  exit 2
fi

INPUT=$(cat)

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The null tests are spelled out because jq's `//` reads
# `false` as absent, and `false` is not a command either.
if ! COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'if .tool_input.command == null then (if .command == null then "" else .command end)
           else .tool_input.command end
           | if type == "string" then . else error end' 2>/dev/null); then
  echo "pre-commit-check: hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
  exit 2
fi

# Two rewrites before anything is read, because the word bash hands git is not
# always the word written. Bash drops the quote characters when it assembles a
# word, so `g''it commit --no-verify` reaches git as a bypassed commit; and it
# ends a word at a redirection operator, so `git commit>/dev/null -n` does too.
# Both were commits nothing checked, since --no-verify is what switches off the
# hooks this whole design calls the judge.
#
# Each rewrite is one character class and no state: every quote character goes,
# every `<` and `>` becomes a space, and neither line knows what stood before
# the character it is on. That boundary is the point. Quote tracking, heredoc
# terminators and `$(`-depth counting are the tokenizer this hook replaced, and
# it grew back one construct at a time over three issues before it was deleted.
# What is left unseen stays unseen: a bypass assembled through an alias, a
# variable or an include.path is not in any word here, and git's armed hooks
# are what catches it.
COMMAND=${COMMAND//\'/}
COMMAND=${COMMAND//\"/}
COMMAND=${COMMAND//>/ }
COMMAND=${COMMAND//</ }

# The whole rule over the command, and it reads no shell. Split on whitespace,
# then a `git` word with a later `commit` word is the commit and a word that is
# --no-verify or a cluster holding -n is the bypass. Whole words, and quoting
# no longer hides one: `git log | grep 'commit'` is a commit word here, which
# is the cost of the two rewrites above and is paid on purpose.
#
# Nothing else is modelled. Every round that tried named one more construct and
# opened the next hole, and two tokenizers in this class were deleted before
# this one. The trade is stated in the frontmatter and runs both ways: a bypass
# spelled in a commit message is refused as the flag, and a bypass the shell
# assembles out of anything but quotes and redirections is not seen. Git's
# armed hooks are the judge; this hook only decides whether to defer to them.
set -f
IFS=$' \t\n\r'
# shellcheck disable=SC2206
WORDS=($COMMAND)
set +f
# An empty or whitespace-only command names nothing. The count is read rather
# than the array: under `set -u` bash before 4.4 treats `"${WORDS[@]}"` on a
# zero-element array as unset and aborts, while `${#WORDS[@]}` is 0 on every
# version back to 3.2 — so this guard is what keeps the loop below reachable
# only when there is something in it. Measured on 3.2.57, 4.2, 4.3 and 4.4; do
# not "simplify" it into expanding the array first.
[ "${#WORDS[@]}" -gt 0 ] || exit 0

COMMIT=""
GIT=""
MOVES=""
BYPASS=""
for word in "${WORDS[@]}"; do
  # Repository-moving words: the commit may land somewhere this hook never
  # measured. Informational only, and read whether or not a commit is found.
  case "$word" in
    -C | cd | --git-dir* | --work-tree* | GIT_DIR=* | GIT_WORK_TREE=*) MOVES=1 ;;
  esac
  if [ -z "$GIT" ]; then
    # A command name can carry a prefix that is not part of it: a path, an
    # opening backtick, or the `$(` a substitution glues to the word in front
    # of it. Those are the two forms KEN-884 named, and dropping everything
    # through the last of those characters is what makes both a `git` word.
    # The commit word takes no such strip, so `--grep=commit` stays prose.
    [ "${word##*[\`\$\(/]}" = git ] && GIT=1
  elif [ -z "$COMMIT" ] && [ "$word" = commit ]; then
    COMMIT=1
  fi
done

if [ -n "$COMMIT" ]; then
  for word in "${WORDS[@]}"; do
    case "$word" in
      # git accepts an unambiguous abbreviation, so the prefix is the flag.
      --no-veri*) BYPASS="$word"; break ;;
      # A core.hooksPath key switches the armed hook off, so it skips the same
      # two gates the flag does: the premise of this whole hook is that git's
      # armed hook is the judge, and that key is what removes the judge. The
      # key is in the word whatever carries it — an attached -c value, the
      # value word after a bare -c, a --config-env, a `git config` argument, or
      # a GIT_CONFIG_* assignment — so the word is the rule and no option is
      # modelled. Nothing else about -c is read: `git commit -c HEAD` reuses a
      # message and is not configuration. An include.path pulling in a file
      # that sets the key is not reachable from the word and is not read.
      *[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]* | GIT_CONFIG_*) BYPASS="$word"; break ;;
      -[A-Za-z]*)
        # A cluster reads left to right: from the first value-taking option the
        # rest of the word is its value, so `-mnote` is a message and `-nm` is
        # not. git commit's value-taking short options are m, F, c, C and t.
        rest="${word#-}"
        while [ -n "$rest" ]; do
          case "${rest%"${rest#?}"}" in
            [mFcCt]) break ;;
            n) BYPASS="$word"; break ;;
          esac
          rest="${rest#?}"
        done
        [ -n "$BYPASS" ] && break
        ;;
    esac
  done
fi

[ -n "$COMMIT" ] || exit 0

# This lane never follows a repository-moving word: where it cannot defer it
# names the directory it judged and leaves the target to the target's own hook.
elsewhere_notice() {
  [ -z "$MOVES" ] && return 0
  echo "pre-commit-check: the command moves repositories (-C, --git-dir, --work-tree, cd, GIT_DIR, or GIT_WORK_TREE); this hook judged $PWD only — the target repository is gated by its own armed git pre-commit hook, if any (kendex guard install there)" >&2
}

HOOKS_DIR=$(git rev-parse --git-path hooks 2>/dev/null) || {
  elsewhere_notice
  exit 0
}
# Armed is our marker in both hook files, in the directory git reads with
# nothing redirecting it, in files git will actually run — git skips a hook
# without the execute bit silently, so a marker in a file it ignores would
# stand this lane aside for nothing at all.
#
# A `core.hooksPath` set to anything at all is not armed: every finer question
# about the value — is it empty, does it spell this repository's own directory,
# does the file it names reach our scripts — is another way to answer "armed"
# about one that is not, and this lane would rather check a commit twice.
#
# Exit 1 is git for "not set" and the only status meaning unredirected. Git
# prints nothing when it fails either (a broken config exits 128), so the
# status decides and anything unmeasured is not armed.
HOOKS_PATH_STATUS=0
git config --get core.hooksPath >/dev/null 2>&1 || HOOKS_PATH_STATUS=$?
ARMED=""
if [ "$HOOKS_PATH_STATUS" -eq 1 ] \
  && [ -x "$HOOKS_DIR/pre-commit" ] && [ -x "$HOOKS_DIR/commit-msg" ] \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/pre-commit" 2>/dev/null \
  && grep -qF -- "$MARKER" "$HOOKS_DIR/commit-msg" 2>/dev/null; then
  ARMED=1
fi
# An armed hook means git gates the commit; a word sidestepping it is refused.
# The refusal is written for the person who did not mean it. That is the common
# case and the expensive one: this hook reads words, so an honest commit message
# about the flag is refused exactly like the flag, and a refusal that only says
# "no" sends them to read the hook. So it names the word, splits the two cases,
# and gives the rewrite for each.
if [ -n "$ARMED" ]; then
  [ -n "$BYPASS" ] || exit 0
  echo "pre-commit-check: refusing this command. The word '$BYPASS' would skip this repository's armed git hooks, and the commit-msg gate with them, so nothing would check this commit or its message." >&2
  echo "  If you meant it: git runs the installed pre-commit and commit-msg hooks itself, so commit without that word." >&2
  echo "  If you did not: this hook reads whitespace-separated words, not shell, so that word counts wherever it stands, a commit message, a heredoc body and a comment tail included. Three ways out, cheapest first: split the command so the text and the commit are separate calls; pass the message with 'git commit -F <file>'; or reword so it is not a word of its own." >&2
  exit 2
fi
elsewhere_notice

# Nothing here carries our marker, and this lane does not stand in. Arming is
# the one act that says a person wants this repository's committed scripts run
# on their commits, and it is local: git clones no hooks, so running one here
# would put execution behind a checkout nobody armed. The commit is refused
# instead, and the refusal names the command that fixes it.
#
# One message, because the flat rule has one failure: not armed. Which of an
# empty core.hooksPath, a redirect, a foreign hook or half a pair it was is the
# taxonomy that kept answering wrongly; `kendex guard check` does know.
echo "pre-commit-check: this repository's git hooks are not armed by kendex in $PWD, so nothing checks this commit — run 'kendex guard install' (this hook does not run a repository's own scripts on its behalf), 'kendex guard check' says what the package makes of it, or remove this hook" >&2
exit 2
