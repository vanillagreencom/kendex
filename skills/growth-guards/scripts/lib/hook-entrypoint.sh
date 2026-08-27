# shellcheck shell=bash
# The second shape --check accepts: a hook someone hand-wired under a
# core.hooksPath directory that execs this skill's scripts directly. It is a
# whole-file grammar over a foreign file, which is why it is its own unit —
# nothing here knows what an install looks like, only whether a given file
# runs our entry point when git executes it.
#
# Sourced by install-git-hooks, which owns SCRIPT_DIR and SH_SHEBANG_RE —
# but strict on its own terms rather than on its caller's: a reader of one
# of these functions should not have to go find out which shell options
# were on when the file was read.
set -euo pipefail

# The one shape the stand-down message prescribes for a core.hooksPath

# directory, matched as a WHOLE FILE rather than searched for line by line:
# a POSIX-sh shebang, then exactly one command, and that command is this
# skill's entry point for the hook (optionally through `exec`, optionally
# quoted, arguments allowed). Blank lines and comments are ignored.
#
# A scan that accepted the entry point ANYWHERE executable-looking kept
# finding new ways to be wrong — `if false; then … fi`, an uncalled function
# body, a heredoc whose terminator is indented — each reporting `armed` for a
# clone whose commits git does not gate at all. Deciding reachability needs a
# shell parser, and a verifier that guesses at it fails OPEN, which is the
# one direction this answer must never fail in. So the grammar is closed: a
# hook this function cannot recognize is reported as UNVERIFIABLE by its
# caller, never as armed and never as ungated.
# A shebang that hands the interpreter an option can stop the body running at
# all: `#!/bin/sh -n` syntax-checks and exits 0, so an otherwise perfect hook
# executes no guard and every commit passes. The shared shebang check accepts
# options because a repo's own hooks may legitimately carry them; a hook this
# tool is about to call ARMED may not.
# Canonical directory of a path: symlinked parents resolve, so an install
# reached through `.agents/` or any other link compares equal to itself.
canonical_dir() { # PATH -> physical directory on stdout, nonzero if unreachable
  local d
  d="$(dirname -- "$1")" || return 1
  (cd -- "$d" 2>/dev/null && pwd -P) || return 1
}

# The interpreter a hand-wired hook may run, by FULL PATH. A basename is not
# an identity here either: `#!/tmp/fake/sh` can be a copy of /bin/true, and
# then git runs true, ignores the body, and the hook gates nothing. An `env`
# form resolves through PATH, which is no more knowable, so it is not on the
# list — such a hook is unverifiable rather than armed.
gg_trusted_interpreter() { # SHEBANG-LINE -> 0 trusted
  local rest="$1"
  rest="${rest#\#!}"
  rest="${rest#"${rest%%[![:blank:]]*}"}"
  rest="${rest%"${rest##*[![:blank:]]}"}"
  case "$rest" in
    /bin/sh | /bin/bash | /bin/dash | /bin/ksh | /bin/zsh) ;;
    /usr/bin/sh | /usr/bin/bash | /usr/bin/dash | /usr/bin/ksh | /usr/bin/zsh) ;;
    *) return 1 ;;
  esac
  # On the list is not on the disk. `/bin/dash` and `/bin/ksh` are absent
  # from plenty of hosts, and git answers `cannot exec` for every commit —
  # clean ones included — rather than running the hook.
  [ -f "$rest" ] && [ -x "$rest" ]
}

hook_runs_entry_point() { # HOOK PATH -> 0 yes, 1 no (recognizably), 3 unrecognized
  local hook="$1" path="$2" line="" body="" cmd="" tail="" rest="" cmd_dir="" own_dir="" shebang=""
  local quoting="" seen=0 matched=0 named=0 opaque=0
  [ -r "$path" ] || return 2
  own_dir="$(canonical_dir "$SCRIPT_DIR/$hook")" || return 2
  while IFS= read -r line || [ -n "$line" ]; do
    # Blanks, not all whitespace: the shell separates tokens on blanks, so a
    # line starting with CR runs a command named `\rexec`, not `exec`.
    body="${line%%[![:blank:]]*}"
    body="${line#"$body"}"
    case "$body" in
      "" | "#"*) continue ;;
    esac
    # An executable line, whatever it turns out to be. Counted BEFORE any
    # classification: a line this function cannot read still runs, and one
    # skipped without counting left a later entry point looking like the only
    # command in the file.
    seen=$((seen + 1))
    # `[:cntrl:]` includes TAB, which is an ordinary separator — `exit<TAB>0`
    # is a normal command. Only control characters the shell keeps inside a
    # word make a line unreadable, so tabs are neutralized before the test.
    case "${body//"$GG_HT"/ }" in
      *[[:cntrl:]]*) opaque=1; continue ;;
    esac
    rest="$body"
    case "$rest" in
      exec[[:blank:]]*)
        rest="${rest#exec}"
        rest="${rest#"${rest%%[![:blank:]]*}"}"
        # `exec -a NAME cmd` runs cmd under another argv[0]. The command word
        # is then two tokens further along, and reading the option as the
        # command would report a hook that gates correctly as not gated.
        case "$rest" in
          -*)
            opaque=1
            continue
            ;;
        esac
        ;;
    esac
    # Split off the command word, honouring one layer of quoting so a path
    # containing a space stays one word.
    # `NAME=value cmd` runs cmd with an env prefix, so the command word is
    # further along. Reading the assignment as the command reported a hook
    # that gates as NOT gated, so the shape is unverifiable instead.
    case "$rest" in
      [A-Za-z_]*=*)
        case "${rest%%=*}" in
          *[!A-Za-z0-9_]*) ;;
          *) opaque=1; continue ;;
        esac
        ;;
    esac
    quoting=none
    case "$rest" in
      \"*)
        quoting=double
        cmd="${rest#\"}"
        cmd="${cmd%%\"*}"
        tail="${rest#\"$cmd\"}"
        ;;
      \'*)
        quoting=single
        cmd="${rest#\'}"
        cmd="${cmd%%\'*}"
        tail="${rest#\'$cmd\'}"
        ;;
      *)
        cmd="${rest%%[[:blank:]]*}"
        tail="${rest#"$cmd"}"
        ;;
    esac
    # The word the SHELL runs, not the one written down. A spelling that
    # survives evaluation unchanged is the only one this check can compare
    # against a file on disk: single quotes make everything literal, double
    # quotes still expand $ and backticks and honour backslashes, and an
    # unquoted word additionally globs and expands ~. A checkout path that
    # literally contains `$slot` passed every file test here while /bin/sh
    # ran whatever `slot` pointed at.
    case "$quoting" in
      single) ;;
      double)
        case "$cmd" in
          *'$'* | *'`'* | *'\\'*) opaque=1; continue ;;
        esac
        ;;
      *)
        case "$cmd" in
          *'$'* | *'`'* | *'\\'* | *'*'* | *'?'* | *'['* | *']'* | *'{'* | *'}'* | *'~'*)
            opaque=1
            continue
            ;;
        esac
        ;;
    esac
    # A tail has to be SEPARATED from the command by a real blank. The shell
    # concatenates `"…/commit-msg""$1"` into one word, so accepting it as
    # command-plus-tail describes a hook that names something git cannot run
    # and fails every commit rather than judging it.
    case "$tail" in
      "" | [[:blank:]]*) ;;
      *) continue ;;
    esac
    # A path is not an identity. `growth-guards/scripts/pre-commit` is a
    # NAME, and an executable copy of /bin/true can wear it — passing every
    # file test while gating nothing. The only thing that settles it is
    # WHICH FILE this resolves to, so the candidate is compared against this
    # install's own entry point by physical location.
    case "$cmd" in
      */"$hook") ;;
      *) continue ;;
    esac
    if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then
      continue
    fi
    # A symlinked final component points wherever it likes; the parent may
    # still be a link to the real install, which resolves below.
    if [ -L "$cmd" ]; then
      named=1
      continue
    fi
    cmd_dir="$(canonical_dir "$cmd")" || { named=1; continue; }
    if [ "$cmd_dir" != "$own_dir" ]; then
      continue
    fi
    named=1
    # The command word is the entry point; the TAIL decides whether running
    # it can still fail the commit. `--help` returns 0 without checking
    # anything and `|| true` throws the status away, so both leave the entry
    # point named on a line that gates nothing.
    #
    # The accepted arguments differ PER HOOK, and swapping them does not
    # merely weaken the gate, it breaks it: `pre-commit` takes none and exits
    # 2 on any, so `pre-commit "$1"` fails every commit with "takes no
    # arguments"; `commit-msg` needs git's message-file path, so a bare
    # `commit-msg` reads inherited stdin and rejects every commit — valid
    # ones included — as an empty message. Either way nothing is validated
    # and `armed` would be a false description of both.
    # Blanks only. `[[:space:]]` would also trim a trailing CR or vertical
    # whitespace, which the shell keeps as part of the word — so a CRLF hook
    # would be accepted for a tail the shell never sees.
    tail="${tail#"${tail%%[![:blank:]]*}"}"
    tail="${tail%"${tail##*[![:blank:]]}"}"
    # `?` is a one-character wildcard in this pattern, so an unescaped one
    # also strips `|| exit $#` — which for pre-commit, where git supplies no
    # arguments, is `exit 0` and swallows every failure.
    tail="${tail% || exit \$\?}"
    case "$hook" in
      pre-commit)
        case "$tail" in
          "" | '"$@"') matched=1 ;;
        esac
        ;;
      *)
        case "$tail" in
          '"$1"' | '"$@"') matched=1 ;;
        esac
        ;;
    esac
  done <"$path"
  # The verdict waits for the whole file. Deciding on the first command
  # instead would call a hook that runs `set -e` before the entry point
  # ungated, which is the false-negative mirror of the bug this closes.
  if [ "$seen" -eq 1 ] && [ "$matched" -eq 1 ] && [ "$opaque" -eq 0 ]; then
    return 0
  fi
  # The entry point IS the command and only its argument list is outside the
  # allowlist — a trailing comment, an extra argument. That may well gate;
  # this tool cannot say, so it says so, rather than calling it ungated.
  if [ "$named" -eq 1 ] || [ "$opaque" -eq 1 ]; then
    return 3
  fi
  # Exactly one command, and it is not our entry point at all: recognizable,
  # and recognizably not a guard. Everything else — several commands, or
  # none — is a shape whose reachability this tool does not get to guess at.
  if [ "$seen" -le 1 ]; then
    return 1
  fi
  return 3
}
