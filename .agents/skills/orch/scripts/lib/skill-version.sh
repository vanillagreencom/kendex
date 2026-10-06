#!/usr/bin/env bash
# skill-version.sh — whether a SKILL.md change is its metadata.version line
# alone, the decision item-tier and the kendex repository's tools/guard both
# make. Sourced; it defines the functions below and sets nothing.
#
# drop_metadata_version
#   Copies the SKILL.md on stdin to stdout less its metadata.version line: an
#   indented `version:` key in the frontmatter under the top-level
#   `metadata:` key. The frontmatter opens at a first line of `---` and ends
#   where the catalog's frontmatter reader ends it, at `---` or `...` with
#   optional trailing space, so no body line is read as part of the metadata
#   map. A column-0 comment is no key and leaves the map open.
#
# metadata_version_only OLD NEW
#   Status 0 when the files OLD and NEW match byte for byte, trailing
#   newlines included, once drop_metadata_version drops that line from each.
#   A side that cannot be read is status 1, a change of more than that line.

drop_metadata_version() {
  awk '
    NR == 1 && $0 == "---" { front = 1; print; next }
    front && /^(---|\.\.\.)[[:space:]]*$/ { front = 0 }
    front && /^[^[:space:]#]/ { metadata = ($0 ~ /^metadata:[[:space:]]*$/) }
    front && metadata && /^[[:space:]]+version:/ { next }
    { print }
  '
}

# The trailing `.` keeps the trailing newlines a command substitution strips.
metadata_version_only() { # OLD NEW
  local old new
  old=$(drop_metadata_version <"$1" && echo .) || return 1
  new=$(drop_metadata_version <"$2" && echo .) || return 1
  [ "$old" = "$new" ]
}
