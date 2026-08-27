# shellcheck shell=bash
# What the header of a commit message IS, and which headers git wrote itself.
# One definition, so the package's commit-msg gate and any repo-local lane
# running beside it judge the same line and stand aside for the same set.
#
# Sourced, never executed.
set -euo pipefail

# The first line that is neither blank nor a '#' comment — git strips comment
# lines before recording the message, so the header is rarely line 1. Empty
# when the message carries no content at all.
gg_commit_header() { # MESSAGE-TEXT — sets GG_COMMIT_HEADER
  local ln
  GG_COMMIT_HEADER=""
  while IFS= read -r ln || [ -n "$ln" ]; do
    ln="${ln%$'\r'}"
    case "$ln" in
      "" | "#"*) continue ;;
    esac
    GG_COMMIT_HEADER="$ln"
    return 0
  done <<EOF
$1
EOF
}

# Headers git writes itself. Nobody chose their shape or their length, so
# every rule over a hand-written header stands aside for all of them.
gg_git_generated_header() { # HEADER -> 0 when git wrote it
  case "$1" in
    "Merge "* | "Revert "* | "Reapply "* | "fixup! "* | "squash! "* | "amend! "*) return 0 ;;
  esac
  return 1
}
