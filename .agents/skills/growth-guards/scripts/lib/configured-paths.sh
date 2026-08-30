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
gg_blob_is_binary() { # FILE LABEL — 0 when a NUL falls in the leading bytes
  local total stripped
  total="$(head -c "$GG_BINARY_SAMPLE" -- "$1" | wc -c)" \
    || gg_collection_error "could not sample $(gg_shown "$2") to classify its content"
  stripped="$(head -c "$GG_BINARY_SAMPLE" -- "$1" | LC_ALL=C tr -d '\000' | wc -c)" \
    || gg_collection_error "could not sample $(gg_shown "$2") to classify its content"
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
GG_WALK_TARGET=""
GG_WALK_TARGET_SHA=""
GG_WALK_LINK_TARGETS=()

gg_note_skip() { # PATH REASON — a matched path this scan cannot measure
  echo "${GG_CHECK:-growth-guards}: not measured: $(gg_shown "$1") — $2"
  GG_WALK_SKIPPED=$((GG_WALK_SKIPPED + 1))
}

gg_read_blob() { # SHA PATH NOUN — the blob's bytes into $GG_TMP/blob
  git cat-file blob "$1" >"$GG_TMP/blob" 2>"$GG_TMP/blob.err" \
    || { [ ! -s "$GG_TMP/blob.err" ] || cat -- "$GG_TMP/blob.err" >&2
      gg_collection_error "cannot read blob $1 for $(gg_shown "$2") — refusing to skip an unread $3"; }
}

# A tracked symlink's blob holds its TARGET PATH, and `git grep --cached`
# skips the entry outright rather than reading through it. Resolving the
# target is what keeps a scoped name from becoming a hole: a SKILL.md that is
# a link to an unscanned body would otherwise carry anything at all.
#
# A target already inside the configured scope is left to its own record — it
# is scanned under its own name, so resolving it here would report every hit
# twice. A target this walk cannot reach — absolute, escaping the repository,
# untracked, or itself a link or a gitlink — is a collection error: content
# the lane was pointed at and cannot read is not content it may skip.
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
  # In scope under its own name: its own record measures it.
  gg_matches_path_glob "$norm" && return 1
  for t in ${GG_WALK_LINK_TARGETS[@]+"${GG_WALK_LINK_TARGETS[@]}"}; do
    if [ "$t" = "$norm" ]; then return 1; fi
  done
  # `ls-files -s` exits 0 whether or not the path matches, so a nonzero status
  # is a failing invocation and empty output is the "not in the index" answer.
  entry="$(git ls-files -s -- ":(literal)$norm")" || status=$?
  [ "$status" -eq 0 ] \
    || gg_collection_error "could not look up $(gg_shown "$norm"), the target of the symlink $(gg_shown "$link") (git ls-files exit $status)"
  [ -n "$entry" ] \
    || gg_collection_error "the symlink $(gg_shown "$link") points at $(gg_shown "$norm"), which this commit does not track"
  case "${entry%% *}" in
    120000) gg_collection_error "the symlink $(gg_shown "$link") points at $(gg_shown "$norm"), itself a symlink; this walk reads one level" ;;
    160000) gg_collection_error "the symlink $(gg_shown "$link") points at $(gg_shown "$norm"), a submodule gitlink" ;;
  esac
  GG_WALK_LINK_TARGETS+=("$norm")
  GG_WALK_TARGET="$norm"
  entry="${entry#* }"
  GG_WALK_TARGET_SHA="${entry%% *}"
  return 0
}

gg_walk_configured_paths() { # NOUN UNREAD-NOUN LINKS ON_FILE
  local noun="$1" unread="$2" links="$3" on_file="$4" rec f mode rest sha
  case "$links" in
    # skip    — name the link as unmeasured; the lane measures files.
    # resolve — measure the target in the link's place.
    skip | resolve) ;;
    *) gg_config_error "gg_walk_configured_paths: unknown symlink policy '$links'" ;;
  esac
  GG_WALK_SKIPPED=0
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
    case "$mode" in
      120000)
        if [ "$links" = "skip" ]; then
          gg_note_skip "$f" "tracked as a symlink, not $noun"
          continue
        fi
        gg_resolve_link_target "$f" "$sha" || continue
        f="$GG_WALK_TARGET"
        sha="$GG_WALK_TARGET_SHA"
        ;;
      160000)
        gg_note_skip "$f" "tracked as a submodule gitlink, not $noun"
        continue
        ;;
    esac
    gg_read_blob "$sha" "$f" "$unread"
    if gg_blob_is_binary "$GG_TMP/blob" "$f"; then
      gg_note_skip "$f" "binary content, not $noun"
      continue
    fi
    "$on_file" "$f" "$GG_TMP/blob"
  done <"$GG_TMP/files.z"
}

