# shellcheck shell=bash
# An omitted author is resolved from the PR read before review evidence counts.
while IFS='|' read -r name reviewer fail want expected_exit; do
  reset
  CFG_PR_AUTHOR=""
  case "$reviewer" in
    AUTHOR) reviews_set "$(review "$AUTHOR" APPROVED)" ;;
    reviewer) CFG_TRUSTED_LOGINS=""; reviews_set "$(review reviewer APPROVED)" ;;
    '') : ;;
    *) exit 1 ;;
  esac
  [ "$fail" != yes ] || export GH_SHIM_FAIL=pull
  run "$name" "$want" "$expected_exit"
done <<'CASES'
resolved author cannot self-approve|AUTHOR||awaiting|0
resolved author permits another reviewer|reviewer||approved|0
author read failure||yes||2
CASES
