#!/usr/bin/env bash
# validate.sh consumes report records and ignores indented detail. Pin the
# whole protocol, including indentation when detail resembles a verdict.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$TEST_DIR/../scripts/lib/diagnostics.sh"
count=0
while IFS='|' read -r name status code value detail want; do
  [ -n "$name" ] || continue
  count=$((count + 1))
  printf -v detail '%b' "$detail"
  printf -v want '%b' "$want"
  got="$(rg_report "$status" "$code" "$value" "$detail")"
  if [ "$got" != "$want" ]; then
    printf 'test-failure=%s value=%q\nexpected=%q actual=%q\n' "$name" "$code" "$want" "$got" >&2
    exit 1
  fi
done <<'ROWS'
pass-record|ok|runtime-ready|scripts/validate.sh|detail|ok check=runtime-ready value=scripts/validate.sh\n  detail
failure-record|FAIL|workflow-count|0|detail|FAIL check=workflow-count value=0\n  detail
notice-record|note|carry-disabled|REVIEW_GATE_CARRY_FORWARD|detail|note check=carry-disabled value=REVIEW_GATE_CARRY_FORWARD\n  detail
detail-verdict|FAIL|workflow-equality|workflow.yml|detail\nFAIL injected|FAIL check=workflow-equality value=workflow.yml\n  detail\n  FAIL injected
space-value|FAIL|runtime-missing|my script.sh|detail|FAIL check=runtime-missing value=my\\ script.sh\n  detail
ROWS
[ "$count" -gt 0 ] || { printf 'test-failure=report-rows value=0\n' >&2; exit 1; }
printf 'test-pass=diagnostics-report value=%s\n' "$count"
