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

GG_TAB="$(printf '\t')"
GG_VIOLATIONS=0
# Cleanup state is per-process. An INHERITED value must never decide what a
# guard deletes on exit: gg_settings_index_mode arms the same trap without
# creating a scratch directory, and the checks a hook lane runs inherit the
# exported settings cache their parent is still reading.
GG_TMP=""
GG_SETTINGS_INDEX_OWNED=0

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
  root="$(git rev-parse --show-toplevel)" || gg_config_error "not inside a git repository"
  cd "$root" || gg_config_error "cannot cd to repository root '$root'"
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
      git show ":$file" || gg_collection_error "could not read the staged copy of $file"
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
  local src="$1" dest="$2" label="$3" tmp
  tmp="$(dirname -- "$dest")/.gg-install.$$.$(basename -- "$dest")"
  if ! cp -- "$src" "$tmp"; then
    rm -f -- "$tmp"
    gg_collection_error "could not stage the replacement for $label beside $dest"
  fi
  if ! mv -- "$tmp" "$dest"; then
    rm -f -- "$tmp"
    gg_collection_error "could not replace $label at $dest — inspect the file before trusting it"
  fi
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

# One banned shape, scanned over INDEX content in two phases: the offending
# FILES (-l -z, so a path containing ':' cannot garble parsing), then the
# numbered hits per file, where the known path prefix strips exactly. Binary
# files are skipped (-I). The per-file pass is line-oriented, so a path
# embedding a newline yields no DETAIL lines — the file still fails phase one.
# Needs GG_TMP (gg_tmpdir) and the excludes already loaded.
gg_grep_lane() { # LABEL ERE REMEDY PATHSPEC... — numbered violations on stdout
  local label="$1" ere="$2" remedy="$3" status=0 f hit_status hit
  shift 3
  gg_require_merged_index "$@"
  LC_ALL=C git grep --cached -lIzE "$ere" -- "$@" >"$GG_TMP/lane.z" 2>"$GG_TMP/lane.err" || status=$?
  gg_grep_guard "$status" "$GG_TMP/lane.err" "scanning tracked files for $label"
  while IFS= read -r -d '' f; do
    gg_is_excluded "$f" && continue
    hit_status=0
    LC_ALL=C git grep --cached -nIE "$ere" -- ":(literal)$f" >"$GG_TMP/lane.hits" 2>"$GG_TMP/lane.err" || hit_status=$?
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
