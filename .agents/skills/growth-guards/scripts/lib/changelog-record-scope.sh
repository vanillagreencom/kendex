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
RECORD_HEAD_MODE=""
gg_record_head_probe() { # fills RECORD_HEAD_ENTRY, _MODE and _SHA, or leaves them empty
  local head_status=0 tree_status=0
  RECORD_HEAD_ENTRY=""
  RECORD_HEAD_SHA=""
  RECORD_HEAD_MODE=""
  git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || head_status=$?
  case "$head_status" in
    0)
      RECORD_HEAD_ENTRY="$(git ls-tree HEAD -- ":(literal)$RECORD")" || tree_status=$?
      [ "$tree_status" -eq 0 ] \
        || gg_collection_error "could not probe HEAD for $(gg_shown "$RECORD") (git ls-tree exit $tree_status)"
      # Record shape: "<mode> <type> <sha>\t<path>". The MODE is kept, not
      # dropped: what HEAD holds at that path is a gitlink, a tree, a symlink
      # or a file, and only the last of those has a blob to read as a record.
      RECORD_HEAD_MODE="${RECORD_HEAD_ENTRY%% *}"
      RECORD_HEAD_SHA="${RECORD_HEAD_ENTRY#* * }"
      RECORD_HEAD_SHA="${RECORD_HEAD_SHA%%"$GG_TAB"*}"
      ;;
    1) ;;
    *) gg_collection_error "could not resolve HEAD while reading $(gg_shown "$RECORD") (git rev-parse exit $head_status)" ;;
  esac
}

# Whether HEAD's copy is one this scope can compare AGAINST, answered once
# over every dimension it has: the entry's MODE, then its bytes, then its
# shape. HEAD is history — the committer cannot change what it holds — so
# each of these is a comparison skipped with its reason, never a refusal.
#
# One classifier because it was two passes: the parse statuses were settled
# and the entry mode was not, so a gitlink or a tree in HEAD still exited on
# a blob read that cannot answer, and a symlink's blob was parsed as though
# the link target were a record. A dimension added later belongs in here, in
# front of the comparison, rather than in a third pass beside it.
#
# The staged side is stricter and stays so: a non-regular mode there is
# refused outright, because that is what the commit is MAKING.
GG_HEAD_WHY=""
gg_record_head_comparable() { # 0 when HEAD's copy is one this scope can compare against
  GG_HEAD_WHY=""
  # Mode first, and by what it IS rather than by a list of what it is not: a
  # gitlink and a tree have no blob at all, and a symlink's blob is a path,
  # so none of them is a document to parse. Reading the sha before asking
  # this is what made two of them exit rather than answer.
  if ! gg_mode_is_regular "$RECORD_HEAD_MODE"; then
    GG_HEAD_WHY="is not a regular file in HEAD's copy (mode $(gg_shown "$RECORD_HEAD_MODE"))"
    return 1
  fi
  if ! gg_changelog_blob "$RECORD_HEAD_SHA" "$RECORD" soft; then
    GG_HEAD_WHY="is not changelog text in HEAD's copy"
    return 1
  fi
  cat -- "$GG_TMP/blob" >"$GG_TMP/record.head" \
    || gg_collection_error "could not take HEAD's copy of $(gg_shown "$RECORD")"
  if ! gg_record_accepts "$GG_TMP/record.head"; then
    GG_HEAD_WHY="$GG_RECORD_WHY, in HEAD's copy"
    return 1
  fi
  return 0
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

# Whether a parsed copy of the record is one this guard ACCEPTS: the section
# is there, it is there once, the fences close, and the level-3 headings
# inside it name sections this family has somewhere to put.
#
# One answer, asked of two copies with different consequences. The STAGED
# copy is what the commit is making, so it must be accepted. HEAD's copy is
# only the thing the staged one is compared against, and HEAD is history —
# the committer cannot change what it holds, so a HEAD this rejects is a
# comparison skipped, never a refusal. Asking the same question both times is
# what keeps a malformed state added later from needing a second exemption:
# whatever the staged copy would be refused for, HEAD is merely not compared
# for.
#
# GG_RECORD_WHY carries the reason it was not accepted, phrased to follow the
# record's name. GG_RECORD_HARD is 1 when the parser could not read the
# document at all, which a caller that must be loud reports as a failed
# measurement rather than a verdict.
GG_RECORD_WHY=""
GG_RECORD_HARD=0
gg_record_accepts() { # PARSED-FILE [BOUNDS-OUT] — 0 when the copy is a record this guard accepts
  local file="$1" out="${2:-}" rc=0 kind a b low
  GG_RECORD_WHY=""
  GG_RECORD_HARD=0
  [ -z "$out" ] || : >"$out"
  LC_ALL=C awk -v emit=bounds "$GG_UNRELEASED_AWK" <"$file" >"$GG_TMP/bounds" || rc=$?
  case "$rc" in
    0) : ;;
    3)
      GG_RECORD_WHY="leaves a code fence unclosed — the [Unreleased] section cannot be located"
      GG_RECORD_HARD=1
      return 1
      ;;
    4)
      GG_RECORD_WHY="carries more than one '## [Unreleased]' heading — which one is the section cannot be decided"
      GG_RECORD_HARD=1
      return 1
      ;;
    5)
      GG_RECORD_WHY="carries no '## [Unreleased]' heading"
      return 1
      ;;
    *)
      GG_RECORD_WHY="could not be read (awk exit $rc) — the [Unreleased] section cannot be located"
      GG_RECORD_HARD=1
      return 1
      ;;
  esac
  while IFS="$GG_TAB" read -r kind a b; do
    case "$kind" in
      unreleased | end) ;;
      section)
        low="$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')"
        # Heading TEXT, so it may hold anything a line holds.
        if ! gg_is_section "$low"; then
          GG_RECORD_WHY="names '$(gg_scrubbed "$b")' under [Unreleased], which is not a Keep a Changelog section"
          return 1
        fi
        b="$low"
        ;;
      *) gg_collection_error "the changelog grammar emitted a boundary this judge does not understand: $(gg_shown "$kind")" ;;
    esac
    # The accepted records, NUL-terminated, in the grammar's own spelling:
    # `record-unreleased<TAB>LINE`, `record-section<TAB>LINE<TAB>NAME`
    # lowercased, `record-end<TAB>LINE`. A file and not a variable, because a
    # shell variable cannot hold the NUL that separates them.
    # tools/changelog-collate reads them off --list and splits the record
    # there, rather than asking the grammar again and getting a second
    # opinion that agreed until it did not.
    [ -z "$out" ] || printf 'record-%s\t%s%s\0' "$kind" "$a" "${b:+$(printf '\t%s' "$b")}" >>"$out"
  done <"$GG_TMP/bounds"
  return 0
}

# The staged copy, which must be accepted. A shape the parser could not read
# is a failed measurement; one it read and this guard will not have is a
# verdict. Returns nonzero either way so the caller stops rather than
# comparing a document it has already rejected.
gg_record_structure() { # 0 when the staged record's shape is one a release can fold into
  if gg_record_accepts "$GG_TMP/record.index" "$GG_TMP/bounds.z"; then
    return 0
  fi
  [ "$GG_RECORD_HARD" -eq 0 ] || gg_collection_error "$(gg_shown "$RECORD") $GG_RECORD_WHY"
  case "$GG_RECORD_WHY" in
    "carries no"*)
      # A release folds every fragment into this heading and deletes the files
      # they came from, so a record without one is a release that cannot run,
      # caught here rather than at the tag.
      refuse "$RECORD" "$GG_RECORD_WHY" \
        "open one — a release folds the fragments into it and has nowhere to put them otherwise"
      ;;
    *) refuse "$RECORD" "$GG_RECORD_WHY" "section one of: $GG_SECTIONS" ;;
  esac
  return 1
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
      # HEAD is history. What the commit is making is the staged copy, judged
      # above; HEAD is only the thing it is compared against, and a comparison
      # that cannot be made is one SKIPPED with a reason. Refusing here would
      # demand a repair and then block the commit performing it, and a record
      # malformed in HEAD could never be fixed at all.
      #
      # Every way HEAD can fail to be a record is one answer, given by
      # gg_record_head_comparable over mode, bytes and shape together. A
      # dimension added there is covered here without anyone deciding it
      # should be.
      head_ok=1
      head_why=""
      if ! gg_record_head_comparable; then
        head_ok=0
        head_why="$GG_HEAD_WHY"
      fi
      # Content, because the shape of what is read here is already settled:
      # the staged copy was accepted above, and HEAD's is read only when it
      # was accepted too.
      ur_status=0
      LC_ALL=C awk "$GG_UNRELEASED_AWK" <"$GG_TMP/record.index" >"$GG_TMP/ur.index" || ur_status=$?
      [ "$ur_status" -eq 0 ] \
        || gg_collection_error "could not read the [Unreleased] section of the staged copy of $(gg_shown "$RECORD") (awk exit $ur_status)"
      LC_ALL=C sort -o "$GG_TMP/ur.index" "$GG_TMP/ur.index" \
        || gg_collection_error "could not order the [Unreleased] lines of the staged copy of $(gg_shown "$RECORD")"
      if [ "$head_ok" -eq 1 ]; then
        ur_status=0
        LC_ALL=C awk "$GG_UNRELEASED_AWK" <"$GG_TMP/record.head" >"$GG_TMP/ur.head" || ur_status=$?
        [ "$ur_status" -eq 0 ] \
          || gg_collection_error "could not read the [Unreleased] section of HEAD's copy of $(gg_shown "$RECORD") (awk exit $ur_status)"
        LC_ALL=C sort -o "$GG_TMP/ur.head" "$GG_TMP/ur.head" \
          || gg_collection_error "could not order the [Unreleased] lines of HEAD's copy of $(gg_shown "$RECORD")"
      fi
      if [ "$head_ok" -eq 0 ]; then
        RECORD_NOTE="; $(gg_shown "$RECORD") NOT compared — it $head_why, which this commit is free to repair and not to blame for"
      elif gg_collation_declared; then
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
