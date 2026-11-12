# shellcheck shell=bash
# What the header of a commit message IS. One definition, so the package's
# commit-msg gate and any repo-local lane running beside it judge the same
# line.
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
