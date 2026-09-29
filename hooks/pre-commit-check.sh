#!/usr/bin/env bash
# ---
# name: pre-commit-check
# event: PreToolUse
# matcher: Bash
# description: On a git commit, defer to the working directory's armed git hooks — both pre-commit and commit-msg, marked and executable (kendex guard install arms them). Otherwise the commit is refused naming that command: arming is the local act that says a person wants this repository's committed scripts run on their commits, and this hook never runs them on their behalf. Where nothing is armed, a commit is a simple command whose command word is `git`, after any NAME=value assignments, any reserved word bash reads before a command (`! { if then else elif while until do time coproc`), the -p of `time` and any leading redirection, with a later `commit` word; a `commit` word anywhere else, a message, a printf of a note or another program's arguments, is not a commit, but a line of quoted text or of a heredoc body that itself leads with `git` and holds `commit` is read as one. A program that launches git (xargs, parallel, env, sudo, timeout) is not a commit where nothing is armed. The simple commands are the lines of the command once bash's non-whitespace metacharacters (`| & ; ( ) < >`) are turned into separators, the five that end a simple command into newlines and the two that redirect into arrow words; a leading path, backtick or `$(` comes off the git word, and nothing comes off the commit word. A backtick is no separator, so a commit in a backtick substitution behind another word is not a commit where nothing is armed, and a code span in the middle of a line of a note starts no line of its own. Where the hooks are armed, a command holding a `git` word with a later `commit` word is refused when it also holds a word that would skip them: the no-verify flag or a short-option cluster holding that letter, read from that git word to the end of its line where the command holds none of ' " \ ` $ and no process substitution, and to the end of the whole command otherwise, so the flag counts in a git call env, sudo or timeout runs, in a note that spells git and commit, and in a stage the commit pipes into once the command holds quoting, while a -n of another program in front of the git word is not a finding; or a word carrying a core.hooksPath key (an attached -c value, the value after a bare -c, a --config-env, a git config argument, a GIT_CONFIG_* assignment), read wherever it stands in the command, since a config write disarms the hook from a call of its own. Git would skip the commit-msg hook too, and nothing here can check the message. A flag that xargs or parallel reads from a pipe, a heredoc or a file is not seen here, and it reaches git. Gates the working directory only: a commit aimed at another repository is gated by that repository's own armed hook, and by nothing here.
# summary: Makes a commit run the repository's armed git hooks and refuses one carrying a word that skips them. Unarmed, it refuses only a line whose command is git commit.
# safety: Reads no shell. One rewrite runs before the words are read: every metacharacter bash(1) lists that is not whitespace (`| & ; ( ) < >`) becomes a separator, because one left attached hides a word bash would have separated, and `true;git commit -m x` then ran unchecked where nothing was armed. The five that end a simple command become newlines and the two that redirect become arrow words, so each line is read as one simple command; the whitespace ones bash lists are IFS below. Nothing is deleted, so a quote character, a backslash, a line continuation and the braces of a brace expansion all stay in the word. The split reads no quoting, so a separator inside quotes, a substitution or an expansion ends a line here too: a line of quoted text or of a heredoc body that leads with `git` and then holds `commit` reads as a commit, which is refused where nothing is armed. For the same reason the split decides the flag's reach only in a command holding none of ' " \ ` $ and no process substitution; in any other command the flag counts from the commit's git word to the end of the whole command. A word is seen only where the command already spells it, so a bypass the shell would join, unquote or expand into the word is not seen here and reaches git, which then skips its armed hooks. A program that launches git is not a commit where nothing is armed; where the hooks are armed, the flag counts in a git call it runs when the command spells the flag after the git word, and a flag that xargs or parallel reads from a pipe, a heredoc or a file reaches git unseen. A `git` word with a later `commit` word counts for the flag and a core.hooksPath key wherever it stands, a message and a heredoc body included, so a note spelling git, commit and the flag is refused where the hooks are armed. The suite's two columns are where each form is named. Git's own armed hooks are the control, and this hook only decides whether to defer to them. Every refusal opens with `pre-commit-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
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
      echo "  If you did not: this hook reads whitespace-separated words, not shell. The flag counts from a git word with a later commit word to the end of its line, or to the end of the whole command where the command holds quoting, escaping or expansion, a message, a heredoc body and a note included; a core.hooksPath key counts anywhere in such a command. Ways out, cheapest first: for a note, reword it so git, commit and that word are not all words of it; for a commit message, pass it with 'git commit -F <file>', or run the text and the commit as separate calls." >&2
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
#   words inside a simple command, so each becomes an arrow word with a space
#   on either side and the command stays on its line; the commit read skips a
#   leading arrow word with its target. The word list the core.hooksPath rule
#   reads is the same either way, since newline is one of its separators too.
#
# A backtick opens and closes a command substitution but is no separator here:
# as one, a markdown code span in a note or a heredoc body would start a line
# with `git` and read as a commit. A commit in a backtick substitution behind
# another word is not read as one where nothing is armed.
#
# An ampersand or a pipe glued to a redirection arrow redirects rather than
# ends a command, so each such pair becomes a plain arrow first; otherwise
# `2>&1` would cut the commit's call in two.
#
# The split reads no quoting, escaping, substitution or expansion, any of which
# can hide a separator. So the split decides the flag's reach only in a command
# holding none of ' " \ ` $ and no process substitution; in any other command
# the flag's reach runs to the end of the whole command. The suite's trust-gate
# table holds one row per character of the bracket class and per process
# substitution, in order. The commit read takes the split lines either way, so
# a line of quoted text or of a heredoc body that leads with `git` and holds
# `commit` is read as a commit; the suite's stated-limits table holds it.
SPLIT_TRUSTED=1
case "$COMMAND" in *[\'\"\\\`\$]* | *\<\(* | *\>\(*) SPLIT_TRUSTED="" ;; esac
COMMAND=${COMMAND//&>/ > }
COMMAND=${COMMAND//>&/ > }
COMMAND=${COMMAND//<&/ < }
COMMAND=${COMMAND//>\|/ > }
COMMAND=${COMMAND//>/ > }
COMMAND=${COMMAND//</ < }
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
# The rule reads no shell, and it has two reads. The commit read decides the
# refusal where nothing is armed: each line is one simple command, split on
# whitespace, and a line is a commit where its command word is `git` and a
# later word is `commit`. A `commit` word in any other line, a message, a
# printf of a note or the arguments of xargs, env or sudo, is not a commit
# there. The flag read decides the refusal where the hooks are armed: a `git`
# word with a later `commit` word anywhere in a line, or in the whole command
# where the split is not trusted, and the flag is a word from that git word to
# the end of the line or command that is --no-verify or a cluster holding -n.
# So the flag counts in a git call launched by env, sudo or timeout, and a -n
# of tail, sed or xargs in front of the git word is not the flag. A word is
# seen only where the command already spells it, so a bypass the shell would
# join, unquote or expand into the word is not seen here and reaches git,
# which skips its armed hooks. A program that launches git with words from a
# pipe, a heredoc or a file (xargs, parallel) hands it a flag unseen, and
# git's own armed hooks are the control there. Which form falls where is
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

# Whether a word is the no-verify flag or a short cluster holding its letter.
is_flag() { # WORD
  local rest
  case "$1" in
    # git accepts an unambiguous abbreviation, so the prefix is the flag.
    --no-veri*) return 0 ;;
    -[A-Za-z]*)
      # A cluster reads left to right: from the first value-taking option the
      # rest of the word is its value, so `-mnote` is a message and `-nm` is
      # not. git commit's value-taking short options are m, F, c, C and t.
      rest="${1#-}"
      while [ -n "$rest" ]; do
        case "${rest%"${rest#?}"}" in
          [mFcCt]) return 1 ;;
          n) return 0 ;;
        esac
        rest="${rest#?}"
      done
      ;;
  esac
  return 1
}

# Reads one simple command and returns whether it is a commit. The command
# word is the first word that is none of these: a NAME=value assignment, a
# reserved word bash reads before a command, the -p option of `time`, a
# redirection arrow with its target, or a descriptor number in front of an
# arrow. So `X=1 git commit`, `{ git commit; }` and `2>/dev/null git commit`
# are commits and `xargs git commit` is not.
git_commit_call() { # WORD...
  local word prev="" target=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      '<' | '>') target=1 ;;
      *)
        if [ -n "$target" ]; then
          target=""
        else
          case "$1" in
            [A-Za-z_]*=* | '!' | '{' | if | then | else | elif | while | until | do | time | [c]oproc) ;;
            -p) [ "$prev" = time ] || break ;;
            *[!0-9]*) break ;;
            *) [ "${2:-}" = '<' ] || [ "${2:-}" = '>' ] || break ;;
          esac
        fi
        ;;
    esac
    prev=$1
    shift
  done
  [ "$#" -gt 0 ] && is_git_word "$1" || return 1
  shift
  for word in "$@"; do
    [ "$word" != commit ] || return 0
  done
  return 1
}

# Reads the flag in one run of words and returns whether a git word with a
# later commit word stands in it. FOUND is the first flag word from the git
# word the commit follows to the end of the run: each git word before the
# commit starts the reading over, so a -n in front of it is not read; no
# subshell.
flag_read() { # WORD...
  local word git="" reach=""
  FOUND=""
  for word in "$@"; do
    if [ -z "$reach" ]; then
      if is_git_word "$word"; then
        git=1
        FOUND=""
        continue
      fi
      [ -z "$git" ] || [ "$word" != commit ] || reach=1
    fi
    [ -n "$FOUND" ] || ! is_flag "$word" || FOUND="$word"
  done
  [ -n "$reach" ] || FOUND=""
  [ -n "$reach" ]
}

MOVES=""
GIT=""
BROAD=""
for word in "${WORDS[@]}"; do
  # Repository-moving words: the commit may land somewhere this hook never
  # measured. Informational only, and read whether or not a commit is found.
  case "$word" in
    -C | cd | --git-dir* | --work-tree* | GIT_DIR=* | GIT_WORK_TREE=*) MOVES=1 ;;
  esac
  if [ -z "$GIT" ]; then
    is_git_word "$word" && GIT=1
  elif [ -z "$BROAD" ] && [ "$word" = commit ]; then
    BROAD=1
  fi
done

# A command with no git word before a commit word holds no commit either read
# would find.
[ -n "$BROAD" ] || exit 0

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
  [ -n "$COMMIT" ] || ! git_commit_call "${SIMPLE[@]}" || COMMIT=1
  [ -z "$SPLIT_TRUSTED" ] || [ -n "$FLAG" ] || ! flag_read "${SIMPLE[@]}" || FLAG=$FOUND
done
IFS=$' \t\n\r'
set +f
[ -n "$SPLIT_TRUSTED" ] || ! flag_read "${WORDS[@]}" || FLAG=$FOUND

BYPASS=""
for word in "${WORDS[@]}"; do
  case "$word" in
    # A core.hooksPath key switches the armed hook off, so it skips the same
    # two gates the flag does: the premise of this whole hook is that git's
    # armed hook is the judge, and that key is what removes the judge. The
    # key is in the word whatever carries it — an attached -c value, the
    # value word after a bare -c, a --config-env, a `git config` argument, or
    # a GIT_CONFIG_* assignment — so the word is the rule and no option is
    # modelled, and it counts in any line of a command with a git word before
    # a commit word, since a config write disarms the hook from a call of its
    # own. Nothing else about -c is read: `git commit -c HEAD` reuses a
    # message and is not configuration. An include.path pulling in a file
    # that sets the key is not reachable from the word and is not read.
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
# instead, and the refusal names the command that fixes it. Only the commit
# read decides it: a git call the flag read found behind another program, or a
# line of prose, is no commit here.
[ -n "$COMMIT" ] || exit 0
message unarmed "$PWD"
exit 2
