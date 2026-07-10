#!/usr/bin/env bash
# Regression test: projects list must not forward --limit > 50 straight to the
# API (Linear's projects connection 400s on large `first`). Instead it caps the
# per-request page size at 50 and paginates with the endCursor to satisfy
# larger --limit values, returning exactly up to --limit projects.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# Mocked curl: serves a virtual corpus of LINEAR_TOTAL projects for the
# ListProjects query, honoring `first` and the `after` cursor. Each response's
# endCursor encodes how many projects have been served so far ("c<N>").
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
variables="$(jq -c '.variables' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

total="${LINEAR_TOTAL:-100}"

case "$query" in
*"query ListProjects"*)
  first="$(jq -r '.variables.first' <<<"$payload")"
  after="$(jq -r '.variables.after // "null"' <<<"$payload")"
  if [ "$after" = "null" ] || [ -z "$after" ]; then
    start=0
  else
    start="${after#c}"
  fi
  body="$(jq -cn --argjson start "$start" --argjson first "$first" --argjson total "$total" '
    ([range($start; ([$start + $first, $total] | min))] | map(. + 1)) as $idx |
    ($start + $first) as $served |
    {
      data: {
        projects: {
          pageInfo: {
            hasNextPage: ($served < $total),
            endCursor: ("c" + ($served | tostring))
          },
          nodes: [ $idx[] | {
            id: ("proj-" + (tostring)),
            name: ("Project " + (tostring)),
            description: null,
            content: null,
            state: "started",
            progress: 0,
            health: null,
            priority: null,
            sortOrder: .,
            targetDate: null,
            startDate: null,
            lead: null,
            teams: { nodes: [] },
            labels: { nodes: [] },
            url: ("https://linear.app/test/project/proj-" + (tostring)),
            createdAt: "2026-07-03T00:00:00Z",
            updatedAt: "2026-07-03T00:00:00Z"
          } ]
        }
      }
    }')"
  printf '%s___HTTP_CODE___200' "$body"
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected query"}]}___HTTP_CODE___200'
  ;;
esac
SH
chmod +x "$TMP_ROOT/bin/curl"

run_list() {
  local payload_log="$1"
  shift
  : >"$payload_log"
  PATH="$TMP_ROOT/bin:$PATH" \
    LINEAR_API_KEY=test-token \
    LINEAR_TOTAL="${LINEAR_TOTAL:-100}" \
    CURL_PAYLOAD_LOG="$payload_log" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" projects list "$@"
}

# --- Case 1: --limit 50 issues a single request capped at 50 -----------------
log1="$TMP_ROOT/limit50.jsonl"
out1="$(run_list "$log1" --limit 50)"

if ! jq -e 'length == 50' >/dev/null <<<"$out1"; then
  echo "FAIL --limit 50 expected 50 projects, got: $(jq 'length' <<<"$out1")"
  exit 1
fi
req_count1="$(jq -s 'length' "$log1")"
if [ "$req_count1" -ne 1 ]; then
  echo "FAIL --limit 50 should be a single API request, made $req_count1"
  cat "$log1"
  exit 1
fi
if ! jq -s -e 'all(.[]; .variables.first == 50)' "$log1" >/dev/null; then
  echo "FAIL --limit 50 per-request first was not 50"
  cat "$log1"
  exit 1
fi

# --- Case 2: --limit 100 paginates into two merged pages ---------------------
log2="$TMP_ROOT/limit100.jsonl"
out2="$(run_list "$log2" --limit 100)"

if ! jq -e 'length == 100' >/dev/null <<<"$out2"; then
  echo "FAIL --limit 100 expected 100 projects, got: $(jq 'length' <<<"$out2")"
  exit 1
fi
req_count2="$(jq -s 'length' "$log2")"
if [ "$req_count2" -ne 2 ]; then
  echo "FAIL --limit 100 expected 2 paginated requests, made $req_count2"
  cat "$log2"
  exit 1
fi
# Per-request page size must never exceed the connection maximum (50).
if ! jq -s -e 'all(.[]; .variables.first <= 50)' "$log2" >/dev/null; then
  echo "FAIL --limit 100 issued a request with first > 50"
  cat "$log2"
  exit 1
fi
# Second page must carry the endCursor from the first.
if ! jq -s -e '.[1].variables.after == "c50"' "$log2" >/dev/null; then
  echo "FAIL --limit 100 second page did not pass the endCursor"
  cat "$log2"
  exit 1
fi
# Merged results are contiguous and de-duplicated across pages.
if ! jq -e '[.[].id] == (["proj-" + (range(1;101) | tostring)])' >/dev/null <<<"$out2"; then
  echo "FAIL --limit 100 merged pages are not the expected contiguous set"
  exit 1
fi

# --- Case 3: --limit 100 against a corpus of only 70 returns 70 --------------
log3="$TMP_ROOT/limit100-small.jsonl"
out3="$(LINEAR_TOTAL=70 run_list "$log3" --limit 100)"
if ! jq -e 'length == 70' >/dev/null <<<"$out3"; then
  echo "FAIL --limit 100 over a 70-project corpus expected 70, got: $(jq 'length' <<<"$out3")"
  exit 1
fi

# --- Case 4: output shape is unchanged (safe list objects) -------------------
if ! jq -e '.[0] | has("id") and has("name") and has("state") and has("url") and has("teams") and has("labels")' >/dev/null <<<"$out1"; then
  echo "FAIL output shape changed; expected safe project objects"
  echo "$out1" | jq '.[0]'
  exit 1
fi

# --- Case 5: --first single-name path stays a single first:1 request ---------
log5="$TMP_ROOT/first.jsonl"
out5="$(run_list "$log5" --first)"
if [ "$out5" != "Project 1" ]; then
  echo "FAIL --first expected 'Project 1', got: $out5"
  exit 1
fi
if ! jq -s -e 'length == 1 and .[0].variables.first == 1' "$log5" >/dev/null; then
  echo "FAIL --first should issue a single first:1 request"
  cat "$log5"
  exit 1
fi

echo "all pass"
