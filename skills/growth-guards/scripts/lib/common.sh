# shellcheck shell=bash
# Shared plumbing for the growth-guards check family. Sourced (not executed)
# by every scripts/* check, which sets GG_CHECK to its own name first so every
# diagnostic names its producer.
#
# Family contract: exit 0 clean, 1 violations, 2 usage/config/collection
# error. A measurement that could not be taken goes through
# gg_collection_error — a loud exit 2, never a silent pass.
#
# Bash 3.2-safe throughout: no Bash 4+ builtins or array kinds, guarded
# expansion for possibly-empty arrays.

set -euo pipefail

# Sourced here rather than by each check: every one of them needs a repository
# root, and that is a path capture.
# not-a-path: this IS the bootstrap that loads the idiom, so it cannot use
# it. A library directory whose name ends in a newline fails here loudly,
# with the source unfound, rather than quietly resolving somewhere else.
# shellcheck source=paths.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/paths.sh"
# The configured-path-list concept, whole: the glob list, the walk, and what
# a lane may measure at a matched path. Its helpers call back into this file,
# which is why it is sourced here rather than by each lane — resolution is at
# call time, so the order of the two is free.
# not-a-path: same bootstrap as above; the idiom it loads is not available yet.
# shellcheck source=configured-paths.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/configured-paths.sh"

GG_TAB="$(printf '\t')"
GG_VIOLATIONS=0
# Cleanup state is per-process. An INHERITED value must never decide what a
# guard deletes on exit: gg_settings_index_mode arms the same trap without
# creating a scratch directory, and the checks a hook lane runs inherit the
# exported settings cache their parent is still reading.
GG_TMP=""
GG_SETTINGS_INDEX_OWNED=0
# In-flight staging file for gg_install_file, so an interrupt between its
# creation and its rename leaves nothing beside the destination.
GG_INSTALL_TMP=""
# Extra `git grep` flags for the index lanes below, set by a check before it
# calls one and empty for every check that does not. Case sensitivity is the one
# thing it carries: a lane banning comment markers or lint pragmas matches
# their exact spelling, while a lane banning WORDS wants -i, where a
# sentence-initial capital is the same word.
GG_GREP_LANE_FLAGS=()

gg_config_error() {
  echo "::error::${GG_CHECK:-growth-guards}: $*" >&2
  exit 2
}

# Same loud exit, distinct name so call sites read as what they are: a
# measurement that failed, never a verdict.
gg_collection_error() { gg_config_error "$@"; }

# Only what THIS process created: GG_SETTINGS_INDEX_DIR is exported to the
# checks a hook lane runs, and they must not delete the directory their parent
# is still resolving settings from.
gg_cleanup() {
  [ -z "${GG_INSTALL_TMP:-}" ] || rm -f -- "$GG_INSTALL_TMP"
  [ -z "${GG_TMP:-}" ] || rm -rf -- "$GG_TMP"
  [ "${GG_SETTINGS_INDEX_OWNED:-0}" = "1" ] && rm -rf -- "$GG_SETTINGS_INDEX_DIR"
  return 0
}

gg_tmpdir() { # per-run scratch directory in GG_TMP, removed at exit
  GG_TMP="$(mktemp -d "${TMPDIR:-/tmp}/gg-${GG_CHECK:-growth-guards}.XXXXXX")" \
    || gg_config_error "could not create a temporary directory"
  trap gg_cleanup EXIT
}

gg_repo_root_cd() { # cd to the repository root; all configured paths are repo-relative
  local root
  gg_path root git rev-parse --show-toplevel || gg_config_error "not inside a git repository"
  cd -- "$root" || gg_config_error "cannot cd to repository root '$root'"
}

# A hook lane judges ONE commit, configuration included: tracked settings
# sources resolve from the index while this is on, so an unstaged edit cannot
# change the policy a commit is measured against. Call it after cd-ing to the
# repository root.
gg_settings_index_mode() {
  GG_SETTINGS_INDEX_DIR="$(mktemp -d "${TMPDIR:-/tmp}/gg-settings.XXXXXX")" \
    || gg_config_error "could not create a temporary directory"
  GG_SETTINGS_INDEX_OWNED=1
  trap gg_cleanup EXIT
  GG_SETTINGS_FROM_INDEX=1
  export GG_SETTINGS_FROM_INDEX GG_SETTINGS_INDEX_DIR
}

gg_positive_int() { # VALUE NAME — config error unless VALUE is a positive integer
  case "$1" in
    "" | *[!0-9]* | 0*[0-9] | 0) gg_config_error "$2 must be a positive integer, got '$1'" ;;
  esac
}

# Lexically normalize a configured repo-relative path (leading ./, internal
# ./ and .. segments): git records canonical relative paths, and every
# literal comparison against them must agree. Pure string surgery — no
# symlink resolution.
gg_normalize_rel_path() { # PATH -> normalized on stdout; nonzero if it escapes
  local input="$1" out="" seg rest
  rest="$input"
  while [ -n "$rest" ]; do
    seg="${rest%%/*}"
    if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    case "$seg" in
      "" | ".") ;;
      "..")
        case "$out" in
          "") return 1 ;;
          */*) out="${out%/*}" ;;
          *) out="" ;;
        esac
        ;;
      *) out="${out:+$out/}$seg" ;;
    esac
  done
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# Validate + normalize one configured path. Absolute paths and paths that
# escape the repository are configuration errors; a path beginning with '-'
# would read as an option to the line utilities that touch it — refuse it
# as configuration rather than trusting every call site's `--` guard.
gg_config_path() { # RAW LABEL — normalized on stdout; nonzero + ::error on stderr
  local raw="$1" label="$2" norm
  case "$raw" in
    /*)
      echo "::error::${GG_CHECK:-growth-guards}: $label path must be repo-root-relative, got absolute: $raw" >&2
      return 1
      ;;
  esac
  if ! norm="$(gg_normalize_rel_path "$raw")"; then
    echo "::error::${GG_CHECK:-growth-guards}: $label path escapes the repository or normalizes empty: $raw" >&2
    return 1
  fi
  case "$norm" in
    -*)
      echo "::error::${GG_CHECK:-growth-guards}: $label path must not begin with '-': $norm" >&2
      return 1
      ;;
  esac
  printf '%s' "$norm"
}

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

# One resolution order for every configured path: an explicit flag wins, then
# the setting, then the built-in default — validated and normalized either way.
gg_resolve_path() { # FLAG-VALUE KEY DEFAULT LABEL — normalized path on stdout
  local raw="$1"
  [ -n "$raw" ] || raw="$(gg_setting "$2" "$3")" || return 1
  gg_config_path "$raw" "$4"
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
      git show ":0:$file" || gg_collection_error "could not read the staged copy of $file"
      return 0
      ;;
    1) ;;
    *) gg_collection_error "could not query the index for $file (git ls-files exit $status); refusing to treat it as untracked" ;;
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
        || gg_collection_error "could not probe HEAD for $file (git ls-tree exit $tree_status); refusing to treat it as untracked"
      # Tracked in HEAD, absent from the index: staged for deletion.
      if [ -n "$entry" ]; then return 1; fi
      ;;
    1) ;;
    *) gg_collection_error "could not resolve HEAD while reading $file (git rev-parse exit $head_status); refusing to treat it as untracked" ;;
  esac
  if [ -f "$file" ]; then
    cat -- "$file" || gg_collection_error "could not read $file"
    return 0
  fi
  return 1
}

# Replace DEST with SRC's bytes through a rename inside DEST's own directory.
# A direct redirect onto DEST, or a rename that crosses a filesystem (where mv
# degrades to copy-then-unlink), leaves DEST TRUNCATED behind an interrupt —
# and a truncated policy file is read as a complete one, which for a ratchet
# baseline loosens the gate instead of failing it.
gg_install_file() { # SRC DEST LABEL
  local src="$1" dest="$2" label="$3"
  # mktemp, never a name derived from the pid: the staging file lands in a
  # directory the repository controls, a predictable name can already be
  # sitting there, and `cp` writes THROUGH a symlink — so a planted
  # `.gg-install.<pid>.<name>` link would redirect the write anywhere the
  # user can reach. mktemp creates the file itself, exclusively.
  GG_INSTALL_TMP="$(mktemp "$dest.gg-install.XXXXXX")" \
    || gg_collection_error "could not stage the replacement for $label beside $dest"
  if ! cat -- "$src" >"$GG_INSTALL_TMP"; then
    rm -f -- "$GG_INSTALL_TMP"
    GG_INSTALL_TMP=""
    gg_collection_error "could not stage the replacement for $label beside $dest"
  fi
  if ! mv -- "$GG_INSTALL_TMP" "$dest"; then
    rm -f -- "$GG_INSTALL_TMP"
    GG_INSTALL_TMP=""
    gg_collection_error "could not replace $label at $dest — inspect the file before trusting it"
  fi
  GG_INSTALL_TMP=""
}

# Shell glob matched against the full repo-relative path (`*` crosses `/`);
# blank lines and `#` comments are ignored; a pattern without a reason is a
# config error. A missing file is an empty list.
gg_load_excludes() { # FILE — fills GG_EXCLUDE_PATTERNS
  local file="$1" line lineno pat reason content status=0
  GG_EXCLUDE_PATTERNS=()
  # The read runs in a command substitution, so a gg_collection_error inside
  # it dies in that SUBSHELL and arrives here as a status. Only status 1 is
  # the answer "the commit has no such file" (an empty list); anything else
  # is the failed measurement that already named itself on stderr, and
  # reading it as an empty list would let the gate run on no policy at all.
  content="$(gg_policy_content "$file")" || status=$?
  case "$status" in
    0) ;;
    1) return 0 ;;
    *) gg_collection_error "refusing to run on an unread exclusion list: $file (exit $status, cause above)" ;;
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
      gg_config_error "$file:$lineno: expected 'pattern<TAB>reason' (every exclusion carries its justification)"
    fi
    GG_EXCLUDE_PATTERNS+=("$pat")
  done <<<"$content"
}

gg_is_excluded() { # PATH — 0 when some exclusion glob matches the full path
  local path="$1" pat
  # Guarded expansion: an empty array is an unbound variable under Bash 3.2
  # with set -u.
  for pat in ${GG_EXCLUDE_PATTERNS[@]+"${GG_EXCLUDE_PATTERNS[@]}"}; do
    # $pat must expand unquoted to act as a glob.
    # shellcheck disable=SC2254
    case "$path" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# `git grep --cached` SKIPS an unmerged index entry entirely: it spends no
# error status and writes no `error:` line doing it, so gg_grep_guard sees a
# complete scan and the lane reports OK over a work tree whose files carry
# conflict markers. The index cannot be scanned while a merge is unresolved,
# so every --cached scan refuses first. The remedy is the only one there is:
# finish or abort the merge.
gg_require_merged_index() { # PATHSPEC... — returns only when nothing is unmerged
  local rows status=0 paths count=0
  rows="$(git ls-files --unmerged -- "$@")" || status=$?
  [ "$status" -eq 0 ] \
    || gg_collection_error "could not read the index for unmerged paths (git ls-files exit $status)"
  [ -n "$rows" ] || return 0
  paths="$(printf '%s\n' "$rows" | cut -f2- | LC_ALL=C sort -u)"
  count="$(printf '%s\n' "$paths" | grep -c .)" || count=0
  printf '%s\n' "$paths" >&2
  gg_collection_error "the index carries $count unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run"
}

# Judge one `git grep` run from its exit status AND captured stderr. The
# status carries only the MATCH result: a staged blob git cannot read is an
# `error:` line on stderr while the status still says 1 (nothing matched) or
# 0 (something else matched), so status alone can bless a scan that skipped
# content — and a status-0 run that also errored must not fold as an
# ordinary violation verdict over a partial scan. The `error:` prefix is
# git's C-locale spelling, so every call feeding this guard runs under
# LC_ALL=C — a translated prefix would slip past the match.
gg_grep_guard() { # STATUS ERRFILE CONTEXT — returns only when the scan is complete
  local status="$1" errfile="$2" context="$3" first_err
  [ ! -s "$errfile" ] || cat -- "$errfile" >&2
  [ "$status" -le 1 ] || gg_collection_error "git grep failed $context (exit $status)"
  first_err="$(grep -E '^error:' -- "$errfile" | head -n 1 || true)"
  [ -z "$first_err" ] || gg_collection_error "git grep could not read staged content while $context ($first_err)"
}

# One banned shape, listed over INDEX content: the tracked files whose staged
# blob carries it, minus the excluded paths and the blobs whose own bytes are
# binary. Survivors land NUL-delimited in OUTFILE (-l -z, so a path containing
# ':' cannot garble parsing).
#
# CONTENT decides what is scannable here and an attribute never does. The
# listing forces text (-a): `git grep -I` asks the path's userdiff driver, so
# one committed `*.ext -diff` or `*.ext binary` row makes git call every
# matching blob binary and drop it with no status and no stderr — a whole
# extension reading as clean. What forcing text lets through is judged on
# content instead: a listed blob carrying a NUL in its leading bytes is a
# genuine asset and is NAMED as unmeasured, so it never reaches a violation
# record as raw bytes and never rides inside a clean total either. Only a path
# the listing NAMED is read, so the sniff costs one `cat-file` per matching
# file, never one per tracked file. That is the same answer todo-ban's commit
# lane gives the same question.
# Needs GG_TMP (gg_tmpdir) and the excludes already loaded.
gg_content_carriers() { # OUTFILE LABEL ERE PATHSPEC... — measurable carriers, NUL-delimited
  local out="$1" label="$2" ere="$3" status=0 f
  shift 3
  gg_require_merged_index "$@"
  LC_ALL=C git grep --cached -alzE ${GG_GREP_LANE_FLAGS[@]+"${GG_GREP_LANE_FLAGS[@]}"} "$ere" -- "$@" >"$GG_TMP/carriers.z" 2>"$GG_TMP/carriers.err" || status=$?
  gg_grep_guard "$status" "$GG_TMP/carriers.err" "scanning tracked files for $label"
  : >"$out"
  while IFS= read -r -d '' f; do
    gg_is_excluded "$f" && continue
    # The stage-0 blob at that exact path, so the sniff reads the same bytes
    # the listing matched.
    gg_read_blob ":0:$f" "$f" "$label"
    if gg_blob_is_binary "$GG_TMP/blob" "$f"; then
      gg_note_skip "$f" "binary content, not text"
      continue
    fi
    printf '%s\0' "$f" >>"$out"
  done <"$GG_TMP/carriers.z"
}

# The same shape detailed per carrier: the numbered hits in each listed file,
# where the known path prefix strips exactly. The detail pass is
# line-oriented, so a path embedding a newline yields no DETAIL lines — the
# file still fails the listing. Both scans force text and move TOGETHER; a
# text-forced listing over a binary-skipping detail scan names a file the
# detail scan then finds nothing in, which the invariant below turns into a
# spurious exit 2.
gg_grep_lane() { # LABEL ERE REMEDY PATHSPEC... — numbered violations on stdout
  local label="$1" ere="$2" remedy="$3" f hit_status hit
  shift 3
  gg_content_carriers "$GG_TMP/lane.z" "$label" "$ere" "$@"
  while IFS= read -r -d '' f; do
    hit_status=0
    LC_ALL=C git grep --cached -anE ${GG_GREP_LANE_FLAGS[@]+"${GG_GREP_LANE_FLAGS[@]}"} "$ere" -- ":(literal)$f" >"$GG_TMP/lane.hits" 2>"$GG_TMP/lane.err" || hit_status=$?
    gg_grep_guard "$hit_status" "$GG_TMP/lane.err" "detailing the $label hits in '$f'"
    # This file just listed as containing hits; anything but a clean re-scan
    # (including "no matches") means the measurement is broken.
    [ "$hit_status" -eq 0 ] || gg_collection_error "git grep could not detail the $label hits in '$f' (exit $hit_status)"
    while IFS= read -r hit; do
      echo "${GG_CHECK:-growth-guards} FAIL $label: $f:${hit#"$f":}"
      echo "  remedies: $remedy"
      GG_VIOLATIONS=$((GG_VIOLATIONS + 1))
    done <"$GG_TMP/lane.hits"
  done <"$GG_TMP/lane.z"
}

gg_count_nonempty_lines() { # FILE — count on stdout; loud exit if grep cannot read it
  # grep -c exits 1 on zero matches but still prints 0 — only exit >= 2
  # (execution/read failure) means the count is unknown.
  local n status=0
  n="$(grep -c . -- "$1")" || status=$?
  [ "$status" -le 1 ] || gg_collection_error "could not count lines in $1 (grep exit $status)"
  printf '%s\n' "$n"
}
