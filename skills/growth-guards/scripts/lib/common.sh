# shellcheck shell=bash
# Shared plumbing for the growth-guards check family. Sourced (not executed)
# by every scripts/* check. Bash 3.2-safe throughout: no Bash 4+ builtins
# or array kinds, guarded expansion for possibly-empty arrays.
#
# Family contract carried here: exit 0 clean, 1 violations, 2
# usage/config/collection error. The gates distinguish "measured and fine"
# from "could not measure": any failure to collect (an unreadable file, a
# git or grep execution failure) goes through gg_collection_error — a loud
# exit 2, never a silent pass.
#
# Each check sets GG_CHECK to its own name before calling any helper, so
# every diagnostic names the check that produced it.

set -euo pipefail

GG_TAB="$(printf '\t')"

gg_config_error() {
  echo "::error::${GG_CHECK:-growth-guards}: $*" >&2
  exit 2
}

# Same loud exit as a config error, distinct name so call sites read as
# what they are: a measurement that failed, never a verdict.
gg_collection_error() {
  echo "::error::${GG_CHECK:-growth-guards}: $*" >&2
  exit 2
}

gg_repo_root_cd() { # cd to the repository root; all configured paths are repo-relative
  local root
  root="$(git rev-parse --show-toplevel)" || gg_config_error "not inside a git repository"
  cd "$root" || gg_config_error "cannot cd to repository root '$root'"
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

# --- exclusion list: pattern<TAB>reason, reason mandatory --------------------
# Shell glob matched against the full repo-relative path (`*` crosses `/`);
# blank lines and `#` comments are ignored; a pattern without a reason is a
# config error — every exclusion carries its justification. A missing file
# is an empty list.
GG_EXCLUDE_PATTERNS=()

gg_load_excludes() { # FILE — fills GG_EXCLUDE_PATTERNS
  local file="$1" line lineno pat reason content
  GG_EXCLUDE_PATTERNS=()
  # The scans read the INDEX, so the exclusion list comes from the index
  # too: staged edits to it govern staged scans, and a sparse checkout
  # that omits the tracked file from disk still applies it. The worktree
  # copy is only the fallback for an untracked list; absent both places
  # is an empty list.
  if git ls-files --error-unmatch -- "$file" >/dev/null 2>&1; then
    content="$(git show ":$file")" || gg_collection_error "could not read the staged copy of $file"
  elif [ -f "$file" ]; then
    content="$(cat -- "$file")" || gg_collection_error "could not read $file"
  else
    return 0
  fi
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

gg_count_nonempty_lines() { # FILE — count on stdout; loud exit if grep cannot read it
  # grep -c exits 1 on zero matches but still prints 0 — only exit >= 2
  # (execution/read failure) means the count is unknown.
  local n status=0
  n="$(grep -c . -- "$1")" || status=$?
  [ "$status" -le 1 ] || gg_collection_error "could not count lines in $1 (grep exit $status)"
  printf '%s\n' "$n"
}
