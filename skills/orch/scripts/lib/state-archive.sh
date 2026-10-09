# shellcheck shell=bash
# State pruning, item close-out and mailbox compaction archive before removal.
# ROOT names the main checkout; REMOVAL_ROOT names its state or mailbox folder.
# PATHS are absolute and RECORDS, where given,
# lands as records.json. Paths inside the archive are relative to /.
# Each build owns its scratch and umask in a subshell, leaving caller locks
# and traps untouched. A failure removes its partial archive and returns its
# diagnostic in ARCHIVE_ERR; success returns the private tarball in ARCHIVE.
ARCHIVE="" ARCHIVE_DIR="" ARCHIVE_ERR=""
# Keep the compatible default here so local and SSH close-out share it.
# This is a storage setting, below the decision-record bar.
archive_root() { # REPO_ROOT DESTINATION_SUFFIX [REMOVAL_ROOT_OR_ARCHIVE_INPUT...]
    local root state_file
    root="$("$SCRIPT_DIR/orch-env" ORCH_ARCHIVE_ROOT "")" || return 1
    if [[ -z "$root" ]]; then
        root="${FLEET_DIR:-$HOME/.fleet}/archive"
        [[ "$root" == /* ]] || root="$PWD/$root"
        printf '%s\n' "$root"
        return 0
    fi
    command -v python3 >/dev/null 2>&1 || { printf '%s\n' 'state-archive: dependency-missing command=python3 key=ORCH_ARCHIVE_ROOT' >&2; return 1; }
    # path owns ORCH_STATE_DIR resolution for every caller, including SSH.
    state_file="$("$SCRIPT_DIR/workflow-state" path oversee)" || return 1
    # merge-pr removes linked checkouts; prune removes state subdirectories.
    # A configured archive must outlive both, including through directory links.
    python3 - "$root" "$1" "$2" "${state_file%/*}" "${@:3}" <<'PY'
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
if not root.is_absolute():
    print(f"state-archive: archive-root-relative key=ORCH_ARCHIVE_ROOT path={root}", file=sys.stderr)
    sys.exit(1)
root = root.resolve()
destination = (root / sys.argv[3]).resolve()
excluded = [pathlib.Path(value).resolve() for value in sys.argv[4:] if value]
# Configured roots need Git's full list because merge-pr removes linked trees.
repo = sys.argv[2]
listing = subprocess.run(["git", "-C", repo, "worktree", "list", "--porcelain", "-z"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
if listing.returncode != 0:
    print(f"state-archive: archive-worktrees-unreadable path={repo}", file=sys.stderr)
    sys.exit(1)
worktrees = [pathlib.Path(field[9:].decode()).resolve()
             for field in listing.stdout.split(b"\0") if field.startswith(b"worktree ")]
# Git lists the main checkout first. worktree remove never removes it.
excluded.extend(worktrees[1:])
for removed in excluded:
    if any(path == removed or removed in path.parents for path in (root, destination)):
        print(f"state-archive: archive-root-overlap key=ORCH_ARCHIVE_ROOT path={root} removed={removed}", file=sys.stderr)
        sys.exit(1)
print(root)
PY
}

archive_write() { # ROOT REMOVAL_ROOT STEM RECORDS PATH...
    local repo_root="$1" removal_root="$2" stem="$3" records="$4" result root
    shift 4
    ARCHIVE="" ARCHIVE_ERR="" ARCHIVE_DIR=""
    root="$(archive_root "$repo_root" "${repo_root##*/}/oversee" "$removal_root" "$@")" || { ARCHIVE_ERR="archive-root-read-failed key=ORCH_ARCHIVE_ROOT"; return 1; }
    ARCHIVE_DIR="$root/${repo_root##*/}/oversee"
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
