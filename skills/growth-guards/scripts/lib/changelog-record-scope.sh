# changelog-record-scope.sh — the record half of the changelog-entries judge,
# which is the half that reads ONE tracked file rather than walking a tree.
# It runs after that walk, on the globals the walk filled in (RECORD_SHA and
# RECORD_MODE), and reports the way the walk does: a violation counted in
# `violations`, a collection error for a measurement that could not run, and
# RECORD_NOTE saying which way the scope stood down when it did.
#
# Its own file because the two scopes share nothing but their verdict: this
# one is about a file's [Unreleased] section against HEAD's, and the walk is
# about what a fragment tree may hold.
#
# Needs lib/common.sh and lib/changelog-grammar.sh sourced first.

# What HEAD carries at the record's path, asked once. Both readers need it —
# the one deciding whether an absent index entry is a deletion, and the one
# taking HEAD's copy to compare against — and a second spelling of this probe
# is a second answer waiting to disagree with the first.
RECORD_HEAD_ENTRY=""
RECORD_HEAD_SHA=""
gg_record_head_probe() { # fills RECORD_HEAD_ENTRY and RECORD_HEAD_SHA, or leaves them empty
  local head_status=0 tree_status=0
  RECORD_HEAD_ENTRY=""
  RECORD_HEAD_SHA=""
  git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || head_status=$?
  case "$head_status" in
    0)
      RECORD_HEAD_ENTRY="$(git ls-tree HEAD -- ":(literal)$RECORD")" || tree_status=$?
      [ "$tree_status" -eq 0 ] \
        || gg_collection_error "could not probe HEAD for $(gg_shown "$RECORD") (git ls-tree exit $tree_status)"
      # Record shape: "<mode> <type> <sha>\t<path>".
      RECORD_HEAD_SHA="${RECORD_HEAD_ENTRY#* * }"
      RECORD_HEAD_SHA="${RECORD_HEAD_SHA%%"$GG_TAB"*}"
      ;;
    1) ;;
    *) gg_collection_error "could not resolve HEAD while reading $(gg_shown "$RECORD") (git rev-parse exit $head_status)" ;;
  esac
}

gg_changelog_record_scope() { # fills RECORD_NOTE; counts violations
  # Judged only when HEAD already carries the record: a repository writing its
  # first CHANGELOG.md is not hand-editing a collated one, and every line of it
  # would read as gained. Each way the scope stands down says which way it was,
  # so a gate somebody disarmed for this run never reads as a repository that
  # has no record yet.
  RECORD_NOTE=""
  if [ -z "$RECORD" ]; then
    RECORD_NOTE="; no record scope — GROWTH_GUARDS_CHANGELOG_RECORD is empty"
  elif [ -z "$RECORD_SHA" ]; then
    # Absent from the index is two states, and they are opposites. Never
    # tracked is the repository that has no record yet. Tracked in HEAD and
    # gone from the index is this commit DELETING the consumer changelog, or
    # renaming it out from under the setting that still names it — read as the
    # first, that ships as a clean run.
    gg_record_head_probe
    if [ -z "$RECORD_HEAD_ENTRY" ]; then
      RECORD_NOTE="; no record to judge — $(gg_shown "$RECORD") is not tracked"
    elif [ "${GROWTH_GUARDS_CHANGELOG_COLLATE:-}" = "1" ]; then
      RECORD_NOTE="; $(gg_shown "$RECORD") removal NOT judged — GROWTH_GUARDS_CHANGELOG_COLLATE=1 declares this write"
    else
      refuse "$RECORD" "is tracked in HEAD and staged away — the collated record cannot be deleted in passing" \
        "restore it, or empty GROWTH_GUARDS_CHANGELOG_RECORD to retire the scope; GROWTH_GUARDS_CHANGELOG_COLLATE=1 declares a release write"
    fi
  else
    # What the record IS — a real file, holding text this family can measure —
    # is judged whenever git carries one. Only the COMPARISON below is a rule a
    # collation legitimately breaks, so only that is what the declaration
    # bypasses: a run that skipped these would let a symlink through, and the
    # collator's own rename would then replace it with a regular file.
    case "$RECORD_MODE" in
      120000 | 160000) gg_collection_error "$(gg_shown "$RECORD") is tracked as a symlink or gitlink — the record could not be read" ;;
    esac
    gg_changelog_blob "$RECORD_SHA" "$RECORD" \
      || gg_collection_error "$(gg_shown "$RECORD") holds binary content in its staged copy — the collated record is not changelog text"
    cat -- "$GG_TMP/blob" >"$GG_TMP/record.index" \
      || gg_collection_error "could not take the staged copy of $(gg_shown "$RECORD")"

    if [ "${GROWTH_GUARDS_CHANGELOG_COLLATE:-}" = "1" ]; then
      RECORD_NOTE="; $(gg_shown "$RECORD") NOT compared — GROWTH_GUARDS_CHANGELOG_COLLATE=1 declares this write"
    else
      gg_record_head_probe
      if [ -z "$RECORD_HEAD_ENTRY" ]; then
        RECORD_NOTE="; no record to compare — HEAD carries no $(gg_shown "$RECORD") yet"
      else
        # HEAD's copy comes in by the same path, so the rules that judged the
        # staged one judge it too.
        gg_changelog_blob "$RECORD_HEAD_SHA" "$RECORD" \
          || gg_collection_error "$(gg_shown "$RECORD") holds binary content in HEAD's copy — the collated record is not changelog text"
        cat -- "$GG_TMP/blob" >"$GG_TMP/record.head" \
          || gg_collection_error "could not take HEAD's copy of $(gg_shown "$RECORD")"
        # An EMPTY section and a MISSING one both parse to nothing, so the
        # comparison alone calls a commit that stages the heading away a record
        # nobody touched. The parser tells them apart; this remembers which
        # copy had one, because only the pair says whether the section was
        # REMOVED or was never there.
        index_heading=1
        head_heading=1
        for side in index head; do
          ur_status=0
          LC_ALL=C awk "$GG_UNRELEASED_AWK" <"$GG_TMP/record.$side" >"$GG_TMP/ur.$side" || ur_status=$?
          # Exit 3 is the parser saying a fence never closed, so it cannot say
          # where the section starts or stops. Reporting the record unchanged
          # over a document it could not read is the silent pass this family
          # refuses.
          [ "$ur_status" -ne 3 ] \
            || gg_collection_error "$(gg_shown "$RECORD") leaves a code fence unclosed in its $side copy — the [Unreleased] section cannot be located; close the fence"
          # Exit 4 is the parser saying the document has two of the heading, so
          # which one is the section is undecided. Both copies are read here, so
          # this refuses the commit that INTRODUCES the second one and every
          # commit after it until one goes.
          [ "$ur_status" -ne 4 ] \
            || gg_collection_error "$(gg_shown "$RECORD") carries more than one '## [Unreleased]' heading in its $side copy — which one is the section cannot be decided; keep one"
          # Exit 5 is the parser saying this copy carries no canonical heading
          # at all. On its own that is a document, not a fault — a record whose
          # section has not been opened yet parses this way — so it is recorded
          # and judged below against the other copy.
          if [ "$ur_status" -eq 5 ]; then
            ur_status=0
            case "$side" in
              index) index_heading=0 ;;
              head) head_heading=0 ;;
            esac
          fi
          [ "$ur_status" -eq 0 ] \
            || gg_collection_error "could not read the [Unreleased] section of the $side copy of $(gg_shown "$RECORD") (awk exit $ur_status)"
          LC_ALL=C sort -o "$GG_TMP/ur.$side" "$GG_TMP/ur.$side" \
            || gg_collection_error "could not order the [Unreleased] lines of the $side copy of $(gg_shown "$RECORD")"
        done
        if [ "$head_heading" -eq 1 ] && [ "$index_heading" -eq 0 ]; then
          # The section HEAD carries would be gone, and the release that folds
          # fragments in has nowhere to fold them. The comparison below cannot
          # see this: with no section staged there is nothing to have gained.
          refuse "$RECORD" "stages away the '## [Unreleased]' heading HEAD carries" \
            "keep it, or rename it to a released version and open a fresh empty one, which is what a release does"
        else
          # No comm -u: a second copy of a line HEAD carries once is a line this
          # commit gained.
          added="$(LC_ALL=C comm -13 "$GG_TMP/ur.head" "$GG_TMP/ur.index")" \
            || gg_collection_error "could not compare the [Unreleased] section of $(gg_shown "$RECORD") against HEAD"
          if [ -z "$added" ]; then
            RECORD_NOTE="; $(gg_shown "$RECORD") unchanged under [Unreleased]"
          else
            echo "changelog-entries FAIL $(gg_shown "$RECORD") gained lines under [Unreleased]"
            # The first five, with every C0 control except tab, and DEL,
            # replaced: these are the record's own bytes, and an escape
            # sequence in one must not reach the reader's terminal. awk caps
            # the count itself rather than piping into `head`, whose exit would
            # break the pipeline under pipefail.
            printf '%s\n' "$added" | LC_ALL=C awk 'NR <= 5 { gsub(/[\001-\010\013-\037\177]/, "?"); print "    " $0 }'
            echo "  write $PATTERNS_SHOWN instead — the collator folds fragments in at release; GROWTH_GUARDS_CHANGELOG_COLLATE=1 declares that write"
            violations=$((violations + 1))
          fi
        fi
      fi
    fi
  fi
}
