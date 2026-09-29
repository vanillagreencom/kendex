#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: On a git commit, defer to the working directory's armed git hooks — both pre-commit and commit-msg, marked and executable (kendex guard install arms them). Otherwise the commit is refused naming that command: arming is the local act that says a person wants this repository's committed scripts run on their commits, and this hook never runs them on their behalf. A commit is a simple command whose command word is `git`, after any NAME=value assignments and any reserved word bash reads before a command (`! { if then else elif while until do time`), with a later `commit` word; a `commit` word anywhere else, a message, a heredoc body, a printf of a note or another program's arguments, is not a commit. The simple commands are the lines of the command once bash's non-whitespace metacharacters (`| & ; ( ) < >`) are turned into separators, the five that end a simple command into newlines and the two that redirect into spaces; a leading path, backtick or `$(` comes off the git word, and nothing comes off the commit word. Where the hooks are armed, a commit is refused when a word would skip them: the no-verify flag or a short-option cluster holding that letter, read in the commit's own simple command only, so that flag in another program's call is not a finding; or a word carrying a core.hooksPath key (an attached -c value, the value after a bare -c, a --config-env, a git config argument, a GIT_CONFIG_* assignment), read wherever it stands in the command, since a config write disarms the hook from a call of its own. Git would skip the commit-msg hook too, and nothing here can check the message. A program that launches git (xargs, parallel, env, sudo) is not read as a commit: git's own armed hooks are the control for it, and where they are not armed nothing here refuses it. Gates the working directory only: a commit aimed at another repository is gated by that repository's own armed hook, and by nothing here.
# summary: Makes a commit go through the repository's own git hooks where they are armed, and refuses a commit carrying a word that would skip them. Only a command that runs git commit itself counts, so a note or a message that mentions git commit passes.
# safety: Reads no shell. One rewrite runs before the words are read: every metacharacter bash(1) lists that is not whitespace (`| & ; ( ) < >`) becomes a separator, because one left attached hides a word bash would have separated, and `true;git commit -m x` then ran unchecked where nothing was armed. The five that end a simple command become newlines and the two that redirect become spaces, so each line is read as one simple command; the whitespace ones bash lists are IFS below. Nothing is deleted, so a quote character, a backslash, a line continuation and the braces of a brace expansion all stay in the word. The split reads no quoting, so a separator inside quotes, a substitution or an expansion ends a line here too: a line of quoted text or of a heredoc body that leads with `git` and then holds `commit` reads as a commit, which is refused where nothing is armed, and a flag after such a separator falls outside the commit's line and is not seen. A word is seen only where the command already spells it, so a bypass the shell would join, unquote or expand into the word is not seen here and reaches git, which then skips its armed hooks. A program that launches git (xargs, parallel, env, sudo, a shell reading a heredoc) is not a commit here: git's own armed hooks are the control for it, a flag that program hands git from a pipe, a heredoc or a file skips them unseen, and where nothing is armed the refusal keeps the same narrowed form. A core.hooksPath key counts wherever it stands once the command holds a commit, a message and a heredoc body included. The suite's two columns are where each form is named. Git's own armed hooks are the control, and this hook only decides whether to defer to them. Every refusal opens with `pre-commit-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 60
# ---

set -euo pipefail

# The marker the commit-guards installer ends every hook line it writes with.
MARKER="# kendex-guards-hook"

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses: the keys and values are the fixed set
# hooks/AGENTS.md names, and the English explanation and the rewrites follow on
# later lines. Only the caller decides the status: `judged` is the notice
# beside a command this hook allows, the rest are refusals.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
message() { # KEY VALUE [CAUSE]
  printf 'pre-commit-check: %s=%s\n' "$1" "$2" >&2
  case "$1=$2" in
    missing-tools=*)
      echo "the commands ${2//,/, } are required to read the hook payload and are not on PATH; refusing rather than skipping the guard" >&2
      ;;
    payload=invalid-json)
      echo "the hook payload is not valid JSON, or names a command that is not a string; refusing rather than skipping the guard" >&2
      ;;
    # The bypass refusal is written for the person who did not mean it. That is
    # the common case and the expensive one: this hook reads words, so an honest
    # commit message about the flag is refused exactly like the flag, and a
    # refusal that only says "no" sends them to read the hook. So it names the
    # word, splits the two cases, and gives the rewrite for each.
    bypass=*)
      echo "refusing this command. The word '$2' would skip this repository's armed git hooks, and the commit-msg gate with them, so nothing would check this commit or its message." >&2
      echo "  If you meant it: git runs the installed pre-commit and commit-msg hooks itself, so commit without that word." >&2
      echo "  If you did not: this hook reads whitespace-separated words, not shell. The flag counts anywhere in the commit's own call, its message included, and a core.hooksPath key anywhere in a command that holds a commit, a heredoc body and a comment tail included. Three ways out, cheapest first: split the command so the text and the commit are separate calls; pass the message with 'git commit -F <file>'; or reword so it is not a word of its own." >&2
      ;;
    # One message, because the flat rule has one failure: not armed. Which of an
    # empty core.hooksPath, a redirect, a foreign hook or half a pair it was is
    # the taxonomy that kept answering wrongly; `kendex guard check` does know.
    unarmed=*)
      echo "this repository's git hooks are not armed by kendex in $2, so nothing checks this commit — run 'kendex guard install' (this hook does not run a repository's own scripts on its behalf), 'kendex guard check' says what the package makes of it, or remove this hook" >&2
      ;;
    judged=*)
      echo "the command moves repositories (-C, --git-dir, --work-tree, cd, GIT_DIR, or GIT_WORK_TREE); this hook judged $2 only — the target repository is gated by its own armed git pre-commit hook, if any (kendex guard install there)" >&2
      ;;
  esac
  # The cause a command this hook ran wrote, captured at the site and replayed
  # here: under the keyed line, never ahead of it.
  [ -z "${3:-}" ] || printf '%s\n' "$3" >&2
}

# jq is the only reader of the payload, and grep is what reads the marker out of
# a hook file. Without them the command cannot be read, or an armed repository
# cannot be told from an unarmed one, and this hook refuses either way. The value
# names every one of them the PATH is missing, in the order checked.
MISSING=""
for dependency in jq cat grep; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || { message missing-tools "${MISSING#,}"; exit 2; }

INPUT=$(cat)

# A payload that does not parse, or that names a command which is not a
# string, is refused rather than skipped. An absent command is the empty
# string and passes. The command is read where each harness carries it:
# `tool_input.command` (Claude Code, Codex, Gemini CLI and the Pi carrier), a
# bare `command`, or Copilot's `toolArgs.command`, whose `toolArgs` arrives as
# an object or as one JSON-encoded string. The null tests are spelled out
# because jq's `//` reads `false` as absent, and `false` is not a command
# either.
COMMAND=$(printf '%s' "$INPUT" \
  | jq -r 'def copilot: .toolArgs
             | if . == null then null elif type == "string" then fromjson else . end
             | if . == null then null elif type == "object" then .command else error end;
           if .tool_input.command != null then .tool_input.command
           elif .command != null then .command
           elif copilot != null then copilot
           else "" end
           | if type == "string" then . else error end' 2>/dev/null) ||
  { message payload invalid-json; exit 2; }

# One rewrite before the words are read, and only one. bash(1) defines a
# metacharacter as a character that separates words when unquoted, and lists
# them: | & ; ( ) < > space tab newline. The whitespace ones are IFS below and
# the rest are substituted here, because one left attached hides a word bash
# would have separated, so `true;git` was no git word and `commit&` no commit
# word and the commit ran unchecked where nothing was armed. The substitution
# deletes nothing, and it separates in two grades, because bash separates in
# two grades:
#
#   `| & ; ( )` end one simple command and begin the next, so each becomes a
#   newline and every line below is one simple command. `< >` only separate
#   words inside a simple command, so each becomes a space and the command
#   stays on its line. The word list the core.hooksPath rule reads is the
#   same either way, since newline is one of its separators too.
#
# An ampersand or a pipe glued to a redirection arrow redirects rather than
# ends a command, so each such pair becomes a plain arrow first; otherwise
# `2>&1` would cut the commit's call in two.
#
# The split reads no quoting, escaping, substitution or expansion, so a
# separator inside any of them ends a line too. A line of quoted text or of a
# heredoc body that leads with `git` and holds `commit` is then read as a
# commit, and a flag behind such a separator is cut off from the commit's
# line; the suite's stated-limits table holds both.
COMMAND=${COMMAND//&>/ > }
COMMAND=${COMMAND//>&/ > }
COMMAND=${COMMAND//<&/ < }
COMMAND=${COMMAND//>\|/ > }
COMMAND=${COMMAND//>/ }
COMMAND=${COMMAND//</ }
NEWLINE='
'
COMMAND=${COMMAND//;/$NEWLINE}
COMMAND=${COMMAND//&/$NEWLINE}
COMMAND=${COMMAND//\|/$NEWLINE}
COMMAND=${COMMAND//\(/$NEWLINE}
COMMAND=${COMMAND//\)/$NEWLINE}

# Deleting characters is the other half of word assembly, and this hook does
# none of it. Rewrites that dropped a quote, a backslash, a line continuation
# or a brace answered `g''it commit` and `--no-{verify,x}` at the cost of
# refusing read-only commands whose text happened to hold these words, and they
# are gone. That is the frozen lexical-scanner class: a finding of that shape
# against this file is declined, not patched.
#
# The rule reads no shell. Each line is one simple command, split on
# whitespace. A line is a commit where its command word is `git` and a later
# word is `commit`; the flag is a word of that line that is --no-verify or a
# cluster holding -n. A word is seen only where the command already spells it,
# so a bypass the shell would join, unquote or expand into the word is not
# seen here and reaches git, which skips its armed hooks. A `commit` word in
# any other line, a message, a heredoc body, a printf of a note or the
# arguments of xargs or parallel, is not a commit, and a program that launches
# git is gated by git's own armed hooks alone. Which form falls where is
# pinned in the suite. Git's armed hooks are the judge; this hook only decides
# whether to defer to them.
set -f
IFS=$' \t\n\r'
# shellcheck disable=SC2206
WORDS=($COMMAND)
set +f
# An empty or whitespace-only command names nothing. The count is read rather
# than the array: under `set -u` bash before 4.4 treats `"${WORDS[@]}"` on a
# zero-element array as unset and aborts, while `${#WORDS[@]}` is 0 on every
# version back to 3.2 — so this guard is what keeps the loops below reachable
# only when there is something in them. Measured on 3.2.57, 4.2, 4.3 and 4.4;
# do not "simplify" it into expanding the array first.
[ "${#WORDS[@]}" -gt 0 ] || exit 0

# A command name can carry a prefix that is not part of it: a path, an
# opening backtick, or the `$(` a substitution glues to the word in front of
# it. Dropping everything through the last of those characters makes each a
# `git` word; the commit word takes no strip, so `--grep=commit` is prose.
is_git_word() { # WORD
  [ "${1##*[\`\$\(/]}" = git ]
}

# Reads one simple command. It returns whether the command is a commit and
# sets FOUND to its first no-verify flag word; no subshell. The command word
# is the first word that is neither a NAME=value assignment nor a reserved
# word bash reads before a command, so `X=1 git commit` and `{ git commit; }`
# are commits and `xargs git commit` is not.
git_commit_call() { # WORD...
  local word rest commit=""
  FOUND=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      [A-Za-z_]*=* | '!' | '{' | if | then | else | elif | while | until | do | time) shift ;;
      *) break ;;
    esac
  done
  [ "$#" -gt 0 ] && is_git_word "$1" || return 1
  shift
  for word in "$@"; do
    [ "$word" != commit ] || commit=1
    [ -z "$FOUND" ] || continue
    case "$word" in
      # git accepts an unambiguous abbreviation, so the prefix is the flag.
      --no-veri*) FOUND="$word" ;;
      -[A-Za-z]*)
        # A cluster reads left to right: from the first value-taking option
        # the rest of the word is its value, so `-mnote` is a message and
        # `-nm` is not. git commit's value-taking short options are m, F, c,
        # C and t.
        rest="${word#-}"
        while [ -n "$rest" ]; do
          case "${rest%"${rest#?}"}" in
            [mFcCt]) break ;;
            n) FOUND="$word"; break ;;
          esac
          rest="${rest#?}"
        done
        ;;
    esac
  done
  [ -n "$commit" ]
}

MOVES=""
for word in "${WORDS[@]}"; do
  # Repository-moving words: the commit may land somewhere this hook never
  # measured. Informational only, and read whether or not a commit is found.
  case "$word" in
    -C | cd | --git-dir* | --work-tree* | GIT_DIR=* | GIT_WORK_TREE=*) MOVES=1 ;;
  esac
done

# Lines are split by expansion, not read from a here-string, whose temporary
# file can fail and exit 1, which the harness reads as a pass.
COMMIT=""
FLAG=""
set -f
IFS=$NEWLINE
# shellcheck disable=SC2206
LINES=($COMMAND)
IFS=$' \t\r'
for line in "${LINES[@]}"; do
  # shellcheck disable=SC2206
  SIMPLE=($line)
  [ "${#SIMPLE[@]}" -gt 0 ] || continue
  git_commit_call "${SIMPLE[@]}" || continue
  COMMIT=1
  [ -n "$FLAG" ] || FLAG=$FOUND
done
IFS=$' \t\n\r'
set +f

[ -n "$COMMIT" ] || exit 0

BYPASS=""
for word in "${WORDS[@]}"; do
  case "$word" in
    # A core.hooksPath key switches the armed hook off, so it skips the same
    # two gates the flag does: the premise of this whole hook is that git's
    # armed hook is the judge, and that key is what removes the judge. The
    # key is in the word whatever carries it — an attached -c value, the
    # value word after a bare -c, a --config-env, a `git config` argument, or
    # a GIT_CONFIG_* assignment — so the word is the rule and no option is
    # modelled, and it counts in any line of a command that holds a commit,
    # since a config write disarms the hook from a call of its own. Nothing
    # else about -c is read: `git commit -c HEAD` reuses a message and is not
    # configuration. An include.path pulling in a file that sets the key is
    # not reachable from the word and is not read.
    *[Hh][Oo][Oo][Kk][Ss][Pp][Aa][Tt][Hh]* | GIT_CONFIG_*) BYPASS="$word"; break ;;
  esac
done
[ -n "$BYPASS" ] || BYPASS=$FLAG

# This lane never follows a repository-moving word. Where there is nothing to
# defer to and nothing to refuse — no git directory to read at all — it says
# which directory it judged and leaves the target to the target's own hook.
# Where it refuses, the refusal's own value is that directory.
elsewhere_notice() {
  [ -z "$MOVES" ] && return 0
  message judged "$PWD"
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
if [ -n "$ARMED" ]; then
  [ -n "$BYPASS" ] || exit 0
  message bypass "$BYPASS"
  exit 2
fi
# Nothing here carries our marker, and this lane does not stand in. Arming is
# the one act that says a person wants this repository's committed scripts run
# on their commits, and it is local: git clones no hooks, so running one here
# would put execution behind a checkout nobody armed. The commit is refused
# instead, and the refusal names the command that fixes it.
message unarmed "$PWD"
exit 2
