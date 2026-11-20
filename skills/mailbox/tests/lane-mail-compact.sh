#!/usr/bin/env bash
# Retention, stable logical numbering, and a writer waiting on the compacted inode.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
# shellcheck source=../../orch/tests/lib/git-env.sh
source "$ROOT/skills/orch/tests/lib/git-env.sh"
# shellcheck source=../../orch/tests/lib/assertions.sh
source "$ROOT/skills/orch/tests/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'lane-mail-compact: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'lane-mail-compact: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'lane-mail-compact: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
rc=0
python3 "$ROOT/skills/mailbox/tests/lib/lane-mail-compact.py" "$ROOT" "$TMP_ROOT" || rc=$?
assert_eq "$rc" 0 'mailbox compaction contract and must-fail controls'
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
