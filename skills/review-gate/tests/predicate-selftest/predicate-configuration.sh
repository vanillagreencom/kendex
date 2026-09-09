# shellcheck shell=bash
# Settings values emitted by callers must refuse under their own rule.
# key|value|code|diagnostic value
while IFS='|' read -r key value code diagnostic; do
  reset
  CFG_TRUSTED_LOGINS=""
  case "$key" in
    floor) CFG_FLOOR="$value" ;;
    state) CFG_MIN_STATE="$value" ;;
    reviewers) CFG_REVIEWERS="$value" ;;
    context-evidence) CFG_CONTEXTS="$value"; CFG_GATE_CONTEXT='Gate X' ;;
    context-override) CFG_OUTAGE="$value"; CFG_GATE_CONTEXT='Gate X' ;;
    context) CFG_GATE_CONTEXT="$value" ;;
    *) exit 1 ;;
  esac
  run "configuration: $key=$value" "" 2
  printf -v quoted '%q' "$diagnostic"
  expected="review-gate-error=$code value=$quoted"
  if [ "${LAST_ERROR%%$'\n'*}" != "$expected" ]; then
    echo "FAIL  configuration: $key emitted ${LAST_ERROR%%$'\n'*}, wanted $expected" >&2
    failures=$((failures + 1))
  fi
done <<'CASES'
floor|abc|predicate-sha-floor-integer|abc
floor|3|predicate-sha-floor-range|3
state|bogus|predicate-min-state|bogus
reviewers|just-a-login-no-pattern|predicate-comment-pair|just-a-login-no-pattern
context-evidence|Devin Review;Gate X|predicate-context-evidence|Gate X
context-override|Gate X|predicate-context-override|Gate X
context||predicate-context-empty|
CASES
