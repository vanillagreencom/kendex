# shellcheck shell=bash
# A zero-byte body, whitespace or a wrong page shape cannot become empty evidence.
while IFS='|' read -r endpoint body code; do
  reset
  CFG_CONTEXTS=mech-ctx
  CFG_REVIEWERS='mech-bot[bot]:Reviewed commit:'
  if [ "$body" = empty ]; then
    export GH_SHIM_EMPTY="$endpoint"
  else
    printf '%b\n' "$body" >"$fixtures/$endpoint.json"
  fi
  run "$endpoint read shape: $body" "" 2
  expected_value=1
  case "$endpoint" in statuses) expected_value="$HEAD" ;; checkruns) expected_value=mech-ctx ;; *) expected_value=1 ;; esac
  printf -v quoted '%q' "$expected_value"
  if ! grep -qxF "review-gate-error=$code value=$quoted" <<<"$LAST_ERROR"; then
    echo "FAIL  $endpoint: expected diagnostic $code" >&2
    failures=$((failures + 1))
  fi
done <<'CASES'
reviews|empty|predicate-reviews-empty
statuses|empty|predicate-statuses-empty
checkruns|empty|predicate-checkruns-empty
comments|empty|predicate-comments-empty
reviews|\n   \n|predicate-reviews-pages
reviews|{"message":"Server Error"}|predicate-reviews-pages
checkruns|\n   \n|predicate-checkruns-pages
checkruns|{}|predicate-checkruns-pages
comments|\n   \n|predicate-comments-pages
CASES
