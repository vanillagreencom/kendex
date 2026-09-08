# shellcheck shell=bash
# Validate the staged destination before collation writes and deletes files.
# Ordinary fragment checks do not read the combined release notes.
# Needs common.sh and changelog-grammar.sh.

GG_RECORD_WHY=""
GG_RECORD_KEY=""
GG_RECORD_VALUE=""
GG_RECORD_HARD=0
# Where the accepted section is, kept for the collation that folds into it:
# the heading's own line, the first line past the section (0 when the file
# ends inside it), and one `LINE<TAB>section` row per level-3 heading in it.
GG_RECORD_START=0
GG_RECORD_END=0
GG_RECORD_SECLINES=""
gg_record_accepts() { # PARSED-FILE — 0 when the copy is a record this guard accepts
  local file="$1" rc=0 kind a b low count=0
  GG_RECORD_WHY=""
  GG_RECORD_KEY=""
  GG_RECORD_VALUE=""
  GG_RECORD_HARD=0
  GG_RECORD_START=0
  GG_RECORD_END=0
  GG_RECORD_SECLINES=""
  LC_ALL=C awk "$GG_UNRELEASED_AWK" <"$file" >"$GG_TMP/bounds" || rc=$?
  case "$rc" in
    0) : ;;
    3)
      GG_RECORD_WHY="leaves a code fence unclosed — the [Unreleased] section cannot be located"
      GG_RECORD_KEY=record-fence
      GG_RECORD_VALUE="$RECORD:unclosed"
      GG_RECORD_HARD=1
      return 1
      ;;
    4)
      while IFS="$GG_TAB" read -r kind a b; do
        [ "$kind" != heading-count ] || count="$a"
      done <"$GG_TMP/bounds"
      GG_RECORD_WHY="carries more than one '## [Unreleased]' heading — which one is the section cannot be decided"
      GG_RECORD_KEY=record-heading-count
      GG_RECORD_VALUE="$RECORD:$count"
      GG_RECORD_HARD=1
      return 1
      ;;
    5)
      GG_RECORD_WHY="carries no '## [Unreleased]' heading"
      GG_RECORD_KEY=record-heading
      GG_RECORD_VALUE="$RECORD:missing"
      return 1
      ;;
    *)
      GG_RECORD_WHY="could not be read (awk exit $rc) — the [Unreleased] section cannot be located"
      GG_RECORD_KEY=record-parse
      GG_RECORD_VALUE="$RECORD:$rc"
      GG_RECORD_HARD=1
      return 1
      ;;
  esac
  while IFS="$GG_TAB" read -r kind a b; do
    case "$kind" in
      unreleased) GG_RECORD_START="$a" ;;
      end) GG_RECORD_END="$a" ;;
      section)
        low="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
        # Heading TEXT, so it may hold anything a line holds.
        if ! gg_is_section "$low"; then
          GG_RECORD_WHY="names '$(gg_scrubbed "$b")' under [Unreleased], which is not a Keep a Changelog section"
          GG_RECORD_KEY=record-section
          GG_RECORD_VALUE="$RECORD:$b"
          return 1
        fi
        # Line numbers, never a heading to search for again: lib/changelog-collate.sh
        # splits the record at these, rather than asking the grammar a second
        # time and getting an opinion that agreed until it did not. A section
        # name is one of GG_SECTIONS, so it holds no newline and the rows can
        # be a plain string.
        GG_RECORD_SECLINES="$GG_RECORD_SECLINES$a$GG_TAB$low
"
        ;;
      *) gg_fail record-boundary "$kind" "the changelog grammar emitted a boundary this judge does not understand: $(gg_shown "$kind")" ;;
    esac
  done <"$GG_TMP/bounds"
  return 0
}

# The staged copy, which must be accepted. A shape the parser could not read
# is a failed measurement; one it read and this guard will not have is a
# verdict. Returns nonzero either way so the caller stops rather than
# writing into a document it has already rejected.
gg_record_structure() { # 0 when the staged record's shape is one a release can fold into
  if gg_record_accepts "$GG_TMP/record.index"; then
    return 0
  fi
  [ "$GG_RECORD_HARD" -eq 0 ] || gg_fail "$GG_RECORD_KEY" "$GG_RECORD_VALUE" "$(gg_shown "$RECORD") $GG_RECORD_WHY"
  case "$GG_RECORD_KEY" in
    record-heading)
      # A release folds every fragment into this heading and deletes the files
      # they came from, so a record without one is a release that cannot run,
      # caught here rather than at the tag.
      refuse "$GG_RECORD_KEY" "$GG_RECORD_VALUE" "$GG_RECORD_WHY" \
        "open one — a release folds the fragments into it and has nowhere to put them otherwise"
      ;;
    *) refuse "$GG_RECORD_KEY" "$GG_RECORD_VALUE" "$GG_RECORD_WHY" "section one of: $GG_SECTIONS" ;;
  esac
  return 1
}


gg_changelog_record_scope() {
  [ -n "$RECORD" ] || gg_fail record-off COMMIT_GUARDS_CHANGELOG_RECORD "no collation destination: COMMIT_GUARDS_CHANGELOG_RECORD is empty"
  [ -n "$RECORD_SHA" ] || gg_fail record-untracked "$(gg_shown "$RECORD")" "$(gg_shown "$RECORD") is not tracked; commit the collation destination first"
  gg_mode_is_regular "$RECORD_MODE" || gg_fail record-mode "$(gg_shown "$RECORD"):$RECORD_MODE" "$(gg_shown "$RECORD") is not a regular collation destination"
  gg_changelog_blob "$RECORD_SHA" "$RECORD" \
    || gg_fail record-binary "$(gg_shown "$RECORD")" "$(gg_shown "$RECORD") holds binary content; collation needs text"
  cat -- "$GG_TMP/blob" >"$GG_TMP/record.index" \
    || gg_fail record-read "$(gg_shown "$RECORD")" "could not read the staged collation destination $(gg_shown "$RECORD")"
  gg_record_structure || return 0
}
