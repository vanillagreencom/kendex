# shellcheck shell=bash
# What a changelog IS to this family: where its two scopes live, and the
# grammars each is judged by — what a fragment is, what an entry measures,
# and where the record's [Unreleased] section starts and stops. Kept apart
# from the scans that run them, and shared, so the changelog-entries check and
# the commit-msg lane cannot come to different answers about the same repo.
#
# Sourced, never executed.
set -euo pipefail

# The two scopes, resolved once. Sets GG_CHANGELOG_PATTERNS (space-separated
# fragment globs), GG_CHANGELOG_SHOWN (that list as a reader must type it) and
# GG_CHANGELOG_RECORD (the collated record, empty when that scope is off).
# The caller has cd'd to the repository root and runs under `set -f`.
gg_changelog_scopes() {
  local raw
  raw="$(gg_setting GROWTH_GUARDS_CHANGELOG_PATHS "changelog.d/*/*.md")" || return 1
  # The fragment globs load through lib/configured-paths.sh, the same way
  # every lane scoped by a configured path list loads its own — validation,
  # the empty-list refusal and the matcher all come from there.
  gg_load_path_globs "$raw" changelog GROWTH_GUARDS_CHANGELOG_PATHS || return 1
  GG_CHANGELOG_PATTERNS="$GG_PATH_GLOBS"
  GG_CHANGELOG_SHOWN="$(gg_scrubbed "$GG_CHANGELOG_PATTERNS")"
  raw="$(gg_setting GROWTH_GUARDS_CHANGELOG_RECORD "CHANGELOG.md")" || return 1
  GG_CHANGELOG_RECORD=""
  [ -n "$raw" ] || return 0
  GG_CHANGELOG_RECORD="$(gg_config_path "$raw" changelog-record)" || return 1
  # The two scopes judge by opposite rules — one entry per file against a file
  # of many — so a path in both is a configuration that cannot pass. One
  # judgement, made here, for every lane that reads these settings.
  ! gg_matches_path_glob "$GG_CHANGELOG_RECORD" \
    || gg_config_error "GROWTH_GUARDS_CHANGELOG_RECORD ($(gg_shown "$GG_CHANGELOG_RECORD")) is also matched by GROWTH_GUARDS_CHANGELOG_PATHS — the collated record is not a fragment"
}

# A fragment is one Markdown list item: it opens with a hyphen and a space,
# and every later line indents under it. A second marker or a heading would
# be a second entry, or would end the section it is folded into. The
# complaint, or nothing.
GG_SHAPE_AWK='
BEGIN { empty = "has no entry in it — a fragment is the Markdown list item it becomes" }
{ sub(/\r$/, "") }
/^[[:space:]]*$/ { next }
!seen {
  seen = 1
  if ($0 !~ /^- /) {
    print "does not open with a list marker — a fragment is the Markdown list item it becomes, opening with a hyphen and a space"
    exit
  }
  # A marker with nothing after it is an entry that says nothing, which is
  # the same defect as a file with no marker at all.
  if ($0 !~ /^- [[:space:]]*[^[:space:]]/) { print empty; exit }
  next
}
!/^[ \t]/ {
  print "holds more than the one entry it becomes — every line after the first indents under it"
  exit
}
END { if (!seen) print empty }
'

# One measurement row, "M<TAB>characters<TAB>first line", or "X<TAB>line" for
# text that cannot be measured. A fragment is one list item whose later lines
# all indent under it, so measuring is joining every line and counting what
# comes out — there is no second entry to find a boundary for.
#
# LC_ALL=C is what makes the character count exact: it puts awk on bytes, and
# gg_chars subtracts the continuation bytes to turn bytes back into
# characters. Under a UTF-8 locale its class would match nothing and every
# multibyte entry would count short. The same byte view is what lets CTRL name
# the C0 controls and DEL exactly, which the quoted first line is stripped of
# — an escape sequence, a carriage return or a backspace in a tracked file
# must not reach the reader's terminal through a diagnostic. Tab survives, and
# so do high bytes: they are the UTF-8 an entry is legitimately written in.
GG_ENTRY_AWK="$GG_CHARS_AWK_FN"'
BEGIN {
  CTRL = "[\001-\010\013-\037\177]"
  # Strict UTF-8, spelled out as the byte grammar RFC 3629 defines: the count
  # below is "bytes that are not continuation bytes", which is the character
  # count only while every continuation byte follows a lead byte that claims
  # it. A line of stray continuation bytes would otherwise measure as nothing.
  UTF8 = "^([\001-\177]"
  UTF8 = UTF8 "|[\302-\337][\200-\277]"
  UTF8 = UTF8 "|\340[\240-\277][\200-\277]"
  UTF8 = UTF8 "|[\341-\354][\200-\277][\200-\277]"
  UTF8 = UTF8 "|\355[\200-\237][\200-\277]"
  UTF8 = UTF8 "|[\356-\357][\200-\277][\200-\277]"
  UTF8 = UTF8 "|\360[\220-\277][\200-\277][\200-\277]"
  UTF8 = UTF8 "|[\361-\363][\200-\277][\200-\277][\200-\277]"
  UTF8 = UTF8 "|\364[\200-\217][\200-\277][\200-\277])*$"
}
{ line = $0; sub(/\r$/, "", line) }
line !~ UTF8 { printf "X\t%d\n", NR; bad = 1; exit }
{
  if (first == "" && line ~ /[^ \t]/) first = line
  text = text " " line
}
END {
  if (bad) exit
  gsub(/[ \t]+/, " ", text)
  sub(/^ /, "", text)
  sub(/ $/, "", text)
  gsub(CTRL, "?", first)
  printf "M\t%d\t%s\n", gg_chars(text), first
}
'

# The lines under `## [Unreleased]`, found by structure. A fenced block opens
# on a run of three or more backticks or tildes (up to three leading spaces)
# and closes only on a run of at least that length in the SAME character with
# nothing but whitespace after it, so a three-backtick line inside a
# four-backtick block does not end it. Nothing inside a fence is a heading; a
# level-1 or level-2 ATX heading switches the section on or off, and every
# other line inside it is content — the fence lines included, so an added
# example counts as much as an added bullet. A code span or a fenced example
# naming `## [Unreleased]` therefore moves nothing.
#
# An unterminated fence leaves the parser unable to say where the section
# starts or stops, so it exits 3 rather than reporting a document with no
# [Unreleased] content: a stray ``` above the heading would otherwise make
# every side parse to nothing and every hand-written line read as unchanged.
GG_UNRELEASED_AWK='
function lead(l,   i) { i = 0; while (i < 3 && substr(l, i + 1, 1) == " ") i++; return i }
function heading_level(l,   i, n, c) {
  i = lead(l)
  if (substr(l, i + 1, 1) != "#") return 0
  n = 0; while (substr(l, i + n + 1, 1) == "#") n++
  if (n > 6) return 0
  c = substr(l, i + n + 1, 1)
  return (c == "" || c == " " || c == "\t") ? n : 0
}
function heading_text(l,   i, n, t) {
  i = lead(l); n = 0; while (substr(l, i + n + 1, 1) == "#") n++
  t = substr(l, i + n + 1)
  sub(/^[ \t]+/, "", t); sub(/[ \t]+#+[ \t]*$/, "", t); sub(/[ \t]+$/, "", t)
  return tolower(t)
}
{
  line = $0; sub(/\r$/, "", line)
  i = lead(line)
  c = substr(line, i + 1, 1)
  run = 0
  if (c == "`" || c == "~") { while (substr(line, i + run + 1, 1) == c) run++ }
  if (fence != "") {
    # A closing fence: same character, at least as long, and nothing after it.
    if (c == fence && run >= flen && substr(line, i + run + 1) ~ /^[ \t]*$/) {
      fence = ""
      if (inside) print line
      next
    }
    if (inside) print line
    next
  }
  if (run >= 3) { fence = c; flen = run; if (inside) print line; next }
  lvl = heading_level(line)
  if (lvl == 1 || lvl == 2) {
    inside = (lvl == 2 && index(heading_text(line), "[unreleased]") == 1)
    next
  }
  if (inside && line ~ /[^ \t]/) print line
}
END { if (fence != "") exit 3 }
'
