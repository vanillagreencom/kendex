#!/usr/bin/env bash
# The shared sandbox releases the previous case before it creates another.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo 'sandbox-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "sandbox-test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'sandbox-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
TMP="$TMP_ROOT/live"
mkdir -p "$TMP"
. "$TEST_DIR/lib/sandbox.sh"
. "$TEST_DIR/lib/workflow-edit.sh"

one_case() {
  sandbox
  local previous="$DIR"
  printf 'case edit\n' >"$DIR/case-edit"
  sandbox
  [ ! -e "$previous" ] && [ -f "$DIR/docs/guide.md" ] &&
    [ ! -e "$DIR/case-edit" ] && [ -d "$PRISTINE/.git" ]
}

cleanup_refused() {
  local previous="$DIR" next="$TMP/case.$((SANDBOX_N + 1))" output status=0
  # A real filesystem can refuse removal. Replace only that operation.
  output="$(rm() { return 73; }; sandbox 2>&1)" || status=$?
  [ "$status" -ne 0 ] &&
    grep -qxF "sandbox-error=cleanup value=$previous" <<<"$output" &&
    [ -d "$previous" ] && [ ! -e "$next" ]
}

if one_case; then ok 'only the current case remains and starts pristine'
else bad 'previous case cleanup'; fi
if cleanup_refused; then ok 'failed removal stops before creating the next case'
else bad 'failed removal continued'; fi

mkdir -p "$TMP_ROOT/control"
cp "$TEST_DIR/lib/sandbox.sh" "$TMP_ROOT/control/sandbox.sh"
file_edit "$TMP_ROOT/control" sandbox.sh 1 'if .* ! rm -rf --' 's/! rm -rf/! : rm -rf/'
if (
  TMP="$TMP_ROOT/control-run"
  mkdir -p "$TMP"
  . "$TMP_ROOT/control/sandbox.sh"
  one_case
); then bad 'control: retained cases escaped the one-case assertion'
else ok 'control: inert removal fails the one-case assertion'; fi
if (
  TMP="$TMP_ROOT/refusal-control-run"
  mkdir -p "$TMP"
  . "$TMP_ROOT/control/sandbox.sh"
  sandbox
  cleanup_refused
); then bad 'control: ignored removal failure escaped the refusal assertion'
else ok 'control: inert removal fails the refusal assertion'; fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
