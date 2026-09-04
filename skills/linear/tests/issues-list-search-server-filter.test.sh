#!/usr/bin/env bash
# `issues list --search` must filter, and must fail
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
# shellcheck source=lib/assert.sh
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
assert_tmpdir TMP_ROOT

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
assert_eq "an impossible term returns zero rows" \
  "$(jq '.issues.nodes | length' <<<"$out1")" "0"

# --- Case 2: the term is filtered server-side, not client-side ---------------
assert "the request filter carries the or/containsIgnoreCase search clauses" \
  jq -s -e '.[0].variables.filter.or ==
      [{title: {containsIgnoreCase: "zzz-no-such-issue-zzz"}},
       {description: {containsIgnoreCase: "zzz-no-such-issue-zzz"}}]' "$log1"

# --- Case 3: matching term returns only matches (title OR description) -------
log3="$TMP_ROOT/match.jsonl"
out3="$(run_list "$log3" --format=raw --search market_data)"
assert_jq "--search market_data matches on title and on description" \
  "$out3" '[.issues.nodes[].identifier] == ["VST-1", "VST-2"]'

# --- Case 4: pipe-separated terms are OR'd, matching case-insensitively ------
log4="$TMP_ROOT/alternation.jsonl"
out4="$(run_list "$log4" --format=raw --search "market_data|order_book")"
assert_jq "pipe-separated terms are OR'd" \
  "$out4" '[.issues.nodes[].identifier] == ["VST-1", "VST-2", "VST-3"]'
assert "two terms produce four or-clauses" \
  jq -s -e '.[0].variables.filter.or | length == 4' "$log4"

# --- Case 5: --search=<term> form behaves identically ------------------------
log5="$TMP_ROOT/equals-form.jsonl"
out5="$(run_list "$log5" --format=raw --search=order_book)"
assert_jq "the --search=<term> form filters the same way" \
  "$out5" '[.issues.nodes[].identifier] == ["VST-3"]'

# --- Case 6: --search composes with other filters ----------------------------
log6="$TMP_ROOT/composed.jsonl"
run_list "$log6" --format=raw --state Todo --search market_data >/dev/null
assert "--state and --search both reach the filter" \
  jq -s -e '.[0].variables.filter | (.state.name.eq == "Todo") and (.or | length == 2)' "$log6"

# --- Case 7: --search with a missing value errors instead of listing all -----
# refuse_search LABEL ARGS... — the listing must fail and send nothing.
refuse_search() {
  local label="$1" log="$2"
  shift 2
  local rc=0
  : >"$log"
  run_list "$log" "$@" >/dev/null 2>&1 || rc=$?

  assert_ne "$label: the listing is refused" "$rc" 0
  assert_not "$label: nothing reaches the API" test -s "$log"
}

log7="$TMP_ROOT/missing-value.jsonl"
refuse_search "--search with no value" "$log7" --format=raw --search
for empty in '--search=' '--search=|'; do
  refuse_search "$empty (no usable term)" "$log7" --format=raw "$empty"
done

# --- Case 7b: option token after --search/--format is a missing value --------
log7b="$TMP_ROOT/option-as-value.jsonl"
refuse_search "--search --state Todo (--state is not a term)" "$log7b" --format=raw --search --state Todo
refuse_search "--format --search market_data (--search is not a format)" "$log7b" --format --search market_data
# Whitespace-only patterns have no usable term and must fail closed.
refuse_search "--search ' | ' (whitespace-only)" "$log7b" --format=raw --search ' | '
# The full whitespace class, not just space/tab: a CR- or LF-only pattern
# passed the old check, the jq trim then emptied every term, and an
# 'or: []' filter reached Linear.
for ws_pat in $'\r' $'\n' $'\n|\n' $'\302\240'; do
  refuse_search "--search with a non-space whitespace pattern" "$log7b" --format=raw --search "$ws_pat"
done

# --- Case 7c: padded terms are trimmed before matching ------------------------
log7c="$TMP_ROOT/trimmed-terms.jsonl"
run_list "$log7c" --format=raw --search 'market_data | order_book' >/dev/null
assert "padded terms are trimmed in the or-clause" \
  jq -s -e '[.[0].variables.filter.or[] | .. | strings]
      | all(test("^[^ ].*[^ ]$|^[^ ]$"))' "$log7c"
assert "a trimmed alternation still produces four or-clauses" \
  jq -s -e '.[0].variables.filter.or | length == 4' "$log7c"

# --- Case 8: space-separated --format is honored (same dropped-flag bug) -----
log8="$TMP_ROOT/format-space.jsonl"
out8="$(run_list "$log8" --format raw --search market_data)"
assert_jq "a space-separated --format raw produces raw JSON output" "$out8" '.issues.nodes'
