#!/usr/bin/env bash
# CLI refusals carry stable codes and values before explanatory text.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREDICATE="$(cd "$TEST_DIR/.." && pwd)/scripts/review-predicate.sh"
work="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${work:?}"' EXIT
PASS=0 FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
# A row encodes argc and arguments; an empty argument stays present.
for row in '1|--wibble' '1|-x' '1|extra' '1|--help=1' '1|' \
  '2||--wibble' '2|--help|extra' '2|-h|-h' \
  '2|--check-config|extra' '2|--check-config|--check-config'; do
  count="${row%%|*}"; args="${row#*|}"
  if [ "$count" = 1 ]; then set -- "$args"; else set -- "${args%%|*}" "${args#*|}"; fi
  rc=0
  out=$("$PREDICATE" "$@" 2>"$work/stderr") || rc=$?
  first=""; IFS= read -r first <"$work/stderr" || true
  if [ "$rc" = 2 ] && [ -z "$out" ] && [ "$first" = "review-gate-error=predicate-arguments value=$count" ]; then
    ok "argument list $row"
  else bad "argument list $row (exit $rc, stdout $out, diagnostic $first)"; fi
done
for flag in --help -h; do
  rc=0
  out=$("$PREDICATE" "$flag" 2>"$work/stderr") || rc=$?
  if [ "$rc" = 0 ] && [ -n "$out" ] && [ ! -s "$work/stderr" ]; then ok "$flag"; else bad "$flag"; fi
done
# Config validation must stop before requiring a PR or reading evidence.
rc=0
out=$(env -u GH_REPO -u PR_NUMBER -u HEAD_SHA -u REVIEW_GATE_MODE \
  REVIEW_GATE_SETTINGS_FILE=/dev/null "$PREDICATE" --check-config 2>"$work/stderr") || rc=$?
if [ "$rc" = 0 ] && [ "${out%%$'\n'*}" = 'review-gate-notice=predicate-config value=valid' ] && [ ! -s "$work/stderr" ]; then
  ok 'config without PR environment'
else bad 'config without PR environment'; fi
# key|value|diagnostic code|diagnostic value: real CLI settings input.
while IFS='|' read -r key value code diagnostic; do
  rc=0
  out=$(env -u GH_REPO -u PR_NUMBER -u HEAD_SHA REVIEW_GATE_SETTINGS_FILE=/dev/null \
    "$key=$value" "$PREDICATE" --check-config 2>"$work/stderr") || rc=$?
  first=""; IFS= read -r first <"$work/stderr" || true
  printf -v quoted '%q' "$diagnostic"
  if [ "$rc" = 2 ] && [ -z "$out" ] && [ "$first" = "review-gate-error=$code value=$quoted" ]; then
    ok "$key=$value"
  else bad "$key=$value (exit $rc, stdout $out, diagnostic $first)"; fi
done <<'CASES'
REVIEW_GATE_MODE|bogus|predicate-mode|bogus
REVIEW_GATE_SHA_PREFIX_FLOOR|2|predicate-sha-floor-range|2
REVIEW_GATE_API_ATTEMPTS|0|predicate-api-attempts|0
REVIEW_GATE_CARRY_FORWARD|prose|predicate-carry-class|prose
REVIEW_GATE_CONTEXT||predicate-context-empty|
REVIEW_GATE_COMMENT_REVIEWERS|missing-colon|predicate-comment-pair|missing-colon
REVIEW_GATE_COMMENT_REVIEWERS|:pattern|predicate-comment-pair|:pattern
REVIEW_GATE_CARRY_FORWARD_EXCLUDE|/AGENTS.md|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE:/AGENTS.md
REVIEW_GATE_CARRY_FORWARD_EXCLUDE|../future/*|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE:../future/*
REVIEW_GATE_CARRY_FORWARD_EXCLUDE|./future/*|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE:./future/*
REVIEW_GATE_CARRY_FORWARD_EXCLUDE|docs/./guide.md|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE:docs/./guide.md
REVIEW_GATE_CARRY_FORWARD_EXCLUDE|docs//guide.md|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE:docs//guide.md
REVIEW_GATE_CARRY_FORWARD_EXCLUDE|docs/|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE:docs/
REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC|../future/*|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC:../future/*
REVIEW_GATE_CARRY_FORWARD_EXCLUDE|[.]/future/*|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE:[.]/future/*
REVIEW_GATE_CARRY_FORWARD_EXCLUDE|docs/\.md|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE:docs/\.md
REVIEW_GATE_CARRY_FORWARD_EXCLUDE|docs/?.md|predicate-pattern|REVIEW_GATE_CARRY_FORWARD_EXCLUDE:docs/?.md
CASES
for spelling in '*AGENTS.md' 'docs/*' '.github/*' 'docs/**/notes.md'; do
  rc=0
  out=$(env -u GH_REPO -u PR_NUMBER -u HEAD_SHA REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$spelling" "$PREDICATE" --check-config 2>"$work/stderr") || rc=$?
  if [ "$rc" = 0 ] && [ "${out%%$'\n'*}" = 'review-gate-notice=predicate-config value=valid' ] && [ ! -s "$work/stderr" ]; then
    ok "pattern $spelling"
  else bad "pattern $spelling"; fi
done
printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
