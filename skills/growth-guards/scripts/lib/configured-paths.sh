# shellcheck shell=bash
# How a lane scoped by a glob list over repo-relative paths finds its content
# and decides what it may measure: the glob list, the walk over the index
# records, and the classification of every shape at a configured path that is
# not the content the lane reads.
#
# TWO glob lists, one matcher. A lane names the paths it is FOR with a
# configured list, and names the paths it is NOT for with an excludes file
# read out of the index. Both are shell globs over the full repo-relative
# path and both go through gg_path_matches, so the two answers cannot come
# from two spellings; the excludes half sits at the foot of this file.
#
# Sourced by lib/common.sh, never executed; the family contract and every
# helper it leans on (gg_config_error, gg_config_path, gg_require_merged_index,
# gg_shown) live there.
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

# A setting holding a LIST of path globs, validated the way one path is. The
# caller word-splits the result, so every check that reads a glob list applies
# the same path discipline: absolute, escaping and '-'-leading entries are
# configuration errors rather than globs that quietly match nothing. An empty
# result means the setting named nothing — the caller decides whether that is
# a switched-off check or an error.
gg_config_path_list() { # RAW LABEL — normalized globs, space-separated, on stdout
  local raw="$1" label="$2" entry norm out=""
  # Callers run under `set -f`, so this splits on whitespace without the shell
  # expanding a glob against the work tree.
  for entry in $raw; do
    norm="$(gg_config_path "$entry" "$label")" || return 1
    out="${out:+$out }$norm"
  done
  printf '%s' "$out"
}

# Shell glob matched against the full repo-relative path (`*` crosses `/`),
# the same match every exclusion list uses. The patterns come in word-split
# and unquoted, which is what makes them globs.
gg_path_matches() { # PATH PATTERN... — 0 when some pattern matches
  local path="$1" pat
  shift
  for pat in "$@"; do
    # $pat must expand unquoted to act as a glob.
    # shellcheck disable=SC2254
    case "$path" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# Where a lane's content LIVES, derived from the same globs: each pattern's
# leading run of glob-free directories, stopping before the first globbed
# segment and before the file name. changelog.d/*/*.md roots at changelog.d.
# A pattern carrying no glob at all names one file and roots nowhere, whether
# or not that name carries a slash — naming one file is not naming the
# directory it sits in.
#
# A root is what lets a lane say "everything else under here is refused". It
# says nothing about depth — that is the pattern's own, in
# gg_path_glob_section below. Deriving the two independently and reconciling
# them by a count is what makes each new pattern shape a new defect.
GG_PATH_GLOBS=""
GG_PATH_GLOBS_SHOWN=""
GG_PATH_ROOTS=""

gg_load_path_globs() { # RAW-LIST LABEL KEY — fills GG_PATH_GLOBS and _SHOWN
  local raw="$1" label="$2" key="$3" pat root rest seg
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
  GG_PATH_ROOTS=""
  for pat in $GG_PATH_GLOBS; do
    case "$pat" in
      *[*?[]*) ;;
      *) continue ;;
    esac
    root=""
    rest="$pat"
    while [ -n "$rest" ]; do
      seg="${rest%%/*}"
      [ "$seg" != "$rest" ] || break
      rest="${rest#*/}"
      case "$seg" in *[*?[]*) break ;; esac
      root="${root:+$root/}$seg"
    done
    [ -n "$root" ] || continue
    case " $GG_PATH_ROOTS " in
      *" $root "*) ;;
      *) GG_PATH_ROOTS="${GG_PATH_ROOTS:+$GG_PATH_ROOTS }$root" ;;
    esac
  done
}

gg_path_segments() { # PATH — how many `/`-separated segments it has
  local rest="$1" n=1
  while [ "${rest#*/}" != "$rest" ]; do
    rest="${rest#*/}"
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# Where a configured glob PLACES a path: the directory it sits in, taken only
# from a pattern that reaches the same depth. A pattern is
# <root...>/<section>/<name>, so its own last two segments say where the
# section sits — and a path deeper or shallower than the pattern is not one
# that pattern places, however readily `*` crossing `/` lets it match.
#
# The depth comes from the pattern rather than from a count applied after the
# root. A two-glob pattern places a path at its own depth and not one a
# directory deeper; a pattern whose section segment is literal narrows the
# same tree to that one section and still places entries in it; a pattern
# with a glob in the middle places whatever reaches ITS depth. A new pattern
# shape is answered by the pattern, not by another rule beside this one.
gg_path_glob_section() { # PATH — sets GG_PATH_SECTION, empty when nothing places it
  local path="$1" pat want have dir
  GG_PATH_SECTION=""
  have="$(gg_path_segments "$path")"
  # One segment is a bare file name: it sits in no directory, so no pattern
  # can place it under a section.
  [ "$have" -ge 2 ] || return 0
  for pat in $GG_PATH_GLOBS; do
    # $pat must expand unquoted to act as a glob.
    # shellcheck disable=SC2254
    case "$path" in
      $pat) ;;
      *) continue ;;
    esac
    want="$(gg_path_segments "$pat")"
    [ "$want" -eq "$have" ] || continue
    dir="${path%/*}"
    GG_PATH_SECTION="${dir##*/}"
    return 0
  done
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

# --- exclusion list: pattern<TAB>reason, reason mandatory --------------------
GG_EXCLUDE_PATTERNS=()

# The scans read the INDEX, so policy files come from the index too: staged
# edits to one govern staged scans, and a sparse checkout that omits the
# tracked file from disk still applies it. A path staged for DELETION governs
# as ABSENT — the commit carries no such file — which is not the same as a
# never-tracked path, where the worktree copy is all there is.
#
# Each probe reserves one status for its one expected answer and routes every
# other status through gg_collection_error. A probe git could not answer must
# not fall through to the worktree copy: that judges the commit against looser
# policy than the index carries, and says nothing while doing it.
gg_policy_content() { # FILE — content on stdout; 1 = the commit has no such file
  local file="$1" status=0 head_status=0 tree_status=0 entry=""
  # :(literal) — a path spelling a glob (`*`, `?`, `[`) must match itself in
  # the index, never whatever the glob happens to reach.
  git ls-files --error-unmatch -- ":(literal)$file" >/dev/null 2>&1 || status=$?
  case "$status" in
    0)
      # `:0:`, never a bare `:$file`: git reads a leading `0:` through `3:` in
      # the path as the stage selector, so a policy file named `0:excludes`
      # would resolve to whatever blob sits at `excludes`.
      git show ":0:$file" || gg_collection_error "could not read the staged copy of $(gg_shown "$file")"
      return 0
      ;;
    1) ;;
    *) gg_collection_error "could not query the index for $(gg_shown "$file") (git ls-files exit $status); refusing to treat it as untracked" ;;
  esac
  # ls-tree, never `cat-file -e`: with rev:path syntax git answers "no such
  # path in HEAD" with the same 128 an operational failure returns, so only
  # ls-tree (exit 0, empty output for an absent path) tells the two apart.
  # An unborn HEAD carries nothing by definition — rev-parse reserves exit 1.
  git rev-parse --verify --quiet HEAD >/dev/null 2>&1 || head_status=$?
  case "$head_status" in
    0)
      entry="$(git ls-tree HEAD -- ":(literal)$file" 2>/dev/null)" || tree_status=$?
      [ "$tree_status" -eq 0 ] \
        || gg_collection_error "could not probe HEAD for $(gg_shown "$file") (git ls-tree exit $tree_status); refusing to treat it as untracked"
      # Tracked in HEAD, absent from the index: staged for deletion.
      if [ -n "$entry" ]; then return 1; fi
      ;;
    1) ;;
    *) gg_collection_error "could not resolve HEAD while reading $(gg_shown "$file") (git rev-parse exit $head_status); refusing to treat it as untracked" ;;
  esac
  if [ -f "$file" ]; then
    cat -- "$file" || gg_collection_error "could not read $(gg_shown "$file")"
    return 0
  fi
  return 1
}

# Shell glob matched against the full repo-relative path (`*` crosses `/`);
# blank lines and `#` comments are ignored; a pattern without a reason is a
# config error. A missing file is an empty list. A `!` pattern CARVES its
# matches back into the scanned set and beats every exclusion row whatever the
# order (DEVELOPMENT.md § Excludes format). A row naming a path that begins
# with `!` escapes it as `\!foo`, which stays an exclusion.
gg_load_excludes() { # FILE — fills GG_EXCLUDE_PATTERNS and GG_EXCLUDE_CARVES
  local file="$1" line lineno pat reason carve content status=0
  GG_EXCLUDE_PATTERNS=()
  GG_EXCLUDE_CARVES=()
  # The read runs in a command substitution, so a gg_collection_error inside
  # it dies in that SUBSHELL and arrives here as a status. Only status 1 is
  # the answer "the commit has no such file" (an empty list); anything else
  # is the failed measurement that already named itself on stderr, and
  # reading it as an empty list would let the gate run on no policy at all.
  content="$(gg_policy_content "$file")" || status=$?
  case "$status" in
    0) ;;
    1) return 0 ;;
    *) gg_collection_error "refusing to run on an unread exclusion list: $(gg_shown "$file") (exit $status, cause above)" ;;
  esac
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      "" | "#"*) continue ;;
    esac
    pat="${line%%"$GG_TAB"*}"
    reason="${line#*"$GG_TAB"}"
    if [ "$pat" = "$line" ] || [ -z "$pat" ] || [ -z "$reason" ]; then
      gg_config_error "$(gg_shown "$file"):$lineno: expected 'pattern<TAB>reason' (every exclusion carries its justification)"
    fi
    case "$pat" in
      "!"*)
        carve="${pat#!}"
        [ -n "$carve" ] \
          || gg_config_error "$(gg_shown "$file"):$lineno: '!' carves matching paths back into the scanned set and needs a pattern after it"
        GG_EXCLUDE_CARVES+=("$carve")
        ;;
      *) GG_EXCLUDE_PATTERNS+=("$pat") ;;
    esac
  done <<<"$content"
}

gg_is_excluded() { # PATH — 0 when an exclusion glob matches and no `!` row carves it back
  # The loaded lists, matched by the one spelling above. Guarded expansion: an
  # empty array is an unbound variable under Bash 3.2 with set -u.
  gg_path_matches "$1" ${GG_EXCLUDE_PATTERNS[@]+"${GG_EXCLUDE_PATTERNS[@]}"} || return 1
  ! gg_path_matches "$1" ${GG_EXCLUDE_CARVES[@]+"${GG_EXCLUDE_CARVES[@]}"}
}
