#!/usr/bin/env bash
# Retention, stable logical numbering, and a writer waiting on the compacted inode.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd -P)" || exit 1
TMP_ROOT="$(mktemp -d)" || { echo 'lane-mail-compact: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'lane-mail-compact: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'lane-mail-compact: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
rc=0
python3 "$ROOT/skills/orch/tests/lib/lane-mail-compact.py" "$ROOT" "$TMP_ROOT" || rc=$?
assert_eq "$rc" 0 'mailbox compaction contract and must-fail controls'
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
