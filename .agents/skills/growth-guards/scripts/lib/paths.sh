# shellcheck shell=bash
# Capturing a path without losing its bytes.
#
# `$(...)` strips every trailing newline from what it captures, and a
# directory name may end in one — it is a legal byte in a filename on every
# system this runs on. So a path captured the ordinary way comes back naming
# a directory that does not exist, and the caller then finds nothing there:
# a sibling gate reported as not installed, a project searched for under a
# name it does not have, a commit passing because the gate that would have
# failed it was never reached.
#
# The whole class fails open, which is why it is closed once here rather
# than argued about per site. kendex closed the same class on its own side
# by reading git's bytes instead of its text.
#
# The idiom: capture with a sentinel `x` so the shell has something to strip
# instead of the newlines, take the sentinel off, then take off exactly the
# ONE newline the command itself added. What is left is the path.
#
# Sourced, never executed.
set -euo pipefail

# A literal newline, for the trim below to name.
GG_NL='
'

# The physical directory a path resolves to, symlinks and `..` settled.
gg_physical() { # DIR
  cd -- "$1" 2>/dev/null && pwd -P
}

# Capture a path-producing command into a variable, bytes intact.
#
# Takes a variable NAME rather than returning, because returning means a
# `$(...)` at the call site and that is the very thing being avoided. The
# command's own failure is the function's: a path that could not be resolved
# leaves the variable empty and returns nonzero, so no caller mistakes it
# for the root directory.
gg_path() { # VAR COMMAND [ARGS...]
  local __name="$1" __raw=""
  shift
  __raw="$("$@" && printf x)" || {
    eval "$__name=''"
    return 1
  }
  __raw="${__raw%x}"
  eval "$__name=\${__raw%\"\$GG_NL\"}"
}

# The same, for git. Every path git answers with — a git dir, a common dir,
# a work tree, a configured hooks path — can end in a newline, because the
# directory it names can.
gg_git_path() { # VAR DIR ARG... — VAR gets git's answer, bytes intact
  local __name="$1" __dir="$2"
  shift 2
  gg_path "$__name" git -C "$__dir" "$@"
}

# Showing a path without losing the line.
#
# The counterpart of the capture above, and the same class from the other
# end. A path keeps every byte it has, so it may carry a newline — which
# ends a message this tool promises is one line, and puts the rest of a
# verdict where a caller reading the first line never sees it — or an ESC,
# which reaches a terminal as control codes rather than as a name.
#
# Both are somebody else's bytes deciding what a message does. %q renders
# any of them on one line, escapes what a terminal would act on, and shows
# an empty value as '' instead of as nothing at all. Every value that is not
# this package's own constant goes through here on its way into a message.
gg_shown() { # VALUE -> the value on one line, safe to print
  printf '%q' "$1"
}
