# shellcheck shell=bash
# Sourced by review-predicate-selftest.sh with its neutral fixture world.
# Read shapes: the reviews and comments endpoints must request
# per_page=100 — the 30-item default paginates long PRs into pure overhead.
reset
CFG_REVIEWERS="mech-bot[bot]:Reviewed commit:"; CFG_FLOOR=7
comment "mech-bot[bot]" "Reviewed commit: \`${HEAD:0:7}\`" >"$fixtures/comments.json"
run "read-shape pin: evidence still evaluates (per_page probe)" approved
cases=$((cases + 1))
if grep -q 'reviews?per_page=100' "$fixtures/.urls.log" 2>/dev/null \
   && grep -q 'comments?per_page=100' "$fixtures/.urls.log" 2>/dev/null; then
  echo "ok    reviews and comments reads carry per_page=100 (url log)"
else
  echo "FAIL  reviews/comments reads must carry per_page=100" >&2
  failures=$((failures + 1))
fi
