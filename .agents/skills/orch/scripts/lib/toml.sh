# shellcheck shell=bash
# The one reader of a codex `config.toml` for the orch scripts, and the one
# editor of a table inside it.
#
# Two unrelated questions are asked of that file: the agent thread cap
# `spawn-adapter` reports, and the launch directory's trust entry
# lib/lane-launch.sh reads before it starts a lane. A second scanner for the
# second question is a copy of the first whose section, comment and whitespace
# handling drifts from it with nothing saying so, so both ask here.
#
# Not a TOML parser. A table is its header line spelled exactly as the caller
# names it, and a key is a word to the left of the first `=` inside that table.
# That is what both callers ask and what every writer of these files emits: the
# fleet's pre-approval step, the harness answering its own folder-trust
# question, and lane_codex_trust_prepare all write `[projects."<dir>"]` on a
# line of its own. A file carrying the same value as a dotted key or inside an
# inline table answers nothing here, and each caller reads that as the file not
# saying.
#
# Sourced, never run. Bash 3.2-safe, like its callers.

# The awk rule that tracks which table each line belongs to: `cur` is the
# header's text between the brackets, empty above the first header, and
# `header` marks the header line itself so the rule that follows can tell it
# from the table's body. Both verbs below split a file by table and would
# otherwise carry a copy of this each; it is concatenated onto each program
# rather than substituted into it, so every program below stays single-quoted
# and reads as the awk it is.
_TOML_SECTION_RULE='
  /^[[:space:]]*\[/ {
    cur = $0
    sub(/^[[:space:]]*\[/, "", cur); sub(/\][[:space:]]*$/, "", cur)
    header = 1
  }
'

# toml_value FILE SECTION KEY — the value text of KEY inside the table whose
# header reads SECTION, SECTION empty for the keys above the first header, with
# one layer of surrounding quotes removed.
#
# Status 1 for a file that is not there, a table that is not there, a key that
# is not in it, and a key whose value is empty. Those are one answer to every
# caller here: the file does not say, and the caller decides what to do about
# it rather than being handed a value it did not read.
toml_value() { # FILE SECTION KEY
  local file="$1" section="$2" key="$3" value
  [ -f "$file" ] || return 1
  # The key is compared as text either side of the first `=`, never matched as
  # a pattern: a caller's key is a literal word, and reading it as a regex
  # would let one carrying a `.` answer for a neighbouring key.
  value="$(awk -v section="$section" -v key="$key" "$_TOML_SECTION_RULE"'
    {
      if (header) { header = 0; next }
      if (cur != section) next
      line = $0
      sub(/#.*$/, "", line)
      eq = index(line, "=")
      if (eq == 0) next
      k = substr(line, 1, eq - 1)
      sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k)
      if (k != key) next
      v = substr(line, eq + 1)
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      print v
      exit
    }
  ' "$file")" || return 1
  [ -n "$value" ] || return 1
  case "$value" in
    '"'*'"') value="${value#\"}"; value="${value%\"}" ;;
    "'"*"'") value="${value#\'}"; value="${value%\'}" ;;
  esac
  printf '%s\n' "$value"
}

# toml_without_table FILE SECTION — FILE's bytes with SECTION's table removed:
# its header line and every line under it up to the next header.
#
# A caller that wants to STATE a table's contents appends its own after this,
# because a second header for a table the file already declares is not an
# override — it is a duplicate key, which the harness reading the file rejects
# outright. The unparsable file that appending blind would produce is exactly
# what the one input this matters for yields: a launch directory the harness has
# already recorded its own answer for.
toml_without_table() { # FILE SECTION
  [ -f "$1" ] || return 1
  awk -v section="$2" "$_TOML_SECTION_RULE"'
    {
      if (header) { header = 0; drop = (cur == section) }
      if (!drop) print
    }
  ' "$1"
}
