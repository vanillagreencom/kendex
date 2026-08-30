#!/usr/bin/env bash
# --declined-on-added-lines, offline: the real predicate behind the gh shim
# (lib/gh-shim.sh). The refusal it exists for is a `Declined:` reply standing
# on a thread anchored to a line this PR's diff ADDED — the disposition
# finding-disposition.md § Recurrence forbids, which shipped six defects
# because nothing downstream checked for it.
#
# Every refusal is paired with the near-miss that must NOT refuse: a decline
# on a context line, on a removed line, a Fixed in / Tracked reply on an
# added line. A check that refused on all of them would pass a suite that
# only proved refusals, and would then block every close.
#
# The must-fail control at the bottom is the one this issue's Done-when
# names: the anchor test is reverted in a scratch copy of the script, and the
# added-line fixture must go from refusal to clean pass while the
# not-touched fixture stays clean in both states.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED="$(cd "$TEST_DIR/../scripts" && pwd)/review-predicate.sh"
[ -x "$PRED" ] || { echo "not executable: $PRED" >&2; exit 1; }

work="$(mktemp -d)"
[ -n "$work" ] || { echo "FATAL: mktemp -d returned an empty path" >&2; exit 1; }
trap 'rm -rf "$work"' EXIT
fixtures="$work/fixtures"
shim="$work/bin"
mkdir -p "$fixtures" "$shim"
cp "$TEST_DIR/lib/gh-shim.sh" "$shim/gh"
chmod +x "$shim/gh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'; return 0; }

# --- fixture writers -----------------------------------------------------
# The shapes GitHub's reviewThreads connection really returns. A hunk's LAST
# line is the line the thread is anchored to, which is what the check reads.
ADDED_HUNK='@@ -1,3 +1,4 @@
 context before
-old line
+the line this diff added'
CONTEXT_HUNK='@@ -1,3 +1,4 @@
-old line
+the line this diff added
 a line the diff did not touch'
REMOVED_HUNK='@@ -1,3 +1,4 @@
 context before
+the line this diff added
-the line this diff removed'

human() { printf '{"body":%s,"diffHunk":%s,"author":{"__typename":"User"}}' \
  "$(jq -Rn --arg b "$1" '$b')" "$(jq -Rn --arg h "${2-}" '$h')"; }
botc()  { printf '{"body":%s,"diffHunk":%s,"author":{"__typename":"Bot"}}' \
  "$(jq -Rn --arg b "$1" '$b')" "$(jq -Rn --arg h "${2-}" '$h')"; }

thread() { # id, path, line, isResolved, comments-json (comma-joined)
  printf '{"id":%s,"path":%s,"line":%s,"originalLine":%s,"isResolved":%s,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[%s]}}' \
    "$(jq -Rn --arg v "$1" '$v')" "$(jq -Rn --arg v "$2" '$v')" "$3" "$3" "$4" "$5"
}

page() { # threads (comma-joined) -> graphql.json
  printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[%s]}}}}}' \
    "$1" >"$fixtures/graphql.json"
}

# --- runner --------------------------------------------------------------
# want: "ok" (exit 0), "refuse" (exit 1), "noverdict" (exit 2).
run() { # name, want, [stdout/stderr must contain], [script override]
  local name="$1" want="$2" needle="${3:-}" script="${4:-$PRED}" rc=0 out
  out="$(env PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    GH_REPO="owner/repo" PR_NUMBER=1 \
    "$script" --declined-on-added-lines 2>&1)" || rc=$?
  local want_rc
  case "$want" in
    ok) want_rc=0 ;;
    refuse) want_rc=1 ;;
    noverdict) want_rc=2 ;;
    *) bad "$name" "unknown expectation '$want'"; return 0 ;;
  esac
  if [ "$rc" != "$want_rc" ]; then
    bad "$name" "exit $rc, wanted $want_rc"$'\n'"$out"
    return 0
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
    bad "$name" "right exit, but not for the reason under test ('$needle'):"$'\n'"$out"
    return 0
  fi
  ok "$name ($want)"
}

echo "=== a decline on a line the diff added refuses the close ==="

page "$(thread PRRT_a "skills/orch/SKILL.md" 42 true "$(human 'Declined: pre-existing, out of scope for this PR' "$ADDED_HUNK")")"
run "a resolved thread declining a finding on an added line refuses" refuse "thread=PRRT_a"

page "$(thread PRRT_a "skills/orch/SKILL.md" 42 true "$(human 'Declined: pre-existing' "$ADDED_HUNK")")"
run "the refusal names the file and the line" refuse "path=skills/orch/SKILL.md line=42"

page "$(thread PRRT_a "a.sh" 7 false "$(human 'Declined: not this diff' "$ADDED_HUNK")")"
run "an unresolved thread refuses on the same rule" refuse "thread=PRRT_a"

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Out of scope, tracked separately.' "$ADDED_HUNK"),$(human 'Declined: the supervisor froze this PR' "$ADDED_HUNK")")"
run "the NEWEST reply decides — a later decline refuses" refuse "thread=PRRT_a"

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "$ADDED_HUNK")"),$(thread PRRT_b "b.sh" 9 true "$(human 'Declined: pre-existing' "$ADDED_HUNK")")"
run "every offending thread is counted, not just the first" refuse "detail=2 thread(s)"

# The forms the audited declines were actually written in. A check that only
# saw `Declined:` would have read three of the six shipped defects as clean,
# which is how they shipped.
for opener in "Declined under this PR's freeze. You are right about the mechanism." \
              "Declined, and the passing state is an over-refusal." \
              "Declined. This is the stated limit of the mechanism."; do
  page "$(thread PRRT_a "a.sh" 7 true "$(human "$opener" "$ADDED_HUNK")")"
  run "a decline written \"${opener%% *} ${opener#* }\" refuses" refuse "thread=PRRT_a"
done

page "$(thread PRRT_a "a.sh" 7 true "$(human 'The finding is declined for now' "$ADDED_HUNK")")"
run "the word mid-sentence is not a disposition — only a reply that OPENS with it" ok "verdict=ok"

echo "=== the near-misses that must close cleanly ==="

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: the caller already guards this' "$CONTEXT_HUNK")")"
run "a decline on a context line the diff did not touch closes" ok "verdict=ok"

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: that path is gone' "$REMOVED_HUNK")")"
run "a decline on a removed line closes" ok "verdict=ok"

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Fixed in abc1234: guarded the empty case' "$ADDED_HUNK")")"
run "Fixed in <sha> on an added line closes" ok "verdict=ok"

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Tracked: KEN-885' "$ADDED_HUNK")")"
run "Tracked: <ID> on an added line closes" ok "verdict=ok"

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "$ADDED_HUNK"),$(human 'Fixed in abc1234 after all' "$ADDED_HUNK")")"
run "a later Fixed in reply clears an earlier decline" ok "verdict=ok"

page "$(thread PRRT_a "a.sh" 7 true "$(human 'What do you think?' "$ADDED_HUNK")")"
run "a thread with no disposition reply closes" ok "verdict=ok"

page "$(thread PRRT_a "a.sh" 7 true "$(botc 'Declined: this is a bot quoting itself' "$ADDED_HUNK")")"
run "a bot decline never moves the disposition" ok "verdict=ok"

page ""
run "a PR with no review threads closes" ok "verdict=ok"

echo "=== unreadable evidence is no verdict, never a pass ==="

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "")" | jq -c '.comments.nodes[0].diffHunk = null')"
run "a declined thread with a null anchor exits 2" noverdict "no readable diff anchor"

page "$(printf '{"id":"PRRT_a","path":"a.sh","line":7,"originalLine":7,"isResolved":true,"comments":{"pageInfo":{"hasNextPage":true},"nodes":[%s]}}' "$(human 'Declined: pre-existing' "$ADDED_HUNK")")"
run "a thread past 50 comments exits 2" noverdict "past 50 comments"

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "$ADDED_HUNK")")"
GH_SHIM_FAIL=graphql run "a failed thread read exits 2" noverdict "could not read review threads"
unset GH_SHIM_FAIL

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "$ADDED_HUNK")")"
GH_SHIM_EMPTY=graphql run "a zero-byte thread read exits 2" noverdict "zero bytes"
unset GH_SHIM_EMPTY

printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":null},"nodes":[]}}}}}' >"$fixtures/graphql.json"
run "hasNextPage with no advancing cursor exits 2" noverdict "did not advance"

printf '{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":null},"nodes":[]}}}}}' >"$fixtures/graphql.json"
run "a page with no next-page flag exits 2" noverdict "review thread page shape"

echo "=== the check is not disabled by the merge gate's switches ==="

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "$ADDED_HUNK")")"
REVIEW_GATE_MODE=off run "REVIEW_GATE_MODE=off does not waive the refusal" refuse "thread=PRRT_a"
unset REVIEW_GATE_MODE

page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "$ADDED_HUNK")")"
REVIEW_GATE_THREADS=off run "REVIEW_GATE_THREADS=off does not waive the refusal" refuse "thread=PRRT_a"
unset REVIEW_GATE_THREADS

echo "=== argument contract ==="

rc=0; env PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" REVIEW_GATE_SETTINGS_FILE=/dev/null \
  "$PRED" --declined-on-added-lines --extra >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "a trailing argument is a configuration error, not a gate evaluation" \
  || bad "a trailing argument is a configuration error, not a gate evaluation" "exit $rc"

rc=0; env PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" REVIEW_GATE_SETTINGS_FILE=/dev/null \
  GH_REPO="" PR_NUMBER=1 "$PRED" --declined-on-added-lines >/dev/null 2>&1 || rc=$?
[ "$rc" = 2 ] && ok "an empty GH_REPO exits 2 rather than reading nothing and passing" \
  || bad "an empty GH_REPO exits 2 rather than reading nothing and passing" "exit $rc"

"$PRED" --help | grep -qF -- '--declined-on-added-lines' \
  && ok "--help documents the flag" \
  || bad "--help documents the flag" "not in usage"

echo
echo "--- must-fail control: the check, reverted ---"
# Revert the refusal in a scratch copy of the script — `anchor_added` never
# holds, so no thread is ever an offender — and re-run the two fixtures.
# The added-line fixture must stop refusing (the assertion that proves this
# suite is testing the check and not the fixtures), and the untouched-line
# fixture must close cleanly in both states. The whole scripts directory is
# copied, not the one file: the predicate sources lib/settings.sh from
# beside itself, and a control that could not even load would "pass" for a
# reason that has nothing to do with the check.
CTRL_DIR="$work/reverted"
cp -R "$(dirname "$PRED")" "$CTRL_DIR"
CTRL="$CTRL_DIR/review-predicate.sh"
sed 's/^def anchor_added: .*$/def anchor_added: false;/' "$PRED" >"$CTRL"
chmod +x "$CTRL"
if cmp -s "$CTRL" "$PRED"; then
  bad "control planted nothing — the anchor_added definition did not match"
elif ! bash -n "$CTRL" 2>"$work/ctrl.err"; then
  bad "the reverted control does not parse" "$(cat "$work/ctrl.err")"
else
  page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "$ADDED_HUNK")")"
  run "reverted: the added-line fixture stops refusing — the live refusal is this check's" ok "verdict=ok" "$CTRL"
  page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "$CONTEXT_HUNK")")"
  run "reverted: the untouched-line fixture still closes cleanly" ok "verdict=ok" "$CTRL"
  page "$(thread PRRT_a "a.sh" 7 true "$(human 'Declined: pre-existing' "$CONTEXT_HUNK")")"
  run "live: the untouched-line fixture closes cleanly in both states" ok "verdict=ok"
fi

echo
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
