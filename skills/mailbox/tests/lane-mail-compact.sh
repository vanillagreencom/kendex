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
# An open replacement's exchange through compaction, against a stateful tracker.
REPLACE_FACTS="$(python3 "$ROOT/skills/mailbox/tests/lib/owner-replace.py" compact \
  "$ROOT/skills/mailbox" "$TMP_ROOT" "$BASH")"
assert_eq "$(jq -c 'with_entries(select(.key | startswith("error:")))' <<<"$REPLACE_FACTS")" '{}' \
  'the compaction replacement case runs to its observation'
assert_eq "$(jq '.replacement_retained' <<<"$REPLACE_FACTS")" true \
  "an open replacement keeps its predecessor's exchange and delivery rows, and an answer is delivered once"
assert_eq "$(jq '.aged_out_unrepeated' <<<"$REPLACE_FACTS")" true \
  'an unrelated closed ask on the item ages out, and its answer is not delivered again'
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
