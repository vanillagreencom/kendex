# shellcheck shell=bash
# Which parent a commit will HAVE, for the lanes that judge a commit rather
# than an index: HEAD for an ordinary commit, and HEAD's own parent for an
# amend, which replaces HEAD rather than following it. Kept apart from the
# rules that read it, and sourced, never executed.
#
# Needs lib/common.sh sourced first, and runs with the caller cd'd to the
# repository root.
set -euo pipefail

# git tells a commit-msg hook the message and nothing else. It passes no flag,
# exports no variable and leaves no file behind that says HEAD is about to be
# REPLACED rather than followed — prepare-commit-msg is the one hook git tells,
# and this family installs none. So the answer lives in a single place, the
# argv of the `git commit` this hook is a descendant of, and it is read there
# under two conditions, because the wrong answer is the dangerous one: a
# commit judged against a parent it does not have is excused by an entry
# belonging to a commit it is not amending.
#
#   GIT_INDEX_FILE   git sets it for the hooks it runs a commit through, so
#                    its absence means a DIRECT run — a person, a test, a
#                    script — whose ancestors say nothing about what it judges
#   the NEAREST git  git runs a hook as a descendant of the `git commit` doing
#   ancestor         the committing, so the first git process above this one
#                    IS that command. The walk stops at it and never reads a
#                    git further up: a `git rebase` driving the commit would
#                    be answering for something else
#
# Anything unreadable — a kernel with no /proc, a process already gone, eight
# generations carrying no git — is not an amend, which is the judgement this
# lane made before: HEAD, and a refusal the writer clears by staging the
# fragment. The lane widens only where it can prove the parent moved.
gg_parent_pid() { # PID — its parent's pid on stdout, empty when unreadable
  local ppid=""
  [ -r "/proc/$1/status" ] || return 0
  ppid="$(awk '/^PPid:/ { print $2; exit }' "/proc/$1/status" 2>/dev/null)" || ppid=""
  printf '%s' "$ppid"
}

gg_is_amend() { # 0 when this run belongs to a `git commit --amend`
  local pid depth arg argv0 seen amend
  [ -n "${GIT_INDEX_FILE:-}" ] || return 1
  pid="${PPID:-}"
  depth=0
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$depth" -lt 8 ]; do
    depth=$((depth + 1))
    [ -r "/proc/$pid/cmdline" ] || return 1
    argv0=""
    seen=0
    amend=1
    # NUL-delimited, the bytes the kernel holds: an argument carrying a
    # newline stays one argument, and a message whose own text is `--amend`
    # is one argument too, never the flag.
    while IFS= read -r -d '' arg; do
      [ "$seen" -eq 1 ] || argv0="$arg"
      seen=1
      [ "$arg" != "--amend" ] || amend=0
    done <"/proc/$pid/cmdline"
    # Both separators: a Windows git under MSYS carries a backslash path in
    # its own argv, and a name still holding one is not `git`.
    argv0="${argv0##*/}"
    case "${argv0##*\\}" in
      git | git.exe) return "$amend" ;;
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
