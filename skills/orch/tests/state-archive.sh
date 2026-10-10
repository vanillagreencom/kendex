#!/usr/bin/env bash
# Surface: lib/state-archive.sh archive_write and archive_root.
# Inputs: scripts/orch-env, scripts/workflow-state, scripts/git-context and their libraries.
# State cleanup and mailbox compaction share this writer. The archive root
# follows project settings and preserves the compatible fallback and modes.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export MSYS=winsymlinks:nativestrict
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPTS="$TEST_DIR/../scripts"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo "state-archive: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "state-archive: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "state-archive: scratch=resolve-failed" >&2; exit 1; }
CONTROL_ROOT="$(env -u TMPDIR mktemp -d)" || exit 1
CONTROL_ROOT="$(cd -- "$CONTROL_ROOT" && pwd -P)" || exit 1
trap 'rm -rf -- "${TMP_ROOT:?}" "${CONTROL_ROOT:?}"' EXIT

cat > "$TMP_ROOT/write.sh" <<'SCRIPT'
set -euo pipefail
SCRIPT_DIR=$1
. "$SCRIPT_DIR/lib/state-archive.sh"
archive_write "${ARCHIVE_TEST_REPO:-$PWD}" "${ARCHIVE_TEST_REMOVED:-$PWD/tmp}" records '{"kept":true}' "$PWD/input" || exit 1
printf '%s\n' "$ARCHIVE"
SCRIPT

while IFS='|' read -r name layer expected; do
    project="$TMP_ROOT/$name/repo"
    mkdir -p "$project/home" "$project/.kendex"
    git -C "$project" init -q
    git -C "$project" config gc.auto 0
    git -C "$project" config maintenance.auto false
    printf 'archive bytes\n' > "$project/input"
    case "$layer" in
        settings|local|private|environment|empty)
            printf '[env]\nORCH_ARCHIVE_ROOT = "%s"\n' "$project/settings archive" > "$project/kendex.settings.toml" ;;
    esac
    case "$layer" in
        local|private|environment)
            printf '[env]\nORCH_ARCHIVE_ROOT = "%s"\n' "$project/local archive" > "$project/.kendex/settings.toml" ;;
    esac
    case "$layer" in
        private|environment)
            printf 'printf "loader-note\\n"\nORCH_ARCHIVE_ROOT="%s"\n' "$project/private archive" > "$project/.env.local" ;;
        empty) printf '[env]\nORCH_ARCHIVE_ROOT = ""\n' > "$project/kendex.settings.toml" ;;
    esac
    args=("PATH=$PATH" "HOME=$project/home")
    [[ "$layer" == home ]] || args+=("FLEET_DIR=$project/fleet")
    [[ "$layer" != environment ]] || args+=("ORCH_ARCHIVE_ROOT=$project/environment archive")
    got="$(cd -- "$project" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" "${args[@]}" "$BASH" "$TMP_ROOT/write.sh" "$SCRIPTS")"
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
empty|empty|fleet/archive
ROWS

# Keep the reader present but restore the old root choice. The same folder
# assertion then rejects the writer's loss of the configured location.
MUTANT="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts ignored-root lib/state-archive.sh)" || exit 1
mutate_file "$MUTANT/lib/state-archive.sh" 'ARCHIVE_DIR="$root/${repo_root##*/}/oversee"' \
    'ARCHIVE_DIR="${FLEET_DIR:-$HOME/.fleet}/archive/${repo_root##*/}/oversee"'
project="$TMP_ROOT/settings/repo"
got="$(cd -- "$project" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" HOME="$project/home" FLEET_DIR="$project/fleet" \
    "$BASH" "$TMP_ROOT/write.sh" "$MUTANT")"
[[ "${got%/*}" != "$project/settings archive/repo/oversee" ]] \
    && pass 'control: ignoring the root fails the configured-folder assertion' \
    || fail 'control: ignoring the root fails the configured-folder assertion'

# orch-env can fail after printing a value if a private file returns failure.
# The unchanged writer must refuse that read and produce no archive.
REFUSED="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts refused-reader orch-env)" || exit 1
cat > "$REFUSED/orch-env" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$PWD/refused archive"
exit 1
STUB
rc=0
(cd -- "$project" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" HOME="$project/home" "$BASH" "$TMP_ROOT/write.sh" "$REFUSED") \
    > "$TMP_ROOT/refused.out" 2> "$TMP_ROOT/refused.err" || rc=$?
assert_eq "$rc" 1 'a failed setting read refuses the archive'
[[ ! -e "$project/refused archive" && ! -s "$TMP_ROOT/refused.out" ]] \
    && pass 'a failed setting read creates no archive' || fail 'a failed setting read creates no archive'
CONTROL="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts ignored-failure lib/state-archive.sh)" || exit 1
rm -- "$CONTROL/orch-env"
cp -- "$REFUSED/orch-env" "$CONTROL/orch-env"
mutate_file "$CONTROL/lib/state-archive.sh" \
    'root="$("$SCRIPT_DIR/orch-env" ORCH_ARCHIVE_ROOT "")" || return 1' \
    'root="$("$SCRIPT_DIR/orch-env" ORCH_ARCHIVE_ROOT "")" || true'
rc=0
(cd -- "$project" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" HOME="$project/home" "$BASH" "$TMP_ROOT/write.sh" "$CONTROL") \
    > "$TMP_ROOT/control.out" 2> "$TMP_ROOT/control.err" || rc=$?
assert_eq "$rc" 0 'control: ignoring the failed read breaks the refusal assertion'
[[ -s "$TMP_ROOT/control.out" ]] && pass 'control: the failed read now creates an archive' \
    || fail 'control: the failed read now creates an archive'

# Local default archives predate the Python resolver and work outside Git.
mkdir -p "$CONTROL_ROOT/no-python-bin" "$CONTROL_ROOT/default/repo"
for tool in bash dirname git mkdir mktemp tar gzip rm cat; do
    ln -s "$(command -v "$tool")" "$CONTROL_ROOT/no-python-bin/$tool"
done
project="$CONTROL_ROOT/default/repo"
printf 'default archive bytes\n' > "$project/input"
while IFS='|' read -r name fleet expected; do
    args=("PATH=$CONTROL_ROOT/no-python-bin" "HOME=$project/home" "ORCH_ARCHIVE_ROOT=")
    [[ "$fleet" == unset ]] || args+=("FLEET_DIR=$fleet")
    got="$(cd -- "$project" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" "${args[@]}" "$BASH" "$TMP_ROOT/write.sh" "$SCRIPTS")"
    assert_eq "${got%/*}" "$project/$expected/repo/oversee" "$name: default works without Python outside Git"
    assert_eq "$(tar -xOzf "$got" "${project#/}/input")" 'default archive bytes' "$name: default archive keeps input"
done <<ROWS
home|unset|home/.fleet/archive
absolute|$project/fleet|fleet/archive
relative|fleet|fleet/archive
ROWS
mutant="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts default-python lib/state-archive.sh)" || exit 1
mutate_file "$mutant/lib/state-archive.sh" "printf '%s\\n' \"\$root\"" \
    'python3 -c '\''import sys; print(sys.argv[1])'\'' "$root"'
rc=0
(cd -- "$project" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$CONTROL_ROOT/no-python-bin" HOME="$project/home" ORCH_ARCHIVE_ROOT= \
    "$BASH" "$TMP_ROOT/write.sh" "$mutant") > "$TMP_ROOT/default-control.out" 2> "$TMP_ROOT/default-control.err" || rc=$?
assert_eq "$rc" 1 'control: default Python dependency breaks the default archive assertion'
[[ ! -s "$TMP_ROOT/default-control.out" ]] && pass 'control: default Python dependency writes no archive' \
    || fail 'control: default Python dependency writes no archive'
rc=0
(cd -- "$project" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$CONTROL_ROOT/no-python-bin" HOME="$project/home" \
    ORCH_ARCHIVE_ROOT="$CONTROL_ROOT/configured-archives" "$BASH" "$TMP_ROOT/write.sh" "$SCRIPTS") \
    > "$TMP_ROOT/python.out" 2> "$TMP_ROOT/python.err" || rc=$?
assert_eq "$rc" 1 'configured roots refuse missing Python'
assert_contains "$(cat "$TMP_ROOT/python.err")" 'dependency-missing command=python3' 'configured root names the missing dependency'
mutant="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts ignored-python-check lib/state-archive.sh)" || exit 1
mutate_file "$mutant/lib/state-archive.sh" 'command -v python3 >/dev/null 2>&1 ||' 'true ||'
rc=0
(cd -- "$project" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$CONTROL_ROOT/no-python-bin" HOME="$project/home" \
    ORCH_ARCHIVE_ROOT="$CONTROL_ROOT/configured-archives" "$BASH" "$TMP_ROOT/write.sh" "$mutant") \
    > "$TMP_ROOT/python-control.out" 2> "$TMP_ROOT/python-control.err" || rc=$?
before="$FAIL"
assert_contains "$(cat "$TMP_ROOT/python-control.err")" 'dependency-missing command=python3' \
    'missing Python retains its dependency category' > "$TMP_ROOT/python-control-assertion.out"
if [[ "$FAIL" -gt "$before" ]]; then FAIL="$before"; pass 'control: missing Python check loses its dependency category'
else fail 'control: missing Python check loses its dependency category'; fi

# A close removes an entire linked checkout, including archives beside tmp.
# A prune removes old state subdirectories. Both bounds belong to the reader.
project="$TMP_ROOT/guard-project"
lane="$TMP_ROOT/guard-lane"
removed="$TMP_ROOT/expired-state"
mkdir -p "$project" "$removed"
git -C "$project" init -q
git -C "$project" config gc.auto 0
git -C "$project" config maintenance.auto false
git -C "$project" -c user.name=test -c user.email=test@example.invalid commit -q --allow-empty -m fixture
git -C "$project" worktree add -q --detach "$lane"
printf 'archive bytes\n' > "$project/input"
ln -s "$lane" "$TMP_ROOT/lane-link"
[[ -L "$TMP_ROOT/lane-link" ]] || exit 1

root_refusal() { # SCRIPTS ROOT LABEL
    local rc=0
    (cd -- "$project" && env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="${ARCHIVE_TEST_PATH:-$PATH}" ARCHIVE_REAL_GIT="$(command -v git)" ARCHIVE_GIT_FAILURE="${ARCHIVE_GIT_FAILURE:-listing}" HOME="$project/home" ORCH_ARCHIVE_ROOT="$2" \
        ARCHIVE_TEST_REPO="${ARCHIVE_TEST_REPO:-$project}" ARCHIVE_TEST_REMOVED="$removed" \
        "$BASH" "$TMP_ROOT/write.sh" "$1") > "$TMP_ROOT/root.out" 2> "$TMP_ROOT/root.err" || rc=$?
    assert_eq "$rc" 1 "$3: refuses an archive that cannot survive removal"
    [[ ! -s "$TMP_ROOT/root.out" ]] && pass "$3: writes no archive" || fail "$3: writes no archive"
}
while IFS='|' read -r form value; do
    case "$form" in
        relative|tilde) root="$value" ;;
        *) root="$TMP_ROOT/$value" ;;
    esac
    root_refusal "$SCRIPTS" "$root" "$form"
done <<'ROWS'
relative|archives
tilde|~/archives
linked-checkout|guard-lane/archives
parent-component|guard-project/../guard-lane/archives
directory-link|lane-link/archives
state-folder|expired-state/archives
ROWS

while IFS='|' read -r name rule replacement root; do
    mutant="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts "$name" lib/state-archive.sh)" || exit 1
    mutate_file "$mutant/lib/state-archive.sh" "$rule" "$replacement"
    [[ "$root" != state ]] || root="$removed/archives"
    before="$FAIL"
    root_refusal "$mutant" "$root" "$name" > "$TMP_ROOT/$name.out"
    if [[ "$FAIL" -gt "$before" ]]; then FAIL="$before"; pass "control: $name turns the refusal assertion red"
    else fail "control: $name turns the refusal assertion red"; fi
done <<'ROWS'
relative-accepted|if not root.is_absolute():|if False and not root.is_absolute():|archives
overlap-accepted|if any(path == removed or removed in path.parents for path in (root, destination)):|if False and any(path == removed or removed in path.parents for path in (root, destination)):|state
ROWS

mkdir -p "$CONTROL_ROOT/git-bin"
cat > "$CONTROL_ROOT/git-bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
[[ "$ARCHIVE_GIT_FAILURE" != all && "${3:-}:${4:-}" != worktree:list ]] || exit 73
exec "$ARCHIVE_REAL_GIT" "$@"
GIT
chmod +x "$CONTROL_ROOT/git-bin/git"
mutant="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts ignored-listing lib/state-archive.sh)" || exit 1
mutate_file "$mutant/lib/state-archive.sh" 'if listing.returncode != 0:' 'if False and listing.returncode != 0:'
while read -r failure; do
    ARCHIVE_TEST_REPO="$project"
    ARCHIVE_TEST_PATH="$CONTROL_ROOT/git-bin:$PATH"
    ARCHIVE_GIT_FAILURE="$failure"
    if [[ "$failure" == non-git ]]; then
        ARCHIVE_TEST_REPO="$CONTROL_ROOT/default/repo"
        ARCHIVE_TEST_PATH="$PATH"
    fi
    root_refusal "$SCRIPTS" "$TMP_ROOT/safe-archives" "$failure: unreadable worktrees"
    assert_contains "$(cat "$TMP_ROOT/root.err")" 'archive-worktrees-unreadable' "$failure: identifies the failed listing"
    before="$FAIL"
    root_refusal "$mutant" "$TMP_ROOT/safe-archives" "$failure: ignored listing" > "$TMP_ROOT/listing-control.out"
    if [[ "$FAIL" -gt "$before" ]]; then FAIL="$before"; pass "control: $failure cannot authorize removal"
    else fail "control: $failure cannot authorize removal"; fi
done <<'ROWS'
listing
all
non-git
ROWS

unset ARCHIVE_TEST_PATH ARCHIVE_TEST_REPO ARCHIVE_GIT_FAILURE
mutant="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts failed-state-path workflow-state)" || exit 1
cat > "$mutant/workflow-state" <<'STATE'
#!/usr/bin/env bash
printf '%s\n' "$PWD/tmp/workflow-state-oversee.json"
exit 1
STATE
root_refusal "$mutant" "$TMP_ROOT/safe-state-archives" 'unreadable state path'
control="$(TMP_ROOT="$CONTROL_ROOT" mutant_scripts ignored-state-path lib/state-archive.sh)" || exit 1
rm -- "$control/workflow-state"
cp -- "$mutant/workflow-state" "$control/workflow-state"
mutate_file "$control/lib/state-archive.sh" \
    'state_file="$("$SCRIPT_DIR/workflow-state" path oversee)" || return 1' \
    'state_file="$("$SCRIPT_DIR/workflow-state" path oversee)" || true'
before="$FAIL"
root_refusal "$control" "$TMP_ROOT/safe-state-archives" 'ignored state path' > "$TMP_ROOT/state-control.out"
if [[ "$FAIL" -gt "$before" ]]; then FAIL="$before"; pass 'control: a failed state lookup cannot authorize removal'
else fail 'control: a failed state lookup cannot authorize removal'; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
