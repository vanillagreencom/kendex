# shellcheck shell=bash
# What a changelog IS to this family: where its two scopes live, and the
# grammars each is judged by — what a fragment is, where the record's
# [Unreleased] section starts and stops, and which release entries name a
# break or an addition. Kept apart
# from the scans that run them, and shared, so the changelog-entries check and
# the commit-msg lane cannot come to different answers about the same repo.
#
# Sourced, never executed.
set -euo pipefail

# The two scopes, resolved once. Sets GG_CHANGELOG_PATTERNS (space-separated
# fragment globs), GG_CHANGELOG_SHOWN (that list as a reader must type it),
# GG_CHANGELOG_PACKAGES (the package-file globs, empty when packages are off)
# and GG_CHANGELOG_RECORD (the collated record, empty when that scope is off).
# The caller has cd'd to the repository root and runs under `set -f`.
gg_changelog_scopes() {
  local raw
  raw="$(gg_setting COMMIT_GUARDS_CHANGELOG_PATHS "changelog.d/*/*.md")" || return 1
  # The fragment globs load through lib/configured-paths.sh, the same way
  # every lane scoped by a configured path list loads its own — validation,
  # the empty-list refusal and the matcher all come from there.
  gg_load_path_globs "$raw" changelog COMMIT_GUARDS_CHANGELOG_PATHS || return 1
  GG_CHANGELOG_PATTERNS="$GG_PATH_GLOBS"
  GG_CHANGELOG_SHOWN="$(gg_scrubbed "$GG_CHANGELOG_PATTERNS")"
  raw="$(gg_setting COMMIT_GUARDS_CHANGELOG_PACKAGE_PATHS "")" || return 1
  GG_CHANGELOG_PACKAGES="$(gg_config_path_list "$raw" changelog-package)" || return 1
  raw="$(gg_setting COMMIT_GUARDS_CHANGELOG_RECORD "CHANGELOG.md")" || return 1
  GG_CHANGELOG_RECORD=""
  [ -n "$raw" ] || return 0
  GG_CHANGELOG_RECORD="$(gg_config_path "$raw" changelog-record)" || return 1
  # The two scopes judge by opposite rules — one entry per file against a file
  # of many — so a path in both is a configuration that cannot pass. One
  # judgement, made here, for every lane that reads these settings.
  ! gg_matches_path_glob "$GG_CHANGELOG_RECORD" \
    || gg_fail changelog-overlap "$GG_CHANGELOG_RECORD" "COMMIT_GUARDS_CHANGELOG_RECORD ($(gg_shown "$GG_CHANGELOG_RECORD")) is also matched by COMMIT_GUARDS_CHANGELOG_PATHS — the collated record is not a fragment"
}

# A pattern places package fragments when the segment after its glob-free
# root is a bare `*`, the package slot, followed by the section and the name
# alone: changelog.d/*/*/*.md places changelog.d/<package>/<section>/<name>.
# Every other pattern, one globbing deeper in its path included, places the
# repository's own program entries, and so does every pattern while no
# package files are configured. Sets GG_PACKAGE_ROOT.
gg_package_pattern() { # PATTERN — 0 when it has a package slot
  local rest
  [ -n "$GG_CHANGELOG_PACKAGES" ] || return 1
  GG_PACKAGE_ROOT="$(gg_path_glob_root "$1")" || return 1
  rest="${1#"$GG_PACKAGE_ROOT"/}"
  case "$rest" in '*'/*/*) ;; *) return 1 ;; esac
  case "${rest#*/}" in */*/*) return 1 ;; esac
}

# The package a placed fragment names, from its placing pattern's package
# slot. Run after gg_path_glob_section placed PATH; sets GG_FRAGMENT_PACKAGE,
# empty for a program entry.
gg_fragment_package() { # PATH
  local rest
  GG_FRAGMENT_PACKAGE=""
  gg_package_pattern "$GG_PATH_PLACER" || return 0
  rest="${1#"$GG_PACKAGE_ROOT"/}"
  GG_FRAGMENT_PACKAGE="${rest%%/*}"
}

# The package files, one pass over the index records in GG_TMP/files.z into
# GG_TMP/packages.z: five NUL-terminated fields a row, the name, the package
# directory, the mode, the sha and the path. A SKILL.md names its directory
# and versions everything under it; any other file names itself, less its
# extension, and carries no version, so its directory field is empty.
gg_package_files() {
  local rec f name dir rest
  : >"$GG_TMP/packages.z"
  [ -n "$GG_CHANGELOG_PACKAGES" ] || return 0
  while IFS= read -r -d '' rec; do
    f="${rec#*"$GG_TAB"}"
    # shellcheck disable=SC2086
    gg_path_matches "$f" $GG_CHANGELOG_PACKAGES || continue
    case "$f" in
      */SKILL.md) dir="${f%SKILL.md}"; name="${dir%/}"; name="${name##*/}" ;;
      *) dir=""; name="${f##*/}"; name="${name%.*}" ;;
    esac
    rest="${rec#* }"
    printf '%s\0%s\0%s\0%s\0%s\0' "$name" "$dir" "${rec%% *}" "${rest%% *}" "$f" >>"$GG_TMP/packages.z" \
      || gg_fail package-files "$(gg_shown "$f")" "Could not record the package file."
  done <"$GG_TMP/files.z"
}

# NAME's row from GG_TMP/packages.z, in GG_PACKAGE_DIR, _MODE, _SHA and _PATH.
gg_package_row() { # NAME — 0 when a package file declares NAME
  local name
  while IFS= read -r -d '' name && IFS= read -r -d '' GG_PACKAGE_DIR && IFS= read -r -d '' GG_PACKAGE_MODE \
    && IFS= read -r -d '' GG_PACKAGE_SHA && IFS= read -r -d '' GG_PACKAGE_PATH; do
    [ "$name" != "$1" ] || return 0
  done <"$GG_TMP/packages.z"
  return 1
}

GG_VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'

# The version a package file states, on stdout: its frontmatter
# metadata.version, read by lib/skill-roots.sh's gg_skill_id, which the
# caller sources. A file this reads without one is a collection error.
gg_package_version() { # MODE SHA PATH
  local id
  gg_mode_is_regular "$1" || gg_fail version-mode "$(gg_shown "$3"):$1" "A package file must be a regular file."
  gg_read_blob "$2" "$3" version
  id="$(gg_skill_id "$GG_TMP/blob")" || gg_fail version-read "$(gg_shown "$3")" "Expected frontmatter with a name and a metadata.version."
  jq -enr --arg v "${id#*"$GG_NL"}" --arg re "$GG_VERSION_RE" '$v | select(test($re))' 2>"$GG_TMP/dependency.err" \
    || gg_fail_cause version-read "$(gg_shown "$3")" "$GG_TMP/dependency.err" "Expected frontmatter metadata.version in major.minor.patch form."
}

# The record's part for package entries: one `### Packages` heading in a
# release section, a level-4 heading per package beneath it. Its entries are
# the packages' releases, never the program's, so the version check skips it.
GG_PACKAGES_PART="packages"

# A fragment is one Markdown list item: it opens with a hyphen and a space,
# and every later line indents under it. A second marker or a heading would
# be a second entry, or would end the section it is folded into. The
# output enum (empty, marker, continuation), or nothing. changelog-entries
# consumes this internal result and supplies the explanation.
GG_SHAPE_AWK='
BEGIN { empty = "empty" }
{ sub(/\r$/, "") }
/^[[:space:]]*$/ { next }
!seen {
  seen = 1
  if ($0 !~ /^- /) {
    print "marker"
    exit
  }
  # A marker with nothing after it is an entry that says nothing, which is
  # the same defect as a file with no marker at all.
  if ($0 !~ /^- [[:space:]]*[^[:space:]]/) { print empty; exit }
  next
}
!/^[ \t]/ {
  print "continuation"
  exit
}
END { if (!seen) print empty }
'

# The first line of a blob that is not valid UTF-8, or nothing. Strict, as the
# byte grammar RFC 3629 defines it: a run of stray continuation bytes, an
# overlong form, a surrogate encoding and an out-of-range lead byte are each
# bytes no reader of the collated record can decode, and the collator folds a
# fragment in verbatim.
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
# land in $GG_TMP/blob having been proven to be text this family can fold:
# git calls a blob binary when a NUL falls in its leading bytes, and text that
# is not valid UTF-8 cannot be read back from the record. Two scopes reading a
# blob their own way would create two places for one rule.
#
# Binary content returns status 1. The caller reports a fragment violation
# or an unusable collation destination.
gg_changelog_blob() { # SHA LABEL — fills $GG_TMP/blob; 1 = not changelog text
  local sha="$1" label="$2" bad
  gg_read_blob "$sha" "$label" changelog
  ! gg_blob_is_binary "$GG_TMP/blob" "$label" || return 1
  # Every NUL becomes \200 before awk reads a byte. An awk that holds a record
  # as a NUL-terminated C string — the BWK awk macOS ships — otherwise sees a
  # line that stops at its first NUL, and a blob git calls text for having its
  # only NUL past the leading sample would be read as the short prefix
  # instead of refused. \200 is a stray continuation byte, which the grammar
  # below already rejects, so the line reports as the invalid UTF-8 it is.
  if ! bad="$({ LC_ALL=C tr '\000' '\200' <"$GG_TMP/blob" | LC_ALL=C awk "$GG_UTF8_AWK"; } 2>"$GG_TMP/encoding.err")"; then
    gg_fail_cause encoding-read "$label" "$GG_TMP/encoding.err" "could not read $(gg_shown "$label") to check its encoding"
  fi
  if [ -n "$bad" ]; then
    gg_fail encoding-line "$label:$bad" "$(gg_shown "$label") line $bad is not valid UTF-8 — the record cannot carry it"
  fi
}

# The Keep a Changelog sections, and the ONE test for membership in them.
#
# A space-joined list is a set only when the value looked up cannot hold the
# separator. These values can. A section name reaches this off a tracked PATH
# segment or out of a level-3 heading's text, and both may carry spaces, so a
# containment test finds ` added changed ` inside the joined list and reads
# `changelog.d/added changed/x.md` as a section — the judge accepts a fragment
# the collator then has no heading for, and the release stops on it. Compared
# token by token it cannot, whatever the value holds.
#
# The same reasoning is why GG_PATH_ROOTS may keep its containment test in
# lib/configured-paths.sh: those values come out of a space-SEPARATED setting,
# so none of them can hold a space to begin with. What decides the shape of
# the test is where the value came from, not how the list is written.
GG_SECTIONS="added changed deprecated removed fixed security"

gg_is_section() { # NAME — 0 when NAME is exactly one of the sections
  local s
  for s in $GG_SECTIONS; do
    if [ "$s" = "$1" ]; then
      return 0
    fi
  done
  return 1
}

# What the record's `## [Unreleased]` section IS, found by structure. A fenced
# block opens on a run of three or more backticks or tildes (up to three
# leading spaces) and closes only on a run of at least that length in the SAME
# character with nothing but whitespace after it, so a three-backtick line
# inside a four-backtick block does not end it. Nothing inside a fence is a
# heading; a level-1 or level-2 ATX heading switches the section on or off,
# and every other line inside it is content — the fence lines included, so an
# example counts as much as a bullet. A code span or a fenced
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
# The parser emits the pending heading line, section heading lines, and end
# line for collation. A missing section, duplicate section, or unclosed fence
# is a refusal. The collator uses these boundaries without another search.
#
# entry_query=1 is the version check's read instead: one "KIND<TAB>line" row
# per release entry it judges, in file order. KIND is breaking for an item
# opening with a named call-out, and added for an item under the release's
# `### Added` heading, a heading only a level-2 record carries. With
# release_alone=1, a record holding the new version's own section answers
# with that section alone, after a "released<TAB>heading" row: those are the
# entries the release publishes, and pending ones wait for the next release.
# With whole_entry=1 the input is one fragment, whose entry_section names its
# directory. packages_part, GG_PACKAGES_PART, names the part whose entries
# are no release entry of the record's own version.
GG_UNRELEASED_AWK='
BEGIN { if (!release_level) release_level = 2 }
function named_breaking(l) { return l ~ /^- \*\*Breaking:\*\*[ \t]+[^ \t]/ }
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
{
  line = $0; sub(/\r$/, "", line)
  if (whole_entry) {
    # A fragment is one list item, so its first non-blank line is the entry.
    if (opened || line !~ /[^ \t]/) next
    opened = 1
    if (named_breaking(line)) printf "breaking\t%s\n", line
    if (entry_section == "added") printf "added\t%s\n", line
    next
  }
  i = lead(line)
  c = substr(line, i + 1, 1)
  run = 0
  if (c == "`" || c == "~") { while (substr(line, i + run + 1, 1) == c) run++ }
  if (fence != "") {
    # A closing fence: same character, at least as long, and nothing after it.
    if (c == fence && run >= flen && substr(line, i + run + 1) ~ /^[ \t]*$/) fence = ""
    next
  }
  if (run >= 3) { fence = c; flen = run; next }
  lvl = heading_level(line)
  # The version check reads the same headings and fences as collation. Its
  # query accepts a pending section or the section a release just renamed.
  if (entry_query) {
    if (lvl > 0 && lvl <= release_level) {
      text = tolower(heading_text(line))
      pending = (release_level == 2 ? "[unreleased]" : "unreleased")
      released = (release_level == 2 ? "[" release_version "]" : release_version)
      if (lvl == release_level && text != pending) releases++
      scope = ""
      if (lvl == release_level && text == pending) scope = "pending"
      else if (lvl == release_level && releases == 1 && (text == released ||
        (release_level == 2 && release_version != "" && index(text, released " - ") == 1))) {
        scope = "released"
        release_heading = line
      }
      part = ""
    } else if (release_level == 2 && lvl == 3) part = tolower(heading_text(line))
    if (scope == "") next
    if (packages_part != "" && part == packages_part) next
    if (named_breaking(line)) { rows[++count] = "breaking\t" line; row_scope[count] = scope }
    if (part == "added" && line ~ /^- /) { rows[++count] = "added\t" line; row_scope[count] = scope }
    next
  }
  if (lvl == 1 || lvl == 2) {
    if (inside) printf "end\t%d\n", NR
    inside = (lvl == 2 && tolower(heading_text(line)) == "[unreleased]")
    if (inside) {
      seen++
      if (seen == 1) printf "unreleased\t%d\n", NR
    }
    next
  }
  if (!inside) next
  if (lvl == 3) printf "section\t%d\t%s\n", NR, heading_text(line)
}
END {
  if (entry_query) {
    if (fence != "") exit 3
    alone = (release_alone && release_heading != "")
    if (alone) printf "released\t%s\n", release_heading
    for (k = 1; k <= count; k++) if (!alone || row_scope[k] == "released") print rows[k]
    exit
  }
  # A body that bailed lands here too, and its status is the one to keep.
  if (rc) exit rc
  # The duplicate count outranks a later unclosed fence, as the former
  # early exit did, but only after the parser measures every visible heading.
  if (seen > 1) { printf "heading-count\t%d\n", seen; exit 4 }
  # The fence first: it is why the heading below it was never seen, and
  # reporting the missing heading would name the symptom over the cause.
  if (fence != "") exit 3
  if (inside) printf "end\t%d\n", NR + 1
  if (!seen) exit 5
}
'
