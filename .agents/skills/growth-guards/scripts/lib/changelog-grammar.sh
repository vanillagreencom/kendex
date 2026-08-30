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

# The first line of a blob that is not valid UTF-8, or nothing. Strict, as the
# byte grammar RFC 3629 defines it: a run of stray continuation bytes, an
# overlong form, a surrogate encoding and an out-of-range lead byte are each
# text with no character count, and counting one would read a run of bytes as
# almost nothing.
GG_UTF8_AWK='
BEGIN {
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
line !~ UTF8 { print NR; exit }
'

# ONE path into a changelog blob, whichever scope is reading it. The bytes
# land in $GG_TMP/blob having been proven to be text this family can measure:
# git calls a blob binary when a NUL falls in its leading bytes, and text that
# is not valid UTF-8 has no character count to take. Two scopes reading a blob
# their own way is two places for the next rule to be added to one of.
#
# Binary is the caller's to phrase — a fragment is refused, a record cannot be
# compared at all — so it comes back as status 1 rather than a verdict here.
gg_changelog_blob() { # SHA LABEL — fills $GG_TMP/blob; 1 = binary, no verdict
  local sha="$1" label="$2" bad
  gg_read_blob "$sha" "$label" changelog
  ! gg_blob_is_binary "$GG_TMP/blob" "$label" || return 1
  bad="$(LC_ALL=C awk "$GG_UTF8_AWK" <"$GG_TMP/blob")" \
    || gg_collection_error "could not read $(gg_shown "$label") to check its encoding"
  [ -z "$bad" ] \
    || gg_collection_error "$(gg_shown "$label") line $bad is not valid UTF-8 — text with no character count cannot be measured"
}

# One measurement row, "M<TAB>characters<TAB>first line". A fragment is one
# list item whose later lines all indent under it, so measuring is joining
# every line and counting what comes out — there is no second entry to find a
# boundary for. It measures; it validates nothing, because gg_changelog_blob
# has already proven these bytes are text this family can count.
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
}
{
  line = $0; sub(/\r$/, "", line)
  if (first == "" && line ~ /[^ \t]/) first = line
  text = text " " line
}
END {
  gsub(/[ \t]+/, " ", text)
  sub(/^ /, "", text)
  sub(/ $/, "", text)
  gsub(CTRL, "?", first)
  printf "M\t%d\t%s\n", gg_chars(text), first
}
'

# What the record's `## [Unreleased]` section IS, found by structure. A fenced
# block opens on a run of three or more backticks or tildes (up to three
# leading spaces) and closes only on a run of at least that length in the SAME
# character with nothing but whitespace after it, so a three-backtick line
# inside a four-backtick block does not end it. Nothing inside a fence is a
# heading; a level-1 or level-2 ATX heading switches the section on or off,
# and every other line inside it is content — the fence lines included, so an
# added example counts as much as an added bullet. A code span or a fenced
# example naming `## [Unreleased]` therefore moves nothing.
#
# The heading matches on EQUALITY, case-folded, once its leading spaces,
# its hashes and any closing hashes come off. A prefix test would make
# `## [Unreleased] archive` the canonical section, and the collator folds
# fragments into whatever bounds it is handed and then deletes the fragment
# files — entries consumed by a heading nobody meant, and no copy left to
# recover them from. A record with no `## [Unreleased]` heading has no
# section at all, which is what its readers refuse.
#
# Two readers, one grammar. The default emits the section's CONTENT, which is
# what a commit's lines are compared against. `-v emit=bounds` emits where the
# section BEGINS and ENDS instead, as NUL-free records:
#
#   unreleased<TAB>LINE          the heading's own line
#   section<TAB>LINE<TAB>TEXT    a level-3 heading inside it, with its text
#   end<TAB>LINE                 the first line past the section
#
# so a collator splits the file at those numbers rather than searching it for
# a heading again — a second search is a second grammar, and it is the one
# that puts entries under a fenced example.
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
  return t
}
function content(l) { if (inside && emit != "bounds") print l }
{
  line = $0; sub(/\r$/, "", line)
  i = lead(line)
  c = substr(line, i + 1, 1)
  run = 0
  if (c == "`" || c == "~") { while (substr(line, i + run + 1, 1) == c) run++ }
  if (fence != "") {
    # A closing fence: same character, at least as long, and nothing after it.
    if (c == fence && run >= flen && substr(line, i + run + 1) ~ /^[ \t]*$/) fence = ""
    content(line)
    next
  }
  if (run >= 3) { fence = c; flen = run; content(line); next }
  lvl = heading_level(line)
  if (lvl == 1 || lvl == 2) {
    if (inside && emit == "bounds") printf "end\t%d\n", NR
    inside = (lvl == 2 && tolower(heading_text(line)) == "[unreleased]")
    if (inside && emit == "bounds") printf "unreleased\t%d\n", NR
    next
  }
  if (!inside) next
  if (emit == "bounds") {
    if (lvl == 3) printf "section\t%d\t%s\n", NR, heading_text(line)
    next
  }
  if (line ~ /[^ \t]/) print line
}
END {
  if (fence != "") exit 3
  if (inside && emit == "bounds") printf "end\t%d\n", NR + 1
}
'
