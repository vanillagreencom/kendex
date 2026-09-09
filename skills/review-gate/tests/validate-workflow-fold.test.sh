#!/usr/bin/env bash
# The full validator relays peer verdicts and folds their counts into its summary.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"
. "$TEST_DIR/lib/workflow-edit.sh"
DRIVER_REL="$VALIDATE_REL"

# A damaged peer can remain executable and parse correctly. Its report and
# exit status must agree before the driver can call the workflow checked.
rows=0; before=$((PASS + FAIL))
while IFS='|' read -r shape check value; do
  rows=$((rows + 1))
  sandbox
  case "$shape" in
    peer-finding)
      workflow_edit "$DIR" 1 '^      DISPATCH_REF: ' '/^      DISPATCH_REF: /d' ;;
    not-executable) chmod -x "$DIR/$WORKFLOW_REL" ;;
    empty-failure) printf '#!/usr/bin/env bash\nexit 1\n' >"$DIR/$WORKFLOW_REL" ;;
    empty-success) printf '#!/usr/bin/env bash\nexit 0\n' >"$DIR/$WORKFLOW_REL" ;;
    status-mismatch)
      printf '#!/usr/bin/env bash\nprintf "FAIL check=fixture value=peer\\n"\nexit 0\n' >"$DIR/$WORKFLOW_REL" ;;
    *) printf 'fixture-error=unknown-peer value=%q\n' "$shape" >&2; exit 2 ;;
  esac
  run_validate "$DIR"
  printf -v expected 'FAIL check=%s value=%q' "$check" "$value"
  failed="$(awk '/^FAIL check=/ { n++ } END { print n+0 }' <<<"$OUT")"
  passed="$(awk '/^ok check=/ { n++ } END { print n+0 }' <<<"$OUT")"
  printf -v summary 'review-gate-failed=%d passed=%d' "$failed" "$passed"
  if [ "$RC" -eq 1 ] && [ "$failed" -gt 0 ] &&
      grep -qxF -- "$expected" <<<"$OUT" && grep -qxF -- "$summary" <<<"$OUT"; then
    ok "$shape"
  else
    bad "$shape (rc=$RC, expected $expected and $summary)" "$OUT"
  fi
done <<'ROWS'
peer-finding|workflow-equality|.github/workflows/review-gate-writer.yml
not-executable|workflow-tool|scripts/validate-workflow.sh
empty-failure|workflow-no-verdict|1
empty-success|workflow-no-verdict|0
status-mismatch|workflow-status-mismatch|0
ROWS
[ "$rows" -gt 0 ] && [ "$((PASS + FAIL - before))" -eq "$rows" ] || { printf 'fixture-error=fold-table value=%q\n' "$rows" >&2; exit 2; }

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
