# shellcheck shell=bash
# The grammars the changelog-entries check judges by, kept apart from the scan
# that runs them: what a fragment IS, what an entry IS, and where the record's
# [Unreleased] section starts and stops.
#
# Sourced, never executed.
set -euo pipefail

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
# the continuation bytes subtracted below are what turn bytes back into
# characters. Under a UTF-8 locale the class would match nothing and every
# multibyte entry would count short. The same byte view is what lets CTRL name
# the C0 controls and DEL exactly, which the quoted first line is stripped of
# — an escape sequence, a carriage return or a backspace in a tracked file
# must not reach the reader's terminal through a diagnostic. Tab survives, and
# so do high bytes: they are the UTF-8 an entry is legitimately written in.
GG_ENTRY_AWK='
BEGIN {
  CONT = "[\200-\277]"
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
function chars(s,   n, c) { n = length(s); c = gsub(CONT, "", s); return n - c }
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
  printf "M\t%d\t%s\n", chars(text), first
}
'

# The lines under `## [Unreleased]`, found by structure. A fenced block is
# opened and closed by three or more backticks or tildes (up to three leading
# spaces) and nothing inside one is a heading; a level-1 or level-2 ATX
# heading switches the section on or off, and every other non-blank line
# inside it is content. So a code span or a fenced example naming
# `## [Unreleased]` moves nothing.
GG_UNRELEASED_AWK='
function lead(l,   i) { i = 0; while (i < 3 && substr(l, i + 1, 1) == " ") i++; return i }
function fence_char(l,   i, c, n) {
  i = lead(l); c = substr(l, i + 1, 1)
  if (c != "`" && c != "~") return ""
  n = 0; while (substr(l, i + n + 1, 1) == c) n++
  return (n >= 3) ? c : ""
}
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
  fc = fence_char(line)
  if (fc != "") {
    if (fence == "") fence = fc
    else if (fence == fc) fence = ""
    else if (inside) print line
    next
  }
  if (fence != "") { if (inside) print line; next }
  lvl = heading_level(line)
  if (lvl == 1 || lvl == 2) {
    inside = (lvl == 2 && index(heading_text(line), "[unreleased]") == 1)
    next
  }
  if (inside && line ~ /[^ \t]/) print line
}
'

