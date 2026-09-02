# shellcheck shell=bash
# Which parent a commit will HAVE, for the lane that judges a commit rather
# than an index — `commit-msg`, its one caller: HEAD for an ordinary commit,
# and HEAD's own parent for an amend, which replaces HEAD rather than following
# it. Sourced, never executed; needs lib/common.sh sourced first and the caller
# cd'd to the repository root.
set -euo pipefail

# git tells a commit-msg hook the message and nothing else: no flag, no
# variable, no file saying HEAD is about to be REPLACED rather than followed.
# So the answer lives in one place, the argv of the `git commit` this hook
# descends from, read under two conditions, because the wrong answer is the
# dangerous one — a commit judged against a parent it does not have is excused
# by an entry belonging to a commit it is not amending. GIT_INDEX_FILE must be
# set, since git sets it for the hooks it runs a commit through and its absence
# means a DIRECT run — a person, a test, a script — whose ancestors say nothing
# about what it judges. And the argv must come from the NEAREST git ancestor,
# the command doing the committing; the walk stops there rather than reading a
# `git rebase` further up, answering for something else. Anything unreadable is
# not an amend — a process already gone, eight generations carrying no git, or
# no `/proc` at all, which is every macOS host — which is the judgement this
# lane made before: HEAD, and a refusal the writer clears by staging the
# fragment. `ps` would reach macOS and is deliberately not the fallback,
# because it joins argv with spaces and a message merely CONTAINING `--amend`
# would excuse a commit.
gg_parent_pid() { # PID — its parent's pid on stdout, empty when unreadable
  local ppid=""
  [ -r "/proc/$1/status" ] || return 0
  ppid="$(awk '/^PPid:/ { print $2; exit }' "/proc/$1/status" 2>/dev/null)" || ppid=""
  printf '%s' "$ppid"
}

gg_opt_abbrev() { # ARG NAME — 0 when ARG is `--x…` and NAME begins with it
  # git's parser takes any unambiguous abbreviation, so equality alone reads
  # `--mess` as an unknown token. ARG is quoted in: bytes, never a glob.
  case "$1" in --?*) ;; *) return 1 ;; esac
  case "$2" in "$1"*) return 0 ;; esac
  return 1
}

gg_no_value_opt() { # ARG — 0 when ARG is a `git commit` option taking NO value
  # The whole vocabulary the scan below understands. Every option that takes a
  # value is absent by construction, in every spelling, and absence means "this
  # one swallowed the token behind it" — so an omission costs a refusal the
  # writer clears, never a commit excused by an entry it does not carry. A name
  # added here that git DOES take a value for would fail open: the one thing an
  # edit to this list is read for.
  local name
  case "$1" in
    -[aeinopqsuvzS]) return 0 ;;
  esac
  for name in --all --patch --interactive --include --only --signoff --dry-run \
    --no-signoff --verify --edit --no-edit --no-post-rewrite --quiet --amend \
    --no-amend --allow-empty --allow-empty-message --gpg-sign --no-gpg-sign \
    --verbose --reset-author --untracked-files --pathspec-file-nul; do
    if gg_opt_abbrev "$1" "$name"; then return 0; fi
  done
  return 1
}

gg_argv_is_amend() { # FILE — 0 when the NUL-delimited argv in FILE is an amend
  # Read NUL-delimited, so an argument carrying whitespace or a newline stays
  # ONE argument, and a value the committer chose that happens to spell the flag
  # is not the flag. Rather than name the options whose values to step over — a
  # list git grows, every gap a commit excused wrongly — the scan reads the
  # token IMMEDIATELY BEFORE each `--amend`: a value-taking option consumes the
  # next argument and nothing further, so it is the only token that can swallow
  # it. Dash-prefixed and not a no-value option means it did, refusing `--mess
  # --amend`, `-am --amend` and `--message=…`; anything else never reached, so
  # `-m msg --amend` is the amend it is. `--no-amend` stands OUTSIDE that guard:
  # a missed flag costs a refusal, a missed negation leaves a stale `--amend`
  # standing. The bare `--` stops the scan, and the wrapper's arguments ahead of
  # `commit` are skipped, so `-c` is never read.
  local arg prev="" eaten seen=0 sub=0 amend=1
  while IFS= read -r -d '' arg; do
    if [ "$seen" -eq 0 ]; then seen=1; continue; fi
    if [ "$sub" -eq 0 ]; then
      case "$arg" in commit) sub=1 ;; esac
      continue
    fi
    case "$arg" in --) break ;; esac
    eaten=0
    case "$prev" in -?*) gg_no_value_opt "$prev" || eaten=1 ;; esac
    if gg_opt_abbrev "$arg" --no-amend; then amend=1
    elif [ "$eaten" -eq 0 ] && gg_opt_abbrev "$arg" --amend; then amend=0
    fi
    prev="$arg"
  done <"$1"
  return "$amend"
}

gg_is_amend() { # 0 when this run belongs to a `git commit --amend`
  local pid depth argv0
  [ -n "${GIT_INDEX_FILE:-}" ] || return 1
  pid="${PPID:-}"
  depth=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$depth" -lt 8 ]; do
    depth=$((depth + 1))
    [ -r "/proc/$pid/cmdline" ] || return 1
    argv0=""
    IFS= read -r -d '' argv0 <"/proc/$pid/cmdline" || true
    # Both separators: a Windows git under MSYS carries a backslash path in
    # its own argv, and a name still holding one is not `git`.
    argv0="${argv0##*/}"
    case "${argv0##*\\}" in
      git | git.exe)
        if gg_argv_is_amend "/proc/$pid/cmdline"; then return 0; fi
        return 1
        ;;
    esac
    pid="$(gg_parent_pid "$pid")"
  done
  return 1
}

gg_commit_base() { # sets GG_COMMIT_BASE — the revision --cached diffs against
  GG_COMMIT_BASE=""
  gg_is_amend || return 0
  GG_COMMIT_BASE="$(git rev-parse --verify --quiet HEAD^ 2>/dev/null)" && return 0
  # Amending a repository's first commit: its parent is the empty tree, hashed
  # rather than spelled out so a repository on any object format gets its own.
  GG_COMMIT_BASE="$(git hash-object -t tree /dev/null)" \
    || gg_collection_error "could not name the empty tree — the commit's parent could not be resolved"
}
