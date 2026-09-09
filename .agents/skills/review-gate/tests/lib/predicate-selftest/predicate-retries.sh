# shellcheck shell=bash
# attempts|fail count (all = permanent)|verdict|exit
while IFS='|' read -r attempts fail_count want exit_code; do
  reset
  CFG_API_ATTEMPTS="$attempts"; CFG_API_DELAY=0; CFG_TRUSTED_LOGINS=""
  reviews_set "$(review reviewer APPROVED)"
  export GH_SHIM_FAIL=reviews
  [ "$fail_count" = all ] || export GH_SHIM_FAIL_TIMES="$fail_count"
  run "retry budget $attempts, failures $fail_count" "$want" "$exit_code"
done <<'CASES'
3|2|approved|0
1|1||2
2|all||2
CASES
while IFS='|' read -r key value code; do
  reset
  case "$key" in attempts) CFG_API_ATTEMPTS="$value" ;; delay) CFG_API_DELAY="$value" ;; *) exit 1 ;; esac
  run "$key=$value is a configuration error" "" 2
  printf -v quoted '%q' "$value"
  if [ "${LAST_ERROR%%$'\n'*}" != "review-gate-error=$code value=$quoted" ]; then
    echo "FAIL  $key=$value: wrong diagnostic" >&2
    failures=$((failures + 1))
  fi
done <<'CASES'
attempts|0|predicate-api-attempts
attempts|lots|predicate-api-attempts
delay|-1|predicate-api-delay
CASES
reset
CFG_API_DELAY="$ACTIVE_API_DELAY"
run "committed REVIEW_GATE_API_RETRY_DELAY_SECONDS ('$ACTIVE_API_DELAY') is accepted" awaiting
