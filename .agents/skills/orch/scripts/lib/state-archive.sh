# shellcheck shell=bash
# State pruning, item close-out and mailbox compaction archive before removal.
# ROOT names the main checkout; PATHS are absolute and RECORDS, where given,
# lands as records.json. Paths inside the archive are relative to /.
# Each build owns its scratch and umask in a subshell, leaving caller locks
# and traps untouched. A failure removes its partial archive and returns its
# diagnostic in ARCHIVE_ERR; success returns the private tarball in ARCHIVE.
ARCHIVE="" ARCHIVE_DIR="" ARCHIVE_ERR=""
archive_write() { # ROOT STEM RECORDS PATH...
    local repo_root="$1" stem="$2" records="$3" result
    shift 3
    ARCHIVE="" ARCHIVE_ERR=""
    ARCHIVE_DIR="${FLEET_DIR:-$HOME/.fleet}/archive/${repo_root##*/}/oversee"
    result="$( (
        stage=""
        trap 'rc=$?; if [[ -n "$stage" ]]; then rm -rf -- "${stage:?}" || exit 1; [[ "$rc" -eq 0 ]] || rm -f -- "${stage:?}.tgz" || exit 1; fi; exit "$rc"' EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        umask 077
        mkdir -p -- "$ARCHIVE_DIR" || exit 1
        candidate="$(mktemp -d "$ARCHIVE_DIR/$stem-XXXXXX" 2>&1)" || { printf '%s\n' "$candidate" >&2; exit 1; }
        stage="$candidate"
        if { { [[ -z "$records" ]] || printf '%s\n' "$records" > "$stage/records.json"; } \
             && { [[ -z "$records" ]] || printf '%s\n' "${stage#/}/records.json"
                  for unit in "$@"; do printf '%s\n' "${unit#/}"; done
                } > "$stage/paths" \
             && tar -czf "$stage.tgz" -C / -T "$stage/paths" 2>"$stage/tar.err"; }; then
            printf '%s\n' "$stage.tgz"
        else
            cat -- "$stage/tar.err" >&2 || exit 1
            exit 1
        fi
    ) 2>&1)" || {
        ARCHIVE_ERR="$result"
        return 1
    }
    ARCHIVE="$result"
}
