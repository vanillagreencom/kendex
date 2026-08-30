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

# The declaration, read in ONE place in this scope and permitting ONE thing:
# the lines a collation adds under [Unreleased]. That is the only rule here a
# release legitimately breaks — it exists to fold entries in — and everything
# else this scope judges is as true during a release as outside one.
#
# Read once because it was read per rule, and each rule got to decide for
# itself which side of the declaration it sat on. Three findings came out of
# that: the acceptance set was disarmed wholesale, then the record's type and
# text checks, then the deletion refusal. The single call site below is what
# makes a rule added later OUTSIDE the declaration without anyone choosing —
# to be inside it, a rule would have to be written into the one branch whose
# whole body is a note saying nothing was compared.
gg_collation_declared() { # 0 when this run is the release commit's own write
  [ "${GROWTH_GUARDS_CHANGELOG_COLLATE:-}" = "1" ]
}

# The record's own STRUCTURE, judged where every other rule about the record
# is judged. It is one file's shape: the section is there, it is there once,
# the fences close, and the level-3 headings inside it name sections this
# family has somewhere to put. tools/changelog-collate needs exactly these
# answers to split the file, and used to take them by asking the grammar
# again itself — a second opinion that agreed until it did not. It reads the
# accepted bounds off --list now, so this is the only place they are decided.
#
# The accepted records land in $GG_TMP/bounds.z, NUL-terminated, in the
# grammar's own spelling: `record-unreleased<TAB>LINE`,
# `record-section<TAB>LINE<TAB>NAME` lowercased, `record-end<TAB>LINE`. A file
# and not a variable, because a shell variable cannot hold the NUL that
# separates them. Returns nonzero when the record is refused, so the caller
# stops rather than comparing a document it has already rejected.
gg_record_structure() { # 0 when the staged record's shape is one a release can fold into
  local rc=0 kind a b low
  : >"$GG_TMP/bounds.z"
  LC_ALL=C awk -v emit=bounds "$GG_UNRELEASED_AWK" <"$GG_TMP/record.index" >"$GG_TMP/bounds" || rc=$?
  case "$rc" in
    0) : ;;
    3) gg_collection_error "$(gg_shown "$RECORD") leaves a code fence unclosed — the [Unreleased] section cannot be located; close the fence" ;;
    4) gg_collection_error "$(gg_shown "$RECORD") carries more than one '## [Unreleased]' heading — which one is the section cannot be decided; keep one" ;;
    5)
      # No section at all. A release folds every fragment into this heading
      # and deletes the files they came from, so a record without one is a
      # release that cannot run, caught here rather than at the tag.
      refuse "$RECORD" "carries no '## [Unreleased]' heading" \
        "open one — a release folds the fragments into it and has nowhere to put them otherwise"
      return 1
      ;;
    *) gg_collection_error "$(gg_shown "$RECORD") could not be read (awk exit $rc) — the [Unreleased] section cannot be located" ;;
  esac
  while IFS="$GG_TAB" read -r kind a b; do
    case "$kind" in
      unreleased | end) ;;
      section)
        low="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
        # Heading TEXT, so it may hold anything a line holds.
        if ! gg_is_section "$low"; then
          refuse "$RECORD" "names '$(gg_scrubbed "$b")' under [Unreleased], which is not a Keep a Changelog section" \
            "section one of: $GG_SECTIONS"
          return 1
        fi
        b="$low"
        ;;
      *) gg_collection_error "the changelog grammar emitted a boundary this judge does not understand: $(gg_shown "$kind")" ;;
    esac
    printf 'record-%s\t%s%s\0' "$kind" "$a" "${b:+$(printf '\t%s' "$b")}" >>"$GG_TMP/bounds.z"
  done <"$GG_TMP/bounds"
  return 0
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
    else
      # The declaration does not reach here. A collation RENAMES a replacement
      # over the record and never removes it, so there is no release that owes
      # this refusal an exemption.
      refuse "$RECORD" "is tracked in HEAD and staged away — the collated record cannot be deleted in passing" \
        "restore it, or empty GROWTH_GUARDS_CHANGELOG_RECORD to retire the scope"
    fi
  else
    # What the record IS — a real file, holding text this family can measure —
    # is judged whenever git carries one, and so is everything below it. Only
    # the gained-line verdict at the foot of this branch is a rule a collation
    # legitimately breaks, and that is the one place the declaration is read.
    case "$RECORD_MODE" in
      120000 | 160000) gg_collection_error "$(gg_shown "$RECORD") is tracked as a symlink or gitlink — the record could not be read" ;;
    esac
    gg_changelog_blob "$RECORD_SHA" "$RECORD" \
      || gg_collection_error "$(gg_shown "$RECORD") holds binary content in its staged copy — the collated record is not changelog text"
    cat -- "$GG_TMP/blob" >"$GG_TMP/record.index" \
      || gg_collection_error "could not take the staged copy of $(gg_shown "$RECORD")"

    gg_record_structure || return 0

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
      # Content, because the structure of both copies is already settled:
      # gg_record_structure judged the staged one, and HEAD's was judged by
      # the run that accepted it. What is left to read is the lines.
      for side in index head; do
        ur_status=0
        LC_ALL=C awk "$GG_UNRELEASED_AWK" <"$GG_TMP/record.$side" >"$GG_TMP/ur.$side" || ur_status=$?
        # Exit 5 is a copy with no canonical heading, which is an empty
        # section's worth of lines. The staged copy cannot be one — it was
        # refused above — so this is HEAD's, from before the section existed.
        [ "$ur_status" -ne 5 ] || ur_status=0
        [ "$ur_status" -eq 0 ] \
          || gg_collection_error "could not read the [Unreleased] section of the $side copy of $(gg_shown "$RECORD") (awk exit $ur_status)"
        LC_ALL=C sort -o "$GG_TMP/ur.$side" "$GG_TMP/ur.$side" \
          || gg_collection_error "could not order the [Unreleased] lines of the $side copy of $(gg_shown "$RECORD")"
      done
      if gg_collation_declared; then
        # THE one thing the declaration permits, at the one place it is read.
        # Everything above ran whether or not it is set, which is the property
        # that keeps a rule added later out of here.
        RECORD_NOTE="; $(gg_shown "$RECORD") NOT compared — GROWTH_GUARDS_CHANGELOG_COLLATE=1 declares this write"
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
}
