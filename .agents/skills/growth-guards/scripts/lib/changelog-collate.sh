# shellcheck shell=bash
# changelog-collate.sh — the WRITE half of the changelog lane, run by
# `changelog-entries --collate` and only by the release commit. It folds the
# fragments this same run accepted into the record's `[Unreleased]` section
# and deletes them. One entry is one file, so no two branches ever write the
# same record line; this is the step that turns the files back into sections.
#
# It judges nothing. Which tracked paths are fragments, which section each
# belongs to, whether one is well formed, which file is the collated record
# and where that record's `[Unreleased]` section begins and ends are all
# settled by the walk and the record scope that ran before it — in this
# process, off this run's verdict. That is what closes the split a separate
# collator carried: one grammar, invoked at every commit and here, rather
# than two spellings that can drift, and a second search for the heading is
# what puts entries under a fenced example of it.
#
# The fragments are the ones git carries, because the walk reads the index;
# their content, and the record's, are read from the working tree, so any
# path the verdict covers that the index and the disk disagree about stops
# the write. That is what makes the verdict a verdict over the bytes about to
# be published.
#
# Every path moves as NUL-terminated bytes from the walk's records to the
# fold and the delete, so a fragment whose name carries a newline is folded
# in and removed like any other — and every path that reaches a message goes
# through gg_shown on the way.
#
# The record is replaced whole or not at all, through gg_install_file: it
# stages beside the record and renames, keeping the record's own mode and
# carrying the staging file to the exit trap so an interrupt leaves nothing
# behind.
#
# Needs lib/common.sh and lib/changelog-grammar.sh sourced first, and runs on
# the state the walk and the record scope filled in: GG_TMP/frags.z, RECORD,
# RECORD_SHA, RECORD_NOTE and the GG_RECORD_* bounds. gg_install_file comes
# from lib/atomic-install.sh, and resolution is at call time, so that one has
# only to be sourced before gg_changelog_collate runs.
#
# Sourced, never executed.

# The heading a section is written under, derived from the section name the
# judge already accepted. Derived rather than tabulated: a second list of
# these names is the drift this lane exists without.
gg_section_heading() { # SECTION — its Keep a Changelog heading text
  local first="${1%"${1#?}"}"
  printf '%s%s' "$(printf '%s' "$first" | LC_ALL=C tr '[:lower:]' '[:upper:]')" "${1#?}"
}

# The collated record, on stdout. Every part carries its own failure out: the
# caller runs this as the left operand of ||, where the shell suppresses
# errexit and would otherwise pass off the last command's status as the whole
# file's.
gg_collate_assemble() {
  local sec
  cat "$GG_TMP/collate.pre" || return 1
  cat "$GG_TMP/collate.lead" || return 1
  for sec in $GG_SECTIONS; do
    if [ -s "$GG_TMP/collate.sec.$sec" ] || [ -s "$GG_TMP/collate.frag.$sec" ]; then
      printf '\n### %s\n\n' "$(gg_section_heading "$sec")" || return 1
      cat "$GG_TMP/collate.sec.$sec" || return 1
      cat "$GG_TMP/collate.frag.$sec" || return 1
    fi
  done
  if [ -s "$GG_TMP/collate.post" ]; then
    printf '\n' || return 1
  fi
  cat "$GG_TMP/collate.post" || return 1
}

gg_changelog_collate() { # folds this run's accepted fragments into the record
  local sec path rec f d shown dirty survivors noun rc=0 count=0 nl guarded
  nl="
"

  # RECORD_NOTE rides every line this function reports on. It is the record
  # scope saying which way it stood down — HEAD carries no record yet, HEAD's
  # copy is not one this can be compared against and why, or the declaration
  # bypassed the comparison — and the release operator is the reader who most
  # needs it, because this run is the one writing the record. The fold's line
  # stands in for the cap verdict below, so a note dropped here is dropped
  # from the release entirely.
  if [ "$checked" -eq 0 ]; then
    echo "changelog-entries: no fragments — nothing to collate$RECORD_NOTE"
    return 0
  fi
  # A collation with nowhere to fold into refuses rather than writing some
  # other file.
  [ -n "$RECORD" ] \
    || gg_config_error "the record scope is off (GROWTH_GUARDS_CHANGELOG_RECORD is empty), so there is no collated record to fold these fragments into"
  # git has to carry the record, or the staleness guard below cannot see it:
  # `git diff` says nothing about an untracked file, so the fold would rewrite
  # a record nothing measured and then delete the tracked fragments that went
  # into it. A record staged for the first time satisfies this.
  [ -n "$RECORD_SHA" ] \
    || gg_config_error "$(gg_shown "$RECORD") is not tracked, so nothing measured it and nothing would notice it change — stage it first"

  for sec in $GG_SECTIONS; do
    : >"$GG_TMP/collate.sel.$sec"
    : >"$GG_TMP/collate.frag.$sec"
    : >"$GG_TMP/collate.sec.$sec"
  done
  : >"$GG_TMP/collate.frags"
  : >"$GG_TMP/collate.dirs"
  : >"$GG_TMP/collate.pre"
  : >"$GG_TMP/collate.lead"
  : >"$GG_TMP/collate.post"

  # The walk's own records, in its own order — which is index order, so each
  # section's fragments arrive in the filename order the release notes have
  # always read. The section came off the walk, which refuses a fragment that
  # names none, so there is nothing left to re-decide here.
  guarded=(":(literal)$RECORD")
  while IFS= read -r -d '' rec; do
    sec="${rec%%"$GG_TAB"*}"
    path="${rec#*"$GG_TAB"}"
    [ -f "$path" ] \
      || gg_collection_error "$(gg_shown "$path") is in the index but not a file on disk — nothing was written"
    printf '%s\0' "$path" >>"$GG_TMP/collate.sel.$sec"
    printf '%s\0' "$path" >>"$GG_TMP/collate.frags"
    # The directory each fragment sits in, so an emptied one can go with it
    # without this run spelling the fragment tree a second time.
    printf '%s\0' "${path%/*}" >>"$GG_TMP/collate.dirs"
    guarded+=(":(literal)$path")
    count=$((count + 1))
  done <"$GG_TMP/frags.z"

  # The write folds in each file on disk and then deletes it, and it replaces
  # the record with what it read there — so an unstaged edit to any of them
  # would be published without anything having measured it. The paths checked
  # are the ones this run judged, so the guard and the thing it guards cannot
  # drift apart.
  git diff --name-only -z -- "${guarded[@]}" >"$GG_TMP/collate.dirty" \
    || gg_collection_error "could not compare the changelog against the index — nothing was written"
  if [ -s "$GG_TMP/collate.dirty" ]; then
    # One line per path, each rendered: a name carrying a newline would
    # otherwise forge lines in this very diagnostic.
    shown=""
    while IFS= read -r -d '' dirty; do
      shown="$shown  $(gg_shown "$dirty")$nl"
    done <"$GG_TMP/collate.dirty"
    gg_config_error "the changelog differs between git and the working tree; the collation publishes the files on disk and the judge measures the ones git carries — stage or restore these first:
${shown%"$nl"}"
  fi

  # awk normalizes a fragment that ends without a newline, which would
  # otherwise glue two entries into one line.
  for sec in $GG_SECTIONS; do
    while IFS= read -r -d '' f; do
      LC_ALL=C awk 1 "$f" >>"$GG_TMP/collate.frag.$sec" \
        || gg_collection_error "could not read $(gg_shown "$f") — nothing was written"
    done <"$GG_TMP/collate.sel.$sec"
  done

  [ -f "$RECORD" ] || gg_collection_error "$(gg_shown "$RECORD") is missing — nothing was written"
  # Where the section begins, which level-3 headings it holds and where it
  # ends are the line numbers the record scope kept when it accepted the
  # staged copy — which the guard above just held equal to the file on disk.
  # Splitting at them is why nothing here searches the record for a heading
  # again: a second search is a second grammar.
  [ "$GG_RECORD_START" -gt 0 ] \
    || gg_collection_error "$(gg_shown "$RECORD") was accepted without a line for its [Unreleased] heading — nothing was written"
  printf '%s' "$GG_RECORD_SECLINES" >"$GG_TMP/collate.secline"

  # Split at those numbers: the part above the heading, that section's lead
  # and per-section bodies, and the released versions below it. Every part of
  # the section — its lead as much as each body — goes through the ONE rule
  # that drops edge blank lines and caps interior runs at one, which is why
  # `out` is seeded at the lead and no branch INSIDE the section writes a line
  # untrimmed; what falls outside it, above the heading and past the section's
  # end, is copied through as it stands. Trimming is what makes a section the
  # record spells under two headings come out as one list, and a second
  # spelling of it is the drift this lane exists without.
  LC_ALL=C awk -v tmp="$GG_TMP" -v start="$GG_RECORD_START" -v end="$GG_RECORD_END" \
    -v table="$GG_TMP/collate.secline" '
    BEGIN {
      while ((getline l < table) > 0) { split(l, p, "\t"); secline[p[1] + 0] = p[2] }
      close(table)
      out = tmp "/collate.lead"
    }
    NR <= start { print > (tmp "/collate.pre"); next }
    end > 0 && NR >= end { print > (tmp "/collate.post"); next }
    NR in secline { out = tmp "/collate.sec." secline[NR]; started = 0; held = 0; next }
    {
      if ($0 ~ /[^[:space:]]/) { if (held) print "" > out; held = 0; print > out; started = 1 }
      else if (started) { held = 1 }
    }
  ' "$RECORD" || rc=$?
  [ "$rc" -eq 0 ] \
    || gg_collection_error "$(gg_shown "$RECORD") could not be split (awk exit $rc) — nothing was written"

  # Assembled first, installed second: gg_install_file is the family's one
  # replace-whole-or-not-at-all, and it stages beside the record, keeps the
  # record's mode and carries the staging file to the exit trap. A failure
  # while assembling leaves the record untouched because nothing has been
  # renamed over it yet.
  gg_collate_assemble >"$GG_TMP/collate.out" \
    || gg_collection_error "could not assemble the collated changelog — $(gg_shown "$RECORD") is untouched"
  gg_install_file "$GG_TMP/collate.out" "$RECORD" "the collated changelog"

  # Past the rename, every fragment is in the record. Deleting stops for none
  # of them: one left behind folds in a second time on the next run, so the
  # refusal names every survivor, not the first.
  survivors=""
  while IFS= read -r -d '' f; do
    rm -f -- "$f" || survivors="$survivors  $(gg_shown "$f")$nl"
  done <"$GG_TMP/collate.frags"
  [ -z "$survivors" ] \
    || gg_config_error "$(gg_shown "$RECORD") is collated, but these fragments survived and would fold in a second time — delete them by hand:
${survivors%"$nl"}"
  # A directory the collation emptied goes with it. Not-empty and not-found
  # are both ordinary, and neither leaves anything to act on.
  while IFS= read -r -d '' d; do
    rmdir -- "$d" 2>/dev/null || true
  done <"$GG_TMP/collate.dirs"

  if [ "$count" -eq 1 ]; then noun=entry; else noun=entries; fi
  echo "changelog-entries: folded $count $noun into $(gg_shown "$RECORD")'s [Unreleased] section$RECORD_NOTE"
}
