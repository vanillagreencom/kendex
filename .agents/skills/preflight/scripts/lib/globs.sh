# shellcheck shell=bash
# Path matching shared by preflight settings that hold space-separated globs.

pf_glob_matches() { # PATTERN PATH — a `*` never reaches past its own component
  local pat="$1" path="$2" pc pp
  while :; do
    if [ -z "$pat" ]; then
      if [ -z "$path" ]; then return 0; fi
      return 1
    fi
    [ -n "$path" ] || return 1
    case "$pat" in */*) pc="${pat%%/*}"; pat="${pat#*/}" ;; *) pc="$pat"; pat="" ;; esac
    case "$path" in */*) pp="${path%%/*}"; path="${path#*/}" ;; *) pp="$path"; path="" ;; esac
    case "$pp" in $pc) ;; *) return 1 ;; esac
  done
}

pf_path_matches_globs() { # GLOBS PATH — `**/` is the only depth crossing
  local globs="$1" path="$2" pat rc=1 rest
  set -f
  for pat in $globs; do
    case "$pat" in
      '**/'*)
        pat="${pat#'**/'}"
        rest="$path"
        while :; do
          if pf_glob_matches "$pat" "$rest"; then
            rc=0
            break
          fi
          case "$rest" in */*) rest="${rest#*/}" ;; *) break ;; esac
        done
        ;;
      *) pf_glob_matches "$pat" "$path" && rc=0 ;;
    esac
    [ "$rc" = 1 ] || break
  done
  set +f
  return "$rc"
}
