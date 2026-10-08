#!/usr/bin/env bash
# lane_host_fetch: isolated lane-close fixtures install the single-read
# dependencies alone. The cache helper belongs only to the cache read path.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo "lane-gitfile: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-gitfile: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-gitfile: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"

mkdir -p "$TMP_ROOT/lib" "$TMP_ROOT/cache"
cp "$TEST_DIR/../scripts/lib/lane-gitfile.sh" \
  "$TEST_DIR/../scripts/lib/lane-host-slots.sh" \
  "$TEST_DIR/../scripts/lib/lane-capabilities.sh" "$TMP_ROOT/lib/"
printf 'fetched\n' > "$TMP_ROOT/bytes"
printf 'KEN-1\t/mail\t0\t1\n' > "$TMP_ROOT/cache/index"
cp "$TMP_ROOT/bytes" "$TMP_ROOT/cache/1"

# Each child clears the ambient cache path. The provider fixture logs every
# invocation, so a cache read that silently reconnects fails the same row.
fetch() { # LIB CACHE
  RC=0
  : > "$TMP_ROOT/calls"
  env -u LANE_HOST_READ_DIR "$BASH" -eu -c '
    root="$3"
    source "$1"
    if [[ -n "$2" ]]; then export LANE_HOST_READ_DIR="$2"; fi
    provider() { printf "%s\n" "$*" >> "$root/calls"; cat "$root/bytes"; }
    lane_host_fetch provider KEN-1 /mail "$3/out" "$3/err"
  ' sh "$1" "$2" "$TMP_ROOT" 2>"$TMP_ROOT/startup.err" || RC=$?
}

fetch "$TMP_ROOT/lib/lane-gitfile.sh" ""
assert_eq "$RC" 0 "single reads work without the cache helper" "$TMP_ROOT/startup.err"
assert_eq "$(cat "$TMP_ROOT/out")" fetched "single reads keep the provider bytes"
assert_eq "$(cat "$TMP_ROOT/calls")" 'cat --item KEN-1 /mail' "single reads keep the cat protocol"

cp "$TMP_ROOT/lib/lane-gitfile.sh" "$TMP_ROOT/lib/unconditional.sh"
mutate_file "$TMP_ROOT/lib/unconditional.sh" \
  'source "$LANE_GITFILE_LIB/lane-capabilities.sh"' \
  $'source "$LANE_GITFILE_LIB/lane-capabilities.sh"\nsource "$LANE_GITFILE_LIB/lane-host-read.sh"'
fetch "$TMP_ROOT/lib/unconditional.sh" ""
assert_eq "$RC" 1 "control: loading the absent helper at startup breaks single reads" "$TMP_ROOT/startup.err"
assert_eq "$(cat "$TMP_ROOT/calls")" '' "control: startup failure reaches no provider"

cp "$TEST_DIR/../scripts/lib/lane-host-read.sh" "$TMP_ROOT/lib/"
fetch "$TMP_ROOT/lib/lane-gitfile.sh" "$TMP_ROOT/cache"
assert_eq "$RC" 0 "cache reads load their helper" "$TMP_ROOT/startup.err"
assert_eq "$(cat "$TMP_ROOT/out")" fetched "cache reads keep the snapshot bytes"
assert_eq "$(cat "$TMP_ROOT/calls")" '' "cache reads make no provider call"

printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
