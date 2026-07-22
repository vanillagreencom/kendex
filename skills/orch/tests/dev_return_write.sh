#!/usr/bin/env bash
# Regression tests for dev-return-write: the deterministic writer for a dev
# agent's round-scoped completion artifact
# ([WORKTREE]/tmp/dev-return-[ISSUE_ID]-[ROUND_ID].json). Running the writer instead
# of hand-authoring the JSON makes the receipt well-formed and complete by
# construction (vstack#776) — every artifact it emits must round-trip through
# dev-artifact-check (round mode) as valid, and every bad invocation must exit 2.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# Assert an invocation fails validation with exit code 2.
assert_exit2() {
  local name="$1"; shift
  set +e
  "$WRITE" "$@" >/dev/null 2>&1
  local rc=$?
  set -e
  assert_eq "$rc" "2" "$name"
}

echo "=== dev-return-write ==="

worktree="$TMP_ROOT/wt"
mkdir -p "$worktree"
RID="1750000000-99"

# --- valid implement (single): no --item → items: [] ---
out="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-776 --round-id "$RID" \
  --branch issue-776 --commit abc123f --validate pass --qa-label needs-review)"
assert_eq "$out" "$worktree/tmp/dev-return-issue-776-$RID.json" "implement single prints the round-scoped artifact path"
assert_eq "$([[ -f "$out" ]] && echo yes)" "yes" "implement single wrote the file"
assert_eq "$(jq -r '.schema_version' "$out")" "1" "implement single .schema_version is 1"
assert_eq "$(jq -r '.schema_version | type' "$out")" "number" "implement single .schema_version is a JSON number"
assert_eq "$(jq -r '.round_id' "$out")" "$RID" "implement single .round_id matches --round-id"
assert_eq "$(jq -r '.kind' "$out")" "implement" "implement single .kind"
assert_eq "$(jq -r '.issue' "$out")" "issue-776" "implement single .issue"
assert_eq "$(jq -r '.commit' "$out")" "abc123f" "implement single .commit"
assert_eq "$(jq -r '.validate' "$out")" "pass" "implement single .validate"
assert_eq "$(jq -c '.qa_labels' "$out")" '["needs-review"]' "implement single .qa_labels"
assert_eq "$(jq -r '.summary_posted' "$out")" "true" "implement single .summary_posted true"
assert_eq "$(jq -r '.summary' "$out")" "null" "implement single .summary null without --summary-file"
assert_eq "$(jq -r '.bundled' "$out")" "false" "implement single .bundled false"
assert_eq "$(jq -c '.items' "$out")" "[]" "implement single .items is []"
# round-trips through dev-artifact-check round mode as valid
assert_eq "$("$CHECK" --worktree "$worktree" --issue issue-776 --round-id "$RID" | jq -r '.reason')" "valid" \
  "implement single round-trips through dev-artifact-check round mode as valid"

# --- valid implement: no qa labels → [] ; --no-summary → false ; FAILING validate ---
out="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-100 --round-id 5-5 \
  --branch b --commit c --validate "FAILING: lint,build" --no-summary)"
assert_eq "$(jq -c '.qa_labels' "$out")" "[]" "implement no labels → qa_labels []"
assert_eq "$(jq -r '.summary_posted' "$out")" "false" "--no-summary sets summary_posted false"
assert_eq "$(jq -r '.validate' "$out")" "FAILING: lint,build" "FAILING validate accepted verbatim"
assert_eq "$("$CHECK" --file "$out" | jq -r '.reason')" "valid" "implement no-summary round-trips as valid"

# --- --summary-file embeds content for GitHub/ad-hoc recovery ---
printf '## Completion Summary\n- did the thing\n' > "$worktree/summary.md"
out="$("$WRITE" --worktree "$worktree" --kind implement --issue issue-gh --round-id 6-6 \
  --branch b --commit c --validate pass --no-summary --summary-file "$worktree/summary.md")"
assert_eq "$(jq -r '.summary' "$out" | head -1)" "## Completion Summary" "--summary-file embeds the summary content"
assert_eq "$(jq -r '.summary_posted' "$out")" "false" "--summary-file keeps summary_posted false (nothing posted to a tracker)"

# --- valid fix: items present ---
out="$("$WRITE" --worktree "$worktree" --kind fix --issue issue-776 --round-id 7-7 \
  --branch issue-776 --commit def456a --validate pass \
  --item 1 Applied "fixed nil deref" --item 2 Skipped "contradicts D010")"
assert_eq "$(jq -r '.kind' "$out")" "fix" "fix .kind"
assert_eq "$(jq -r '.items | length' "$out")" "2" "fix has 2 items"
assert_eq "$(jq -r '.items[0].n | type' "$out")" "number" "fix item[0].n is a JSON number"
assert_eq "$(jq -r '.items[1].decision' "$out")" "Skipped" "fix item[1].decision"
assert_eq "$("$CHECK" --worktree "$worktree" --issue issue-776 --round-id 7-7 --expect-items 1,2 | jq -r '.reason')" "valid" \
  "fix round-trips through round mode with matching --expect-items"

# --- valid bundled implement: --bundled + items ---
out="$("$WRITE" --worktree "$worktree" --kind implement --issue PROJ-100 --round-id 8-8 \
  --branch feat/proj-100 --commit aaa111 --validate pass --bundled \
  --item 1 Applied "sub A done" --item 2 Applied "sub B done" \
  --qa-label needs-safety-audit --qa-label needs-review)"
assert_eq "$(jq -r '.bundled' "$out")" "true" "bundled implement .bundled true"
assert_eq "$(jq -r '.items | length' "$out")" "2" "bundled implement has 2 items"
assert_eq "$(jq -c '.qa_labels' "$out")" '["needs-safety-audit","needs-review"]' "bundled implement aggregated qa_labels"
assert_eq "$("$CHECK" --worktree "$worktree" --issue PROJ-100 --round-id 8-8 | jq -r '.reason')" "valid" \
  "bundled implement round-trips as valid"

# --- Blocked decision accepted ---
out="$("$WRITE" --worktree "$worktree" --kind fix --issue issue-b --round-id 9-9 \
  --branch b --commit c --validate pass --item 3 Blocked "needs API design")"
assert_eq "$(jq -r '.items[0].decision' "$out")" "Blocked" "fix item Blocked decision accepted"

# --- atomic write: no leftover temp files in tmp/ after a successful write ---
tmp_leftovers="$(find "$worktree/tmp" -maxdepth 1 -name '.dev-return-*' | wc -l | tr -d ' ')"
assert_eq "$tmp_leftovers" "0" "atomic write leaves no temp files behind"

# --- validation / exit-2 paths ---
assert_exit2 "bad --kind exits 2" \
  --worktree "$worktree" --kind review --issue i --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "missing --round-id exits 2" \
  --worktree "$worktree" --kind implement --issue i --branch b --commit c --validate pass
assert_exit2 "missing --issue (required arg) exits 2" \
  --worktree "$worktree" --kind implement --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "value flag with no value at end exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate
assert_exit2 "missing --worktree exits 2" \
  --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "nonexistent --worktree dir exits 2" \
  --worktree "$TMP_ROOT/nope" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "bad --validate exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate weird
assert_exit2 "path-unsafe --issue (slash) exits 2" \
  --worktree "$worktree" --kind implement --issue "a/b" --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "path-traversal --issue (..) exits 2" \
  --worktree "$worktree" --kind implement --issue ".." --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "path-unsafe --round-id (slash) exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "a/../b" --branch b --commit c --validate pass
assert_exit2 "path-traversal --round-id (..) exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id ".." --branch b --commit c --validate pass
assert_exit2 "missing --summary-file exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass --summary-file "$TMP_ROOT/nope.md"
assert_exit2 "bad --item DECISION exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass --item 1 Fixed "x"
assert_exit2 "empty --item REASONING exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass --item 1 Applied ""
assert_exit2 "non-numeric --item N exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass --item x Applied "x"
assert_exit2 "--item with too few args exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass --item 1 Applied
assert_exit2 "fix with no --item exits 2" \
  --worktree "$worktree" --kind fix --issue i --round-id "$RID" --branch b --commit c --validate pass
assert_exit2 "bundled implement with no --item exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass --bundled
assert_exit2 "unknown argument exits 2" \
  --worktree "$worktree" --kind implement --issue i --round-id "$RID" --branch b --commit c --validate pass --frobnicate

# A rejected invocation must not leave a partial artifact at the target path.
set +e
"$WRITE" --worktree "$worktree" --kind fix --issue issue-noitems --round-id "$RID" \
  --branch b --commit c --validate pass >/dev/null 2>&1
set -e
assert_eq "$([[ -f "$worktree/tmp/dev-return-issue-noitems-$RID.json" ]] && echo yes || echo no)" "no" \
  "rejected fix (no items) writes no artifact file"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
