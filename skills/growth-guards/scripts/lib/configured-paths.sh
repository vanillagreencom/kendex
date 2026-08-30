# shellcheck shell=bash
# How a lane scoped by a configured PATH LIST finds its content and decides
# what it may measure: the glob list, the walk over the index records, and the
# classification of every shape at a configured path that is not the content
# the lane reads. Sourced by lib/common.sh, never executed; the family
# contract and every helper it leans on (gg_config_error, gg_config_path,
# gg_require_merged_index, gg_shown) live there.
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
  local raw="$1" label="$2" key="$3" pat
  # The precondition enforces itself. Without `set -f` the failure is
  # invisible — no status, no message, just a scan over whatever the work
  # tree happens to hold — so a lane that forgot it must not run at all.
  case "$-" in
    *f*) ;;
    *) gg_config_error "gg_load_path_globs: pathname expansion is on; the caller must run under 'set -f' or the configured globs resolve against the work tree instead of matching the index" ;;
  esac
  # The validation loop is gg_config_path_list's, in lib/common.sh: a lane
  # that reads two configured lists calls that directly, and one scoped by a
  # single list arrives here, so both go through one spelling of it.
  GG_PATH_GLOBS=""
  GG_PATH_GLOBS_SHOWN=""
  GG_PATH_GLOBS="$(gg_config_path_list "$raw" "$label")" || return 1
  [ -n "$GG_PATH_GLOBS" ] \
    || gg_config_error "$key names no path — name at least one, or drop this check from GROWTH_GUARDS_CHECKS"
  # The same list rendered for messages. Not gg_shown: %q escapes the globs
  # out of a value whose whole purpose is to be typed back into a settings
  # file, so a remedy would name a path that cannot exist. gg_scrubbed keeps
  # the bytes and replaces only what a terminal would act on.
  GG_PATH_GLOBS_SHOWN="$(gg_scrubbed "$GG_PATH_GLOBS")"
}

gg_matches_path_glob() { # PATH — 0 when some configured glob matches the full path
  # The loaded list, matched by the one spelling in lib/common.sh.
  # shellcheck disable=SC2086
  gg_path_matches "$1" $GG_PATH_GLOBS
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
#
# The tally is of PATHS, which is what the verdict line claims — and one path
# reaches the sniff once per scan that lists it, so a check running several
# lanes over overlapping pathspecs meets the same unreadable blob several
# times. The paths already named are kept in $GG_TMP/skipped.z, NUL-delimited
# so a path holding any byte but NUL round-trips exactly; a repeat is neither
# printed again nor counted again, and the reason it carries is the first
# one it was given. The file lives beside the counter and is emptied wherever
# the counter is reset, so the two always describe the same run.
GG_WALK_SKIPPED=0

gg_skip_seen() { # PATH — 0 when this path was already named unmeasured
  local seen
  [ -s "$GG_TMP/skipped.z" ] || return 1
  while IFS= read -r -d '' seen; do
    if [ "$seen" = "$1" ]; then
      return 0
    fi
  done <"$GG_TMP/skipped.z"
  return 1
}

gg_note_skip() { # PATH REASON — a matched path this scan cannot measure
  if gg_skip_seen "$1"; then
    return 0
  fi
  printf '%s\0' "$1" >>"$GG_TMP/skipped.z"
  echo "${GG_CHECK:-growth-guards}: not measured: $(gg_shown "$1") — $2"
  GG_WALK_SKIPPED=$((GG_WALK_SKIPPED + 1))
}

gg_read_blob() { # SHA PATH NOUN — the blob's bytes into $GG_TMP/blob
  git cat-file blob "$1" >"$GG_TMP/blob" 2>"$GG_TMP/blob.err" \
    || { [ ! -s "$GG_TMP/blob.err" ] || cat -- "$GG_TMP/blob.err" >&2
      gg_collection_error "cannot read blob $1 for $(gg_shown "$2") — refusing to skip an unread $3"; }
}

gg_walk_configured_paths() { # NOUN UNREAD-NOUN ON_FILE
  local noun="$1" unread="$2" on_file="$3" rec f mode rest sha
  GG_WALK_SKIPPED=0
  : >"$GG_TMP/skipped.z"
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
        gg_note_skip "$f" "tracked as a symlink, not $noun"
        continue
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

