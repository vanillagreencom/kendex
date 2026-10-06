#!/usr/bin/env bash
# skill-version.sh — whether a SKILL.md change is its metadata.version line
# alone, the decision item-tier and the kendex repository's tools/guard both
# make. Sourced; it defines the functions below and sets nothing.
#
# drop_metadata_version
#   Copies the SKILL.md on stdin to stdout less each indented `version:` line
#   of its frontmatter's metadata map, the map being the lines under a
#   top-level `metadata:` line, empty after the colon but for whitespace, up
#   to the next line whose first character is neither whitespace nor `#`. The
#   frontmatter opens at a first line that is exactly `---` and closes at a
#   line of `---` or `...` with optional trailing whitespace, the terminator
#   the catalog's frontmatter reader takes, so no body line is read as part
#   of the metadata map. awk ends every line it prints with a newline, a last
#   line that had none included.
#
# metadata_version_only OLD NEW
#   Status 0 when the files OLD and NEW are equal line for line once
#   drop_metadata_version has copied each, extra trailing blank lines
#   included. A missing final newline is not compared, since the copy adds
#   it, and neither is a NUL byte, which bash drops from a command
#   substitution. A side that cannot be read is status 1, as for any other
#   change.

drop_metadata_version() {
  awk '
    NR == 1 && $0 == "---" { front = 1; print; next }
    front && /^(---|\.\.\.)[[:space:]]*$/ { front = 0 }
    front && /^[^[:space:]#]/ { metadata = ($0 ~ /^metadata:[[:space:]]*$/) }
    front && metadata && /^[[:space:]]+version:/ { next }
    { print }
  '
}

# The trailing `.` stops the command substitution stripping trailing newlines,
# so extra trailing blank lines are compared.
metadata_version_only() { # OLD NEW
  local old new
  old=$(drop_metadata_version <"$1" && echo .) || return 1
  new=$(drop_metadata_version <"$2" && echo .) || return 1
  [ "$old" = "$new" ]
}
