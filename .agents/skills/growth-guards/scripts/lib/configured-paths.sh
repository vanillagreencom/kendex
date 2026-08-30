# shellcheck shell=bash
# How a lane scoped by a configured PATH LIST finds its content and decides
# what it may measure: the glob list, the walk over the index records, and the
# classification of every shape at a configured path that is not the content
# the lane reads. Sourced by lib/common.sh, never executed; the family
# contract and every helper it leans on (gg_config_error, gg_config_path,
# gg_normalize_rel_path, gg_require_merged_index, gg_shown) live there.
#
# Bash 3.2-safe throughout, like its parent.

# --- configured path globs: one setting naming a space-separated list -------
# The lanes scoped by a PATH LIST rather than by an excludes file share this.
# Each pattern goes through the family's path discipline — absolute, escaping
# and '-'-leading values are configuration errors, never a glob that quietly
# matches nothing — and an empty list is one too: a check that measures
# nowhere while reporting OK is the silent pass this family refuses, and
# dropping the check from GROWTH_GUARDS_CHECKS is how it is turned off.
#
# The caller runs under `set -f`. The list is word-split, and pathname
# expansion would resolve each pattern against the WORK TREE — matching
# whatever happens to be checked out instead of the tracked paths the scan
# judges, and matching nothing at all in a sparse or bare checkout.
GG_PATH_GLOBS=""
GG_PATH_GLOBS_SHOWN=""

gg_load_path_globs() { # RAW-LIST LABEL KEY — fills GG_PATH_GLOBS and _SHOWN
  local raw="$1" label="$2" key="$3" pat norm
  # The precondition enforces itself. Without `set -f` the failure is
  # invisible — no status, no message, just a scan over whatever the work
  # tree happens to hold — so a lane that forgot it must not run at all.
  case "$-" in
    *f*) ;;
    *) gg_config_error "gg_load_path_globs: pathname expansion is on; the caller must run under 'set -f' or the configured globs resolve against the work tree instead of matching the index" ;;
  esac
  GG_PATH_GLOBS=""
  GG_PATH_GLOBS_SHOWN=""
  for pat in $raw; do
    norm="$(gg_config_path "$pat" "$label")" || return 1
    GG_PATH_GLOBS="${GG_PATH_GLOBS:+$GG_PATH_GLOBS }$norm"
    # The same list rendered for messages: a configured pattern is somebody's
    # bytes too, and %q would escape the globs out of the copy that has to
    # match.
    GG_PATH_GLOBS_SHOWN="${GG_PATH_GLOBS_SHOWN:+$GG_PATH_GLOBS_SHOWN }$(gg_shown "$norm")"
  done
  [ -n "$GG_PATH_GLOBS" ] \
    || gg_config_error "$key names no path — name at least one, or drop this check from GROWTH_GUARDS_CHECKS"
}

gg_matches_path_glob() { # PATH — 0 when some configured glob matches the full path
  local path="$1" pat
  for pat in $GG_PATH_GLOBS; do
    # $pat must expand unquoted to act as a glob.
    # shellcheck disable=SC2254
    case "$path" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# git calls a blob binary when a NUL byte falls in its leading bytes, and the
# --cached scans skip such a blob — `git grep -I` drops it with no status and
# no stderr. A lane walking configured paths makes the same judgement here so
# it can NAME the path as unmeasured, rather than counting an unread blob into
# a clean total.
GG_BINARY_SAMPLE=8000
gg_blob_is_binary() { # FILE DESC — 0 when a NUL falls in the leading bytes
  local total stripped
  total="$(head -c "$GG_BINARY_SAMPLE" -- "$1" | wc -c)" \
    || gg_collection_error "could not sample $2 to classify its content"
  stripped="$(head -c "$GG_BINARY_SAMPLE" -- "$1" | LC_ALL=C tr -d '\000' | wc -c)" \
    || gg_collection_error "could not sample $2 to classify its content"
  [ "$((total))" -ne "$((stripped))" ]
}

# --- one walk over the configured paths -------------------------------------
# The lanes scoped by a configured path list share this walk: the `ls-files
# -s` records, the glob match, and the shapes at a configured path that are
# not the content the lane measures — a symlink, a submodule gitlink, and a
# blob git would call binary. Each of those is a path a `--cached` scan drops
# with NO status and NO stderr, so a lane that let one through would print a
# clean verdict over content it never read. Each is NAMED here and counted
# apart from the clean total, in GG_WALK_SKIPPED.
#
# Needs gg_tmpdir and the configured globs already loaded. ON_FILE runs in
# the caller's own shell, as `ON_FILE PATH BLOBFILE`, so it may set the
# caller's counters.
GG_WALK_SKIPPED=0
# Scoped paths whose content another record already covers: a link to a file
# in the configured scope, or a second link to a body the first one queued.
# Counted rather than silent, so a lane can tell "nothing matched the globs"
# from "everything that matched is covered elsewhere" — and so a future gap
# between gg_resolve_link_target's refusals and its deferral cannot pass for
# the former.
GG_WALK_DEFERRED=0
GG_WALK_TARGET=""
GG_WALK_TARGET_SHA=""
GG_WALK_LINK_TARGETS=()

# DESC is already rendered by the caller, which is what lets a resolved
# symlink name both halves: the path the configured globs matched and the
# target read in its place. A reader given only the target cannot get back to
# the scoped path that pulled it in.
gg_note_skip() { # DESC REASON — a matched path this scan cannot measure
  echo "${GG_CHECK:-growth-guards}: not measured: $1 — $2"
  GG_WALK_SKIPPED=$((GG_WALK_SKIPPED + 1))
}

gg_read_blob() { # SHA DESC NOUN — the blob's bytes into $GG_TMP/blob
  git cat-file blob "$1" >"$GG_TMP/blob" 2>"$GG_TMP/blob.err" \
    || { [ ! -s "$GG_TMP/blob.err" ] || cat -- "$GG_TMP/blob.err" >&2
      gg_collection_error "cannot read blob $1 for $2 — refusing to skip an unread $3"; }
}

# A tracked symlink's blob holds its TARGET PATH, and `git grep --cached`
# skips the entry outright rather than reading through it. Resolving the
# target is what keeps a scoped name from becoming a hole: a SKILL.md that is
# a link to an unscanned body would otherwise carry anything at all.
#
# A target this walk cannot reach — absolute, escaping the repository,
# untracked, the link itself, or itself a link or a gitlink — is a collection
# error: content the lane was pointed at and cannot read is not content it
# may skip. Only what survives every one of those is deferred: a target
# already inside the configured scope is left to its own record, since it is
# scanned under its own name and resolving it here would report every hit
# twice.
gg_resolve_link_target() { # LINKPATH LINKSHA — 0 with GG_WALK_TARGET(_SHA) set;
                           # 1 when the target needs no scan of its own here
  local link="$1" sha="$2" target dir cand norm entry status=0 t
  GG_WALK_TARGET=""
  GG_WALK_TARGET_SHA=""
  target="$(git cat-file blob "$sha" 2>/dev/null)" \
    || gg_collection_error "cannot read the target of the symlink $(gg_shown "$link")"
  [ -n "$target" ] || gg_collection_error "the symlink $(gg_shown "$link") has an empty target"
  case "$target" in
    /*) gg_collection_error "the symlink $(gg_shown "$link") points outside the repository (absolute target $(gg_shown "$target"))" ;;
  esac
  dir="${link%/*}"
  [ "$dir" != "$link" ] || dir=""
  cand="${dir:+$dir/}$target"
  norm="$(gg_normalize_rel_path "$cand")" \
    || gg_collection_error "the symlink $(gg_shown "$link") points outside the repository (target $(gg_shown "$target"))"
  # Every refusal below runs BEFORE the deferral. A deferral says "another
  # record measures this", so it must be reached only once that record is
  # known to exist and to be a regular blob; reached earlier it swallows the
  # refusals whole and the lane exits 0 having read nothing for a scoped path.
  [ "$norm" != "$link" ] \
    || gg_collection_error "the symlink $(gg_shown "$link") points at itself"
  # `ls-files -s` exits 0 whether or not the path matches, so a nonzero status
  # is a failing invocation and empty output is the "not in the index" answer.
  entry="$(git ls-files -s -- ":(literal)$norm")" || status=$?
  [ "$status" -eq 0 ] \
    || gg_collection_error "could not look up $(gg_shown "$norm"), the target of the symlink $(gg_shown "$link") (git ls-files exit $status)"
  [ -n "$entry" ] \
    || gg_collection_error "the symlink $(gg_shown "$link") points at $(gg_shown "$norm"), which this commit does not track"
  # A link to a link is refused wherever the target sits, in the configured
  # scope or outside it. Deferring one instead is what closes a cycle: two
  # scoped links pointing at each other each defer to the other, and neither
  # is ever read. One level is the rule, and refusing here is what makes every
  # deferral below provably sound — the record deferred to is a regular blob,
  # so it scans something.
  case "${entry%% *}" in
    120000) gg_collection_error "the symlink $(gg_shown "$link") points at $(gg_shown "$norm"), itself a symlink; this walk reads one level" ;;
    160000) gg_collection_error "the symlink $(gg_shown "$link") points at $(gg_shown "$norm"), a submodule gitlink" ;;
  esac
  # In scope under its own name: its own record measures it, and resolving it
  # again would report every hit twice.
  if gg_matches_path_glob "$norm"; then
    GG_WALK_DEFERRED=$((GG_WALK_DEFERRED + 1))
    return 1
  fi
  # A second link to a body already queued by the first: one read covers both.
  for t in ${GG_WALK_LINK_TARGETS[@]+"${GG_WALK_LINK_TARGETS[@]}"}; do
    if [ "$t" = "$norm" ]; then
      GG_WALK_DEFERRED=$((GG_WALK_DEFERRED + 1))
      return 1
    fi
  done
  GG_WALK_LINK_TARGETS+=("$norm")
  GG_WALK_TARGET="$norm"
  entry="${entry#* }"
  GG_WALK_TARGET_SHA="${entry%% *}"
  return 0
}

gg_walk_configured_paths() { # NOUN UNREAD-NOUN LINKS ON_FILE
  local noun="$1" unread="$2" links="$3" on_file="$4" rec f mode rest sha via desc
  case "$links" in
    # skip    — name the link as unmeasured; the lane measures files.
    # resolve — measure the target in the link's place.
    skip | resolve) ;;
    *) gg_config_error "gg_walk_configured_paths: unknown symlink policy '$links'" ;;
  esac
  GG_WALK_SKIPPED=0
  GG_WALK_DEFERRED=0
  GG_WALK_LINK_TARGETS=()
  # `ls-files -s` emits one record per STAGE for an unmerged path, so the walk
  # would read rival blobs as separate files.
  gg_require_merged_index
  git ls-files -sz >"$GG_TMP/files.z" || gg_collection_error "git ls-files failed"
  while IFS= read -r -d '' rec; do
    # Record shape: "<mode> <sha> <stage>\t<path>".
    f="${rec#*"$GG_TAB"}"
    gg_matches_path_glob "$f" || continue
    mode="${rec%% *}"
    rest="${rec#* }"
    sha="${rest%% *}"
    via=""
    case "$mode" in
      120000)
        if [ "$links" = "skip" ]; then
          gg_note_skip "$(gg_shown "$f")" "tracked as a symlink, not $noun"
          continue
        fi
        gg_resolve_link_target "$f" "$sha" || continue
        # The scoped path stays: it is the only way back from a target that
        # the configured globs do not name to the link that pulled it in.
        via="$f"
        f="$GG_WALK_TARGET"
        sha="$GG_WALK_TARGET_SHA"
        echo "${GG_CHECK:-growth-guards}: read $(gg_shown "$f") for the symlink $(gg_shown "$via")"
        ;;
      160000)
        gg_note_skip "$(gg_shown "$f")" "tracked as a submodule gitlink, not $noun"
        continue
        ;;
    esac
    desc="$(gg_shown "$f")"
    [ -z "$via" ] || desc="$desc, the target of the symlink $(gg_shown "$via")"
    gg_read_blob "$sha" "$desc" "$unread"
    if gg_blob_is_binary "$GG_TMP/blob" "$desc"; then
      gg_note_skip "$desc" "binary content, not $noun"
      continue
    fi
    "$on_file" "$f" "$GG_TMP/blob"
  done <"$GG_TMP/files.z"
}

