# shellcheck shell=bash
# Shared commit changes for the changelog gate and repository compile checks.
# Call after common.sh and settings.sh, from the repository root.
# shellcheck source=commit-parent.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/commit-parent.sh"

gg_commit_changes() { # sets GG_TMP/staged.z, written.z and product.z
  local meta src dest srcmode dstmode srcsha dstsha status f required_raw required
  # --raw, the spelling todo-ban and byte-ceiling already use: a raw record
  # carries the old and new MODE and the old and new BLOB for every path, so
  # what a commit did to a file is read off the record rather than inferred
  # from a letter. --name-status collapses each record into one letter, which
  # hides a rename from its source, a copy from a rename, and a chmod from a
  # rewrite. Blobs leave nothing to interpret.
  # -c diff.renames=true and --find-renames=100%, the sibling spelling again:
  # detection is PINNED rather than inherited, so `diff.renames=copies`
  # cannot put a record shape on this stream that the loop does not read, and
  # R stays the only status carrying two paths.
  # -z, so a path carrying a newline or a byte git would otherwise quote
  # reaches the globs as the bytes git recorded: a quoted name matches no
  # glob, which is a rule that stops seeing the files it is about. Read back
  # from a FILE rather than a pipe, so the loops set variables in this shell.
  #
  # The base is the parent the commit will HAVE: HEAD ordinarily, HEAD's own
  # parent for an amend, which replaces HEAD rather than following it, so
  # `--cached` alone would show only what was staged on top of a fragment the
  # commit already carries. GG_COMMIT_BASE is empty in the ordinary case,
  # where `--cached` already means HEAD, and unquoted for exactly that reason:
  # one revision or no argument at all, never a path and never a glob.
  gg_tmpdir
  gg_commit_base
  # shellcheck disable=SC2086
  git -c diff.renames=true diff --cached --raw --no-abbrev -z --find-renames=100% \
    $GG_COMMIT_BASE \
    >"$GG_TMP/raw.z" \
    || gg_collection_error "could not read the commit's file list — the changelog rule could not run"

  # What "written" MEANS, over the record's full identity: a mode and a sha
  # together, never a sha alone. Equal shas are TWO states, and only the modes
  # beside them tell those apart — a chmod leaves both modes regular, while a
  # symlink replaced by a regular file holding the link target's own bytes is
  # one blob under two modes. git emits that second record as
  # `:120000 100644 <sha> <sha> T`, so a sha comparison alone would refuse a
  # commit whose only changelog work was turning a link into a real fragment.
  #
  #   no blob after the commit    no — the path is gone, and deleting a
  #                               fragment is not writing one
  #   the blob changed            yes — the ordinary case, an addition
  #                               included, since an addition has no old blob
  #   the blob is the same, and
  #     it became a regular file  yes — that path holds a document now where
  #                               it held a link or a gitlink before, which
  #                               is content it did not carry here
  #     it did not                no — only permission bits moved
  gg_record_gained() { # SRCMODE SRCSHA DSTMODE DSTSHA — 0 when the path gained content
    case "$4" in
      *[!0]*) ;;
      *) return 1 ;;
    esac
    [ "$2" = "$4" ] || return 0
    gg_mode_is_regular "$3" || return 1
    ! gg_mode_is_regular "$1"
  }

  # TOUCHED is every path the record names, both sides of a rename included:
  # the source loses its content and the destination gains it, and a file
  # moved OUT of a required path is a change to that path.
  #
  # WRITTEN is narrower: gg_record_gained above, plus a rename's destination,
  # which held nothing at that path before and so is written whatever its
  # blob says — which is why a pure rename, whose two blobs are equal, still
  # counts. What the content turned INTO is the changelog-entries lane's
  # judgement, running beside this one.
  #
  # A COPY leaves its source unchanged, so staging it would demand an entry
  # for a file the commit did not touch. Pinning detection above is what
  # keeps C off this stream; the arm below refuses it rather than reading it
  # as a rename, because that pin is the only thing holding.
  : >"$GG_TMP/staged.z"
  : >"$GG_TMP/written.z"
  while IFS= read -r -d '' meta; do
    IFS= read -r -d '' src \
      || gg_collection_error "the commit's file list ended mid-record after $(gg_shown "$meta") — the changelog rule could not run"
    # Record shape: ":srcmode dstmode srcsha dstsha status". Splitting is safe
    # under `set -f` below — the fields are modes, hex
    # and a letter, and none of them is a path.
    # shellcheck disable=SC2086
    set -f
    set -- $meta
    [ "$#" -eq 5 ] \
      || gg_collection_error "the commit's file list carried a record of $# field(s), not five: $(gg_shown "$meta") — the changelog rule could not run"
    srcmode="${1#:}"
    dstmode="$2"
    srcsha="$3"
    dstsha="$4"
    status="$5"
    case "$status" in
      C*)
        gg_collection_error "git reported a copy ($(gg_shown "$status")) though this scan pins diff.renames=true — the changelog rule could not run"
        ;;
      R*)
        IFS= read -r -d '' dest \
          || gg_collection_error "the commit's file list ended before the destination of a $(gg_shown "$status") record — the changelog rule could not run"
        printf '%s\0' "$src" "$dest" >>"$GG_TMP/staged.z"
        printf '%s\0' "$dest" >>"$GG_TMP/written.z"
        continue
        ;;
    esac
    printf '%s\0' "$src" >>"$GG_TMP/staged.z"
    ! gg_record_gained "$srcmode" "$srcsha" "$dstmode" "$dstsha" \
      || printf '%s\0' "$src" >>"$GG_TMP/written.z"
  done <"$GG_TMP/raw.z"


  required_raw="$(gg_setting GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS "")" || exit 2
  required="$(gg_config_path_list "$required_raw" changelog-required)" || exit 2
  : >"$GG_TMP/product.z"
  while IFS= read -r -d '' f; do
    # Configured patterns are words, never expanded against the worktree.
    # shellcheck disable=SC2086
    if gg_path_matches "$f" $required; then
      printf '%s\0' "$f" >>"$GG_TMP/product.z"
    fi
  done <"$GG_TMP/staged.z"
}
