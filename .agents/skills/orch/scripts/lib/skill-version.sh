#!/usr/bin/env bash
# skill-version.sh — the one reader of a SKILL.md's metadata.version line,
# shared by item-tier and the kendex repository's tools/guard. Sourced; it
# defines the function below and sets nothing.
#
# drop_metadata_version
#   Copies the SKILL.md on stdin to stdout less its metadata.version line: an
#   indented `version:` key in the frontmatter under the top-level
#   `metadata:` key. The frontmatter opens at a first line of `---` and ends
#   where the catalog's frontmatter reader ends it, at `---` or `...` with
#   optional trailing space, so no body line is read as part of the metadata
#   map. A column-0 comment is no key and leaves the map open.

drop_metadata_version() {
  awk '
    NR == 1 && $0 == "---" { front = 1; print; next }
    front && /^(---|\.\.\.)[[:space:]]*$/ { front = 0 }
    front && /^[^[:space:]#]/ { metadata = ($0 ~ /^metadata:[[:space:]]*$/) }
    front && metadata && /^[[:space:]]+version:/ { next }
    { print }
  '
}
