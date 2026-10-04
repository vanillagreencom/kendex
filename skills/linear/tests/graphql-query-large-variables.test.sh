#!/usr/bin/env bash
# graphql_query hands its variables to jq on stdin, never as one argv string,
# so a variables payload past the kernel's per-argument cap (MAX_ARG_STRLEN,
# 128 KiB) reaches the API whole. Producers: an issue description or comment
# body read from a file, and an id filter over a workspace-sized cache. A
# variables string that is not exactly one JSON value still refuses.
#
# Runs fully offline against a mocked curl.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir ROOT

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
git -C "$ROOT" init -q -b main
mkdir -p "$ROOT/bin"

cat >"$ROOT/bin/curl" <<SH
#!/usr/bin/env bash
sed -n 's/^data = //p' | jq -r . >"$ROOT/payload.json"
printf '%s' '{"data":{"viewer":{"id":"u1"}}}___HTTP_CODE___200'
SH
chmod +x "$ROOT/bin/curl"

# The variables are read from a file inside the subject: handing them over as
# an argument would hit the same per-argument cap this suite is about.
cat >"$ROOT/subject" <<'SH'
set -euo pipefail
cd "$1"
source "$2"
vars=$(cat "$3")
graphql_query 'query Probe { viewer { id } }' "$vars"
SH

# run_query VARIABLES_FILE — RC and ERR hold the subject's status and stderr.
run_query() {
  rm -f "$ROOT/payload.json"
  RC=0
  env -i PATH="$ROOT/bin:$PATH" HOME="$ROOT" LINEAR_API_KEY_OVERRIDE=lin_api_test \
    LINEAR_CACHE_ROOT="$ROOT" LINEAR_RETRY_BASE_DELAY=0 \
    bash "$ROOT/subject" "$ROOT" "$SKILL_DIR/scripts/lib/common.sh" "$1" \
    >"$ROOT/out" 2>"$ROOT/err" || RC=$?
  ERR="$(cat "$ROOT/err")"
}

# A 6226-id filter, the cache size that first passed the cap.
jq -nc '{filter: {id: {in: [range(6226) | "00000000-0000-4000-8000-\(1000000000000 + . | tostring | .[1:])"]}}}' \
  >"$ROOT/large.json"
assert "the large variables pass the per-argument cap" \
  test "$(wc -c <"$ROOT/large.json")" -gt 131072

run_query "$ROOT/large.json"
assert_eq "variables past the per-argument cap are sent" "$RC" 0
assert "the request carries the variables unchanged" \
  jq -e --slurpfile want "$ROOT/large.json" '.variables == $want[0]' "$ROOT/payload.json"

# name|variables: each must refuse before any request.
while IFS='|' read -r name vars; do
  printf '%s' "$vars" >"$ROOT/bad.json"
  run_query "$ROOT/bad.json"
  assert_ne "$name refuses" "$RC" 0
  assert_contains "$name names the variables as invalid" "$ERR" "Invalid GraphQL variables JSON"
  assert_not "$name sends no request" test -f "$ROOT/payload.json"
done <<'ROWS'
unparseable variables|{"filter":
two variables values|{} {}
ROWS
