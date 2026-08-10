#!/usr/bin/env bash
# Regression test (VST-188): `issues list --search` must filter, and must fail
# closed. The old parser dropped the bare `--search` flag in its first pass, so
# the pattern never reached any filter and every search returned the full
# newest-first list — silently passing the dedupe preflight it exists for.
#
# The fix threads --search into the GraphQL IssueFilter as
#   or: [{title: {containsIgnoreCase}}, {description: {containsIgnoreCase}}]
# with pipe-separated terms OR'd, so Linear filters the whole team server-side
# instead of a client-side regex over one fetched page.
#
# The mocked curl below implements that filter shape over a fixture corpus, so
# a search term that reaches the API returns only its matches — and a term
# that never reaches the API (the original defect) returns the full corpus,
# which the assertions reject.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"

# Mocked curl: serves a fixed 4-issue corpus for ListIssues, honoring the
# `or`/`containsIgnoreCase` clauses of the incoming filter exactly the way
# Linear does. No filter (or an empty one) returns the whole corpus — the
# fail-open shape this test exists to reject.
cat >"$TMP_ROOT/bin/curl" <<'SH'
#!/usr/bin/env bash
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
printf '%s\n' "$payload" >> "${CURL_PAYLOAD_LOG:?}"

case "$query" in
*"query ListIssues"*)
  body="$(jq -cn --argjson filter "$(jq -c '.variables.filter // {}' <<<"$payload")" '
    def corpus: [
      { id: "i1", identifier: "VST-1", title: "Wire market_data feed",
        description: "Streaming ticks" },
      { id: "i2", identifier: "VST-2", title: "Fix janitor routing",
        description: "Bundles the market_data follow-ups" },
      { id: "i3", identifier: "VST-3", title: "Order_Book depth panel",
        description: null },
      { id: "i4", identifier: "VST-4", title: "Refresh CLI docs",
        description: "Nothing searchable here" }
    ] | map(. + {
      state: {name: "Todo", type: "unstarted"}, assignee: null,
      project: null, projectMilestone: null, cycle: null, parent: null,
      labels: {nodes: []}, priority: 0, estimate: null, sortOrder: 1,
      url: ("https://linear.app/test/issue/" + .identifier),
      createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z",
      archivedAt: null, trashed: false,
      relations: {nodes: []}, inverseRelations: {nodes: []}
    });

    def clause_match($i):
      (.title.containsIgnoreCase // null) as $t |
      (.description.containsIgnoreCase // null) as $d |
      if $t != null then (($i.title // "") | ascii_downcase | contains($t | ascii_downcase))
      elif $d != null then (($i.description // "") | ascii_downcase | contains($d | ascii_downcase))
      else false end;

    ($filter.or // null) as $or |
    (corpus | if $or == null then .
      else map(. as $i | select(any($or[]; clause_match($i)))) end) as $nodes |
    { data: { issues: {
        pageInfo: { hasNextPage: false, endCursor: null },
        nodes: $nodes } } }')"
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
    LINEAR_API_KEY_OVERRIDE=test-token \
    CURL_PAYLOAD_LOG="$payload_log" \
    bash "$TMP_ROOT/.agents/skills/linear/scripts/linear.sh" issues list "$@"
}

# --- Case 1: impossible term returns zero rows (fail closed) -----------------
log1="$TMP_ROOT/impossible.jsonl"
out1="$(run_list "$log1" --format=raw --search "zzz-no-such-issue-zzz")"
count1="$(jq '.issues.nodes | length' <<<"$out1")"
if [ "$count1" -ne 0 ]; then
  echo "FAIL impossible term returned $count1 rows instead of 0 (search fails open)"
  jq '.issues.nodes | map(.identifier)' <<<"$out1"
  exit 1
fi

# --- Case 2: the term is filtered server-side, not client-side ---------------
if ! jq -s -e '.[0].variables.filter.or ==
      [{title: {containsIgnoreCase: "zzz-no-such-issue-zzz"}},
       {description: {containsIgnoreCase: "zzz-no-such-issue-zzz"}}]' \
      "$log1" >/dev/null; then
  echo "FAIL request filter missing the or/containsIgnoreCase search clauses"
  jq -s '.[0].variables.filter' "$log1"
  exit 1
fi

# --- Case 3: matching term returns only matches (title OR description) -------
log3="$TMP_ROOT/match.jsonl"
out3="$(run_list "$log3" --format=raw --search market_data)"
if ! jq -e '[.issues.nodes[].identifier] == ["VST-1", "VST-2"]' >/dev/null <<<"$out3"; then
  echo "FAIL --search market_data expected VST-1 (title) + VST-2 (description)"
  jq '[.issues.nodes[].identifier]' <<<"$out3"
  exit 1
fi

# --- Case 4: pipe-separated terms are OR'd, matching case-insensitively ------
log4="$TMP_ROOT/alternation.jsonl"
out4="$(run_list "$log4" --format=raw --search "market_data|order_book")"
if ! jq -e '[.issues.nodes[].identifier] == ["VST-1", "VST-2", "VST-3"]' >/dev/null <<<"$out4"; then
  echo "FAIL alternation expected VST-1..3"
  jq '[.issues.nodes[].identifier]' <<<"$out4"
  exit 1
fi
if ! jq -s -e '.[0].variables.filter.or | length == 4' "$log4" >/dev/null; then
  echo "FAIL alternation should produce 4 or-clauses (2 terms x title/description)"
  jq -s '.[0].variables.filter' "$log4"
  exit 1
fi

# --- Case 5: --search=<term> form behaves identically ------------------------
log5="$TMP_ROOT/equals-form.jsonl"
out5="$(run_list "$log5" --format=raw --search=order_book)"
if ! jq -e '[.issues.nodes[].identifier] == ["VST-3"]' >/dev/null <<<"$out5"; then
  echo "FAIL --search=order_book expected only VST-3"
  jq '[.issues.nodes[].identifier]' <<<"$out5"
  exit 1
fi

# --- Case 6: --search composes with other filters ----------------------------
log6="$TMP_ROOT/composed.jsonl"
run_list "$log6" --format=raw --state Todo --search market_data >/dev/null
if ! jq -s -e '.[0].variables.filter | (.state.name.eq == "Todo") and (.or | length == 2)' \
      "$log6" >/dev/null; then
  echo "FAIL --state + --search must send both filter clauses"
  jq -s '.[0].variables.filter' "$log6"
  exit 1
fi

# --- Case 7: --search with a missing value errors instead of listing all -----
log7="$TMP_ROOT/missing-value.jsonl"
if out7="$(run_list "$log7" --format=raw --search 2>&1)"; then
  echo "FAIL --search with no value must exit non-zero, got output:"
  printf '%s\n' "$out7"
  exit 1
fi
if [ -s "$log7" ]; then
  echo "FAIL --search with no value must not reach the API"
  cat "$log7"
  exit 1
fi
for empty in '--search=' '--search=|'; do
  if run_list "$log7" --format=raw "$empty" >/dev/null 2>&1; then
    echo "FAIL '$empty' (no usable term) must exit non-zero"
    exit 1
  fi
  if [ -s "$log7" ]; then
    echo "FAIL '$empty' must not reach the API"
    cat "$log7"
    exit 1
  fi
done

# --- Case 7b: option token after --search/--format is a missing value --------
log7b="$TMP_ROOT/option-as-value.jsonl"
if run_list "$log7b" --format=raw --search --state Todo >/dev/null 2>&1; then
  echo "FAIL '--search --state Todo' must refuse (--state is not a term)"
  exit 1
fi
if [ -s "$log7b" ]; then
  echo "FAIL '--search --state Todo' must not reach the API"
  cat "$log7b"
  exit 1
fi
if run_list "$log7b" --format --search market_data >/dev/null 2>&1; then
  echo "FAIL '--format --search market_data' must refuse (--search is not a format)"
  exit 1
fi
if [ -s "$log7b" ]; then
  echo "FAIL '--format --search ...' must not reach the API"
  cat "$log7b"
  exit 1
fi
# Whitespace-only patterns have no usable term and must fail closed.
if run_list "$log7b" --format=raw --search ' | ' >/dev/null 2>&1; then
  echo "FAIL --search ' | ' (whitespace-only) must exit non-zero"
  exit 1
fi
if [ -s "$log7b" ]; then
  echo "FAIL --search ' | ' must not reach the API"
  cat "$log7b"
  exit 1
fi
# The full whitespace class, not just space/tab: a CR- or LF-only pattern
# passed the old check, the jq trim then emptied every term, and an
# 'or: []' filter reached Linear.
for ws_pat in $'\r' $'\n' $'\n|\n' $'\302\240'; do
  if run_list "$log7b" --format=raw --search "$ws_pat" >/dev/null 2>&1; then
    echo "FAIL --search CR/LF-only pattern must exit non-zero"
    exit 1
  fi
  if [ -s "$log7b" ]; then
    echo "FAIL --search CR/LF-only pattern must not reach the API"
    cat "$log7b"
    exit 1
  fi
done

# --- Case 7c: padded terms are trimmed before matching ------------------------
log7c="$TMP_ROOT/trimmed-terms.jsonl"
run_list "$log7c" --format=raw --search 'market_data | order_book' >/dev/null
if ! jq -s -e '[.[0].variables.filter.or[] | .. | strings]
      | all(test("^[^ ].*[^ ]$|^[^ ]$"))' "$log7c" >/dev/null; then
  echo "FAIL padded 'a | b' terms must be trimmed in the or-clause"
  jq -s '.[0].variables.filter.or' "$log7c"
  exit 1
fi
if ! jq -s -e '.[0].variables.filter.or | length == 4' "$log7c" >/dev/null; then
  echo "FAIL trimmed alternation should still produce 4 or-clauses"
  exit 1
fi

# --- Case 8: space-separated --format is honored (same dropped-flag bug) -----
log8="$TMP_ROOT/format-space.jsonl"
out8="$(run_list "$log8" --format raw --search market_data)"
if ! jq -e '.issues.nodes' >/dev/null 2>&1 <<<"$out8"; then
  echo "FAIL space-separated '--format raw' did not produce raw JSON output"
  printf '%s\n' "$out8" | head -5
  exit 1
fi

echo "all pass"
