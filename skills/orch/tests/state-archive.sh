#!/usr/bin/env bash
# Surface: lib/state-archive.sh archive_write and archive_root.
# Inputs: scripts/orch-env, scripts/lib/kendex-env.sh.
# State cleanup and mailbox compaction share this writer. The archive root
# follows project settings and preserves the compatible fallback and modes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$TEST_DIR/../scripts"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo "state-archive: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "state-archive: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "state-archive: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

cat > "$TMP_ROOT/write.sh" <<'SCRIPT'
set -euo pipefail
SCRIPT_DIR=$1
. "$SCRIPT_DIR/lib/state-archive.sh"
archive_write "$PWD/repo" records '{"kept":true}' "$PWD/input" || exit 1
printf '%s\n' "$ARCHIVE"
SCRIPT

while IFS='|' read -r name layer expected; do
    project="$TMP_ROOT/$name"
    mkdir -p "$project/home" "$project/.kendex"
    printf 'archive bytes\n' > "$project/input"
    case "$layer" in
        settings|local|private|environment|relative|empty)
            printf '[env]\nORCH_ARCHIVE_ROOT = "%s"\n' "$project/settings archive" > "$project/kendex.settings.toml" ;;
    esac
    case "$layer" in
        local|private|environment)
            printf '[env]\nORCH_ARCHIVE_ROOT = "%s"\n' "$project/local archive" > "$project/.kendex/settings.toml" ;;
    esac
    case "$layer" in
        private|environment)
            printf 'printf "loader-note\\n"\nORCH_ARCHIVE_ROOT="%s"\n' "$project/private archive" > "$project/.env.local" ;;
        relative) printf '[env]\nORCH_ARCHIVE_ROOT = "relative archive"\n' > "$project/kendex.settings.toml" ;;
        empty) printf '[env]\nORCH_ARCHIVE_ROOT = ""\n' > "$project/kendex.settings.toml" ;;
    esac
    args=("PATH=$PATH" "HOME=$project/home")
    [[ "$layer" == home ]] || args+=("FLEET_DIR=$project/fleet")
    [[ "$layer" != environment ]] || args+=("ORCH_ARCHIVE_ROOT=$project/environment archive")
    got="$(cd -- "$project" && env -i "${args[@]}" "$BASH" "$TMP_ROOT/write.sh" "$SCRIPTS")"
    assert_eq "${got%/*}" "$project/$expected/repo/oversee" "$name: archive folder"
    assert_eq "$(tar -xOzf "$got" "${project#/}/input")" 'archive bytes' "$name: archive keeps input bytes"
    modes="$(python3 -c 'import pathlib, sys; p = pathlib.Path(sys.argv[1]); print(oct(p.parent.stat().st_mode & 0o777), oct(p.stat().st_mode & 0o777))' "$got")"
    assert_eq "$modes" '0o700 0o600' "$name: private directory and archive"
done <<'ROWS'
default-home|home|home/.fleet/archive
default-fleet|fleet|fleet/archive
settings|settings|settings archive
local-settings|local|local archive
private|private|private archive
environment|environment|environment archive
relative|relative|relative archive
empty|empty|fleet/archive
ROWS

# Keep the reader present but restore the old root choice. The same folder
# assertion then rejects the writer's loss of the configured location.
MUTANT="$(mutant_scripts ignored-root lib/state-archive.sh)" || exit 1
mutate_file "$MUTANT/lib/state-archive.sh" 'ARCHIVE_DIR="$root/${repo_root##*/}/oversee"' \
    'ARCHIVE_DIR="${FLEET_DIR:-$HOME/.fleet}/archive/${repo_root##*/}/oversee"'
project="$TMP_ROOT/settings"
got="$(cd -- "$project" && env -i PATH="$PATH" HOME="$project/home" FLEET_DIR="$project/fleet" \
    "$BASH" "$TMP_ROOT/write.sh" "$MUTANT")"
[[ "${got%/*}" != "$project/settings archive/repo/oversee" ]] \
    && pass 'control: ignoring the root fails the configured-folder assertion' \
    || fail 'control: ignoring the root fails the configured-folder assertion'

# orch-env can fail after printing a value if a private file returns failure.
# The unchanged writer must refuse that read and produce no archive.
REFUSED="$(mutant_scripts refused-reader orch-env)" || exit 1
cat > "$REFUSED/orch-env" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD/refused archive"
exit 1
STUB
rc=0
(cd -- "$project" && env -i PATH="$PATH" HOME="$project/home" "$BASH" "$TMP_ROOT/write.sh" "$REFUSED") \
    > "$TMP_ROOT/refused.out" 2> "$TMP_ROOT/refused.err" || rc=$?
assert_eq "$rc" 1 'a failed setting read refuses the archive'
[[ ! -e "$project/refused archive" && ! -s "$TMP_ROOT/refused.out" ]] \
    && pass 'a failed setting read creates no archive' || fail 'a failed setting read creates no archive'
CONTROL="$(mutant_scripts ignored-failure lib/state-archive.sh)" || exit 1
rm -- "$CONTROL/orch-env"
cp -- "$REFUSED/orch-env" "$CONTROL/orch-env"
mutate_file "$CONTROL/lib/state-archive.sh" \
    '|| { ARCHIVE_ERR="archive-root-read-failed key=ORCH_ARCHIVE_ROOT"; return 1; }' '|| true'
rc=0
(cd -- "$project" && env -i PATH="$PATH" HOME="$project/home" "$BASH" "$TMP_ROOT/write.sh" "$CONTROL") \
    > "$TMP_ROOT/control.out" 2> "$TMP_ROOT/control.err" || rc=$?
assert_eq "$rc" 0 'control: ignoring the failed read breaks the refusal assertion'
[[ -s "$TMP_ROOT/control.out" ]] && pass 'control: the failed read now creates an archive' \
    || fail 'control: the failed read now creates an archive'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
